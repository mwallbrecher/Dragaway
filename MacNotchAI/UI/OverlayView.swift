import SwiftUI
import AppKit

// MARK: - Root overlay view

struct OverlayView: View {
    @ObservedObject private var vm          = OverlayViewModel.shared
    @ObservedObject private var dragMonitor = DragMonitor.shared
    let provider: any AIProvider

    @AppStorage("uiScale") private var uiScaleRaw = UIScale.small.rawValue
    private var scale: CGFloat { UIScale(rawValue: uiScaleRaw)?.multiplier ?? 1.0 }

    // Entry animation gate. Set to true by onAppear on the first frame.
    // Never reset to false — collapse is driven by vm.isCollapsing instead,
    // so both directions share one scaleEffect without a @State write from outside.
    @State private var appeared = false

    // Shared namespace for the close button matchedGeometryEffect —
    // animates the X from FileHeaderView (stages 1-2) to the result icon bar (stage 3).
    @Namespace private var closeNS

    // True = pill / card is at full visual scale.
    // False = collapsed sliver (either before entry or during/after close animation).
    private var isAtFullScale: Bool { appeared && !vm.isCollapsing }

    private var cornerRadius: CGFloat { 20 }

    var body: some View {
        // ── Stage routing ─────────────────────────────────────────────────────
        // Stage 1 owns its own black background + clipShape so the outer ZStack
        // stays transparent in the 288×96 canvas, giving the wobble scaleEffect
        // room to overflow without hitting the window boundary.
        // Stages 2/3 share a card ZStack that applies background + clip itself.
        Group {
            switch vm.stage {
            case .waitingForDrop:
                // Pin pill to the TOP of the 288×96 canvas so its top edge stays
                // flush with the notch bottom — matching the pre-canvas-expansion
                // position. The 28 pt transparent gap below gives vertical wobble
                // headroom (jellyY 1.09 → +3 pt, well within the extra space).
                WaitingPillView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)

            default:
                // ZStack lets the SecondFilePromptBanner overlay the bottom of the
                // card. Both card content and banner are wrapped together BEFORE
                // liquidGlass so the clipShape includes the banner.
                ZStack(alignment: .bottom) {
                    Group {
                        switch vm.stage {
                        case .chips(let url, let actions):
                            ChipsColumnView(fileURL: url, actions: actions, provider: provider, closeNS: closeNS)
                                .transition(.asymmetric(
                                    insertion: .scale(scale: 0.88, anchor: .top)
                                        .combined(with: .opacity),
                                    removal: .scale(scale: 0.92, anchor: .top)
                                        .combined(with: .opacity)
                                ))
                        case .loading(let url, _), .result(let url, _, _), .error(let url, _):
                            TwoColumnView(fileURL: url, provider: provider, closeNS: closeNS)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .opacity
                                ))
                        default:
                            EmptyView()
                        }
                    }
                    // Blur + dim the card content itself when a second-file drag is
                    // in progress so the session is visible as a ghosted backdrop.
                    // The overlay only adds the icon/text on top — no opaque layer.
                    .blur(radius: (dragMonitor.isDraggingFile && vm.pendingSecondFileURL == nil) ? 3.5 : 0)
                    .opacity((dragMonitor.isDraggingFile && vm.pendingSecondFileURL == nil) ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.22),
                               value: dragMonitor.isDraggingFile && vm.pendingSecondFileURL == nil)

                    // Second-file drag overlay — darkens the card and shows a hint
                    // the moment the user starts dragging ANY file while a session is
                    // open, even before they bring it near the notch. Hidden once the
                    // drop lands and the banner takes over.
                    if dragMonitor.isDraggingFile, vm.pendingSecondFileURL == nil {
                        SecondFileDragOverlay()
                            .transition(.opacity)
                    }

                    // Second-file prompt banner — spring-slides up from the bottom
                    // edge of the card when a second file is dropped mid-session.
                    if vm.pendingSecondFileURL != nil {
                        SecondFilePromptBanner(provider: provider)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.20),
                            value: dragMonitor.isDraggingFile && vm.pendingSecondFileURL == nil)
                .animation(.spring(response: 0.35, dampingFraction: 0.72),
                            value: vm.pendingSecondFileURL != nil)
                .liquidGlass(cornerRadius: cornerRadius, tintOpacity: 0.60)
                // Elastic landing deform on expand/collapse. Anchor .top pins the
                // notch edge so only the BOTTOM edge reacts. Purely visual (a
                // scaleEffect — NSView bounds + window size unchanged), so it can
                // overbounce without re-entering the constraint solver.
                //
                // Timing matters: the keyframe HOLDS at 1.0 for the first ~0.26 s
                // while the monotonic easeInOut height reflow carries the bottom
                // edge to its final position. Only THEN does it squash (impact) and
                // rebound past 1.0 (stretch) before settling — so the overshoot reads
                // as the bottom edge landing, not as the card deforming on the way.
                .keyframeAnimator(initialValue: 1.0, trigger: vm.isChipsExpanded) { card, scaleY in
                    card.scaleEffect(x: 1.0, y: scaleY, anchor: .top)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(1.0, duration: 0.20)   // wait out the (faster) reflow
                        CubicKeyframe(0.94, duration: 0.07)   // squash on impact
                        SpringKeyframe(1.0, duration: 0.32,
                                       spring: Spring(response: 0.26, dampingRatio: 0.62))
                    }
                }
                // Whole card is a window-drag handle (low-priority gesture, so
                // buttons / prompt field / scroll view / file drag-out still win).
                .windowDrag()
                // Movable-window grabber — thin line at top center that expands on
                // hover/drag. A visible affordance on top of the whole-card drag.
                .overlay(alignment: .top) { WindowGrabber() }
                .transition(.identity)
            }
        }
        .environment(\.uiScale, scale)
        .compositingGroup()

        // ── Content hide on collapse ──────────────────────────────────────────
        // Snap text/icons to invisible the moment isCollapsing fires so the
        // user never sees content squishing during the Y-scale collapse below.
        // Uses a dedicated fast ease-out that overrides the ambient withAnimation
        // spring coming from AppDelegate.hideOverlay() for just this property.
        .opacity(vm.isCollapsing ? 0 : 1)
        .animation(.easeOut(duration: 0.06), value: vm.isCollapsing)

        // ── Entry / collapse scale ────────────────────────────────────────────
        // Content is already gone; only the bare background shell collapses.
        // Entry  : appeared false→true on onAppear → bouncy pop-in spring.
        // Dismiss: isCollapsing false→true via withAnimation in hideOverlay()
        //          → fast critically-damped spring, no overshoot, no bounce.
        // Reuse  : reset() sets isCollapsing=false while appeared stays true
        //          → isAtFullScale flips true, entry spring re-plays.
        // NOTE: scaleEffect is a purely visual transform — NSView bounds and
        // the drag hitbox are always the full 288×96 canvas.
        //
        // X depends ONLY on `appeared`: it pops 0.78 → 1.0 on entry but HOLDS at 1.0
        // during collapse (isCollapsing never touches it). That turns the close
        // animation into a clean vertical squish into the notch rather than a
        // diagonal corner-pull, which is what read as overshoot before. Y still rides
        // isAtFullScale — up on entry, down to a sliver on collapse.
        .scaleEffect(x: appeared ? 1.0 : 0.78,
                     y: isAtFullScale ? 1.0 : 0.02,
                     anchor: .top)
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: appeared)

        // ── Jelly wobble (stage 1 only) ──────────────────────────────────────
        // Driven by direct withAnimation calls in OverlayViewModel. No Tasks here.
        // In stages 2-4 both values are always 1.0, so this is a no-op.
        // Stage-change animation smoothly returns jelly to 1×1 when pill exits.
        .scaleEffect(
            x: vm.stage.tag == 0 ? vm.jellyX : 1.0,
            y: vm.stage.tag == 0 ? vm.jellyY : 1.0,
            anchor: .top
        )
        .animation(.spring(response: 0.30, dampingFraction: 1.0), value: vm.stage.tag)

        // Trigger entry animation. onAppear fires before the first committed frame
        // so SwiftUI batches the state change and the animation together — no Task
        // scheduling, no async race, no multi-phase timing.
        .onAppear { appeared = true }
    }
}

