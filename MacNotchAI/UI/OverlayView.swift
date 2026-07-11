import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                        case .fileResult(let original, let output, let tool):
                            FileResultView(original: original, output: output, tool: tool)
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
                    .blur(radius: (dragMonitor.isDraggingFile && vm.pendingDroppedURLs.isEmpty) ? 3.5 : 0)
                    .opacity((dragMonitor.isDraggingFile && vm.pendingDroppedURLs.isEmpty) ? 0.45 : 1.0)
                    .animation(.easeInOut(duration: 0.22),
                               value: dragMonitor.isDraggingFile && vm.pendingDroppedURLs.isEmpty)

                    // Second-file drag overlay — darkens the card and shows a hint
                    // the moment the user starts dragging ANY file while a session is
                    // open, even before they bring it near the notch. Hidden once the
                    // drop lands and the banner takes over.
                    if dragMonitor.isDraggingFile, vm.pendingDroppedURLs.isEmpty {
                        SecondFileDragOverlay()
                            .transition(.opacity)
                    }

                    // Second-file prompt banner — spring-slides up from the bottom
                    // edge of the card when one or more files are dropped mid-session.
                    if !vm.pendingDroppedURLs.isEmpty {
                        SecondFilePromptBanner(provider: provider)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.20),
                            value: dragMonitor.isDraggingFile && vm.pendingDroppedURLs.isEmpty)
                .animation(.spring(response: 0.35, dampingFraction: 0.72),
                            value: vm.pendingDroppedURLs.isEmpty)
                .liquidGlass(cornerRadius: cornerRadius, tintOpacity: 0.60, verticalFade: true,
                             material: .hudWindow, emphasized: false)
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
        // The overlay is a floating HUD that often isn't the key window — force the active
        // control appearance so Liquid Glass + buttons never render greyed/desaturated.
        .environment(\.controlActiveState, .active)
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
        .onAppear { appeared = vm.windowShown }
        // Replay the pop-in every time the immortal window is un-parked. The window
        // (and this view) now live for the whole app lifetime — .onAppear fires
        // exactly once ever, so the entry spring must key off windowShown instead.
        .onChange(of: vm.windowShown, initial: false) { _, shown in
            if shown {
                appeared = false                       // reset silently…
                DispatchQueue.main.async { appeared = true }   // …then spring in
            } else {
                appeared = false
            }
        }
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

            Text(vm.isDragHovering ? "  Release here " : "Drop anything")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: vm.isDragHovering)
        }
        .padding(.horizontal, 22 * scale)
        .padding(.vertical, 18 * scale)
        // Height = 68 × scale so cornerRadius = 34 × scale → perfect stadium shape.
        .frame(width: 240 * scale, height: 68 * scale)
        // Plain, slightly-transparent black surface — matches the radial launcher's
        // flat look rather than the frosted glass the later stages use. Background +
        // clip live HERE (inside WaitingPillView), not on the outer canvas in
        // OverlayView, so the outer 288×96 canvas stays transparent and the wobble
        // scaleEffect (applied after this in OverlayView) can overflow freely.
        //
        // Hover: the surface darkens a touch and the rim picks up the system accent.
        .background(
            RoundedRectangle(cornerRadius: 34 * scale, style: .continuous)
                .fill(Color.black.opacity(vm.isDragHovering ? 0.64 : 0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 34 * scale, style: .continuous)
                        .strokeBorder(vm.isDragHovering
                                      ? Color.accentColor.opacity(0.65)
                                      : Color.white.opacity(0.14),
                                      lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 34 * scale, style: .continuous))
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

/// Scroll geometry of the chips-stage tab list, used to drive the custom scroll indicator.
/// `offset` is the content top relative to the viewport (0 at top, negative when scrolled);
/// `contentHeight` is the full (unclamped) height of the rows.
private struct ChipsScrollMetrics: Equatable {
    var offset: CGFloat
    var contentHeight: CGFloat
}

private struct ChipsScrollMetricsKey: PreferenceKey {
    static var defaultValue = ChipsScrollMetrics(offset: 0, contentHeight: 0)
    static func reduce(value: inout ChipsScrollMetrics, nextValue: () -> ChipsScrollMetrics) {
        value = nextValue()
    }
}

private struct ChipsColumnView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @ObservedObject private var store = PromptStore.shared
    @ObservedObject private var outputStore = OutputDirectoryStore.shared
    @ObservedObject private var scriptsStore = ScriptsStore.shared
    @Environment(\.uiScale) private var scale

    // Inline "add custom prompt" composer state (Custom tab "+" row).
    @State private var isAddingCustom = false
    @State private var newCustom = ""
    /// The media utility currently running (async AVFoundation/Speech op) — drives its
    /// row spinner and blocks re-entrancy while in flight. `nil` = idle.
    @State private var runningTool: FileTool?
    /// Live scroll offset + content height of the tab list, fed by a GeometryReader so the
    /// custom (thin, dim) scroll indicator can position its knob. (The native macOS scroller
    /// can't be made smaller/darker, so we hide it and draw our own.)
    @State private var scrollMetrics = ChipsScrollMetrics(offset: 0, contentHeight: 0)
    @FocusState private var customFieldFocused: Bool
    // Utilities-tab inline output-path editing.
    @State private var editingOutputPath = false
    @State private var outputPathDraft = ""
    @FocusState private var outputFieldFocused: Bool
    // Drag-to-reorder (Scripts + Utilities rows): id of the row being dragged.
    @State private var draggingRowID: String?
    // Tab currently under the pointer — drives the single dynamic caption above
    // the tab row. Falls back to the selected tab when nothing is hovered.
    @State private var hoveredTab: OverlayViewModel.ChipsTab?

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            FileHeaderView(fileURL: fileURL, closeNS: closeNS)
                .zIndex(100)   // floating name badge must render above chips below it

            // Media sessions stay permanently expanded (there is no prompt field to
            // collapse down to), so the Utilities + Open-in content always shows.
            if vm.isChipsExpanded || isMediaSession {
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

                // Pillar 1: numbered "Open in" launch row for the user's favorite apps.
                ToolRow()
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.17)),
                        removal:   .opacity.animation(.easeIn(duration: 0.07))
                    ))
            }

            // Video/audio carries no hosted-AI path — hide the prompt field so the
            // model can never be invoked for it (zero operator token cost).
            if !isMediaSession {
                PromptField(text: $vm.customPrompt, onSubmit: runCustomPrompt)
            }

        }
        .padding(18 * scale)
        .frame(width: 280 * scale, alignment: .topLeading)
    }

    /// Video/audio: no hosted-AI actions apply. The chips stage shows only file
    /// Utilities + the "Open in" launch row — no prompt field, no AI tabs — so the
    /// model is never invoked for media (zero operator token cost).
    private var isMediaSession: Bool { FileInspector.isMediaFile(fileURL) }

    private func runAction(_ action: AIAction) {
        sendTurn(provider: provider, fileURL: fileURL, action: action, typedPrompt: nil)
    }

    private func runCustomPrompt() { runCustomPromptText(vm.customPrompt) }

    /// Run an arbitrary free-text prompt against the current session. Logged to
    /// History inside sendTurn. Used by the prompt field and History/Custom chips.
    private func runCustomPromptText(_ raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        sendTurn(provider: provider, fileURL: fileURL, action: .freeform, typedPrompt: prompt)
    }

    // ── Prompt tabs: Suggested / History / Custom ─────────────────────────────

    /// File-utility actions for the current file/session (Utilities tab). Shared by
    /// the content view and the row-count calc so the window height stays in sync.
    private var utilityTools: [FileTool] {
        FileToolActions.utilityTools(for: fileURL, sessionFiles: vm.sessionFileURLs)
    }

    /// `utilityTools` sorted by the user's saved order (unlisted tools keep catalogue order, last).
    private var sortedUtilityTools: [FileTool] {
        let order = vm.utilityOrder
        return utilityTools.enumerated().sorted { a, b in
            let ra = order.firstIndex(of: a.element.title) ?? (order.count + a.offset)
            let rb = order.firstIndex(of: b.element.title) ?? (order.count + b.offset)
            return ra < rb
        }.map { $0.element }
    }

    // MARK: - Drag-to-reorder rows

    /// A small grab handle on the right of a row that initiates a reorder drag.
    private func reorderGrip(id: String) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11 * scale, weight: .semibold))
            .foregroundColor(.white.opacity(0.28))
            .frame(width: 24 * scale, height: 28 * scale)
            .contentShape(Rectangle())
            .onDrag {
                draggingRowID = id
                return NSItemProvider(object: id as NSString)
            }
            .help("Drag to reorder")
    }

    /// Wrap a row with a trailing reorder grip + a drop target. `onDrop` receives the dragged id.
    @ViewBuilder
    private func reorderableRow<Content: View>(id: String,
                                               onDrop: @escaping (String) -> Void,
                                               @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4 * scale) {
            content()
            reorderGrip(id: id)
        }
        .onDrop(of: [.plainText], isTargeted: nil) { _ in
            let dragged = draggingRowID
            draggingRowID = nil
            guard let dragged, dragged != id else { return false }
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) { onDrop(dragged) }
            return true
        }
    }

    private func reorderScript(dragged: String, ontoID: String) {
        let s = scriptsStore.scripts
        guard let from = s.firstIndex(where: { $0.id.uuidString == dragged }),
              let to = s.firstIndex(where: { $0.id.uuidString == ontoID }), from != to else { return }
        scriptsStore.move(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
    }

    private func reorderUtility(dragged: String, ontoTitle: String) {
        var titles = sortedUtilityTools.map(\.title)
        guard let from = titles.firstIndex(of: dragged),
              let to = titles.firstIndex(of: ontoTitle), from != to else { return }
        titles.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        // Keep order entries for other file types (not currently visible) after the visible ones.
        let others = vm.utilityOrder.filter { !titles.contains($0) }
        vm.utilityOrder = titles + others
    }

    /// Logical (unclamped) row count of the active tab — must match the value
    /// AppDelegate.resizeOverlay uses so the window height fits the content region.
    private var currentRowCount: Int {
        ChipsLayout.rows(for: vm.chipsTab,
                         suggested: actions.count,
                         history: store.history.count,
                         custom: store.customPrompts.count,
                         utilities: utilityTools.count,
                         scripts: scriptsStore.scripts.count)
    }

    private var chipsTabBar: some View {
        // One flush row of tab icons under a SINGLE caption that reflects whichever
        // tab is hovered (or selected when nothing is hovered): AI Suggestions /
        // AI History / AI Customs / Utilities / Scripts.
        // Total height = ChipsLayout.tabBarHeight (caption + gap + icon row).
        let active = hoveredTab ?? vm.chipsTab
        return VStack(alignment: .leading, spacing: ChipsLayout.tabCaptionGap * scale) {
            HStack(spacing: 3 * scale) {
                Image(systemName: tabCaptionIcon(active))
                    .font(.system(size: 7 * scale, weight: .semibold))
                Text(tabCaptionLabel(active).uppercased())
                    .font(.system(size: 8 * scale, weight: .semibold))
                    .tracking(0.5)
            }
            .foregroundColor(.white.opacity(0.32))
            .frame(height: ChipsLayout.tabCaptionHeight * scale)
            .animation(.easeInOut(duration: 0.15), value: active)

            HStack(spacing: 0) {
                // Media (video/audio) has no AI path — show only Utilities + Scripts.
                if !isMediaSession {
                    // The three AI tabs sit tight inside a subtle grouping pill. The
                    // active AI icon is full-size; the two inactive ones are smaller.
                    HStack(spacing: 1 * scale) {
                        aiTabButton(.suggested, icon: "sparkles.2",       help: "Suggested")
                        aiTabButton(.history,   icon: "list.bullet",      help: "History")
                        aiTabButton(.custom,    icon: "slider.vertical.3", help: "Custom prompts")
                    }
                    .padding(.horizontal, 2 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                            .fill(Color.white.opacity(0.045))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                            )
                    )
                    Spacer().frame(width: 12 * scale)   // visual gap before utilities
                }
                tabButton(.utilities, icon: "wrench.and.screwdriver", help: "File utilities")
                tabButton(.scripts,   icon: "terminal",               help: "Run a saved command")
                Spacer(minLength: 0)
            }
        }
        .frame(height: ChipsLayout.tabBarHeight * scale, alignment: .bottom)
    }

    /// Caption shown above the tab row for the hovered/selected tab.
    private func tabCaptionLabel(_ tab: OverlayViewModel.ChipsTab) -> String {
        switch tab {
        case .suggested: return "AI Suggestions"
        case .history:   return "AI History"
        case .custom:    return "AI Customs"
        case .utilities: return "Utilities"
        case .scripts:   return "Scripts"
        }
    }

    private func tabCaptionIcon(_ tab: OverlayViewModel.ChipsTab) -> String {
        switch tab {
        case .suggested: return "sparkles"
        case .history:   return "list.bullet"
        case .custom:    return "slider.vertical.3"
        case .utilities: return "wrench.and.screwdriver"
        case .scripts:   return "terminal"
        }
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
                // icon-row height and a wider span so the buttons are easier to
                // hit. Leading-align the visible chip so the first icon stays
                // flush with the chip rows below (no 5px drift).
                .frame(width: 44 * scale, height: ChipsLayout.tabIconRowHeight * scale,
                       alignment: .leading)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.22), value: selected)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            if inside { hoveredTab = tab }
            else if hoveredTab == tab { hoveredTab = nil }
        }
    }

    /// AI-group tab button. Tighter footprint than `tabButton`, and the icon shrinks
    /// when the tab is inactive so the active AI tab visually leads its two siblings.
    /// Switching tabs cross-fades the size/opacity cleanly via `withAnimation`.
    @ViewBuilder
    private func aiTabButton(_ tab: OverlayViewModel.ChipsTab, icon: String, help: String) -> some View {
        let selected = vm.chipsTab == tab
        Button {
            guard vm.chipsTab != tab else { return }
            isAddingCustom = false          // close any open composer when switching
            withAnimation(.easeInOut(duration: 0.22)) { vm.chipsTab = tab }
        } label: {
            Image(systemName: icon)
                .font(.system(size: (selected ? 11.5 : 9.5) * scale, weight: .semibold))
                .foregroundColor(selected ? .white : .white.opacity(0.38))
                .frame(width: (selected ? 28 : 24) * scale, height: 24 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(Color.white.opacity(selected ? 0.14 : 0.0))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                                .strokeBorder(Color.white.opacity(selected ? 0.18 : 0.0), lineWidth: 0.5)
                        )
                )
                // Centered (not leading) so the three icons sit evenly inside the
                // grouping pill. Tappable area fills the icon-row height.
                .frame(height: ChipsLayout.tabIconRowHeight * scale)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.22), value: selected)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            if inside { hoveredTab = tab }
            else if hoveredTab == tab { hoveredTab = nil }
        }
    }

    private var chipsTabContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: ChipsLayout.rowSpacing * scale) {
                switch vm.chipsTab {
                case .suggested:
                    if actions.isEmpty {
                        emptyHint("No AI actions for this file type — use Utilities or “Open in”.")
                    } else {
                        // Pills (ActionChip) for the AI-insight suggestions, matching the
                        // History / Custom tabs. (Utilities keep the menu-row look.)
                        ForEach(actions) { action in
                            ActionChip(title: action.rawValue, isLoading: false) { runAction(action) }
                        }
                    }
                case .history:
                    if store.history.isEmpty {
                        emptyHint("No prompts yet — ask anything below.")
                    } else {
                        ForEach(store.history, id: \.self) { p in
                            ActionChip(title: p, isLoading: false) { runCustomPromptText(p) }
                        }
                        clearAllRow(confirmClearPromptHistory)
                    }
                case .custom:
                    ForEach(store.customPrompts, id: \.self) { p in
                        ActionChip(title: p, isLoading: false) { runCustomPromptText(p) }
                    }
                    customAddRow
                case .utilities:
                    // Output-folder control: where produced files land this session.
                    outputDirRow
                    // Pillar 2: file-utility actions as chips (convert/rename/move/…),
                    // type-gated to the dropped file. Tapping runs the FileTools engine
                    // and confirms the macOS-native way (Finder reveal / NSAlert).
                    ForEach(sortedUtilityTools) { tool in
                        reorderableRow(id: tool.title,
                                       onDrop: { reorderUtility(dragged: $0, ontoTitle: tool.title) }) {
                            MenuActionRow(title: tool.title, systemImage: tool.systemImage,
                                          isLoading: runningTool == tool) {
                                // One media op at a time; sync utilities are instant.
                                guard runningTool == nil else { return }
                                if tool.isAsync {
                                    runningTool = tool
                                    Task {
                                        await FileToolActions.performAsync(
                                            tool, fileURL: fileURL, sessionFiles: vm.sessionFileURLs)
                                        runningTool = nil
                                    }
                                } else {
                                    FileToolActions.perform(tool, fileURL: fileURL,
                                                            sessionFiles: vm.sessionFileURLs)
                                }
                            }
                        }
                    }
                case .scripts:
                    // User-defined shell commands run against the dropped file's project.
                    if scriptsStore.scripts.isEmpty {
                        emptyHint("No scripts yet — add one in Settings.")
                    } else {
                        ForEach(scriptsStore.scripts) { script in
                            reorderableRow(id: script.id.uuidString,
                                           onDrop: { reorderScript(dragged: $0, ontoID: script.id.uuidString) }) {
                                MenuActionRow(title: script.name,
                                              systemImage: script.inTerminal ? "terminal" : "play.circle") {
                                    ScriptRunner.run(script, fileURL: fileURL)
                                }
                            }
                        }
                    }
                    scriptsSettingsRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Report scroll offset (content top relative to the viewport) + content height
            // so the custom scroll indicator can size & place its knob.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ChipsScrollMetricsKey.self,
                        value: ChipsScrollMetrics(
                            offset: geo.frame(in: .named("chipsScroll")).minY,
                            contentHeight: geo.size.height))
                }
            )
        }
        .coordinateSpace(name: "chipsScroll")
        .frame(height: ChipsLayout.contentHeight(rows: currentRowCount) * scale, alignment: .top)
        // Fade the bottom edge when the list is taller than the visible region, so it
        // reads as "scroll down for more". No fade when everything fits (mask all-opaque).
        .mask(
            VStack(spacing: 0) {
                Rectangle().fill(.white)
                LinearGradient(
                    colors: [.white, hasTabOverflow ? .clear : .white],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 22 * scale)
            }
        )
        // Custom scroll indicator — drawn AFTER the fade mask so it isn't faded out.
        // Thin + dim by design (the native macOS scroller can't be restyled this way).
        .overlay(alignment: .topTrailing) { scrollIndicator }
        .onPreferenceChange(ChipsScrollMetricsKey.self) { scrollMetrics = $0 }
    }

    /// A slim, dim scroll-position knob shown only when the tab list overflows. Geometry
    /// comes from `scrollMetrics` (offset + content height) vs. the fixed viewport height.
    @ViewBuilder private var scrollIndicator: some View {
        let viewportH = ChipsLayout.contentHeight(rows: currentRowCount) * scale
        let contentH  = scrollMetrics.contentHeight
        if contentH > viewportH + 1 {
            let knobH      = max(16 * scale, viewportH * (viewportH / contentH))
            let scrollable = contentH - viewportH
            let progress   = min(1, max(0, -scrollMetrics.offset / scrollable))
            let knobY      = progress * (viewportH - knobH)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.22))
                .frame(width: 2.5 * scale, height: knobH)
                .padding(.trailing, 2 * scale)
                .offset(y: knobY)
                .allowsHitTesting(false)
        }
    }

    /// True when the active tab has more rows than the visible region can show, i.e. the
    /// content region is scrolling (`contentHeight` clamps at `maxVisibleRows`).
    private var hasTabOverflow: Bool {
        currentRowCount > ChipsLayout.maxVisibleRows
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

    /// Footer of the Scripts tab — opens Settings → Scripts to add/edit (name, command, run mode).
    private var scriptsSettingsRow: some View {
        Button { NotificationCenter.default.post(name: .showScripts, object: nil) } label: {
            HStack(spacing: 6 * scale) {
                Image(systemName: "plus")
                    .font(.system(size: 11 * scale, weight: .bold))
                Text("Add / edit scripts")
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

    // MARK: - Utilities-tab output folder control

    /// "Where do produced files go" control atop the Utilities tab. Shows the effective
    /// output folder (session override → persisted store → "Same folder"); the folder button
    /// opens the **Change Directory** dialog; the gear opens the Output Directory settings;
    /// an × (when a folder is active) resets to same-folder for this session.
    /// Output-folder control atop the Utilities tab. Shows the destination path (the active
    /// override, or the file's own folder on the default) — **click it to edit the path inline**.
    /// The folder button opens Finder right away; the gear opens the Output Directory settings;
    /// an × (when overridden) resets to the file's folder for this session.
    @ViewBuilder private var outputDirRow: some View {
        let override = FileToolActions.effectiveOutputDir(for: fileURL)   // nil = default (file's folder)
        let dir = override ?? fileURL.deletingLastPathComponent()
        let display = (dir.path as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 6 * scale) {
            if editingOutputPath {
                TextField("Same folder as the file", text: $outputPathDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundColor(.white)
                    .focused($outputFieldFocused)
                    .onSubmit { commitOutputPath() }
                    .onExitCommand { editingOutputPath = false; outputFieldFocused = false }
                    .onChange(of: outputFieldFocused) { _, focused in
                        if !focused && editingOutputPath { commitOutputPath() }   // commit on blur
                    }
                    .padding(.horizontal, 8 * scale)
                    .padding(.vertical, 5 * scale)
                    .frame(maxWidth: .infinity)
                    .background(outputFieldBox(active: true))
            } else {
                // A Button (reliable hit-testing in the ScrollView) styled as a text field so the
                // non-editing state reads as an input you can click into.
                Button { beginEditingOutputPath(dir) } label: {
                    Text(display)
                        .font(.system(size: 11.5 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(override != nil ? 0.92 : 0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8 * scale)
                        .padding(.vertical, 5 * scale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(outputFieldBox(active: false))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Click to edit — \(dir.path)")
                if override != nil {
                    Button { vm.sessionOutputOverride = .sibling } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11 * scale))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Reset to the file’s folder for this session")
                }
            }
            Button(action: pickOutputFolder) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .help("Choose output folder in Finder…")
            Button { NotificationCenter.default.post(name: .showOutputDirectory, object: nil) } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("Output Directory settings")
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
        )
    }

    /// Text-field-style box for the output path (subtle inset + border; accent border while editing).
    private func outputFieldBox(active: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
            .fill(Color.white.opacity(active ? 0.10 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .strokeBorder(active ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.18),
                                  lineWidth: active ? 1 : 0.6)
            )
    }

    private func beginEditingOutputPath(_ dir: URL) {
        outputPathDraft = dir.path
        editingOutputPath = true
        outputFieldFocused = true
    }

    /// Apply the inline-edited path: empty → same folder; a real folder → that folder; a path
    /// ending in a (new) filename → its parent folder; otherwise beep and keep the current dir.
    private func commitOutputPath() {
        defer { editingOutputPath = false; outputFieldFocused = false }
        let typed = outputPathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { vm.sessionOutputOverride = .sibling; return }
        let expanded = (typed as NSString).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            vm.sessionOutputOverride = .folder(URL(fileURLWithPath: expanded))
            return
        }
        // Not an existing directory — fall back to the parent if that's a real folder (so the
        // user can edit the trailing name; producers derive the actual filename themselves).
        let parent = (expanded as NSString).deletingLastPathComponent
        if !parent.isEmpty, fm.fileExists(atPath: parent, isDirectory: &isDir), isDir.boolValue {
            vm.sessionOutputOverride = .folder(URL(fileURLWithPath: parent))
            return
        }
        NSSound.beep()
    }

    /// Open the Finder folder picker directly and set it as this session's output folder.
    private func pickOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = FileToolActions.effectiveOutputDir(for: fileURL)
            ?? fileURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.sessionOutputOverride = .folder(url)
    }

    /// Subtle dashed, red-tinted destructive footer — mirrors `customAddRow`'s "+" pill.
    private func clearAllRow(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                Image(systemName: "trash")
                    .font(.system(size: 11 * scale, weight: .semibold))
                Text("Clear All")
                    .font(.system(size: 12 * scale, weight: .medium))
            }
            .foregroundColor(.red.opacity(0.85))
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 8 * scale)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundColor(.red.opacity(0.35))
            )
        }
        .buttonStyle(.plain)
    }

    /// Confirm-then-wipe the typed-prompt History tab (no undo).
    private func confirmClearPromptHistory() {
        guard confirmDestructive(title: "Clear Prompt History?") else { return }
        withAnimation(.easeInOut(duration: 0.2)) { store.clearHistory() }
    }
}

