import AppKit
import Quartz

class OverlayWindow: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 68),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel             = true
        level                       = .floating
        backgroundColor             = .clear
        isOpaque                    = false
        hasShadow                   = false
        isMovableByWindowBackground = false
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Quick Look (QLPreviewPanelController)
    //
    // QLPreviewPanel walks the key window's responder chain looking for a controller.
    // The overlay is `canBecomeKey`, so once it's made key (QuickLookController.present)
    // these hooks let the shared panel preview the dropped session files. The data source
    // is the QuickLookController singleton. Esc inside the panel is delivered to OUR app,
    // so the global Esc dismiss monitor doesn't fire — the panel closes, the session stays.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate   = QuickLookController.shared
        panel.currentPreviewItemIndex = QuickLookController.shared.currentIndex
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate   = nil
    }

    // MARK: - Show / hide

    func show() {
        alphaValue = 1                    // also revives a PARKED window
        OverlayViewModel.shared.windowShown = true
        guard !isVisible else { return }
        orderFront(nil)
    }

    // MARK: - Persistent parking (drag-snapshot fix)
    //
    // Drag sources like Safari enumerate the eligible destination windows when THEIR
    // drag begins — a window created mid-drag never receives draggingEntered, however
    // correct its registered types are. So the overlay window is created once at app
    // launch and, when "hidden", is PARKED instead of ordered out: alpha 0, shrunk to
    // a strip inside the physical notch housing (nothing clickable lives there, so the
    // invisible window can't steal clicks or menu-bar drags). Being ordered-in since
    // before any drag starts makes it part of every source's destination snapshot.
    func park() {
        OverlayViewModel.shared.windowShown = false
        // NOT 0: fully transparent windows are excluded from the window server's
        // drag-destination candidates (verified: Safari's tab-drag snapshot never
        // delivered draggingEntered at alpha 0). 0.01 sits inside the black notch
        // housing and is invisible to the eye but real to the drag system.
        alphaValue = 0.01
        setFrame(Self.parkedFrame(), display: false)
#if DEBUG
        dragDiag("PARK frame=\(frame) visible=\(isVisible)")
#endif
    }

    static func parkedFrame() -> NSRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return NSRect(x: 0, y: 0, width: 2, height: 2)
        }
        // Notch housing height when present (safe-area top); 2pt sliver otherwise.
        let inset = screen.safeAreaInsets.top
        let h: CGFloat = inset > 1 ? inset : 2
        let w: CGFloat = 160
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    /// Fade the window to alpha 0 over 0.14 s, then call `completion`.
    ///
    /// The caller is responsible for `orderOut` / cleanup inside `completion`.
    /// Keeping `orderOut` out of this method lets AppDelegate cancel a pending
    /// dismiss (by ignoring the completion) when a new drag interrupts the fade —
    /// preventing the "two live windows" race that caused the EXC_BREAKPOINT crash.
    func dismissAnimated(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }) {
            // Reset alpha so the window is ready for potential reuse.
            self.alphaValue = 1
            completion?()
        }
    }

    // MARK: - Positioning

    // Remembered so reapplyUserOffset() can recompute the frame at the current
    // size/anchor when the user drags the grabber, without resizing the window.
    private var lastSize: CGSize = CGSize(width: 240, height: 68)
    private var lastAnchorAtNotchCenter = false

    /// Place the window at the correct notch position instantly — call BEFORE show().
    func place(size: CGSize, anchorAtNotchCenter: Bool) {
        lastSize = size
        lastAnchorAtNotchCenter = anchorAtNotchCenter
        setFrame(notchFrame(for: size, anchorAtNotchCenter: anchorAtNotchCenter,
                            offset: OverlayViewModel.shared.userDragOffset), display: false)
    }

    /// Re-apply the notch frame at the existing size with an explicit drag offset.
    /// Called synchronously as the user drags (offset changes, size doesn't).
    /// The offset is passed in rather than read from the VM because this runs from
    /// the @Published willSet, before the stored property has been committed.
    func reapplyUserOffset(_ offset: CGSize) {
        let f = notchFrame(for: lastSize, anchorAtNotchCenter: lastAnchorAtNotchCenter, offset: offset)
        guard frame.origin != f.origin else { return }
        setFrameOrigin(f.origin)
    }

    /// Resize and reposition the window instantly.
    ///
    /// We intentionally do NOT use NSAnimationContext / animator().setFrame() here.
    /// The animated proxy drives the window frame through intermediate sizes at 60 fps;
    /// AppKit runs a full constraint-solving layout pass on each intermediate frame.
    /// When those intermediate sizes are inconsistent with the NSHostingView's fixed-width
    /// SwiftUI subviews the solver cannot converge → recursive "Update Constraints in
    /// Window" → abort().  All visual animation is handled by SwiftUI transitions and
    /// spring modifiers inside the content view, so the instant frame change is invisible
    /// to the user — they only see the black content shape morphing smoothly.
    func animateTo(size: CGSize, anchorAtNotchCenter: Bool) {
        lastSize = size
        lastAnchorAtNotchCenter = anchorAtNotchCenter
        let newFrame = notchFrame(for: size, anchorAtNotchCenter: anchorAtNotchCenter,
                                  offset: OverlayViewModel.shared.userDragOffset)
        guard frame != newFrame else { return }
        // display: false — do NOT trigger an immediate AppKit redraw here.
        // display: true causes AppKit to start a layout pass synchronously inside
        // setFrame; if a SwiftUI transition is already mid-flight (e.g. pill → chips)
        // that second layout pass re-enters the constraint solver before it has
        // finished, producing "more Update Constraints in Window passes than views" → abort().
        // AppKit will schedule its own display on the next run-loop cycle automatically.
        setFrame(newFrame, display: false)
    }

    // MARK: - Private helpers

    private func notchFrame(for size: CGSize, anchorAtNotchCenter: Bool, offset: CGSize) -> NSRect {
        // NSScreen.main is transiently nil during space/screen transitions.
        // Fall through the chain rather than returning the current (possibly
        // zero-size) frame — a zero-size setFrame triggers a layout pass with
        // unsatisfiable constraints → crash.
        guard let screen = NSScreen.main
                        ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })
                        ?? NSScreen.screens.first
        else { return frame }

        let notchBottomY: CGFloat = 37
        var y = screen.frame.height - notchBottomY - size.height
        // The notch camera sits at the screen's horizontal centre. Centre the
        // window so the card — and its centre grabber handle — lands directly
        // below the notch, at every stage and UI scale. This matches the stage-1
        // pill (which is already centred). The legacy `anchorAtNotchCenter` branch
        // biased the expanded card ~110 pt (≈39 %) left of centre, which pushed
        // the *window centre* ~30 pt right of the notch (≈54 pt for the result
        // card) — visible because the grabber no longer aligned with the camera.
        _ = anchorAtNotchCenter   // retained for call-site compatibility
        var x = (screen.frame.width - size.width) / 2

        // Apply the user's manual drag offset on TOP of the notch-anchored origin.
        // Screen coords are bottom-up, so +offset.height moves the window up.
        // The offset is reset to .zero on each fresh drop, so the default origin
        // stays pinned to the notch — only the active session can be nudged.
        x += offset.width
        y += offset.height

        // Clamp so the window can never be dragged fully off-screen (keep ≥ 80 pt
        // of width on screen and the top edge below the menu bar region).
        let vf = screen.visibleFrame
        x = min(max(x, vf.minX - size.width + 80), vf.maxX - 80)
        y = min(max(y, vf.minY + 20), screen.frame.height - notchBottomY - size.height)

        return NSRect(origin: CGPoint(x: x, y: y), size: size)
    }
}