// MARK: - Movable-window grabber

/// Thin line centered at the top edge of the stage-2/3 card. Collapsed by default;
/// expands + brightens on hover or while dragging. Dragging it moves the window by
/// writing vm.userDragOffset (applied to the window origin in OverlayWindow).
/// Deliberately NOT isMovableByWindowBackground — that would hijack file drops.
private struct WindowGrabber: View {
    @Environment(\.uiScale) private var scale
    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        let active = isHovered || isDragging
        VStack(spacing: 0) {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(active ? 0.55 : 0.20))
                .frame(width: (active ? 52 : 30) * scale, height: 4 * scale)
                .animation(.spring(response: 0.26, dampingFraction: 0.82), value: active)
            Spacer(minLength: 0)
        }
        // Tall, full-width hit strip so the line is easy to grab without stealing
        // clicks from the header buttons further down.
        .frame(maxWidth: .infinity)
        .frame(height: 16 * scale)
        .padding(.top, 5 * scale)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .windowDrag(isDragging: $isDragging)
        .help("Drag to move")
    }
}

// MARK: - Window-drag gesture

/// Drags the overlay window by writing vm.userDragOffset. Attach to the grabber
/// AND the whole card so the user can move the window from anywhere on it.
///
/// Tracks the ABSOLUTE cursor position via NSEvent.mouseLocation (screen coords,
/// y-up) rather than the DragGesture's translation. SwiftUI's .global translation
/// is measured relative to the window — and the window is moving as we drag — which
/// created a feedback loop (jitter/glitch). Screen coordinates are independent of
/// the window, so the move tracks the cursor 1:1 with no drift.
///
/// Uses .gesture (low priority), so child controls — buttons, the prompt field, the
/// scroll view, and file-pill drag-out — keep their own gestures; the window only
/// moves when the drag starts on empty card surface.
private struct WindowDragModifier: ViewModifier {
    @ObservedObject private var vm = OverlayViewModel.shared
    @Binding var isDragging: Bool
    @State private var anchorMouse: CGPoint? = nil
    @State private var startOffset: CGSize = .zero

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if anchorMouse == nil {
                        anchorMouse = mouse
                        startOffset = vm.userDragOffset
                        isDragging  = true
                    }
                    let anchor = anchorMouse ?? mouse
                    vm.userDragOffset = CGSize(
                        width:  startOffset.width  + (mouse.x - anchor.x),
                        height: startOffset.height + (mouse.y - anchor.y)
                    )
                }
                .onEnded { _ in
                    anchorMouse = nil
                    isDragging  = false
                }
        )
    }
}

private extension View {
    /// Make this view a drag handle for the overlay window.
    func windowDrag(isDragging: Binding<Bool> = .constant(false)) -> some View {
        modifier(WindowDragModifier(isDragging: isDragging))
    }
}

// MARK: - Stage 1: Waiting pill

private struct WaitingPillView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 10 * scale) {
            // Icon morphs when file hovers
            Image(systemName: vm.isDragHovering ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundColor(vm.isDragHovering ? .white : .white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))

            Text(vm.isDragHovering ? "  Release file " : "Drop file here")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: vm.isDragHovering)
        }
        .padding(.horizontal, 22 * scale)
        .padding(.vertical, 18 * scale)
        // Height = 68 × scale so cornerRadius = 34 × scale → perfect stadium shape.
        .frame(width: 240 * scale, height: 68 * scale)
        // Background + clip live HERE (inside WaitingPillView), not on the outer
        // canvas in OverlayView. The outer 288×96 canvas stays transparent so the
        // wobble scaleEffect (applied after this clip in OverlayView) can overflow
        // freely without hitting the window clip boundary.
        //
        // Hover: apple system-blue tint fades in; tintOpacity drops slightly so the
        // blue colour reads through the dark base rather than washing out.
        .liquidGlass(
            cornerRadius: 34 * scale,
            tintOpacity: vm.isDragHovering ? 0.42 : 0.58,
            colorTint: vm.isDragHovering ? Color.accentColor : .clear
        )
        .animation(.easeInOut(duration: 0.18), value: vm.isDragHovering)
        // Jelly: call withAnimation directly in the VM — no Tasks, no sleep timers.
        // initial: false so it doesn't fire on view creation and call stopJellyHover()
        // immediately (which was spawning a wobble Task with jellyX=0.94 before any
        // hover occurred, racing against the entry animation → EXC_BREAKPOINT).
        .onChange(of: vm.isDragHovering, initial: false) { _, hovering in
            if hovering { vm.startJellyHover() } else { vm.stopJellyHover() }
        }
    }
}

// MARK: - Stage 2: Chips column only

