import AppKit
import Combine
import SwiftUI

/// DEBUG drag diagnostics → /tmp/dragaway_diag.txt (unified log proved unreliable).
func dragDiag(_ s: String) {
#if DEBUG
    let line = "\(Date()) \(s)\n"
    guard let d = line.data(using: .utf8) else { return }
    let path = "/tmp/dragaway_diag.txt"
    if let h = FileHandle(forWritingAtPath: path) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(d)
    } else {
        FileManager.default.createFile(atPath: path, contents: d)
    }
#endif
}

/// Watches for droppable drags anywhere on screen. Normal stage transitions are
/// handled by DroppableHostingView; browser tabs additionally use the bounded
/// late-window fallback below when AppKit never discovers the new destination.
@MainActor
class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published var isDraggingFile = false

    private var dragMonitor:    Any?
    private var mouseUpMonitor: Any?

    // ── Drag-end polling ─────────────────────────────────────────────────────
    // NSEvent.addGlobalMonitorForEvents(.leftMouseUp) is NOT delivered during
    // an active AppKit drag session because macOS runs the drag in the special
    // .eventTracking runloop mode which silences .default-mode global monitors.
    // A Timer added to .common mode fires in EVERY mode (default, eventTracking,
    // modalPanel) and polls the drag pasteboard — when it empties the drag ended.
    private var pollTimer: Timer?

    // ── Stale-pasteboard guard ────────────────────────────────────────────────
    // NSPasteboard(name: .drag) retains its content between drag sessions.
    // Any leftMouseDragged (even with no file) would find the old file URLs and
    // falsely trigger the pill.  We only react when the changeCount increments —
    // which happens exactly once per new drag session (when the source app writes
    // fresh items to the drag pasteboard).
    private var lastDragChangeCount: Int = NSPasteboard(name: .drag).changeCount

    // ── Press-time guard ──────────────────────────────────────────────────────
    // Snapshot the drag pasteboard changeCount the instant the left mouse button
    // goes down.  In handleDrag we only proceed if count EXCEEDS this snapshot —
    // meaning the source app wrote new drag data AFTER the press started.
    // This eliminates false triggers where stale file data in the pasteboard
    // (from a previous drag) would fire the pill on a plain pointer-hold + move.
    private var pressTimeChangeCount: Int = NSPasteboard(name: .drag).changeCount
    private var mouseDownMonitor: Any?

    // ── Late-window browser fallback ─────────────────────────────────────────
    // Safari snapshots eligible destination windows when its tab drag begins. The
    // notch pill is ordered front only AFTER the global monitor sees that drag, so
    // Safari can keep ignoring its perfectly valid NSDraggingDestination forever:
    // no draggingEntered, no hover, no performDragOperation. Cache the best browser
    // payload (bitmap before URL) while
    // the drag pasteboard is readable and, only when AppKit never takes ownership,
    // derive hover/drop from the physical cursor + button state instead.
    private var fallbackPayload: DropMaterializer.Payload?
    private var appKitOwnsCurrentDrag = false
    /// Last moment the fallback hover was ON the pill. Diag showed users reliably
    /// touching the pill, then releasing 40–50pt below it — the exact 240×68 zone is
    /// too unforgiving for a tab drag. A recent hover keeps the release committable.
    private var lastFallbackHoverAt: Date = .distantPast
#if DEBUG
    private var didLogFallbackGeometry = false
