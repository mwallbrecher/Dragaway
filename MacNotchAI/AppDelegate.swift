import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: OverlayWindow?
    private var onboardingWindow: NSWindow?
    private var hotkeyPickerWindow: NSWindow?
    private var startupToastWindow: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?
    private var dragOutEndTimer: Timer?          // polls mouse state after a drag-out gesture

    // ── Dismiss-race protection ───────────────────────────────────────────────
    // When hideOverlay() fires, dismissAnimated() starts a 0.14 s alpha fade.
    // If a new drag begins during that window, the fading window is still alive
    // and its DroppableHostingView still observes OverlayViewModel.  A freshly
    // created second window produces two WaitingPillViews both calling jelly
    // animation methods → two concurrent withAnimation{} on the same bindings
    // → SwiftUI invariant violation → EXC_BREAKPOINT.
    //
    // Fix: DON'T nil overlayWindow in hideOverlay().  Instead issue a UUID token
    // that travels with the dismissAnimated completion closure.  ensureOverlayVisible()
    // can safely reuse the fading window by invalidating the token — the completion
    // closure's token-guard then skips orderOut/nil so the window stays alive.
    //
    // isWindowDismissing gates resizeOverlay() so a stage-change resize triggered
    // by reset() (e.g. chips→waitingForDrop) doesn't visually resize a fading window.
    private var dismissToken      = UUID()
    private var isWindowDismissing = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        DragMonitor.shared.startMonitoring()
        observeDragState()
        observeDragOutState()
        observeStageChanges()
        observeChipsExpanded()
        observeChipsTab()
        observeUserDragOffset()
        prewarmSwiftUI()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOnboarding),
            name: .showOnboarding, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleHideOverlay),
            name: .hideOverlay, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowHotkeyPicker),
            name: .showHotkeyPicker, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowCustomDisable),
            name: .showCustomDisable, object: nil
        )

        // Space switches cancel any active system drag and leave DragMonitor in a
        // stale state — pressTimeChangeCount and lastDragChangeCount diverge, making
        // the next drag on the new space fail the pasteboard guard silently.
        // Reset drag state on every space change so the pill can appear fresh.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        // If the user's key screen changes (external display connected/disconnected,
        // lid closed, etc.) reposition the overlay window to the new notch location.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Show onboarding on very first launch.
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showOnboarding()
            }
        }

        // Brief startup toast — let the user know AI Drop is alive and ready.
        // Skip on the very first launch (onboarding already greets them).
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                self.showStartupToast()
            }
        }
    }

    @objc private func handleShowOnboarding()    { showOnboarding()    }
    @objc private func handleHideOverlay()       { hideOverlay()       }
    @objc private func handleShowHotkeyPicker()  { showHotkeyPicker()  }
    @objc private func handleShowCustomDisable() { showCustomDisable() }

    /// Called by macOS whenever the user switches Mission Control spaces.
    /// Resets DragMonitor so stale pasteboard change-counts from the previous
    /// space don't block the pill from appearing on the new space.
    ///
    /// The notification arrives up to ~200 ms after the visual space transition.
    /// If the user starts a new drag on the target space within that window the
    /// Task below fires while a live drag is already in progress — calling
    /// hideOverlay() here would tear down the pill while a file is mid-air
    /// (miscatch) or while AppKit is delivering drag callbacks to the now-
    /// deallocated DroppableHostingView (crash). Guard against both by skipping
    /// the dismiss whenever a drag is already in flight.
    @objc private func handleActiveSpaceChanged() {
        Task { @MainActor in
            DragMonitor.shared.resetAfterSpaceChange()
            // Only dismiss the Stage-1 pill if no drag is currently active.
            if case .waitingForDrop = OverlayViewModel.shared.stage,
               !DragMonitor.shared.isDraggingFile {
                hideOverlay()
            }
        }
    }

    /// Called when screens are added, removed, or change resolution.
    /// Re-positions the overlay window so it stays centred on the correct notch.
    @objc private func handleScreenParametersChanged() {
        Task { @MainActor in
            guard let window = overlayWindow, window.isVisible else { return }
            let anchorLeft = OverlayViewModel.shared.stage.tag > 0
            window.place(
                size: window.frame.size,
                anchorAtNotchCenter: anchorLeft
            )
        }
    }

    // MARK: - Drag observation
    // Stage 1 → pill visible while any file is being dragged.
    // Stage 2 → triggered by a physical DROP on the pill (DroppableHostingView).

    private func observeDragState() {
        DragMonitor.shared.$isDraggingFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                guard let self else { return }
                let vm = OverlayViewModel.shared
                if isDragging {
                    // Only show the pill if we're not already in a later stage.
                    // This also prevents re-triggering during a drag-OUT gesture.
                    if case .waitingForDrop = vm.stage {
                        // Respect the "Disable for X minutes" setting.
                        guard !self.isPillDisabled else { return }
                        self.ensureOverlayVisible()
                    }
                } else {
                    if case .waitingForDrop = vm.stage {
                        // ── Poll-timer race guard ────────────────────────────────
                        // isDraggingFile=false can arrive from two sources:
                        //   a) dragCompleted() — drop WAS caught (stage already .chips → not reached)
                        //   b) poll timer or handleMouseUp() — drag ended without a catch
                        //
                        // The poll timer fires in .common runloop mode (fires even inside
                        // AppKit's .eventTracking drag loop) and can see an empty drag
                        // pasteboard milliseconds BEFORE AppKit delivers performDragOperation
                        // — the source app starts tearing down its session the instant the
                        // mouse is released, racing the poll interval.
                        //
                        // Calling hideOverlay() immediately here would dismiss the window
                        // before performDragOperation arrives, losing the cached URL and
                        // causing a silent drop failure. Fix: defer by 150 ms and re-check.
                        // By then any in-flight performDragOperation has advanced the stage
                        // to .chips (or .error), making the second guard a safe no-op.
                        guard !DragMonitor.shared.isDraggingFile else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self else { return }
                            guard !DragMonitor.shared.isDraggingFile,
                                  case .waitingForDrop = OverlayViewModel.shared.stage else { return }
                            self.hideOverlay()
                        }
                    }
                    // Shelf stays open until the user explicitly closes it.
                    // Drag-out roll-back is handled separately by observeDragOutState().
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Drag-out detection
    //
    // SwiftUI's .onDrag uses an internal AppKit NSDraggingSession that does NOT
    // write to NSPasteboard(name: .drag), so DragMonitor never sees it and
    // isDraggingFile never changes.  Global leftMouseUp monitors are also silenced
    // inside AppKit's .eventTracking runloop mode.
    //
    // Solution: the moment isDraggingOut becomes true, start a 50 ms timer in
    // .common runloop mode (fires in ALL modes, including .eventTracking) that
    // polls NSEvent.pressedMouseButtons.  When the left button is released the
    // drag has ended — apply the stage roll-back and stop the timer.

    private func observeDragOutState() {
        OverlayViewModel.shared.$isDraggingOut
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] draggingOut in
                if draggingOut {
                    self?.startDragOutEndDetector()
                } else {
                    self?.stopDragOutEndDetector()
                }
            }
            .store(in: &cancellables)
    }

    private func startDragOutEndDetector() {
        stopDragOutEndDetector()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Left mouse button no longer held — drag session has ended.
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.handleDragOutEnded()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragOutEndTimer = t
    }

    private func stopDragOutEndDetector() {
        dragOutEndTimer?.invalidate()
        dragOutEndTimer = nil
    }

    @MainActor
    private func handleDragOutEnded() {
        stopDragOutEndDetector()
        let vm = OverlayViewModel.shared
        guard vm.isDraggingOut else { return }
        vm.isDraggingOut = false

        if case .result(let url, _, _) = vm.stage {
            // Stage 3 → stage 2. Keep the AI reply cached so → can restore it.
            // Also collapse chips so the shelf lands in its compact resting state.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                vm.navigateBackToChips(savingResult: vm.stage, url: url)
                vm.isChipsExpanded = false
            }
        } else if case .chips = vm.stage, vm.isChipsExpanded {
            // Stage 2 with chips shown → collapse them.
            withAnimation(.spring(response: 0.18, dampingFraction: 1.0)) {
                vm.isChipsExpanded = false
            }
        }
    }

    private func observeStageChanges() {
        OverlayViewModel.shared.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                // Defer to the NEXT runloop cycle.
                // The sink can fire while SwiftUI is mid-layout (the @Published change
                // and the Combine delivery both happen on the main thread).
                // Calling NSAnimationContext/animator().setFrame() from inside an active
                // AppKit layout pass triggers the recursive "Update Constraints in Window"
                // assertion → abort(). One async hop breaks that synchronous chain.
                DispatchQueue.main.async { self?.resizeOverlay(for: stage) }
            }
            .store(in: &cancellables)
    }

    /// Reposition (not resize) the window as the user drags the grabber handle.
    /// The grabber's DragGesture writes userDragOffset; we apply it to the window
    /// origin here. No deferral needed — setFrameOrigin doesn't run a layout pass.
    private func observeUserDragOffset() {
        // NO .receive(on:) — that schedules an async runloop hop even on the main
        // thread, so the window trailed the cursor by a frame (visible lag). The
        // gesture writes the offset on the main thread, so deliver synchronously and
        // move the window in the same tick. setFrameOrigin runs no layout pass, so
        // this is safe inside the @Published willSet. We use the value the publisher
        // hands us (the property isn't committed yet during willSet).
        OverlayViewModel.shared.$userDragOffset
            .sink { [weak self] offset in
                guard let window = self?.overlayWindow, window.isVisible else { return }
                window.reapplyUserOffset(offset)
            }
            .store(in: &cancellables)
    }

    private func observeChipsExpanded() {
        OverlayViewModel.shared.$isChipsExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeOverlay(for: OverlayViewModel.shared.stage)
                }
            }
            .store(in: &cancellables)
    }

    /// Stage-2 chips window must follow the active prompt tab AND the row count of
    /// the History / Custom lists (both can change while the chips card is up, e.g.
    /// adding a custom prompt via the "+" row). All three feed the same resize.
    private func observeChipsTab() {
        let resize: (Any) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                self?.resizeOverlay(for: OverlayViewModel.shared.stage)
            }
        }
        OverlayViewModel.shared.$chipsTab
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
        PromptStore.shared.$customPrompts
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
        PromptStore.shared.$history
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
    }

    private func observeFollowupsExpanded() {
        OverlayViewModel.shared.$isFollowupsExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeOverlay(for: OverlayViewModel.shared.stage)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay lifecycle

    /// Warms up SwiftUI's hosting infrastructure at launch.
    ///
    /// Creating an NSHostingView causes Metal/CoreAnimation initialisation and the
    /// first SwiftUI layout pass. If this happens on the drag-detection hot path
    /// (first ever file drag) the combined overhead introduces a visible cold-start
    /// delay or, in rare cases, a crash when a layout pass races the first stage
    /// transition. A minimal hidden view created eagerly at launch eliminates both.
    private func prewarmSwiftUI() {
        // Host the ACTUAL chips leaf views (OverlayPrewarmView), not a 1×1 Color.
        // The first real chips render otherwise pays SwiftUI's one-time costs —
        // generic specialisation, Core Text glyph caches, the LiquidGlass/Metal
        // pipeline, NSWorkspace icon service — on the drop hot path, which reads as
        // a hitch between drop and the card appearing (worst right after launch).
        // Rendering it here off-screen pays those costs up front. Sized to the real
        // chips frame so layout warms at the right dimensions; positioned far
        // off-screen with zero alpha so it never paints anything the user can see.
        let hosting = NSHostingView(rootView: OverlayPrewarmView())
        let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 320),
                           styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.alphaValue   = 0
        win.contentView  = hosting
        win.orderBack(nil)               // force a real layout/display pass while hidden
        // Retain for 2 s then release — SwiftUI/Metal are warmed up by then.
        var retained: NSWindow? = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            retained?.orderOut(nil)
            retained = nil
        }
    }

    // MARK: - Startup toast

    /// Shows a compact "AI Drop is ready" banner just below the notch for 5 s,
    /// then spring-fades it out. Called on every launch after onboarding is done.
    private func showStartupToast() {
        guard startupToastWindow == nil else { return }

        let toastW: CGFloat = 390
        let toastH: CGFloat = 56     // matches StartupToastView intrinsic height

        // ── Build the floating panel ────────────────────────────────────────
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toastW, height: toastH),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.isFloatingPanel             = true
        panel.level                       = .floating
        panel.backgroundColor             = .clear
        panel.isOpaque                    = false
        panel.hasShadow                   = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // ── Observable state that drives the SwiftUI spring animation ───────
        let toastState = StartupToastState()
        let hosting = NSHostingView(rootView: StartupToastView(state: toastState))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        panel.contentView = hosting

        // ── Position: centred on screen, just below the notch ──────────────
        if let screen = NSScreen.main {
            let x = (screen.frame.width - toastW) / 2
            // notchBottomY=37 + 10 pt gap = top edge of the toast window
            let y = screen.frame.height - 37 - toastH - 10
            panel.setFrame(NSRect(x: x, y: y, width: toastW, height: toastH),
                           display: false)
        }

        panel.orderFront(nil)
        startupToastWindow = panel

        // Trigger the spring pop-in one run-loop cycle after orderFront so
        // the window is fully composited before the animation starts.
        DispatchQueue.main.async {
            toastState.show()
        }

        // ── Auto-dismiss after 5 s ──────────────────────────────────────────
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            toastState.dismiss {
                self?.startupToastWindow?.orderOut(nil)
                self?.startupToastWindow = nil
            }
        }
    }

    private func ensureOverlayVisible() {
        let s = UIScale.current.multiplier
        let pillSize = CGSize(width: 288 * s, height: 96 * s)

        if let win = overlayWindow {
            // ── Reuse path ───────────────────────────────────────────────────
            // A window exists — it is either already visible (no-op) or mid-dismiss
            // (alpha fading to 0).  In the latter case: invalidate the pending
            // dismiss token so its completion closure no-ops, then snap alpha back
            // to 1 and reset the view model.
            // Full reset is safe here: we're about to show WaitingPillView again,
            // and cancelling the token means the deferred reset in the completion
            // will never fire (token mismatch guard), so there's no double-reset.
            dismissToken       = UUID()    // ← cancels any pending dismiss completion
            isWindowDismissing = false     // ← unblocks resizeOverlay()
            win.alphaValue     = 1
            OverlayViewModel.shared.reset()   // ← stage → .waitingForDrop before orderFront
            win.place(size: pillSize, anchorAtNotchCenter: false)
            win.orderFront(nil)
            startDismissMonitors()
            return
        }

        // ── Create path ──────────────────────────────────────────────────────
        // No window at all — build one fresh.
        let window = OverlayWindow()
        let hostingView = DroppableHostingView(
            rootView: OverlayView(provider: resolveProvider())
        )
        window.contentView = hostingView
        overlayWindow = window

        // Guarantee clean ViewModel state before the window is ever visible.
        // The deferred reset() inside hideOverlay() covers most cases, but on the
        // very first launch (or if a space-change hide raced with a new drag) the
        // deferred closure may not have fired yet — calling reset() here is safe
        // because stage is already .waitingForDrop and SwiftUI hasn't painted yet.
        OverlayViewModel.shared.reset()

        // Pre-position at the notch synchronously BEFORE ordering front.
        // Without this the window flashes at screen origin (0, 0) for one frame.
        overlayWindow?.place(size: pillSize, anchorAtNotchCenter: false)
        overlayWindow?.show()
        startDismissMonitors()
    }

    func hideOverlay() {
        guard overlayWindow != nil else { return }   // already hidden — no double-dismiss
        stopDismissMonitors()

        // ── Partial reset (flags only, stage intact) ──────────────────────────
        // Clears hover/jelly flags but leaves stage unchanged so the SwiftUI
        // content keeps showing whatever was on screen when the user pressed ×.
        OverlayViewModel.shared.partialReset()

        // ── Trigger SwiftUI collapse animation ────────────────────────────────
        // Explicit withAnimation so the collapse uses a DIFFERENT spring than
        // the entry. Entry (in OverlayView.onAppear) uses dampingFraction 0.58
        // (underdamped → bouncy pop-in). Collapse uses dampingFraction 1.0
        // (critically damped → Y goes monotonically 1.0 → 0.02, never overshoots
        // into negative values, never "pops" back into view).
        // anchor: .top = the overlay squishes straight up into the notch.
        // Only Y collapses now (X holds at 1.0 in OverlayView), so this is a clean
        // vertical shrink — no diagonal corner-pull that read as overshoot before.
        // response: 0.24 → calm, unhurried settle into the notch.
        // dampingFraction: 1.0 → critically damped, Y travels straight to its target,
        // no overshoot, no bounce back into view.
        withAnimation(.spring(response: 0.24, dampingFraction: 1.0)) {
            OverlayViewModel.shared.isCollapsing = true
        }

        // ── Token-guarded deferred teardown ──────────────────────────────────
        // 0.34 s gives the calmer collapse spring room to reach Y≈0.02 and settle
        // before the window is ordered out. If ensureOverlayVisible() fires first it
        // writes a new token → this closure becomes a no-op and the window is reused.
        let token = UUID()
        dismissToken       = token
        isWindowDismissing = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.dismissToken == token else { return }
            self.isWindowDismissing = false
            self.overlayWindow?.orderOut(nil)
            self.overlayWindow = nil
            // Full reset now: window is invisible so the stage flip is silent.
            OverlayViewModel.shared.reset()   // also sets isCollapsing = false
        }
        // NOTE: overlayWindow is intentionally NOT nilled here.
        // ensureOverlayVisible() checks for an existing window and reuses it.
    }

    // MARK: - Window sizing

    private func resizeOverlay(for stage: OverlayViewModel.Stage) {
        // Skip resize while a dismiss animation is in flight.  reset() triggers a
        // .waitingForDrop stage change that would otherwise instantly shrink a
        // chips/result-sized window while it's fading out — visible and wrong.
        guard let window = overlayWindow, window.isVisible, !isWindowDismissing else { return }

        let s = UIScale.current.multiplier
        let size: CGSize
        let anchorLeft: Bool   // true = pin left column under notch centre

        switch stage {
        case .waitingForDrop:
            size = CGSize(width: 288 * s, height: 96 * s)   // extra canvas for wobble overflow
            anchorLeft = false

        case .chips(_, let actions):
            if OverlayViewModel.shared.isChipsExpanded {
                // Height follows the ACTIVE prompt tab's row count (capped), using
                // the same ChipsLayout numbers the SwiftUI content region uses so
                // the window always fits exactly. See ChipsLayout.
                let store = PromptStore.shared
                let rows = ChipsLayout.rows(for: OverlayViewModel.shared.chipsTab,
                                            suggested: actions.count,
                                            history: store.history.count,
                                            custom: store.customPrompts.count)
                let contentH = ChipsLayout.contentHeight(rows: rows)
                // header(50) + spacing(10) + tabBar + spacing(10)
                // + content + spacing(10) + prompt(42) + padding(36)
                let h = (50 + 10 + ChipsLayout.tabBarHeight + 10 + contentH + 10 + 42 + 36) * s
                size = CGSize(width: 280 * s, height: max(h, 220 * s))
            } else {
                // Collapsed: header + spacing + prompt field + padding only
                let h = (50 + 10 + 42 + 36) * s
                size = CGSize(width: 280 * s, height: max(h, 148 * s))
            }
            anchorLeft = true

        case .loading:
            size = CGSize(width: 500 * s, height: 280 * s)
            anchorLeft = true

        case .result(_, _, let text):
            // Window is always sized to fit the full expanded layout (result card +
            // prompt + follow-up chips). The follow-up toggle only controls content
            // visibility inside the window — the ScrollView grows into the freed space
            // without the window frame changing at all.
            let lines = max(text.components(separatedBy: "\n").count, text.count / 55)
            let resultH = min(CGFloat(lines) * 20, 200)
            let h = (18 + 44 + resultH + 44 + 20 + 3 * 40 + 44 + 18) * s
            size = CGSize(width: 500 * s, height: min(max(h, 380 * s), 600 * s))
            anchorLeft = true

        case .error:
            size = CGSize(width: 500 * s, height: 220 * s)
            anchorLeft = true
        }

        window.animateTo(size: size, anchorAtNotchCenter: anchorLeft)
    }

    // MARK: - Dismiss monitors

    private func startDismissMonitors() {
        stopDismissMonitors()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.hideOverlay() }
            }
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let window = self.overlayWindow else { return }
                guard !NSPointInRect(NSEvent.mouseLocation, window.frame) else { return }
                // Shelf behaviour: outside clicks only dismiss the Stage-1 pill.
                // Once a file is placed (stages 2/3) the window acts as a desk —
                // it stays open until the user clicks ×, drags the file out, or presses Esc.
                if case .waitingForDrop = OverlayViewModel.shared.stage {
                    self.hideOverlay()
                }
            }
        }
    }

    private func stopDismissMonitors() {
        if let m = escapeMonitor       { NSEvent.removeMonitor(m); escapeMonitor       = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    // MARK: - Disable helper

    /// True when the user has temporarily paused the pill via "Disable for X minutes".
    private var isPillDisabled: Bool {
        UserDefaults.standard.double(forKey: "disabledUntil") > Date().timeIntervalSince1970
    }

    // MARK: - Hotkey picker

    func showHotkeyPicker() {
        if hotkeyPickerWindow == nil {
            let hosting = NSHostingController(rootView: HotkeyPickerView {
                self.hotkeyPickerWindow?.close()
                self.hotkeyPickerWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Drag Hotkey"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            hotkeyPickerWindow = win
        }
        hotkeyPickerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Custom disable duration

    func showCustomDisable() {
        let alert = NSAlert()
        alert.messageText     = "Disable AI Drop for…"
        alert.informativeText = "Enter a duration in minutes (e.g. 45)."
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Minutes"
        field.font = .systemFont(ofSize: 13)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let minutes = Int(text), minutes > 0 else { return }
        let until = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
        UserDefaults.standard.set(until, forKey: "disabledUntil")
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView {
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Welcome to AI Drop"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            onboardingWindow = win
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted { showAccessibilityOnboarding() }
    }

    private func showAccessibilityOnboarding() {
        let alert = NSAlert()
        alert.messageText     = "One permission needed"
        alert.informativeText = "AI Drop needs Accessibility access to detect when you drag files.\n\nOpen System Settings → Privacy & Security → Accessibility and enable AI Drop."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showOnboarding   = Notification.Name("com.aidrop.showOnboarding")
    static let hideOverlay      = Notification.Name("com.aidrop.hideOverlay")
    static let showHotkeyPicker = Notification.Name("com.aidrop.showHotkeyPicker")
    static let showCustomDisable = Notification.Name("com.aidrop.showCustomDisable")
}

// MARK: - Provider resolution

func resolveProvider() -> any AIProvider {
    // Free / Pro tiers route through the hosted Worker (host key lives server-side).
    // Falls back to BYOK until the Worker URL is pasted into BackendConfig.
    if EntitlementStore.shared.tier != .byok, BackendConfig.proxyBaseURL != nil {
        return HostedProvider()
    }

    let raw  = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    let type = AIProviderType(rawValue: raw) ?? .groq

    switch type {
    case .groq:
        return GroqProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.groq") ?? "")
    case .gemini:
        return GeminiProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.gemini") ?? "")
    case .anthropic:
        return AnthropicProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.anthropic") ?? "")
    case .openai:
        return OpenAIProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.openai") ?? "")
    case .ollama:
        return OllamaProvider()
    }
}
