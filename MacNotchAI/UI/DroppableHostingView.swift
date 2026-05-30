import AppKit
import SwiftUI

/// NSHostingView subclass that acts as an NSDraggingDestination.
/// Drop detection is intentionally permissive — we always return .copy
/// for valid file URLs and guard the actual state transition in
/// performDragOperation. This prevents missed drops due to timing races.
final class DroppableHostingView<Content: View>: NSHostingView<Content> {

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
    private var cachedDropURL: URL?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // Register all file drag flavours — modern + legacy fallback
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.file-url"),
        ])
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
        guard let url = extractURL(from: sender.draggingPasteboard) else { return [] }
        // Cache here — pasteboard is fully open while the drag is in flight.
        cachedDropURL = url
        // Hover only when cursor is actually over the visible pill, not the transparent
        // canvas that surrounds it. The window is 288×96 but the pill is only 240×68
        // pinned to the top — the 28pt strip below the pill is transparent dead space.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // URL already cached from draggingEntered — no second pasteboard read needed.
        guard cachedDropURL != nil else { return [] }
        // Re-evaluate hover as the cursor moves within the window so the jelly fires
        // exactly when the cursor crosses into the pill, not into the canvas border.
        OverlayViewModel.shared.isDragHovering = isOverPillArea(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        cachedDropURL = nil
        OverlayViewModel.shared.isDragHovering = false
    }

    /// Must return true for performDragOperation to be called.
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Clear hover and signal drag-end UNCONDITIONALLY — the user released the
        // mouse button so the drag session is over regardless of payload validity.
        OverlayViewModel.shared.isDragHovering = false
        DragMonitor.shared.dragCompleted()

        guard let url = cachedDropURL else { cachedDropURL = nil; return false }
        cachedDropURL = nil

        let vm = OverlayViewModel.shared

        // ── Active session: offer add/replace ────────────────────────────────────
        // Stage 2/3 is open — don't replace the session silently. Instead set the
        // pending URL so the banner prompt appears inside the card.
        guard case .waitingForDrop = vm.stage else {
            // Unsupported types can't be added to a session either
            guard !FileInspector.isUnsupportedFileType(url) else { return false }
            withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                vm.pendingSecondFileURL = url
            }
            return true
        }

        // ── Normal first-file flow ────────────────────────────────────────────────
        if FileInspector.isUnsupportedFileType(url) {
            vm.stage = .error(
                url: url,
                message: "\"\(url.lastPathComponent)\" can't be analysed.\nAI Drop supports PDF, text, images, and code files."
            )
            return true
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 1.0)) {
            vm.setChips(url: url)
        }
        return true
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
        let s = UIScale(rawValue: UserDefaults.standard.string(forKey: "uiScale") ?? "")?.multiplier ?? 1.0
        let pillW = 240 * s
        let pillH =  68 * s
        // NSHostingView.isFlipped == true: y=0 is at the VISUAL top of the view.
        // convert(_:from:nil) maps from the non-flipped window base system into this
        // flipped space, so "top of pill" → small y, "bottom of pill" → larger y.
        // Using y=0 here correctly anchors the rect to the visual top of the canvas
        // (where the pill sits) and covers the full 240×68 pill area.
        // The 28pt transparent strip BELOW the pill has y > pillH in flipped coords
        // and is therefore excluded, which is the intended behaviour.
        let pillRect = NSRect(x: (bounds.width - pillW) / 2,
                              y: 0,
                              width: pillW, height: pillH)
        return pillRect.contains(loc)
    }

    // MARK: - Helper

    private func extractURL(from pasteboard: NSPasteboard) -> URL? {
        // Primary: modern fileURL type
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let first = urls.first {
            return first
        }
        // Fallback: legacy NSFilenamesPboardType (older apps, Finder on some OS versions)
        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], let path = paths.first {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