#endif

    private init() {}

    func startMonitoring() {
        // Global drag callbacks already fire on the main thread.
        // MainActor.assumeIsolated gives ZERO async hop — pill appears on the
        // very same runloop turn as the first drag event.
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { event in
            MainActor.assumeIsolated { DragMonitor.shared.handleDrag(event) }
        }

        // Snapshot the pasteboard changeCount the instant the mouse button goes
        // down — before any drag source has had a chance to write new data.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { _ in
            MainActor.assumeIsolated {
                let monitor = DragMonitor.shared
                monitor.clearBrowserFallback()
                monitor.pressTimeChangeCount = NSPasteboard(name: .drag).changeCount
            }
        }

        // mouseUp monitor: fast-path for releases outside AppKit's drag loop.
        // Guard: if the left button is already down again a new drag has started —
        // this Up event belongs to the previous press, skip cleanup entirely.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                    DragMonitor.shared.handleMouseUp()
                }
            }
        }
    }

    func stopMonitoring() {
        if let m = dragMonitor      { NSEvent.removeMonitor(m) }
        if let m = mouseUpMonitor   { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        dragMonitor      = nil
        mouseUpMonitor   = nil
        mouseDownMonitor = nil
        stopPolling()
        clearBrowserFallback()
    }

    /// Called as soon as the real NSDraggingDestination receives draggingEntered.
    /// From that moment AppKit is authoritative for the whole gesture, including a
    /// later exit/re-entry, so the release fallback must never create a second drop.
    func appKitDragEntered() {
        appKitOwnsCurrentDrag = true
        fallbackPayload = nil
    }

    /// The overlay was explicitly dismissed (notably via Escape) while a drag was
    /// still live. Keep the normal drag watchdog running, but make a later mouse-up
    /// incapable of reviving the hidden pill as a browser drop.
    func cancelBrowserFallback() {
#if DEBUG
        if fallbackPayload != nil { dragDiag("FALLBACK CANCELLED by hideOverlay (mid-drag!)") }
#endif
        clearBrowserFallback()
    }

    /// Called by DroppableHostingView immediately after a successful drop.
    func dragCompleted() {
        isDraggingFile = false
        stopPolling()
        clearBrowserFallback()
    }

    /// Called when the user switches Mission Control spaces.
    /// Re-syncs the stale-pasteboard guards so the first drag on the new space
    /// isn't blocked by a changeCount left over from the previous session.
    ///
    /// If a drag is already in flight (user started dragging on the target space
    /// before this notification fired) we ONLY update `lastDragChangeCount` —
    /// leaving `isDraggingFile`, the poll timer, and `pressTimeChangeCount` intact.
    /// Resetting those while a live drag is active would cause observeDragState to
    /// call hideOverlay(), tearing down the pill mid-air.
    func resetAfterSpaceChange() {
        let count = NSPasteboard(name: .drag).changeCount
        if isDraggingFile {
            // Active drag on the new space — just advance the seen-count baseline
            // so subsequent drag events aren't treated as stale.
            lastDragChangeCount = count
            return
        }
        isDraggingFile = false
        stopPolling()
        clearBrowserFallback()
        lastDragChangeCount  = count
        pressTimeChangeCount = count
    }

    // MARK: - Private – event handlers

    private func handleDrag(_ event: NSEvent) {
        let pb    = NSPasteboard(name: .drag)
        let count = pb.changeCount

        // Skip events where the pasteboard hasn't changed.
        guard count != lastDragChangeCount else { return }

        // Only react to pasteboard writes that happened AFTER this mouse press.
        // If count == pressTimeChangeCount the data is stale (written in a
        // previous session) — a plain pointer-hold + move must not trigger the
        // pill.  Mark it seen and bail; a real file drag will increment count
        // above pressTimeChangeCount before the first drag event arrives.
        guard count > pressTimeChangeCount else {
            lastDragChangeCount = count   // mark seen so we don't loop
            return
        }
        lastDragChangeCount = count

        // "Drag anything": files AND text selections / links / raw images wake the pill.
        let hasDrag = hasDroppable(on: pb)
#if DEBUG
        // Diagnostics for drags the pill wakes for but can't catch (e.g. Safari tabs):
        // append the DECLARED drag types to /tmp/dragaway_diag.txt once per session.
        if hasDrag, !isDraggingFile {
            let t = (pb.types ?? []).map(\.rawValue).joined(separator: " | ")
            dragDiag("monitor-types: \(t)")
        }
#endif
        if hasDrag, !isDraggingFile, !RadialLauncherController.shared.isActive {
            // Cache only a browser image or HTTP(S) URL. Bitmap bytes win when a
            // browser advertises both the dragged image and its page/source URL.
            fallbackPayload = DropMaterializer.browserFallbackPayload(from: pb)
            appKitOwnsCurrentDrag = false
#if DEBUG
            switch fallbackPayload {
            case .image(let data):
                dragDiag("FALLBACK ARMED imageBytes=\(data.count)")
            case .webURL(let url):
                dragDiag("FALLBACK ARMED url=\(url.absoluteString)")
            case .text, .none:
                break
            }
#endif
            let hk = HotkeyManager.shared

            // Each drag mode (notch pill, radial launcher) has an OPTIONAL trigger
            // key. If any configured trigger is held at drag start, show exactly the
            // matching mode(s); otherwise show every mode whose trigger is "None"
            // (the defaults). Both set to None ⇒ both appear on a plain drag.
            // Master switches first — a disabled mode never shows, whatever its key.
            let pillOn   = hk.pillEnabled
            let radialOn = hk.radialEnabled
            let pillHasKey   = pillOn   && hk.isEnabled
            let radialHasKey = radialOn && !hk.radialModifiers.isEmpty
            let pillHeld     = pillOn   && hk.pillHotkeyHeld()
            let radialHeld   = radialOn && hk.radialModifiersHeld()

            var showPill   = false
            var showRadial = false
            if pillHeld || radialHeld {
                showPill   = pillHeld
                showRadial = radialHeld
            } else {
                showPill   = pillOn   && !pillHasKey    // enabled + no key → default mode
                showRadial = radialOn && !radialHasKey  // enabled + no key → default mode
            }

            // Radial is always full-screen so it keeps tracking far flicks. When it
            // shares the drag with the pill (coexist) it carves out a pill-approach
            // zone near the notch and hands the drop off to the pill there.
            if showRadial {
                let ok = RadialLauncherController.shared.begin(
                    urls: fileURLs(on: pb), coexistWithPill: showPill)
                if !ok { showPill = true }                      // no favorites → fall back to pill
            }
            if showPill {
                isDraggingFile = true
                startPolling()
            }
        } else if !hasDrag {
            isDraggingFile = false
            stopPolling()
            clearBrowserFallback()
        }
    }

    private func handleMouseUp() {
        if commitBrowserFallbackIfPossible() { return }
        isDraggingFile = false
        stopPolling()
        clearBrowserFallback()
    }

    // MARK: - Private – drag-end polling

    /// Starts a timer that fires in .common runloop mode (works even inside
    /// AppKit's .eventTracking modal drag loop) and clears isDraggingFile
    /// the moment the drag pasteboard empties.
    private func startPolling() {
        stopPolling()
        var buttonUpTicks = 0
        let t = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer fires on the main runloop; MainActor.assumeIsolated is safe.
            MainActor.assumeIsolated {
                let buttonIsDown = NSEvent.pressedMouseButtons & 1 != 0

                // Safari may never send draggingEntered to a window that appeared
                // after its tab drag began. Drive the jelly directly until AppKit
                // proves it owns this gesture.
                if self.fallbackPayload != nil, !self.appKitOwnsCurrentDrag {
                    self.updateBrowserFallbackHover()
                    if !buttonIsDown, self.commitBrowserFallbackIfPossible() { return }
                }

                // Fast path: the source app cleared the drag pasteboard (files do this).
                if !self.hasDroppable(on: NSPasteboard(name: .drag)) {
                    // A cached browser payload remains valid even if its source clears the
                    // live pasteboard just before mouse-up. While still pressed, keep
                    // tracking it; on release the commit attempt above is definitive.
                    if buttonIsDown, self.fallbackPayload != nil,
                       !self.appKitOwnsCurrentDrag { return }
                    self.isDraggingFile = false
                    self.stopPolling()
                    self.clearBrowserFallback()
                    return
                }
                // WATCHDOG — text/URL/tab drags often leave STALE content on the drag
                // pasteboard after release, so the check above never fires and
                // isDraggingFile would stay true FOREVER (every future drag then hits
                // the `!isDraggingFile` guard → the pill never appears again until
                // relaunch). The physical button is ground truth: a drag cannot
                // outlive the press. Three consecutive button-up ticks (~0.3 s grace,
                // so a caught drop's dragCompleted() wins first) ⇒ the drag is over,
                // whatever the pasteboard claims.
                if !buttonIsDown {
                    buttonUpTicks += 1
                    if buttonUpTicks >= 3 {
                        self.isDraggingFile = false
                        self.stopPolling()
                        self.clearBrowserFallback()
                    }
                } else {
                    buttonUpTicks = 0
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)   // .common = fires in ALL modes
        pollTimer = t
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        // Snapshot the current changeCount so the next identical pasteboard state
        // (stale data from this drag) doesn't re-trigger handleDrag.
        lastDragChangeCount = NSPasteboard(name: .drag).changeCount
    }

    // MARK: - Private – browser fallback

    private func updateBrowserFallbackHover() {
        guard !appKitOwnsCurrentDrag, fallbackPayload != nil else { return }
        let point = NSEvent.mouseLocation
        let frame = DroppableHostingView.screenDropTargetFrame()
#if DEBUG
        if !didLogFallbackGeometry {
            didLogFallbackGeometry = true
            dragDiag("FALLBACK GEOMETRY mouse=\(point) target=\(String(describing: frame))")
        }
#endif
        let hovering = frame?.contains(point) == true
        if hovering { lastFallbackHoverAt = Date() }
        guard OverlayViewModel.shared.isDragHovering != hovering else { return }
#if DEBUG
        dragDiag("FALLBACK HOVER \(hovering) mouse=\(point)")
#endif
        OverlayViewModel.shared.isDragHovering = hovering
    }

    /// Forgiving commit test: the pill frame padded generously (±70pt sideways,
    /// 90pt below — above is the screen edge anyway), OR the cursor touched the
    /// pill within the last 0.4s. Tab drags carry a large preview under the cursor;
    /// demanding a pixel-exact release lost real drops (see diag 21:27).
    private func isReleaseNearTarget(_ point: NSPoint) -> Bool {
        if Date().timeIntervalSince(lastFallbackHoverAt) < 0.4 { return true }
        guard var f = DroppableHostingView.screenDropTargetFrame() else { return false }
        f = NSRect(x: f.minX - 70, y: f.minY - 90,
                   width: f.width + 140, height: f.height + 90 + 40)
        return f.contains(point)
    }

    /// Returns true only when this call consumed the browser gesture as a drop.
    private func commitBrowserFallbackIfPossible() -> Bool {
#if DEBUG
        // Name the guard that kills a commit attempt — blind guessing wasted a day.
        if fallbackPayload != nil || appKitOwnsCurrentDrag {
            let over = isReleaseNearTarget(NSEvent.mouseLocation)
            dragDiag("FALLBACK COMMIT? appKitOwns=\(appKitOwnsCurrentDrag) payload=\(fallbackPayload != nil) dragging=\(isDraggingFile) nearTarget=\(over) mouse=\(NSEvent.mouseLocation)")
        }
#endif
        guard !appKitOwnsCurrentDrag,
              let payload = fallbackPayload,
              isDraggingFile,
              isReleaseNearTarget(NSEvent.mouseLocation),
              let file = DropMaterializer.materialize(payload) else { return false }

#if DEBUG
        dragDiag("FALLBACK DROP output=\(file.lastPathComponent)")
#endif
        isDraggingFile = false
        stopPolling()
        clearBrowserFallback()

        // Stage mutations are deferred one runloop tick, matching the overlay's
        // constraint-safety invariant and letting Safari finish its drag teardown.
        DispatchQueue.main.async {
            let vm = OverlayViewModel.shared
            if case .waitingForDrop = vm.stage {
                NotificationCenter.default.post(name: .radialOpenSession, object: [file])
            } else {
                withAnimation(.spring(response: 0.36, dampingFraction: 1.0)) {
                    vm.pendingDroppedURLs = [file]
                }
            }
        }
        return true
    }

    private func clearBrowserFallback() {
        fallbackPayload = nil
        appKitOwnsCurrentDrag = false
        lastFallbackHoverAt = .distantPast
#if DEBUG
        didLogFallbackGeometry = false
#endif
        OverlayViewModel.shared.isDragHovering = false
    }

    // MARK: - Private – pasteboard inspection

    /// File URLs currently on the drag pasteboard (used to seed the radial launcher).
    private func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty { return urls }

        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    /// Anything the pill can accept: real files, or a materializable payload
    /// (text selection / web link / raw image — see DropMaterializer).
    private func hasDroppable(on pasteboard: NSPasteboard) -> Bool {
        if hasFile(on: pasteboard) || DropMaterializer.hasPayload(on: pasteboard) { return true }
        // File PROMISES (Safari tab → .webloc, Photos, Mail) — content arrives only
        // after an accepted drop, but the promise types are declared during the drag.
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        return !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes)
    }

    private func hasFile(on pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty { return true }

        if let paths = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String], !paths.isEmpty { return true }

        return false
    }
}