/// Shared modal confirm for destructive "Clear All" actions. Returns `true` only when
/// the user picks the (first) destructive button. Mirrors AppDelegate's NSAlert pattern.
@MainActor
func confirmDestructive(title: String,
                        confirmTitle: String = "Clear All") -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = "Are you sure? You can not undo this action."
    alert.alertStyle = .warning
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
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
                    MenuActionRow(
                        title: action.rawValue,
                        systemImage: action.icon,
                        isLoading: {
                            if case .loading(_, let a) = vm.stage { return a == action }
                            return false
                        }()
                    ) { runAction(action) }
                }
            }

            Spacer(minLength: 0)

            // Pillar 1: the same "Open in" favorite-app launch row as the chips stage,
            // pinned to the bottom-left corner. Identical ToolRow → identical styling,
            // including the trailing "+" add button. Option+1…9 are functional here too
            // (the tool-hotkey monitor runs in both chips and result stages).
            ToolRow()
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
                            MenuActionRow(title: action.rawValue, systemImage: action.icon) {
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
            // "Continue in [Provider]" handoff removed — the result stays in-app; users
            // can launch into another app directly via the radial launcher / Open-in row.
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

            // New conversation — clear the chat transcript but keep the same file(s),
            // returning to the suggested actions. The only full-reset control here.
            ResultIconButton(systemName: "arrow.clockwise", tooltip: "New conversation") {
                withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                    OverlayViewModel.shared.restartConversation(url: fileURL)
                }
            }

            // Go deeper — Pro-only manual escalation to the most capable model. Hosted
            // only: BYOK uses a fixed model per provider, so it can't escalate.
            if provider is HostedProvider, EntitlementStore.shared.isPremiumUnlocked {
                ResultIconButton(systemName: "sparkles",
                                 tooltip: "Go deeper — re-answer with the most capable model") {
                    goDeeper()
                }
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

        case .result:
            // The result stage is a full chat transcript: user prompts as right-aligned
            // bubbles, assistant replies as full-width Markdown, plus a Thinking row while
            // a follow-up is in flight. Auto-scrolls to the newest turn.
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 10 * scale) {
                        ForEach(vm.conversation) { msg in
                            ChatBubble(message: msg).id(msg.id)
                        }
                        if vm.isAwaitingReply {
                            ThinkingRow().id("thinking")
                        }
                    }
                    .padding(12 * scale)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // When follow-ups are hidden the chips' vertical space is freed.
                // .infinity lets the ScrollView grow to fill it; layoutPriority(1)
                // ensures it wins space over the Spacer below it.
                // When follow-ups are visible it's capped so chips stay on screen.
                .frame(maxHeight: vm.isFollowupsExpanded ? 200 * scale : .infinity)
                .layoutPriority(1)
                .animation(.easeInOut(duration: 0.22), value: vm.isFollowupsExpanded)
                .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.60)
                .onChange(of: vm.conversation.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(vm.conversation.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: vm.isAwaitingReply) { _, awaiting in
                    if awaiting {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
            }

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
        sendTurn(provider: provider, fileURL: fileURL, action: action, typedPrompt: nil)
    }

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        sendTurn(provider: provider, fileURL: fileURL, action: .freeform, typedPrompt: prompt)
    }

    /// Manual escalation: re-answer the last turn on the most capable model. Pro-only,
    /// hosted-only (gated at the call site), so the pricey model fires only on demand.
    private func goDeeper() {
        guard case .result(_, let action, _) = vm.stage else { return }
        sendTurn(provider: provider, fileURL: fileURL, action: action,
                 typedPrompt: nil, forceTier: .extraStrong, regenerate: true)
    }
}

