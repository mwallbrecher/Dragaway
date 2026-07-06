import AppKit
import SwiftUI
import Combine

// MARK: - Steps

/// One tour page. `trigger` nil = informational (Next); otherwise the page waits for
/// the REAL action (a drop, a Tab-cycle, a hotkey…) and auto-advances on detection.
struct TutorialStep {
    enum Trigger: String { case drop, dropAnything, tabs, toolLaunched, radial, clipboard }
    let icon: String
    let title: String
    let body: String
    let trigger: Trigger?
    let hint: String

    static let all: [TutorialStep] = [
        .init(icon: "arrow.down.circle",
              title: "Drop a file",
              body: "Drag any file toward the top of your screen — a pill drops from the notch. Release the file on it and a session opens with smart actions for that file.",
              trigger: .drop,
              hint: "Try it now: drag any file from Finder onto the pill."),
        .init(icon: "photo.on.rectangle.angled",
              title: "Drop literally anything",
              body: "Not just files: selected text, links, and images work too. Drag an image straight out of a Google Images results page — no download needed — or drag a text selection from any app.",
              trigger: .dropAnything,
              hint: "Try it now: drag an image from the web (or some selected text) onto the pill."),
        .init(icon: "square.grid.2x2",
              title: "The session card",
              body: "Suggested AI actions adapt to the file and learn what you use. Five tabs: Suggested · History · Custom · Utilities (local conversions, no upload) · Scripts.",
              trigger: .tabs,
              hint: "Try it now: press Tab (or ⇧Tab) to cycle through the tabs."),
        .init(icon: "square.and.arrow.up.on.square",
              title: "Launch into your tools",
              body: "The “Open in” row at the bottom of the card opens the dropped file in your favorite apps. Configure them per file type in Settings → Favorite Tools.",
              trigger: .toolLaunched,
              hint: "Try it now: press ⌥1 or click an app in the row — or Skip if you haven’t added favorites yet."),
        .init(icon: "circle.dashed",
              title: "The radial launcher",
              body: "Hold ⇧ Shift as you START dragging a file: an app wheel fans out around your cursor. Flick to a wedge and release. The top slot starts an AI session. Keys are configurable under Add Hotkey.",
              trigger: .radial,
              hint: "Try it now: hold ⇧ Shift and start dragging any file."),
        .init(icon: "doc.on.clipboard",
              title: "Clipboard powers",
              body: "⌃⌘V opens your clipboard history (last 20 — password managers are never captured). ⌃⌘N opens a new session from whatever is in the clipboard right now.",
              trigger: .clipboard,
              hint: "Try it now: press ⌃⌘V or ⌃⌘N."),
        .init(icon: "camera.viewfinder",
              title: "Screenshots → session",
              body: "Turn on “Open new screenshots in a session” in Settings → Clipboard & Capture, and every ⇧⌘4 / ⇧⌘5 screenshot opens in Dragaway — instantly, or after the floating thumbnail; your choice.",
              trigger: nil, hint: ""),
        .init(icon: "clock.arrow.circlepath",
              title: "Sessions live on",
              body: "Minimize a session with – and bring it back from the menu bar. Recent Sessions keeps your last 25 — searchable (including the answers) via Search Sessions.",
              trigger: nil, hint: ""),
    ]
}

// MARK: - Controller

/// Drives the tour: watches the view model + `.tutorialEvent` posts and advances the
/// current page when its real action happens.
@MainActor
final class TutorialController: ObservableObject {
    @Published var stepIndex = 0
    @Published var stepDone = false
    let steps = TutorialStep.all
    var onExit: (() -> Void)?
    /// The hosting window — dropped to .normal while Settings is opened from a step,
    /// restored to .floating on advance so the tour stays visible during try-its.
    weak var window: NSWindow?

    private var bag = Set<AnyCancellable>()

    init() {
        // A drop is any transition into the chips stage. Distinguish REAL files from
        // materialized non-file drags (text/link/image land in our Drops folder), so
        // the file step and the drop-anything step each demand their own kind.
        OverlayViewModel.shared.$stage
            .sink { [weak self] s in
                guard case .chips(let url, _) = s else { return }
                if url.path.contains("/Drops/") { self?.complete(.dropAnything) }
                else { self?.complete(.drop) }
            }
            .store(in: &bag)
        // Tab-cycling = any chips-tab change while the tour runs.
        OverlayViewModel.shared.$chipsTab
            .dropFirst()
            .sink { [weak self] _ in self?.complete(.tabs) }
            .store(in: &bag)
        // No favorites yet? Adding the FIRST one also completes the tools step —
        // the step adapts into "pick your apps" when the list is empty.
        FavoriteToolsStore.shared.$general
            .dropFirst()
            .sink { [weak self] tools in
                if !tools.isEmpty { self?.complete(.toolLaunched) }
            }
            .store(in: &bag)
        // Explicit feature events (hotkeys, radial, tool launch).
        NotificationCenter.default.publisher(for: .tutorialEvent)
            .compactMap { $0.object as? String }
            .compactMap(TutorialStep.Trigger.init(rawValue:))
            .sink { [weak self] t in self?.complete(t) }
            .store(in: &bag)
    }

