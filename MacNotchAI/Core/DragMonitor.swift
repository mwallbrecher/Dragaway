import AppKit
import Combine

/// Watches for file drags anywhere on screen.
/// Only publishes `isDraggingFile`; the actual stage transition (Stage 1 → 2)
/// is handled by DroppableHostingView via NSDraggingDestination.
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
                DragMonitor.shared.pressTimeChangeCount = NSPasteboard(name: .drag).changeCount
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
    }

    /// Called by DroppableHostingView immediately after a successful drop.
    func dragCompleted() {
        isDraggingFile = false
        stopPolling()
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

        let hasDrag = hasFile(on: pb)
        if hasDrag, !isDraggingFile, !RadialLauncherController.shared.isActive {
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
        }
    }

    private func handleMouseUp() {
        isDraggingFile = false
        stopPolling()
    }

    // MARK: - Private – drag-end polling

    /// Starts a timer that fires in .common runloop mode (works even inside
    /// AppKit's .eventTracking modal drag loop) and clears isDraggingFile
    /// the moment the drag pasteboard empties.
    private func startPolling() {
        stopPolling()
        let t = Timer(timeInterval: 0.10, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Timer fires on the main runloop; MainActor.assumeIsolated is safe.
            MainActor.assumeIsolated {
                if !self.hasFile(on: NSPasteboard(name: .drag)) {
                    self.isDraggingFile = false
                    self.stopPolling()
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