// MARK: - Utility result stage (Pillar 2 — "second result stage")

/// Shown after a file utility produces a NEW file (Stage.fileResult): the output file's
/// details (with a size delta vs the source) sit above the original file's details, both
/// as downward-expanded file pills, plus Reveal-in-Finder / Quick Look / ← back actions.
/// Single column (~500 pt wide). Facts are gathered off-main via FileFacts.gather.
private struct FileResultView: View {
    let original: URL
    let output: URL
    let tool: FileTool
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    @State private var outFacts:  FileFacts.Facts?
    @State private var origFacts: FileFacts.Facts?

    /// Output-vs-original size delta ("73% smaller"), once both facts are loaded.
    private var deltaText: String? {
        guard let o = outFacts, let s = origFacts else { return nil }
        return FileFacts.deltaText(output: o.sizeBytes, original: s.sizeBytes)
    }

    /// Re-gather if the pair changes (e.g. a session URL remap renames the files).
    private var pairKey: String { output.path + "→" + original.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            // ── Header: tool title + actions (Reveal / Quick Look / Back) + close ─
            HStack(spacing: 6 * scale) {
                Image(systemName: tool.systemImage)
                    .font(.system(size: 13 * scale, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
                Text(tool.resultTitle)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6 * scale)
                FileResultIconButton(systemImage: "folder", help: "Reveal in Finder") {
                    FileTools.revealInFinder([output])
                }
                FileResultIconButton(systemImage: "eye", help: "Quick Look") {
                    QuickLookController.shared.present(urls: [output], current: 0)
                }
                FileResultIconButton(systemImage: "arrow.left", help: "Back") {
                    withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                        vm.returnToChips()
                    }
                }
                CloseButton()
            }

            // ── Output (the new file) ────────────────────────────────────────
            sectionCaption("RESULT")
            ExpandedFilePill(url: output, facts: outFacts, badge: deltaText, accent: true)

            // ── Original (the source) ────────────────────────────────────────
            sectionCaption("ORIGINAL")
            ExpandedFilePill(url: original, facts: origFacts, badge: nil, accent: false)

            Spacer(minLength: 0)
        }
        .padding(16 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: pairKey) {
            outFacts  = await FileFacts.gather(output)
            origFacts = await FileFacts.gather(original)
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10 * scale, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(.white.opacity(0.35))
    }
}