    // ── In-window sample drags ────────────────────────────────────────────────
    // Own-app drags never hit the GLOBAL event monitors that normally summon the
    // pill, so raise it manually when a sample drag starts; the drop itself lands in
    // DroppableHostingView as usual. A button-state poll retracts the pill if the
    // drag is released anywhere else.
    private var sampleDragTimer: Timer?

    func sampleDragBegan() {
        DragMonitor.shared.isDraggingFile = true
        sampleDragTimer?.invalidate()
        var upTicks = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { upTicks = 0; return }
                upTicks += 1
                guard upTicks >= 3 else { return }
                self?.sampleDragTimer?.invalidate()
                self?.sampleDragTimer = nil
                DragMonitor.shared.isDraggingFile = false   // no-op after a caught drop
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sampleDragTimer = t
    }

    private func complete(_ t: TutorialStep.Trigger) {
        guard steps.indices.contains(stepIndex),
              steps[stepIndex].trigger == t, !stepDone else { return }
        stepDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.stepDone else { return }
            self.advance()
        }
    }

    func advance() {
        stepDone = false
        window?.level = .floating          // restore if a step dropped it for Settings
        window?.orderFront(nil)
        if stepIndex < steps.count - 1 { stepIndex += 1 } else { finish() }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "tutorialShown")
        onExit?()
    }
}

// MARK: - View

struct TutorialView: View {
    @ObservedObject var controller: TutorialController
    @ObservedObject private var toolsStore = FavoriteToolsStore.shared

    private var step: TutorialStep { controller.steps[controller.stepIndex] }

    static let sampleText = "Dragaway turns any drag into a session — summarise, translate, convert, or launch straight into your tools, all from the notch."
    static let sampleImage: NSImage = NSImage(
        size: NSSize(width: 96, height: 96), flipped: false
    ) { rect in
        NSGradient(colors: [.systemBlue, .systemPurple])?.draw(in: rect, angle: 45)
        return true
    }

    /// Tools step with an empty favorites list → the step becomes a setup step.
    private var needsFavorites: Bool {
        step.trigger == .toolLaunched && toolsStore.general.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<controller.steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == controller.stepIndex ? Color.accentColor
                              : Color.secondary.opacity(0.35))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 22)

            // Icon + done check
            ZStack {
                Image(systemName: step.icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundColor(.accentColor)
                    .opacity(controller.stepDone ? 0.25 : 1)
                if controller.stepDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(height: 64)
            .padding(.top, 14)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: controller.stepDone)

            Text(step.title)
                .font(.title2.bold())
                .padding(.top, 2)

            Text(step.body)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
                .padding(.top, 8)

            if !step.hint.isEmpty {
                Text(controller.stepDone ? "Nice — got it!"
                     : (needsFavorites
                        ? "You haven’t picked any favorite apps yet — choose the tools you most likely want to launch into. Adding your first one completes this step."
                        : step.hint))
                    .font(.callout.weight(.medium))
                    .foregroundColor(controller.stepDone ? .green : .accentColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 30)
                    .padding(.top, 12)
                if step.trigger == .toolLaunched, !controller.stepDone {
                    Button(needsFavorites ? "Choose Favorite Tools…" : "Edit Favorite Tools…") {
                        controller.window?.level = .normal   // let Settings come in front
                        NotificationCenter.default.post(name: .showFavoriteTools, object: nil)
                    }
                    .padding(.top, 6)
                }

                // Self-contained "drag anything" playground: drag these straight onto
                // the notch — no browser hunt needed. (Google Images offered as the
                // real-world variant.)
                if step.trigger == .dropAnything, !controller.stepDone {
                    HStack(spacing: 12) {
                        Text("Drag me — I'm a text selection ✍️")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.15)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor.opacity(0.4)))
                            .onDrag {
                                controller.sampleDragBegan()
                                return NSItemProvider(object: Self.sampleText as NSString)
                            }
                        Image(nsImage: Self.sampleImage)
                            .resizable()
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .onDrag {
                                controller.sampleDragBegan()
                                return NSItemProvider(object: Self.sampleImage)
                            }
                            .help("Drag me — I'm an image")
                    }
                    .padding(.top, 10)
                    Button("…or open Google Images and drag a real one") {
                        NSWorkspace.shared.open(
                            URL(string: "https://www.google.com/search?tbm=isch&q=aurora+borealis")!)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 16)

            Text("You can reopen this tour anytime: Settings → Help.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button("Exit Tutorial") { controller.finish() }
                Spacer()
                Button(step.trigger == nil || controller.stepDone
                       ? (controller.stepIndex == controller.steps.count - 1 ? "Done" : "Next")
                       : "Skip Step") { controller.advance() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 20)
        }
        .frame(width: 460, height: 420)
    }
}