private struct ChipsColumnView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @ObservedObject private var store = PromptStore.shared
    @Environment(\.uiScale) private var scale

    // Inline "add custom prompt" composer state (Custom tab "+" row).
    @State private var isAddingCustom = false
    @State private var newCustom = ""
    @FocusState private var customFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            FileHeaderView(fileURL: fileURL, closeNS: closeNS)
                .zIndex(100)   // floating name badge must render above chips below it

            if vm.isChipsExpanded {
                chipsTabBar
                    .transition(.asymmetric(
                        // Delay insertion so the window finishes resizing before
                        // the bar pops in — prevents content appearing in a too-small frame.
                        insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.13)),
                        removal:   .opacity.animation(.easeIn(duration: 0.07))
                    ))

                chipsTabContent
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top))
                                           .animation(.spring(response: 0.28, dampingFraction: 0.7).delay(0.15)),
                        removal:   .opacity.animation(.easeIn(duration: 0.07))
                    ))
            }

            PromptField(text: $vm.customPrompt, onSubmit: runCustomPrompt)

            // Handoff confirmation pill — pops in ~0.18 s after navigation, stays
            // 6 s then dissolves with a wobbly spring so it feels alive not abrupt.
            if let name = vm.handoffProviderName {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.green)
                    Text("Session opened in \(name).")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
                .padding(.horizontal, 10 * scale)
                .padding(.vertical, 6 * scale)
                .frame(maxWidth: .infinity, alignment: .center)
                .background(Color.green.opacity(0.10))
                .liquidGlassCapsule(tintOpacity: 0.08)
                .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
            }
        }
        .padding(18 * scale)
        .frame(width: 280 * scale, alignment: .topLeading)
    }

    private func runAction(_ action: AIAction) {
        setStage(.loading(url: fileURL, action: action))
        let additionalURLs = vm.additionalFileURLs
        Task {
            do {
                let (content, imageURL, truncated) = try await buildMultiFileContent(
                    primary: fileURL, additional: additionalURLs)
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                OverlayViewModel.shared.contentTruncated = truncated
                SessionHistoryStore.shared.recordTurn(
                    primary: fileURL, additional: additionalURLs,
                    action: action, prompt: nil, result: text)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    private func runCustomPrompt() { runCustomPromptText(vm.customPrompt) }

    /// Run an arbitrary free-text prompt against the current session and log it to
    /// History. Used by the prompt field (typed) and by tapping a History/Custom chip.
    private func runCustomPromptText(_ raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        store.recordHistory(prompt)        // log every run to the History tab
        vm.customPrompt = ""
        vm.cachedResult = nil
        let action = AIAction.freeform
        setStage(.loading(url: fileURL, action: action))
        let additionalURLs = vm.additionalFileURLs
        Task {
            do {
                let (baseContent, imageURL, truncated) = try await buildMultiFileContent(
                    primary: fileURL, additional: additionalURLs)
                let finalContent = imageURL != nil
                    ? "Question: \(prompt)"
                    : "Question: \(prompt)\n\n--- Documents ---\n\(baseContent)"
                let text = try await provider.complete(action: action, content: finalContent, imageURL: imageURL)
                OverlayViewModel.shared.contentTruncated = truncated
                SessionHistoryStore.shared.recordTurn(
                    primary: fileURL, additional: additionalURLs,
                    action: action, prompt: prompt, result: text)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    // ── Prompt tabs: Suggested / History / Custom ─────────────────────────────

    /// Logical (unclamped) row count of the active tab — must match the value
    /// AppDelegate.resizeOverlay uses so the window height fits the content region.
    private var currentRowCount: Int {
        ChipsLayout.rows(for: vm.chipsTab,
                         suggested: actions.count,
                         history: store.history.count,
                         custom: store.customPrompts.count)
    }

    private var chipsTabBar: some View {
        // Spacing 0: each tabButton already carries transparent hit-padding,
        // so the buttons sit flush with no dead zones between them.
        HStack(spacing: 0) {
            tabButton(.suggested, icon: "sparkles.2",        help: "Suggested")
            tabButton(.history,   icon: "list.bullet",       help: "History")
            tabButton(.custom,    icon: "slider.vertical.3",  help: "Custom prompts")
            Spacer(minLength: 0)
        }
        .frame(height: ChipsLayout.tabBarHeight * scale)
    }

    @ViewBuilder
    private func tabButton(_ tab: OverlayViewModel.ChipsTab, icon: String, help: String) -> some View {
        let selected = vm.chipsTab == tab
        Button {
            guard vm.chipsTab != tab else { return }
            isAddingCustom = false          // close any open composer when switching
            withAnimation(.easeInOut(duration: 0.22)) { vm.chipsTab = tab }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundColor(selected ? .white : .white.opacity(0.40))
                .frame(width: 34 * scale, height: 24 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.12 : 0.0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                .strokeBorder(Color.white.opacity(selected ? 0.16 : 0.0), lineWidth: 0.5)
                        )
                )
                // Visible chip stays 34×24, but the tappable area fills the
                // full tab-bar height and a wider span so the buttons are
                // easier to hit. Leading-align the visible chip so the first
                // icon stays flush with the chip rows below (no 5px drift).
                .frame(width: 44 * scale, height: ChipsLayout.tabBarHeight * scale,
                       alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var chipsTabContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ChipsLayout.rowSpacing * scale) {
                switch vm.chipsTab {
                case .suggested:
                    ForEach(actions) { action in
                        ActionChip(title: action.rawValue, isLoading: false) { runAction(action) }
                    }
                case .history:
                    if store.history.isEmpty {
                        emptyHint("No prompts yet — ask anything below.")
                    } else {
                        ForEach(store.history, id: \.self) { p in
                            ActionChip(title: p, isLoading: false) { runCustomPromptText(p) }
                        }
                    }
                case .custom:
                    ForEach(store.customPrompts, id: \.self) { p in
                        ActionChip(title: p, isLoading: false) { runCustomPromptText(p) }
                    }
                    customAddRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: ChipsLayout.contentHeight(rows: currentRowCount) * scale, alignment: .top)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11 * scale))
            .foregroundColor(.white.opacity(0.30))
            .frame(maxWidth: .infinity, minHeight: ChipsLayout.rowStride * scale, alignment: .leading)
    }

    @ViewBuilder
    private var customAddRow: some View {
        if isAddingCustom {
            HStack(spacing: 6 * scale) {
                TextField("New prompt…", text: $newCustom)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.white.opacity(0.85))
                    .focused($customFieldFocused)
                    .onSubmit(commitCustom)
                Button(action: commitCustom) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(Circle().fill(Color.blue))
                }
                .buttonStyle(.plain)
                .disabled(newCustom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 12 * scale)
            .padding(.trailing, 5 * scale)
            .padding(.vertical, 4 * scale)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            )
        } else {
            Button {
                newCustom = ""
                withAnimation(.easeInOut(duration: 0.2)) { isAddingCustom = true }
                customFieldFocused = true
            } label: {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "plus")
                        .font(.system(size: 11 * scale, weight: .bold))
                    Text("Add prompt")
                        .font(.system(size: 12 * scale, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 14 * scale)
                .padding(.vertical, 8 * scale)
                .background(
                    Capsule(style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundColor(.white.opacity(0.18))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func commitCustom() {
        let t = newCustom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { withAnimation(.easeInOut(duration: 0.22)) { store.addCustom(t) } }
        newCustom = ""
        withAnimation(.easeInOut(duration: 0.2)) { isAddingCustom = false }
    }

    /// Set stage safely: always deferred one runloop tick so the change
    /// never fires inside an active AppKit or SwiftUI layout pass.
    private func setStage(_ stage: OverlayViewModel.Stage) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                OverlayViewModel.shared.stage = stage
            }
        }
    }
}

// MARK: - Stage 3: Two-column layout (GeometryReader rebuild)
//
// Previous version used fixed pixel widths (219 + 1 + 280 = 500 pt hard-coded).
// Any mismatch between those values and the actual NSHostingView width caused
// NSHostingView's rectangular clip to win over the SwiftUI RoundedRectangle clip
// AND caused NSAnimationContext frame animation to drive the window through
// intermediate sizes where the fixed-width constraints couldn't be satisfied →
// recursive "Update Constraints in Window" crash.
//
// This rebuild uses GeometryReader so the columns are always proportional to
// whatever size the window actually is — no overflow, no fixed-width assumptions.

private struct TwoColumnView: View {
    let fileURL: URL
    let provider: any AIProvider
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        GeometryReader { geo in
            let totalW  = geo.size.width
            let divW    = CGFloat(1)
            let leftW   = floor(totalW * 0.42)
            let rightW  = totalW - leftW - divW

            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(width: leftW, alignment: .topLeading)
                    .clipped()

                Color.white.opacity(0.08)
                    .frame(width: divW)

                rightColumn
                    .frame(width: rightW, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: totalW, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Left: file header + chip list ────────────────────────────────────────

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            FileHeaderView(fileURL: fileURL, closeNS: closeNS)
                .zIndex(100)   // floating name badge must render above chips below it

            Text("Suggested")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.35))

            VStack(alignment: .leading, spacing: 6 * scale) {
                ForEach(FileInspector.suggestedActions(for: fileURL)) { action in
                    ActionChip(
                        title: action.rawValue,
                        isLoading: {
                            if case .loading(_, let a) = vm.stage { return a == action }
                            return false
                        }()
                    ) { runAction(action) }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(15 * scale)
    }

    // ── Right: icon bar (result only) + result card + prompt field + follow-ups ─

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            // Icon bar — only in result state; close button animates here from header
            if case .result(_, let action, let text) = vm.stage {
                resultIconBar(action: action, text: text)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top))
                                           .animation(.spring(response: 0.30, dampingFraction: 0.70).delay(0.06)),
                        removal:   .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }

            resultCard

            // Truncation notice — the source was larger than the extractor's cap,
            // so only the leading slice was sent to the model.
            if case .result = vm.stage, vm.contentTruncated {
                HStack(spacing: 5 * scale) {
                    Image(systemName: "scissors")
                        .font(.system(size: 9 * scale, weight: .semibold))
                    Text("Large file — analysed the first part only.")
                        .font(.system(size: 10 * scale, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.45))
                .transition(.opacity)
            }

            PromptField(text: $vm.customPrompt, onSubmit: runCustomPrompt)

            if case .result = vm.stage {
                // ── Follow-up header + collapse toggle ───────────────────────
                HStack {
                    Text("Follow up")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.22)) {
                            vm.isFollowupsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: vm.isFollowupsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7 * scale, weight: .bold))
                            .foregroundColor(.white.opacity(0.45))
                            .frame(width: 18 * scale, height: 18 * scale)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(vm.isFollowupsExpanded ? "Hide follow-ups" : "Show follow-ups")
                }

                if vm.isFollowupsExpanded {
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        ForEach(followUpActions) { action in
                            ActionChip(title: action.rawValue, isLoading: false) {
                                runAction(action)
                            }
                        }
                    }
                    .transition(.asymmetric(
                        // Delay so chips pop in after the ScrollView has shrunk
                        // to its capped height and the layout has stabilised.
                        insertion: .opacity.combined(with: .move(edge: .top))
                                           .animation(.spring(response: 0.26, dampingFraction: 0.75).delay(0.14)),
                        removal:   .opacity.animation(.easeIn(duration: 0.08))
                    ))
                }
            }

            Spacer(minLength: 0)

            // Handoff button — visible once we have a result
            if case .result(let url, let act, let text) = vm.stage {
                HandoffButton(fileURL: url, action: act, result: text)
                    .padding(.top, 4 * scale)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .padding(14 * scale)
    }

    // ── Stage-3 icon bar ──────────────────────────────────────────────────────
    // Sits above the ScrollView in result state.
    // Buttons: ← back | copy | repeat | [spacer] | ✕ close (matchedGeometryEffect)

    @ViewBuilder
    private func resultIconBar(action: AIAction, text: String) -> some View {
        HStack(spacing: 6 * scale) {
            // Back to stage 2 (chips) — saves result so → can restore it
            ResultIconButton(systemName: "arrow.left", tooltip: "Back to prompts") {
                let snapshot = vm.stage   // capture .result(...) before navigation
                withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                    OverlayViewModel.shared.navigateBackToChips(savingResult: snapshot, url: fileURL)
                }
            }

            // Copy AI reply to clipboard
            ResultIconButton(systemName: "doc.on.doc", tooltip: "Copy reply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            // Re-run the last action
            ResultIconButton(systemName: "arrow.clockwise", tooltip: "Repeat prompt") {
                runAction(action)
            }

            Spacer(minLength: 0)

            // Minimize — park the session; restore from the menu-bar icon.
            MinimizeButton()

            // Close — matched so it animates from FileHeaderView's position
            CloseButton()
                .matchedGeometryEffect(id: "closeBtn", in: closeNS)
        }
    }

    // ── Result / loading / error card ─────────────────────────────────────────

    @ViewBuilder
    private var resultCard: some View {
        switch vm.stage {
        case .loading:
            HStack(spacing: 8 * scale) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.62 * scale)
                    .tint(.white)
                Text("Thinking…")
                    .font(.system(size: 13 * scale))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(12 * scale)
            .frame(maxWidth: .infinity, minHeight: 56 * scale, alignment: .leading)
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.15)

        case .result(_, _, let text):
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownText(source: text)
                    .padding(12 * scale)
            }
            // When follow-ups are hidden the chips' vertical space is freed.
            // .infinity lets the ScrollView grow to fill it; layoutPriority(1)
            // ensures it wins space over the Spacer below it.
            // When follow-ups are visible it's capped so chips stay on screen.
            .frame(maxHeight: vm.isFollowupsExpanded ? 200 * scale : .infinity)
            .layoutPriority(1)
            .animation(.easeInOut(duration: 0.22), value: vm.isFollowupsExpanded)
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.60)

        case .error(_, let msg):
            HStack(alignment: .top, spacing: 8 * scale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13 * scale))
                Text(msg)
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.white.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.20))
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.08)

        default:
            EmptyView()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private var followUpActions: [AIAction] {
        guard case .result(_, let action, _) = vm.stage else { return [] }
        switch action {
        case .summariseBullets: return [.summariseShort, .translateGerman, .extractKeyPoints]
        case .extractKeyDates:  return [.summariseBullets, .translateGerman]
        default:                return [.summariseBullets, .rephraseFormal]
        }
    }

    private func runAction(_ action: AIAction) {
        vm.customPrompt = ""
        vm.cachedResult = nil
        setStage(.loading(url: fileURL, action: action))
        let additionalURLs = vm.additionalFileURLs
        Task {
            do {
                let (content, imageURL, truncated) = try await buildMultiFileContent(
                    primary: fileURL, additional: additionalURLs)
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                OverlayViewModel.shared.contentTruncated = truncated
                SessionHistoryStore.shared.recordTurn(
                    primary: fileURL, additional: additionalURLs,
                    action: action, prompt: nil, result: text)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        PromptStore.shared.recordHistory(prompt)   // log to History tab
        vm.customPrompt = ""
        vm.cachedResult = nil
        let action = AIAction.freeform
        setStage(.loading(url: fileURL, action: action))
        let additionalURLs = vm.additionalFileURLs
        Task {
            do {
                let (baseContent, imageURL, truncated) = try await buildMultiFileContent(
                    primary: fileURL, additional: additionalURLs)
                let finalContent = imageURL != nil
                    ? "Question: \(prompt)"
                    : "Question: \(prompt)\n\n--- Documents ---\n\(baseContent)"
                let text = try await provider.complete(action: action, content: finalContent, imageURL: imageURL)
                OverlayViewModel.shared.contentTruncated = truncated
                SessionHistoryStore.shared.recordTurn(
                    primary: fileURL, additional: additionalURLs,
                    action: action, prompt: prompt, result: text)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    /// Always deferred one runloop tick — never called during an active layout pass.
    private func setStage(_ stage: OverlayViewModel.Stage) {
        DispatchQueue.main.async {
            // Collapse follow-ups whenever a fresh result arrives so the section
            // starts closed and the user can expand it on demand.
            if case .result = stage { OverlayViewModel.shared.isFollowupsExpanded = false }
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                OverlayViewModel.shared.stage = stage
            }
        }
    }
}

// MARK: - Shared subviews

/// File header: unified file-info pill on the left, collapse toggle + close on the right.
/// The entire pill (icon + name + share) is drag-source for moving the file out.
/// In stage 3 (result) the close button is hidden here — it lives in the icon bar
/// above the ScrollView instead, and animates there via matchedGeometryEffect.
private struct FileHeaderView: View {
    let fileURL: URL
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @State private var isHoveringCollapse = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 8 * scale) {

            // ── File pill(s) ─────────────────────────────────────────────────
            // One icon-only pill per file; carousel kicks in beyond two files.
            FilePillsRow(primaryURL: fileURL)

            Spacer(minLength: 0)

            // ── Collapse suggestions toggle (chips stage only) ───────────────
            if vm.stage.tag == 1 {
                Button {
                    // Height reflow stays monotonic (no Y-jump). The elastic
                    // overbounce is the keyframeAnimator on the card (triggered by
                    // isChipsExpanded) — it holds, then squashes when the bottom
                    // edge lands and rebounds. See the .keyframeAnimator below.
                    withAnimation(.easeInOut(duration: 0.22)) {
                        vm.isChipsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: vm.isChipsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(isHoveringCollapse ? 1.0 : 0.60))
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(isHoveringCollapse ? 0.12 : 0.06))
                                .overlay(Circle().strokeBorder(
                                    Color.white.opacity(isHoveringCollapse ? 0.22 : 0.12),
                                    lineWidth: 0.5
                                ))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringCollapse = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHoveringCollapse)
                .help(vm.isChipsExpanded ? "Hide suggestions" : "Show suggestions")
            }

            // ── Forward to cached result (chips stage only) ──────────────────
            // Shown after the user navigated back with ← so they can restore
            // the previous AI answer without re-running the request.
            if vm.stage.tag == 1, let cached = vm.cachedResult {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                        OverlayViewModel.shared.stage = cached
                        OverlayViewModel.shared.cachedResult = nil
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(0.70))
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("Back to AI reply")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity)
                                               .animation(.spring(response: 0.26, dampingFraction: 0.68)),
                    removal:   .scale(scale: 0.7).combined(with: .opacity)
                                               .animation(.easeIn(duration: 0.10))
                ))
            }

            // ── Minimize ───────────────────────────────────────────────────────
            // Parks the session and hides the overlay; the menu-bar icon restores it.
            // Shown for chips (1) and error (4) only: result (3) has its own button in
            // the stage-3 icon bar, and loading (2) is excluded so an in-flight request
            // can't complete into a hidden, reset stage (the reply would be lost).
            if vm.stage.tag == 1 || vm.stage.tag == 4 {
                MinimizeButton()
            }

            // ── Close ────────────────────────────────────────────────────────
            // Hidden in result stage — the button lives in the icon bar above
            // the ScrollView there, animating to its new position via
            // matchedGeometryEffect. In all other stages it stays here.
            if vm.stage.tag != 3 {
                CloseButton()
                    .matchedGeometryEffect(id: "closeBtn", in: closeNS)
            }
        }
    }
}

