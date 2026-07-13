import AppKit
import SwiftUI

/// NSHostingView subclass that acts as an NSDraggingDestination.
/// Drop detection is intentionally permissive — we always return .copy
/// for valid file URLs and guard the actual state transition in
/// performDragOperation. This prevents missed drops due to timing races.
///
/// NOTE: intentionally NON-generic (concrete `NSHostingView<OverlayView>`).
/// A generic `NSHostingView` subclass crashes the Swift compiler's IRGen pass
/// while emitting the implicit `deinit` under x86_64 + optimization (Release
/// archive only — arm64 Debug is fine), aborting the notarization archive.
/// Every call site already builds it with `rootView: OverlayView(...)`, so
/// pinning Content to `OverlayView` costs nothing and sidesteps the bug.
final class DroppableHostingView: NSHostingView<OverlayView> {

    // ── URL cache ─────────────────────────────────────────────────────────────
    // pasteboard.readObjects() can stall 150-300 ms in performDragOperation
    // because the source app starts tearing down its drag session the instant
    // the user releases the mouse — the pasteboard IPC round-trip races that
    // teardown and can block the main thread.
    //
    // draggingEntered fires while the drag is still fully in flight (source app
    // is alive and the pasteboard is open), so the read is always fast there.
    // Cache the result and reuse it in performDragOperation so we never touch
    // the pasteboard again at drop time.
    private var cachedDropURLs: [URL] = []
    /// Non-file payload (text / link / raw image) captured at draggingEntered —
    /// materialized into a small local file only when the drop actually lands.
    private var cachedPayload: DropMaterializer.Payload?
    /// Drag carries file PROMISES (Safari tab, Photos, Mail) — the real file is only
    /// written by the source app AFTER we accept the drop.
    private var cachedHasPromise = false
    private static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1      // serial → safe shared accumulator
        return q
    }()

    required init(rootView: OverlayView) {
        super.init(rootView: rootView)
        // Register all file drag flavours — modern + legacy fallback
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.file-url"),
            // "Drag anything" — text selections, links, raw images (no file behind them).
            .string,
            .URL,
            NSPasteboard.PasteboardType("public.url"),
            // Safari link/tab drags: legacy URL-with-title flavours. Without these
            // registered, AppKit never even offers us the drop.
            NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"),
            NSPasteboard.PasteboardType("public.url-name"),
            NSPasteboard.PasteboardType("Apple URL pasteboard type"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
            NSPasteboard.PasteboardType("NSPromiseContentsPboardType"),
            NSPasteboard.PasteboardType("com.apple.Safari.bookmarkDictionaryList"),
            NSPasteboard.PasteboardType("com.apple.safari.tab"),
            .tiff,
            .png,
        ] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        // Transparent layer — prevents gray/white flash before SwiftUI paints
        wantsLayer = true
        layer?.backgroundColor = CGColor.clear
        layer?.borderWidth     = 0
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - NSDraggingDestination

    /// Returning false prevents excessive timer-based draggingUpdated calls.
    /// Movement-based calls (cursor moves within the view) still fire — sufficient
    /// to update the hover state as the cursor crosses the pill boundary.
    var wantsPeriodicDraggingUpdates: Bool { false }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // If AppKit reached us, it owns this gesture. Disarm the global Safari
        // release fallback before reading any payload so one drag cannot commit twice.
        DragMonitor.shared.appKitDragEntered()
#if DEBUG
        dragDiag("ENTERED types: "
            + (sender.draggingPasteboard.types ?? []).map(\.rawValue).joined(separator: " | "))
#endif
        let urls = extractURLs(from: sender.draggingPasteboard)
        if urls.isEmpty {
            // Non-file drag (text / link / raw image) — capture the payload now while
            // the drag pasteboard is fully open; it's written to disk only on drop.
            // Bitmap data is deliberately checked before URL: browser image drags vend
            // both, whereas tab/link drags have no bitmap and still resolve to webURL.
            let payload = DropMaterializer.preferredBrowserPayload(
                from: sender.draggingPasteboard)
            let hasPromise = sender.draggingPasteboard.canReadObject(
                forClasses: [NSFilePromiseReceiver.self], options: nil)
            let declaresImage = DropMaterializer.declaresImage(
                on: sender.draggingPasteboard)
            // Prefer a promise over a text-only payload: a Safari TAB drag offers
            // both a title string and a .webloc promise — the promise has the URL.
            var preferPromise = hasPromise && payload == nil
            if hasPromise, let payload {
                if payload.isText { preferPromise = true }
                // An advertised image whose eager bytes could not be read should stay
                // an image via its promise, never silently degrade to the page URL.
                if declaresImage, !payload.isImage { preferPromise = true }
            }
            if preferPromise {
                cachedHasPromise = true
                cachedPayload = nil
            } else if let payload {
                cachedPayload = payload
            } else {
                return []
            }
            cachedDropURLs = []
            OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
            return .copy
        }
        // Cache here — pasteboard is fully open while the drag is in flight.
        cachedDropURLs = urls
        // Hover only when cursor is actually over the visible pill, not the transparent
        // canvas that surrounds it. The window is 288×96 but the pill is only 240×68
        // pinned to the top — the 28pt strip below the pill is transparent dead space.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Payload already cached from draggingEntered — no second pasteboard read needed.
        // Accept while EITHER file URLs or a non-file payload (text/link/image) is
        // cached; guarding on URLs alone silently refused every "drag anything" drop.
        guard !cachedDropURLs.isEmpty || cachedPayload != nil || cachedHasPromise else { return [] }
        // Re-evaluate hover as the cursor moves within the window so the jelly fires
        // exactly when the cursor crosses into the pill, not into the canvas border.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cachedDropURLs = []
        cachedPayload = nil
        cachedHasPromise = false
        OverlayViewModel.shared.isDragHovering = false
    }

    /// Must return true for performDragOperation to be called.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Clear hover and signal drag-end UNCONDITIONALLY — the user released the
        // mouse button so the drag session is over regardless of payload validity.
        OverlayViewModel.shared.isDragHovering = false
        DragMonitor.shared.dragCompleted()

        var urls = cachedDropURLs
        cachedDropURLs = []
        // File-promise drop (Safari tab, Photos, Mail): accept NOW, the source app
        // writes the real file(s) asynchronously — the session opens on delivery.
        if urls.isEmpty, cachedHasPromise {
            cachedHasPromise = false
            cachedPayload = nil
            if let receivers = sender.draggingPasteboard.readObjects(
                   forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
               !receivers.isEmpty {
                receivePromises(receivers)
                return true
            }
            return false
        }
        cachedHasPromise = false
        // Non-file drop → materialize the captured text / link / image into a small
        // local file so the whole downstream file pipeline works unchanged.
        if urls.isEmpty, let payload = cachedPayload,
           let materialized = DropMaterializer.materialize(payload) {
            urls = [materialized]
        }
        cachedPayload = nil
        guard let first = urls.first else { return false }

        let vm = OverlayViewModel.shared

        // ── Active session: offer add/replace ────────────────────────────────────
        // Stage 2/3 is open — don't replace the session silently. Instead set the
        // pending URLs so the (batch-aware) banner prompt appears inside the card.
        guard case .waitingForDrop = vm.stage else {
            // Only the analysable files can be added to a session.
            let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
            guard !supported.isEmpty else { return false }
            withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                vm.pendingDroppedURLs = supported
            }
            grabFocusAfterDrop()
            return true
        }

        // ── Normal first-drop flow (one or many files → one session) ──────────────
        let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
        if supported.isEmpty {
            vm.stage = .error(
                url: first,
                message: "\"\(first.lastPathComponent)\" can't be analysed.\nDragaway supports PDF, text, images, and code files."
            )
            grabFocusAfterDrop()
            return true
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) {
            vm.setChips(urls: supported)
        }
        grabFocusAfterDrop()
        return true
    }

    /// Receive promised files into the Drops folder, unwrap .webloc links (Safari
    /// tabs) through the normal web path, then open/merge the session on the main
    /// actor. Failures simply produce no session — the drop can never wedge anything.
    private func receivePromises(_ receivers: [NSFilePromiseReceiver]) {
        let dest = DropMaterializer.dropsDirectory()
        var received: [URL] = []                      // mutated only on the serial queue
        let group = DispatchGroup()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: dest, options: [:],
                                          operationQueue: Self.promiseQueue) { url, error in
                if error == nil { received.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                let final = received.map { DropMaterializer.normalizeReceived($0) }
                    .filter { !FileInspector.isUnsupportedFileType($0) }
                guard !final.isEmpty else { return }
                let vm = OverlayViewModel.shared
                if case .waitingForDrop = vm.stage {
                    NotificationCenter.default.post(name: .radialOpenSession, object: final)
                } else {
                    withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                        vm.pendingDroppedURLs = final
                    }
                }
            }
        }
    }

    /// Pull the app + overlay window into focus right after a completed drop, so the
    /// user can immediately type a prompt or use Tab without clicking first.
    ///
    /// The pill window is shown with a plain `orderFront` during the drag (it's a
    /// `.nonactivatingPanel`, so it deliberately does NOT steal focus mid-drag and
    /// cancel the Finder drag session). Once the drop lands the mouse is already
    /// released — there's no live drag to disturb — so it's safe to activate.
    ///
    /// Deferred one run-loop tick to stay clear of the drop's in-flight SwiftUI
    /// layout pass (this codebase aborts if a second AppKit layout re-enters the
    /// constraint solver mid-transition).
    private func grabFocusAfterDrop() {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.window?.makeKey()
        }
    }

    // MARK: - Pill hit-test helper

    /// Returns true if the drag cursor is over the visible pill area.
    ///
    /// In stage 1 the window canvas is 288×96 but the pill is 240×68 pinned to the
    /// top — the bottom 28pt strip is transparent. Without this check `isDragHovering`
    /// would fire for the transparent zone, triggering the jelly wobble while the cursor
    /// appears to be hovering BELOW the pill. In stages 2/3 the whole card is the target
    /// so we return true unconditionally.
    private func isOverPillArea(_ sender: NSDraggingInfo) -> Bool {
        guard case .waitingForDrop = OverlayViewModel.shared.stage else { return true }
        // draggingLocation is in the window's base coordinate system.
        // convert(_:from:nil) maps that to the view's own coordinate space.
        let loc = convert(sender.draggingLocation, from: nil)
        // Pill content: 240×68 pt at base scale, centred horizontally in the
        // 288×96 canvas (24 pt each side) and pinned to the TOP of the canvas
        // (AppKit y=0 is at the BOTTOM, so bottom edge = bounds.height − 68).
        // Both the canvas and the pill content scale by the same multiplier, so
        // the margins stay proportional and the formula stays the same with `s`.
        // NSHostingView.isFlipped == true: y=0 is at the VISUAL top of the view.
        // convert(_:from:nil) maps from the non-flipped window base system into this
        // flipped space, so "top of pill" → small y, "bottom of pill" → larger y.
        // Using y=0 here correctly anchors the rect to the visual top of the canvas
        // (where the pill sits) and covers the full 240×68 pill area.
        // The 28pt transparent strip BELOW the pill has y > pillH in flipped coords
        // and is therefore excluded, which is the intended behaviour.
        return dropTargetRect.contains(loc)
    }

    /// True when a global AppKit screen point is over the visible drop target.
    /// Used only for browser drags whose source never discovers this late-created
    /// NSDraggingDestination. Normal drags continue through isOverPillArea(_:).
    static func isScreenPointOverDropTarget(_ point: NSPoint) -> Bool {
        screenDropTargetFrame()?.contains(point) == true
    }

    /// Current drop target in global AppKit screen coordinates.
    static func screenDropTargetFrame() -> NSRect? {
        guard let view = NSApp.windows
            .compactMap({ $0.contentView as? DroppableHostingView })
            .first(where: { $0.window?.isVisible == true }),
              let window = view.window else { return nil }
        let inWindow = view.convert(view.dropTargetRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    /// Stage 1 accepts only the visible 240×68 pill; later stages accept the card.
    private var dropTargetRect: NSRect {
        guard case .waitingForDrop = OverlayViewModel.shared.stage else { return bounds }
        let s = UIScale(rawValue: UserDefaults.standard.string(forKey: "uiScale") ?? "")?.multiplier ?? 1.0
        let pillW = 240 * s
        let pillH =  68 * s
        return NSRect(x: (bounds.width - pillW) / 2, y: 0, width: pillW, height: pillH)
    }

    // MARK: - Helper

    private func extractURLs(from pasteboard: NSPasteboard) -> [URL] {
        // Primary: modern fileURL type — returns ALL dragged files in order.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }
        // Fallback: legacy NSFilenamesPboardType (older apps, Finder on some OS versions)
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }
}