/// A file pill expanded downward into a details card: icon + name + size (with an
/// optional delta badge) on top, then a key/value detail grid (kind, dimensions /
/// pages / duration / item count). Draggable out + click-to-Quick-Look, matching the
/// header file pill. `facts == nil` renders just the header until gathering finishes.
private struct ExpandedFilePill: View {
    let url: URL
    let facts: FileFacts.Facts?
    /// e.g. "73% smaller" — tinted capsule beside the size (output pill only).
    let badge: String?
    /// Accent = the produced file (brighter fill + accent border); false = the source.
    let accent: Bool
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    @State private var fileIcon = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()

    var body: some View {
        VStack(alignment: .leading, spacing: 9 * scale) {
            // Header: icon + name + size(+delta) + share
            HStack(spacing: 9 * scale) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()                       // keep thumbnail aspect (no stretch)
                    .frame(width: 30 * scale, height: 30 * scale)

                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12.5 * scale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6 * scale) {
                        Text(facts?.sizeText ?? "—")
                            .font(.system(size: 10.5 * scale, weight: .medium))
                            .foregroundColor(.white.opacity(0.50))
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9.5 * scale, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6 * scale)
                                .padding(.vertical, 1.5 * scale)
                                .background(Color.accentColor.opacity(0.80))
                                .clipShape(Capsule(style: .continuous))
                        }
                    }
                }

                Spacer(minLength: 0)
                ShareButton(fileURL: url)
            }

            // Detail grid (kind + type-specific facts)
            if !detailRows.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 0.75)
                VStack(alignment: .leading, spacing: 5 * scale) {
                    ForEach(detailRows, id: \.0) { row in
                        HStack(spacing: 0) {
                            Text(row.0)
                                .font(.system(size: 10.5 * scale, weight: .medium))
                                .foregroundColor(.white.opacity(0.40))
                                .frame(width: 92 * scale, alignment: .leading)
                            Text(row.1)
                                .font(.system(size: 10.5 * scale, weight: .medium))
                                .foregroundColor(.white.opacity(0.80))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(Color.white.opacity(accent ? 0.07 : 0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .strokeBorder(accent ? Color.accentColor.opacity(0.35)
                                             : Color.white.opacity(0.12),
                                      lineWidth: 0.75)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { QuickLookController.shared.present(urls: [url], current: 0) }
        .onDrag {
            vm.isDraggingOut = true
            return NSItemProvider(object: url as NSURL)
        }
        .help(url.lastPathComponent)
        .onAppear {
            FileThumbnail.load(for: url, size: 30) { fileIcon = $0 }
        }
    }

    /// Type-specific detail rows derived from the gathered facts.
    private var detailRows: [(String, String)] {
        guard let f = facts else { return [] }
        var rows: [(String, String)] = [("Kind", f.kind)]
        if let d = f.dimensions { rows.append(("Dimensions", d)) }
        if let p = f.pageCount  { rows.append(("Pages", p.formatted())) }
        if let d = f.duration   { rows.append(("Duration", d)) }
        if let n = f.itemCount  { rows.append(("Items", n.formatted())) }
        return rows
    }
}

/// Compact icon-only action button for the utility result header (Reveal / Quick Look / Back).
/// Matches the minimize/close circular glass buttons so the header reads as one control cluster.
private struct FileResultIconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.75))
                .frame(width: 22 * scale, height: 22 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(Circle().strokeBorder(
                            Color.white.opacity(isHovered ? 0.22 : 0.12), lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(help)
    }
}

// MARK: - Chat transcript rows

/// One transcript line. User prompts render as a right-aligned tinted capsule;
/// assistant replies render full-width as Markdown.
private struct ChatBubble: View {
    let message: OverlayViewModel.ChatMessage
    @Environment(\.uiScale) private var scale

    var body: some View {
        switch message.role {
        case .user:
            HStack(spacing: 0) {
                Spacer(minLength: 28 * scale)
                Text(message.display)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 11 * scale)
                    .padding(.vertical, 7 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                            .fill(Color.accentColor.opacity(0.32))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                            )
                    )
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            MarkdownText(source: message.display)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Thinking…" row shown beneath the transcript while a follow-up reply is in flight.
private struct ThinkingRow: View {
    @Environment(\.uiScale) private var scale
    var body: some View {
        HStack(spacing: 8 * scale) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.55 * scale)
                .tint(.white)
            Text("Thinking…")
                .font(.system(size: 12 * scale))
                .foregroundColor(.white.opacity(0.45))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // Hidden for media: there's no prompt field to collapse down to, so the
            // toggle would have nothing to do.
            if vm.stage.tag == 1, !FileInspector.isMediaFile(fileURL) {
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
                .help(cached.tag == 5 ? "Back to result" : "Back to AI reply")
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

                    // Overflow control — a right arrow to reveal the hidden files.
                    // (No "+N" badge: it read as a stray blue bar and crowded the
                    // header's trailing buttons against the window edge.)
                    if allFiles.count > 2, hiddenCount > 0 {
                        carouselArrow(forward: true)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
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
            // Icon + name = a click target that opens Quick Look (the pill's drag
            // still works — a drag needs movement, a bare click previews).
            HStack(spacing: 8 * scale) {
                Image(nsImage: fileIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()                       // keep thumbnail aspect (no stretch)
                    .frame(width: 24 * scale, height: 24 * scale)

                VStack(alignment: .leading, spacing: 1 * scale) {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Click to preview · drag to move")
                        .font(.system(size: 9 * scale, weight: .regular))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle())
            .onTapGesture { QuickLookController.shared.present(urls: vm.sessionFileURLs, current: 0) }

            // Share the file via the native macOS share sheet. File utilities now
            // live in the chips-stage "Utilities" tab, not behind a ••• menu here.
            ShareButton(fileURL: fileURL)
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
            FileThumbnail.load(for: fileURL, size: 24) { fileIcon = $0 }
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
            .scaledToFit()                       // keep thumbnail aspect (no stretch)
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
            // Share badge — top-leading corner, visible on hover
            .overlay(alignment: .topLeading) {
                if isHovering {
                    ShareButton(fileURL: fileURL, compact: true)
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
            // Bare click → Quick Look this file (the carousel's other files stay
            // reachable via the panel's ◀ ▶). Drag still moves the file out.
            .onTapGesture {
                let urls = vm.sessionFileURLs
                QuickLookController.shared.present(urls: urls,
                                                   current: urls.firstIndex(of: fileURL) ?? 0)
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
    /// Compact = small dark corner badge (icon-only multi-file pills). Default =
    /// 22×22 glass circle (single-file pill), matching the header controls.
    var compact: Bool = false
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    /// Convenience init for the common single-file case.
    init(fileURL: URL, compact: Bool = false) { fileURLs = [fileURL]; self.compact = compact }
    init(fileURLs: [URL], compact: Bool = false) { self.fileURLs = fileURLs; self.compact = compact }

    private var tooltip: String {
        fileURLs.count == 1 ? "Share file" : "Share \(fileURLs.count) files"
    }

    var body: some View {
        ShareLink(items: fileURLs) {
            if compact {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 6 * scale, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 13 * scale, height: 13 * scale)
                    .background(Circle().fill(Color(white: 0.20).opacity(0.95)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            } else {
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
                // Enlarge the hit target beyond the visible 22pt circle: liquidGlassCircle
                // clips hit-testing to the circle, so near-edge clicks (and the frame
                // corners) were dead — making the button feel small / flaky. The 32pt
                // transparent rectangle keeps the visible circle the same but catches them.
                .frame(width: 32 * scale, height: 32 * scale)
                .contentShape(Rectangle())
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
                // Larger hit target than the visible 22pt circle (see CloseButton) so
                // edge clicks register and it stays aligned with the close button.
                .frame(width: 32 * scale, height: 32 * scale)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Minimize")
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

// MARK: - Menu action row
//
// Apple-menu styling for ACTIONS (AI insights + file utilities): a full-width row with a
// leading SF Symbol + label and a soft translucent-white highlight on hover, like a native
// macOS menu item. Pills (ActionChip) are reserved for typed PROMPTS (History / Custom).
// Kept within the ChipsLayout.rowStride budget so the chips-stage window-height math is
// unchanged — no AppDelegate.sizeForStage edit needed.

struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var isLoading: Bool = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9 * scale) {
                ZStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.5)
                            .tint(.white)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 12 * scale, weight: .medium))
                    }
                }
                .frame(width: 16 * scale, height: 16 * scale)
                .foregroundColor(.white.opacity(0.70))

                Text(title)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8 * scale)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Full-row rounded highlight — the macOS menu "selection" look, neutral
            // white so it sits on the dark card glass without competing for attention.
            .background(
                RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
        .disabled(isLoading)
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
            // Liquid Glass capsule (real glassEffect on macOS 26; subtle blur fallback below).
            .liquidGlassCapsule(tintOpacity: isHovered ? 0.12 : 0.20)
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

// MARK: - Conversation orchestrator
//
// Every chip tap and typed prompt funnels through sendTurn() so the result stage is
// one continuous chat transcript, not a series of one-shot answers. The document is
// extracted ONCE per session (cached in vm.baseContext) and the WHOLE conversation is
// re-sent every turn, so follow-ups keep the file context without re-reading the file.

/// Deferred stage write (one runloop tick). Shared by both run sites — mirrors the
/// per-view setStage(): never mutate `stage` inside an active layout pass. Entering
/// .result collapses follow-ups so the section starts closed.
@MainActor
private func applyStage(_ stage: OverlayViewModel.Stage) {
    DispatchQueue.main.async {
        if case .result = stage { OverlayViewModel.shared.isFollowupsExpanded = false }
        withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
            OverlayViewModel.shared.stage = stage
        }
    }
}

/// Append one turn to the conversation and stream back the assistant's reply.
/// - action: the chip's action, or `.freeform` for a typed prompt.
/// - typedPrompt: the raw text the user typed; `nil` for a chip tap.
/// - forceTier: override the routed model tier (the manual "Go deeper" forces `.extraStrong`).
/// - regenerate: re-answer the EXISTING last user turn on a different model — drops the
///   stale assistant reply and adds no new user bubble (used by "Go deeper").
@MainActor
private func sendTurn(provider: any AIProvider,
                      fileURL: URL,
                      action: AIAction,
                      typedPrompt: String?,
                      forceTier: AITier? = nil,
                      regenerate: Bool = false) {
    let vm = OverlayViewModel.shared

    // What the user's bubble shows vs. what the model receives as this turn's text.
    let display     = typedPrompt ?? action.rawValue
    let instruction = typedPrompt ?? action.systemPrompt

    if let typed = typedPrompt { PromptStore.shared.recordHistory(typed) }
    // Learn which chip actions the user runs, per file category, so future
    // suggestions lead with them (local frecency — see ActionFrecency).
    if typedPrompt == nil, action != .freeform, !regenerate {
        ActionFrecency.record(action, category: FileInspector.category(for: fileURL))
    }
    vm.customPrompt = ""
    vm.cachedResult = nil

    // Is a transcript already on screen? (Determines loading-card vs. thinking-row.)
    let showsTranscript: Bool = { if case .result = vm.stage { return true }; return false }()
    let priorTurns = vm.conversation.count

    if regenerate {
        // "Go deeper": re-answer the existing last user turn on a stronger model.
        // Drop the stale assistant reply; do NOT add a new user bubble.
        if vm.conversation.last?.role == .assistant { vm.conversation.removeLast() }
    } else {
        // Optimistic user bubble.
        vm.conversation.append(.init(role: .user, display: display, modelText: instruction))
    }

    if showsTranscript {
        vm.isAwaitingReply = true            // thinking row appears beneath transcript
    } else {
        applyStage(.loading(url: fileURL, action: action))
    }

    let additionalURLs = vm.additionalFileURLs

    // Resolve the provider FRESH for this turn. The `provider` passed into OverlayView
    // is captured once when the overlay window is first built, and that window is reused
    // for the whole app lifetime (never recreated — see the window invariants). So after
    // the user switches tier (BYOK ↔ Dragaway Free / Pro) the baked-in provider goes
    // STALE: requests keep routing through whatever tier was active at first launch.
    // Re-resolving here makes a switch take effect on the next request — no relaunch —
    // and is why "Dragaway Free" requests were still hitting the stored BYOK key (flash).
    let liveProvider = resolveProvider()

    Task {
        do {
            // Extract the document ONCE per session; reuse for every turn.
            let base: OverlayViewModel.BaseContext
            if let cached = vm.baseContext {
                base = cached
            } else {
                // Pro/subscribers read twice as much of a file before truncation.
                // Resolved on the main actor here; the Worker enforces a matching
                // server-verified ceiling so this can't be spoofed for spend.
                let charLimit = EntitlementStore.shared.isPremiumUnlocked
                    ? FileContentExtractor.maxCharsPro : FileContentExtractor.maxChars
                let (content, imageURL, truncated) = try await buildMultiFileContent(
                    primary: fileURL, additional: additionalURLs, charLimit: charLimit)
                base = .init(content: content, imageURL: imageURL, truncated: truncated)
                vm.baseContext = base
            }

            let turns = buildChatTurns(conversation: vm.conversation,
                                       baseContent: base.content,
                                       imageURL: base.imageURL)
            // Routing decision (model tier + output ceiling). A typed prompt routes
            // through the non-load-bearing heuristic; a chip uses its action's static plan.
            // `forceTier` (manual "Go deeper") overrides the tier, keeping the ceiling.
            let basePlan = typedPrompt.map(RoutingPlan.forCustomPrompt) ?? action.routing
            let plan = forceTier.map { basePlan.with(tier: $0) } ?? basePlan
            // Streaming: deltas grow an assistant bubble live (BYOK providers all
            // stream; the hosted Worker falls back to a single non-streamed reply).
            let text = try await liveProvider.replyStream(
                messages: turns, imageURL: base.imageURL, plan: plan
            ) { delta in
                vm.appendStreamDelta(delta, url: fileURL, action: action)
            }

            vm.contentTruncated = base.truncated
            vm.isAwaitingReply  = false
            // Swap the streamed bubble for the definitive text; if the provider
            // didn't stream (no bubble), append the reply as before.
            if !vm.finalizeStreamedReply(text) {
                vm.conversation.append(.init(role: .assistant, display: text, modelText: text))
            }
            // Don't double-log a regeneration — it answers an already-recorded turn.
            if !regenerate {
                SessionHistoryStore.shared.recordTurn(
                    primary: fileURL, additional: additionalURLs,
                    action: action, prompt: typedPrompt, result: text)
            }
            applyStage(.result(url: fileURL, action: action, text: text))
        } catch {
            vm.abortStreamedReply()   // keep any partial text; stop tracking the bubble
            vm.isAwaitingReply = false
            let msg = error.localizedDescription
            if priorTurns > 0 {
                // Keep the transcript — surface the failure as an assistant note.
                let note = "⚠️ \(msg)"
                vm.conversation.append(.init(role: .assistant, display: note, modelText: note))
                applyStage(.result(url: fileURL, action: action, text: note))
            } else {
                // Nothing on screen yet — show the error stage (drops the lone bubble).
                vm.conversation.removeAll()
                applyStage(.error(url: fileURL, message: msg))
            }
        }
    }
}

/// Serialise the transcript into provider ChatTurns. A leading system turn sets the
/// persona; the FIRST user turn carries the extracted document appended to its
/// instruction (skipped for image sessions — the image is attached separately).
@MainActor
private func buildChatTurns(conversation: [OverlayViewModel.ChatMessage],
                            baseContent: String,
                            imageURL: URL?) -> [ChatTurn] {
    var turns: [ChatTurn] = [
        ChatTurn(role: "system", content:
            "You are Dragaway, a concise assistant embedded in macOS. The user dropped a "
            + "document or image and asks about it. Answer directly and format replies "
            + "in Markdown.")
    ]
    var documentAttached = false
    for msg in conversation {
        switch msg.role {
        case .user:
            // The document rides on the FIRST user turn as a SEPARATE, stable block
            // (`cacheableDocument`) so prompt caching can target it (doc §6). Image
            // sessions attach the image instead, so they carry no document.
            if !documentAttached {
                documentAttached = true
                let doc = (imageURL == nil && !baseContent.isEmpty) ? baseContent : nil
                turns.append(ChatTurn(role: "user", content: msg.modelText, cacheableDocument: doc))
            } else {
                turns.append(ChatTurn(role: "user", content: msg.modelText))
            }
        case .assistant:
            turns.append(ChatTurn(role: "assistant", content: msg.display))
        }
    }
    return turns
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
    additional additionalURLs: [URL],
    charLimit: Int = FileContentExtractor.maxChars
) async throws -> (content: String, imageURL: URL?, truncated: Bool) {
    let allURLs = [fileURL] + additionalURLs

    // ── Single image (no additionals) ─────────────────────────────────────────
    if allURLs.count == 1, FileInspector.isImageFile(allURLs[0]) {
        return ("Analyse the attached image.", allURLs[0], false)
    }

    // ── Single non-image ──────────────────────────────────────────────────────
    if allURLs.count == 1 {
        // Media has no AI path in the UI; guard here too so a stray call never spends
        // tokens decoding binary audio/video as Latin-1 text.
        if FileInspector.isMediaFile(allURLs[0]) {
            throw FileContentExtractor.ExtractionError.unsupportedFileType
        }
        let result = try await FileContentExtractor.extract(from: allURLs[0], limit: charLimit)
        return (result.text, nil, result.truncated)
    }

    // ── Multiple files ────────────────────────────────────────────────────────
    var sections: [String] = []
    var anyTruncated = false
    for url in allURLs {
        let body: String
        if FileInspector.isMediaFile(url) {
            // Never feed raw audio/video to the model — name it and move on.
            body = "[Media: \(url.lastPathComponent) — audio/video is not analysed]"
        } else if FileInspector.isImageFile(url) {
            // Vision analysis is only available for single-image sessions;
            // in multi-file mode describe the image by name / context.
            body = "[Image: \(url.lastPathComponent) — visual description not available in multi-file mode]"
        } else if let result = try? await FileContentExtractor.extract(from: url, limit: charLimit) {
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
        let urls = vm.pendingDroppedURLs
        guard let first = urls.first else { return AnyView(EmptyView()) }

        // Title: single filename, or "N files" for a batch.
        let title = urls.count == 1 ? first.lastPathComponent : "\(urls.count) files"
        let addLabel = urls.count == 1 ? "Add to session" : "Add \(urls.count) files"

        return AnyView(
            VStack(alignment: .leading, spacing: 8 * scale) {

                // ── Header ─────────────────────────────────────────────────────
                HStack(spacing: 6 * scale) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                    Text(title)
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // Dismiss / cancel
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                            vm.pendingDroppedURLs = []
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
                    Button { addToSession(urls: urls) } label: {
                        Label(addLabel, systemImage: "plus.circle.fill")
                            .font(.system(size: 11 * scale, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7 * scale)
                            .background(Color.accentColor.opacity(0.88))
                            .clipShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("Analyse all files together in the current session")

                    // New session
                    Button { startNewSession(urls: urls) } label: {
                        Label("New session", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11 * scale, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7 * scale)
                            .liquidGlassCapsule(tintOpacity: 0.38)
                    }
                    .buttonStyle(.plain)
                    .help("Start a new session with only the new file(s)")
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

    private func addToSession(urls: [URL]) {
        // Only analysable files join the session; the drop layer already filtered,
        // but guard again so a Finder/legacy path can't sneak an unsupported type in.
        let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
        guard !supported.isEmpty else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.80)) {
                vm.pendingDroppedURLs = []
            }
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
            vm.additionalFileURLs.append(contentsOf: supported)
            vm.pendingDroppedURLs = []
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

    private func startNewSession(urls: [URL]) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) {
            vm.pendingDroppedURLs = []
            vm.setChips(urls: urls)   // setChips() resets additionalFileURLs to the batch
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
            // Warm BOTH chip leaves the real card uses: MenuActionRow (AI actions /
            // utilities) and ActionChip (typed-prompt pills).
            ForEach(["Summarise", "Key points", "Explain"], id: \.self) { title in
                MenuActionRow(title: title, systemImage: "sparkles", action: {})
            }
            ActionChip(title: "Saved prompt", isLoading: false, action: {})
            PromptField(text: .constant(""), onSubmit: {})
            MarkdownText(source: "**Warming up** the renderer…")
        }
        .padding(12)
        .frame(width: 280, height: 320)
        .liquidGlass(cornerRadius: 22, tintOpacity: 0.7)
        .environment(\.uiScale, UIScale.current.multiplier)
    }
}