// MARK: - File pills row

/// Horizontal gallery of icon-only draggable file pills.
/// - 1–2 files: shown side by side.
/// - 3+ files:  shows 2 at a time with prev/next chevrons and a "+N" overflow badge.
private struct FilePillsRow: View {
    let primaryURL: URL
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    /// Index of the first visible file in the carousel window.
    @State private var offset = 0

    private var allFiles: [URL] { [primaryURL] + vm.additionalFileURLs }

    /// The 1 or 2 files currently visible in the carousel window.
    private var visibleFiles: [URL] {
        let start = min(offset, max(0, allFiles.count - 2))
        let end   = min(start + 2, allFiles.count)
        return Array(allFiles[start..<end])
    }

    /// How many files are hidden beyond the right edge of the window.
    private var hiddenCount: Int { max(0, allFiles.count - (offset + 2)) }

    var body: some View {
        Group {
            if allFiles.count == 1 {
                // ── Single file: restore full pill (icon + name + share) ─────
                SingleFilePill(fileURL: primaryURL)
            } else {
                // ── Multi-file: icon-only carousel ──────────────────────────
                HStack(spacing: 5 * scale) {
                    // Left arrow — shown once user has scrolled right
                    if offset > 0 {
                        carouselArrow(forward: false)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }

                    // Visible file pills (max 2)
                    ForEach(visibleFiles, id: \.absoluteString) { url in
                        FilePill(fileURL: url, onRemove: removeAction(for: url))
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.80).combined(with: .opacity),
                                removal:   .scale(scale: 0.80).combined(with: .opacity)
                            ))
                    }

                    // Overflow controls — only when there are more than 2 files total
                    if allFiles.count > 2 {
                        HStack(spacing: 4 * scale) {
                            // "+N" badge: remaining files beyond the current window
                            if hiddenCount > 0 {
                                Text("+\(hiddenCount)")
                                    .font(.system(size: 9 * scale, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5 * scale)
                                    .padding(.vertical, 2 * scale)
                                    .background(Color.accentColor.opacity(0.75))
                                    .clipShape(Capsule(style: .continuous))
                                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                            }
                            // Right arrow
                            if hiddenCount > 0 {
                                carouselArrow(forward: true)
                                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                            }
                        }
                    }

                    // Share button — shares all files in the session together
                    ShareButton(fileURLs: allFiles)
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: offset)
                // Clamp offset when files are removed
                .onChange(of: allFiles.count, initial: false) { _, count in
                    let maxOffset = max(0, count - 2)
                    if offset > maxOffset {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                            offset = maxOffset
                        }
                    }
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: allFiles.count)
    }

    /// Returns the remove closure for a given pill URL.
    /// - Additional file: removes it from `additionalFileURLs`.
    /// - Primary file: promotes the first additional to primary, keeping the rest.
    private func removeAction(for url: URL) -> () -> Void {
        {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                if url == primaryURL {
                    // Promote first additional to primary
                    guard let newPrimary = vm.additionalFileURLs.first else { return }
                    let remaining = Array(vm.additionalFileURLs.dropFirst())
                    let allNew = [newPrimary] + remaining
                    vm.stage = .chips(
                        url: newPrimary,
                        actions: FileInspector.suggestedActions(forAll: allNew)
                    )
                    vm.additionalFileURLs = remaining
                } else {
                    vm.additionalFileURLs.removeAll { $0 == url }
                    // Recalculate chip actions with updated file list
                    if case .chips(let primary, _) = vm.stage {
                        let allNew = [primary] + vm.additionalFileURLs
                        vm.stage = .chips(
                            url: primary,
                            actions: FileInspector.suggestedActions(forAll: allNew)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func carouselArrow(forward: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                offset = max(0, min(offset + (forward ? 1 : -1), allFiles.count - 2))
            }
        } label: {
            Image(systemName: forward ? "chevron.right" : "chevron.left")
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 18 * scale, height: 18 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Single file pill (full — icon + name + share)

/// Original full pill shown when exactly one file is in the session.
/// Reverts to the pre-multi-file design: icon + truncated name + ShareButton + drag hint.
private struct SingleFilePill: View {
    let fileURL: URL
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    @State private var fileIcon: NSImage = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8 * scale) {
            Image(nsImage: fileIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24 * scale, height: 24 * scale)

            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Drag to move")
                    .font(.system(size: 9 * scale, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: false, vertical: true)

            // ••• now owns Share too (see FileToolsButton) — no separate share button.
            FileToolsButton(fileURL: fileURL)
        }
        .padding(.horizontal, 9 * scale)
        .padding(.vertical, 7 * scale)
        .background(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(Color.white.opacity(isHovering ? 0.08 : 0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
                )
        )
        .onDrag {
            vm.isDraggingOut = true
            return NSItemProvider(object: fileURL as NSURL)
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help("Drag to move file elsewhere")
        // Floating full-name badge on hover
        .overlay(alignment: .bottomLeading) {
            if isHovering {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 6 * scale)
                    .frame(maxWidth: 220 * scale, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .fill(Color(white: 0.10).opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.40), radius: 8, x: 0, y: 3)
                    )
                    .fixedSize()
                    .offset(y: 38 * scale)
                    .zIndex(200)
                    .transition(
                        .scale(scale: 0.90, anchor: .topLeading)
                         .combined(with: .opacity)
                         .animation(.spring(response: 0.22, dampingFraction: 0.72))
                    )
            }
        }
        .onAppear {
            Task { @MainActor in
                fileIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
            }
        }
    }
}

// MARK: - Single file pill (icon-only)

/// Icon-only draggable pill for one file.
/// Shows a floating filename tooltip and an × remove button on hover.
private struct FilePill: View {
    let fileURL: URL
    /// Called when the user clicks the × badge. Nil = no × shown (e.g. primary file
    /// when it is the only remaining file, though that case uses SingleFilePill).
    let onRemove: (() -> Void)?
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    @State private var fileIcon: NSImage = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()
    @State private var isHovering = false

    var body: some View {
        Image(nsImage: fileIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: 24 * scale, height: 24 * scale)
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 7 * scale)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.10 : 0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
                    )
            )
            // ••• file-tools badge — top-leading corner, visible on hover
            .overlay(alignment: .topLeading) {
                if isHovering {
                    FileToolsButton(fileURL: fileURL, compact: true)
                        .offset(x: -4 * scale, y: -4 * scale)
                        .transition(.scale(scale: 0.5).combined(with: .opacity)
                            .animation(.spring(response: 0.20, dampingFraction: 0.68)))
                }
            }
            // × remove badge — top-trailing corner, visible on hover
            .overlay(alignment: .topTrailing) {
                if isHovering, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 6 * scale, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 13 * scale, height: 13 * scale)
                            .background(Circle().fill(Color(white: 0.20).opacity(0.95)))
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4 * scale, y: -4 * scale)
                    .transition(.scale(scale: 0.5).combined(with: .opacity)
                        .animation(.spring(response: 0.20, dampingFraction: 0.68)))
                }
            }
            .onDrag {
                vm.isDraggingOut = true
                return NSItemProvider(object: fileURL as NSURL)
            }
            .onHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .help(fileURL.lastPathComponent)
            // Floating filename tooltip
            .overlay(alignment: .bottomLeading) {
                if isHovering {
                    VStack(alignment: .leading, spacing: 2 * scale) {
                        Text(fileURL.lastPathComponent)
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Drag to move")
                            .font(.system(size: 9 * scale, weight: .regular))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 9 * scale)
                    .padding(.vertical, 6 * scale)
                    .frame(maxWidth: 200 * scale, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .fill(Color(white: 0.10).opacity(0.96))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.40), radius: 8, x: 0, y: 3)
                    )
                    // fixedSize lets the tooltip escape the narrow pill's layout bounds
                    .fixedSize()
                    .offset(y: 38 * scale)
                    .zIndex(200)
                    .transition(
                        .scale(scale: 0.90, anchor: .topLeading)
                         .combined(with: .opacity)
                         .animation(.spring(response: 0.22, dampingFraction: 0.72))
                    )
                }
            }
            .onAppear {
                Task { @MainActor in
                    fileIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
                }
            }
    }
}

