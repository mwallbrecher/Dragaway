import AppKit

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

    // MARK: - Show / hide

    func show() {
        guard !isVisible else { return }
        alphaValue = 1
        orderFront(nil)
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
        var x: CGFloat
        if anchorAtNotchCenter {
            // Keep the notch centre at ~39 % from the window's left edge —
            // the same visual relationship at every UI scale.
            // At base size (280 pt card width) this equals the original 110 pt offset.
            x = (screen.frame.width / 2) - (size.width * (110.0 / 280.0))
        } else {
            x = (screen.frame.width - size.width) / 2
        }

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