// MARK: - Share button

/// Circular share button in the file header. Presents the native macOS share sheet
/// (NSSharingServicePicker) via `ShareLink` — full service list + extensions.
/// Accepts one or more URLs; all files are shared together.
private struct ShareButton: View {
    /// All files to share. Pass a single-element array for single-file sessions.
    let fileURLs: [URL]
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    /// Convenience init for the common single-file case.
    init(fileURL: URL) { fileURLs = [fileURL] }
    init(fileURLs: [URL]) { self.fileURLs = fileURLs }

    private var tooltip: String {
        fileURLs.count == 1 ? "Share file" : "Share \(fileURLs.count) files"
    }

    var body: some View {
        ShareLink(items: fileURLs) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                .frame(width: 22 * scale, height: 22 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(isHovered ? 0.22 : 0.12),
                                lineWidth: 0.5
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(tooltip)
    }
}

// MARK: - Result icon button

/// A small circular icon button used in the stage-3 icon bar above the ScrollView.
/// Matches the 22×22 pt size of CloseButton. Shows a tooltip label on hover.
private struct ResultIconButton: View {
    let systemName: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                .frame(width: 22 * scale, height: 22 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(isHovered ? 0.22 : 0.12),
                                lineWidth: 0.5
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(tooltip)
    }
}

// MARK: - Close button

/// Small × button — closes the current shelf session.
/// Posts a notification so AppDelegate can coordinate teardown.
private struct CloseButton: View {
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .hideOverlay, object: nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8 * scale, weight: .heavy))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.80))
                .frame(width: 22 * scale, height: 22 * scale)
                // Red-tinted liquid glass circle — keeps the glassy depth
                // while clearly signalling a destructive/close action.
                .liquidGlassCircle(
                    tintOpacity: isHovered ? 0.30 : 0.45,
                    colorTint: Color(red: 1.0, green: 0.22, blue: 0.20)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Minimize button

/// Small − button — parks the current session and squishes the overlay into the
/// notch. Posts a notification so AppDelegate can snapshot the session and tear the
/// window down; clicking the menu-bar icon restores it.
private struct MinimizeButton: View {
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .minimizeOverlay, object: nil)
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 8 * scale, weight: .bold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                .frame(width: 22 * scale, height: 22 * scale)
                // Matches the collapse / share buttons: a subtle white glass circle,
                // not the heavier liquid-glass tint (which read too dark beside them).
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(Circle().strokeBorder(
                            Color.white.opacity(isHovered ? 0.22 : 0.12),
                            lineWidth: 0.5
                        ))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Minimize")
    }
}

// MARK: - Handoff button

/// "Continue in [Provider]" — copies context + opens the AI app.
/// Morphs into a ✓ confirmation pill for 2 seconds after tapping.
private struct HandoffButton: View {
    let fileURL: URL
    let action: AIAction
    let result: String

    @State private var didTap = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            guard !didTap else { return }
            didTap = true
            HandoffManager.handOff(fileURL: fileURL, action: action, result: result)
            let vm = OverlayViewModel.shared
            let providerName = HandoffManager.providerName()
            if case .result = vm.stage {
                // Navigate to stage 2 instantly — the button disappears with the card.
                withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                    vm.navigateBackToChips(savingResult: vm.stage, url: fileURL)
                    vm.isChipsExpanded = false
                }
                // Pop the confirmation pill into the already-visible stage 2 card
                // after the navigation spring has had a moment to settle.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                        vm.handoffProviderName = providerName
                    }
                }
                // Calm fade-out after 6 s — well-damped so the pill dissolves
                // cleanly without oscillating.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
                    withAnimation(.spring(response: 0.40, dampingFraction: 0.82)) {
                        vm.handoffProviderName = nil
                    }
                }
            }
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: didTap ? "checkmark" : HandoffManager.providerIcon())
                    .font(.system(size: 9 * scale, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))

                Text(didTap
                     ? "Copied · check clipboard"
                     : "Continue in \(HandoffManager.providerName())")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .lineLimit(1)

                if !didTap {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                }
            }
            .foregroundColor(.white.opacity(didTap ? 1.0 : 0.45))
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity)
            .background(didTap ? Color.green.opacity(0.25) : Color.clear)
            .liquidGlassCapsule(tintOpacity: didTap ? 0.10 : 0.18)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: didTap)
    }
}

// MARK: - Prompt field with mic

/// Shared text-input bar used in both stage 2 (chips) and stage 3 (result right column).
/// The trailing mic button toggles native on-device speech recognition — no API tokens.
/// When the field has content a blue Send button springs out from behind the mic icon.
private struct PromptField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    @ObservedObject private var speech = SpeechRecognizer.shared
    @Environment(\.uiScale) private var scale
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            TextField("Ask anything…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12 * scale))
                .foregroundColor(.white.opacity(0.75))
                .padding(.leading, 11 * scale)
                .padding(.vertical, 8 * scale)
                .onSubmit(onSubmit)

            // Send button — slides out from the trailing edge (from behind the mic)
            // when the field is non-empty, retreats back when cleared.
            if hasContent {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24 * scale, height: 24 * scale)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5 * scale)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    )
                )
                .help("Send prompt")
            }

            // Mic button
            Button {
                speech.toggle { recognised in text = recognised }
            } label: {
                Image(systemName: speech.isRecording ? "waveform" : "mic")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(speech.isRecording ? .red : .white.opacity(0.40))
                    .frame(width: 34 * scale, height: 34 * scale)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .buttonStyle(.plain)
            .help(speech.isRecording ? "Stop recording" : "Dictate prompt")
        }
        // Flat background — no blur, no specular.  The card itself already
        // provides the glass context; the field sits inside it as a plain inset.
        .background(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        // Drive both the insertion/removal transition and any geometry changes
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: hasContent)
    }
}

// MARK: - Action chip

struct ActionChip: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(.white)
                        .frame(width: 10 * scale, height: 10 * scale)
                }
                Text(title)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 8 * scale)
            // Flat capsule — no blur, no specular.  Simple stroke ring
            // differentiates the chip without competing with the card glass.
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.05))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0.10),
                                          lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        // Grow rightward from the leading edge so the hover bump doesn't push
        // the left edge past the card's leading inset and clip.
        .scaleEffect(isHovered ? 1.03 : 1.0, anchor: .leading)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
        .disabled(isLoading)
    }
}

// MARK: - Multi-file content builder

/// Extracts and joins content from all files in the session.
/// Single-file behaviour is unchanged — exactly the same strings as before.
/// Multi-file: each file's content is preceded by a filename header.
/// Returns (content, imageURL, truncated): imageURL is only set for a SINGLE-image
/// session (no additionals) so vision models work; `truncated` is true when any
/// file's content was cut to fit the extractor's char/page cap.
private func buildMultiFileContent(
    primary fileURL: URL,
    additional additionalURLs: [URL]
) async throws -> (content: String, imageURL: URL?, truncated: Bool) {
    let allURLs = [fileURL] + additionalURLs

    // ── Single image (no additionals) ─────────────────────────────────────────
    if allURLs.count == 1, FileInspector.isImageFile(allURLs[0]) {
        return ("Analyse the attached image.", allURLs[0], false)
    }

    // ── Single non-image ──────────────────────────────────────────────────────
    if allURLs.count == 1 {
        let result = try await FileContentExtractor.extract(from: allURLs[0])
        return (result.text, nil, result.truncated)
    }

    // ── Multiple files ────────────────────────────────────────────────────────
    var sections: [String] = []
    var anyTruncated = false
    for url in allURLs {
        let body: String
        if FileInspector.isImageFile(url) {
            // Vision analysis is only available for single-image sessions;
            // in multi-file mode describe the image by name / context.
            body = "[Image: \(url.lastPathComponent) — visual description not available in multi-file mode]"
        } else if let result = try? await FileContentExtractor.extract(from: url) {
            body = result.text
            anyTruncated = anyTruncated || result.truncated
        } else {
            body = "[Could not read: \(url.lastPathComponent)]"
        }
        sections.append("=== \(url.lastPathComponent) ===\n\(body)")
    }
    return (sections.joined(separator: "\n\n"), nil, anyTruncated)
}

// MARK: - Second-file drag overlay

/// Full-card dark overlay that appears as soon as the user starts dragging any
/// file while a session is already open. Communicates that the card is still a
/// valid drop target — the user can release here to add the file or start fresh.
///
/// Disappears the moment the drop lands (replaced by SecondFilePromptBanner).
private struct SecondFileDragOverlay: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    /// True once the cursor is physically over the card — drives the
    /// enhanced "release now" state.
    private var isHovering: Bool { vm.isDragHovering }

    var body: some View {
        ZStack {
            // ── Very light darkening tint only — the card content below is already
            // blurred + dimmed via modifiers on the Group in the parent ZStack, so
            // NO opaque VisualEffectBlur here. This tint just lifts the white text
            // slightly above the ghosted backdrop on hover.
            Color.black.opacity(isHovering ? 0.18 : 0.04)
                .animation(.easeInOut(duration: 0.14), value: isHovering)

            // Optional blue tint mirrors the stage-1 pill hover colour
            Color.accentColor.opacity(isHovering ? 0.08 : 0)
                .animation(.easeInOut(duration: 0.14), value: isHovering)

            // ── Icon + text ─────────────────────────────────────────────────
            VStack(spacing: 10 * scale) {
                Image(systemName: isHovering ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 28 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovering ? 1.0 : 0.85))
                    .scaleEffect(isHovering ? 1.05 : 1.0)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovering)

                Text(isHovering ? "Release to add or replace" : "Drop here to add another file\nor start a new session")
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovering ? 1.0 : 0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.14), value: isHovering)
            }
            .padding(20 * scale)
        }
        // Fill the entire card
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Second-file prompt banner

/// Slides up from the bottom of the active card when the user drops a second file
/// while a session is already open. Offers two choices: add the file to the
/// current session's AI context, or start a fresh session with just the new file.
private struct SecondFilePromptBanner: View {
    let provider: any AIProvider
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        guard let url = vm.pendingSecondFileURL else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 8 * scale) {

                // ── Header ─────────────────────────────────────────────────────
                HStack(spacing: 6 * scale) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                    Text(url.lastPathComponent)
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // Dismiss / cancel
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            vm.pendingSecondFileURL = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9 * scale, weight: .bold))
                            .foregroundColor(.white.opacity(0.40))
                            .frame(width: 20 * scale, height: 20 * scale)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }

                // ── Action buttons ─────────────────────────────────────────────
                HStack(spacing: 8 * scale) {

                    // Add to session
                    Button { addToSession(url: url) } label: {
                        Label("Add to session", systemImage: "plus.circle.fill")
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7 * scale)
                            .background(Color.accentColor.opacity(0.88))
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Analyse both files together in the current session")

                    // New session
                    Button { startNewSession(url: url) } label: {
                        Label("New session", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7 * scale)
                            .liquidGlassCapsule(tintOpacity: 0.38)
                    }
                    .buttonStyle(.plain)
                    .help("Start a new session with only the new file")
                }
            }
            .padding(.horizontal, 12 * scale)
            .padding(.top, 10 * scale)
            .padding(.bottom, 12 * scale)
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                    Color.black.opacity(0.55)
                    // Top separator
                    VStack(spacing: 0) {
                        Color.white.opacity(0.13)
                            .frame(height: 0.75)
                        Spacer(minLength: 0)
                    }
                }
            )
        )
    }

    private func addToSession(url: URL) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
            vm.additionalFileURLs.append(url)
            vm.pendingSecondFileURL = nil
            // Update chip actions to the union of all files in the session
            if case .chips(let primaryURL, _) = vm.stage {
                let allURLs = [primaryURL] + vm.additionalFileURLs
                vm.stage = .chips(
                    url: primaryURL,
                    actions: FileInspector.suggestedActions(forAll: allURLs)
                )
            }
        }
    }

    private func startNewSession(url: URL) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
            vm.pendingSecondFileURL = nil
            vm.setChips(url: url)   // setChips() clears additionalFileURLs
        }
    }
}

// MARK: - Cold-start prewarm
//
// The chips subtree (file pill, action chips, prompt field, glass material,
// Markdown renderer) is only laid out the first time a file is dropped. That
// first layout pays SwiftUI's one-time costs — generic specialisation, Core Text
// glyph caches, the LiquidGlass blur/Metal pipeline, and NSWorkspace's icon
// service — which is the visible hitch between the drop and the card appearing,
// most noticeable right after launch.
//
// AppDelegate.prewarmSwiftUI() hosts this view in an offscreen, zero-alpha window
// at launch so those costs are paid up front. It uses a throwaway URL, never
// touches OverlayViewModel.shared's `stage`, and is released after a couple
// seconds. It MUST stay composed of the SAME leaf views the real chips card uses
// (FilePillsRow / ActionChip / PromptField / MarkdownText + .liquidGlass) — that
// is what makes warming them effective.
struct OverlayPrewarmView: View {
    // Nonexistent path on purpose: FilePillsRow's icon lookup returns the generic
    // document icon (warming NSWorkspace) without reading any real file.
    private let dummyURL = URL(fileURLWithPath: "/private/tmp/aidrop.prewarm.txt")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FilePillsRow(primaryURL: dummyURL)
            ForEach(["Summarise", "Key points", "Explain"], id: \.self) { title in
                ActionChip(title: title, isLoading: false, action: {})
            }
            PromptField(text: .constant(""), onSubmit: {})
            MarkdownText(source: "**Warming up** the renderer…")
        }
        .padding(12)
        .frame(width: 280, height: 320)
        .liquidGlass(cornerRadius: 22, tintOpacity: 0.7)
        .environment(\.uiScale, UIScale.current.multiplier)
    }
}
