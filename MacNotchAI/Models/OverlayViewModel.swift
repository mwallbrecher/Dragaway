import SwiftUI
import Combine
import AppKit

/// Shared state that drives which stage the overlay is in.
/// AppDelegate writes to it; OverlayView reads from it.
@MainActor
class OverlayViewModel: ObservableObject {
    static let shared = OverlayViewModel()

    // Persisted UI preference keys
    private static let keyChipsExpanded     = "pref.chipsExpanded"
    private static let keyFollowupsExpanded = "pref.followupsExpanded"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // ── Restore persisted UI preferences from the previous session ────────
        // This means collapsing chips or follow-ups carries over between drops.
        if let saved = UserDefaults.standard.object(forKey: Self.keyChipsExpanded) as? Bool {
            isChipsExpanded = saved
        }
        if let saved = UserDefaults.standard.object(forKey: Self.keyFollowupsExpanded) as? Bool {
            isFollowupsExpanded = saved
        }

        // ── Persist changes automatically ─────────────────────────────────────
        // dropFirst() skips the initial value that Combine emits on subscription
        // so we don't write UserDefaults unnecessarily at startup.
        $isChipsExpanded
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: Self.keyChipsExpanded) }
            .store(in: &cancellables)

        $isFollowupsExpanded
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: Self.keyFollowupsExpanded) }
            .store(in: &cancellables)
    }

    /// Active tab in the stage-2 prompt section (the dropped-file chips card).
    /// Suggested = file-type action chips; History = re-runnable typed prompts;
    /// Custom = user-curated prompts. Observed by AppDelegate so the chips window
    /// resizes to the active tab's row count.
    enum ChipsTab: Int, CaseIterable {
        case suggested, history, custom
    }

    enum Stage {
        case waitingForDrop
        case chips(url: URL, actions: [AIAction])
        case loading(url: URL, action: AIAction)
        case result(url: URL, action: AIAction, text: String)
        case error(url: URL, message: String)

        var showsRightColumn: Bool {
            switch self {
            case .loading, .result, .error: return true
            default: return false
            }
        }

        var fileURL: URL? {
            switch self {
            case .chips(let u, _), .loading(let u, _),
                 .result(let u, _, _), .error(let u, _): return u
            default: return nil
            }
        }

        /// Integer tag used as SwiftUI animation value when stage changes.
        var tag: Int {
            switch self {
            case .waitingForDrop: return 0
            case .chips:          return 1
            case .loading:        return 2
            case .result:         return 3
            case .error:          return 4
            }
        }
    }

    @Published var stage: Stage = .waitingForDrop
    // Active tab in the stage-2 prompt section. Reset to .suggested on each fresh
    // drop so a new file always opens on its suggested actions.
    @Published var chipsTab: ChipsTab = .suggested
    @Published var isDragHovering = false
    // True when the current result was produced from content cut to fit the
    // extractor's char/page cap. Drives the "analysed the first part" hint.
    @Published var contentTruncated = false
    @Published var isDraggingOut  = false
    @Published var customPrompt: String = ""

    // Last AI result snapshot — saved when the user taps ← back so they can
    // restore it via → without re-running the AI call. Cleared on fresh drop,
    // new action start, or full reset.
    @Published var cachedResult: Stage? = nil
    // Drives the "Session opened in …" confirmation pill in stage 2.
    // Set after handoff navigation, auto-cleared after 6 s.
    @Published var handoffProviderName: String? = nil

    /// User-applied drag offset (screen coordinates: +x right, +y up) for the
    /// movable window. Applied on top of the notch-anchored origin in
    /// OverlayWindow.notchFrame, so it survives every stage resize. Reset to .zero
    /// on each fresh drop (setChips) and full reset() so the default origin stays
    /// pinned to the notch — only the current session can be nudged.
    @Published var userDragOffset: CGSize = .zero

    // ── Minimize / restore ─────────────────────────────────────────────────────
    // A session parked by the − (minimize) button. Kept SEPARATE from `stage` so the
    // overlay can fully tear down — freeing Stage-1 drag detection so new drags still
    // pop the pill — while the parked session waits to be restored from the menu bar.
    struct MinimizedSnapshot {
        var stage: Stage
        var chipsTab: ChipsTab
        var isChipsExpanded: Bool
        var isFollowupsExpanded: Bool
        var userDragOffset: CGSize
        var cachedResult: Stage?
        var additionalFileURLs: [URL]
        var contentTruncated: Bool
        var customPrompt: String
    }

    /// True while a minimized session is waiting to be restored. Drives the menu-bar
    /// icon's left-click (restore the session vs. open the menu).
    @Published var hasMinimizedSession: Bool = false
    private var minimizedSnapshot: MinimizedSnapshot?

    /// True when the system "Reduce Motion" accessibility setting is on.
    /// Used to drop the jelly scale entirely so the pill just settles in place.
    var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// URL of a second file dropped while an active session is running.
    /// Shown as a banner prompt: "Add to session" or "New session".
    /// Cleared when the user picks an option or dismisses.
    @Published var pendingSecondFileURL: URL? = nil

    /// Files added to the current session via "Add to session".
    /// Their content is concatenated with the primary file's content in AI calls.
    /// Cleared on reset() and setChips() (fresh session).
    @Published var additionalFileURLs: [URL] = []

    // ── Jelly wobble ─────────────────────────────────────────────────────────
    // Applied to the pill scaleEffect in OverlayView (outside clipShape so it
    // overflows into the transparent canvas without hitting NSHostingView clip).
    // IMPORTANT: NSView bounds are NOT changed by SwiftUI scaleEffect — the
    // drag hitbox is always the full 288×96 canvas, regardless of visual scale.
    @Published var jellyX: CGFloat = 1.0
    @Published var jellyY: CGFloat = 1.0

    // ── Collapse / entry gate ─────────────────────────────────────────────────
    // OverlayView combines this with its local `appeared` Bool to compute
    // `isAtFullScale`. Setting isCollapsing = true plays the spring in reverse
    // (Y: 1.0 → 0.02, squishing back into the notch). reset() clears it so the
    // next entry (or reuse) plays the pop-in spring again.
    @Published var isCollapsing:        Bool = false
    @Published var isChipsExpanded:     Bool = true     // overwritten by init() from UserDefaults
    @Published var isFollowupsExpanded: Bool = false    // overwritten by init() from UserDefaults

    // MARK: - Jelly
    //
    // Design rule: ONE withAnimation call per method, called directly on the main
    // thread. No Tasks, no sleep-based timing, no multi-phase choreography.
    // The spring's own damping ratio produces the wobble naturally — if damping < 1
    // the spring overshoots and oscillates to rest, which IS the wobble effect.
    // This eliminates the entire class of "two concurrent withAnimation on the same
    // binding" crashes that multi-Task approaches produce.

    func startJellyHover() {
        // Reduce Motion: no scale at all — the pill stays put.
        guard !reduceMotion else { return }
        // Subtle 1.05 lift, well-damped so it reaches the target cleanly with no
        // oscillation. A calm "alive" cue rather than an expressive bounce.
        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            jellyX = 1.05; jellyY = 1.05
        }
    }

    func stopJellyHover() {
        // High damping fraction → spring settles back to 1.0 without overshoot.
        // Previously 0.44 (visible wobble); now a gentle return, no oscillation.
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            jellyX = 1.0; jellyY = 1.0
        }
    }

    // MARK: - State

    func setChips(url: URL) {
        // A genuine new drop supersedes any parked (minimized) session.
        minimizedSnapshot = nil
        hasMinimizedSession = false
        additionalFileURLs = []   // fresh drop clears any previously added files
        chipsTab = .suggested     // always open a new file on its suggested actions
        // Fresh drop — previous session's cached result no longer relevant.
        cachedResult = nil
        // Fresh drop re-anchors the window at the notch; discard any manual nudge.
        userDragOffset = .zero
        contentTruncated = false
        // Fresh drop = a new history session (record persisted on the first turn).
        SessionHistoryStore.shared.beginSession(primary: url)
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    /// Navigate back to the chips stage while keeping the current result cached
    /// so the user can tap → to restore it without re-running the AI.
    func navigateBackToChips(savingResult result: Stage, url: URL) {
        cachedResult = result
        stage = .chips(url: url, actions: FileInspector.suggestedActions(for: url))
        customPrompt = ""
    }

    // MARK: - Minimize / restore

    /// Capture the current session so it can be restored later. Returns false (no-op)
    /// at `waitingForDrop` — there is no session to minimize.
    func minimizeCurrentSession() -> Bool {
        guard stage.tag != 0 else { return false }
        minimizedSnapshot = MinimizedSnapshot(
            stage: stage, chipsTab: chipsTab,
            isChipsExpanded: isChipsExpanded, isFollowupsExpanded: isFollowupsExpanded,
            userDragOffset: userDragOffset, cachedResult: cachedResult,
            additionalFileURLs: additionalFileURLs, contentTruncated: contentTruncated,
            customPrompt: customPrompt)
        hasMinimizedSession = true
        return true
    }

    /// Park an externally-built snapshot (e.g. reopening a session from the history
    /// menu) so the standard restoreMinimizedSession() path can bring it on screen.
    func stageMinimized(_ snapshot: MinimizedSnapshot) {
        minimizedSnapshot = snapshot
        hasMinimizedSession = true
    }

    /// Hand back (and clear) the parked snapshot. Returns nil if nothing is parked.
    func consumeMinimizedSnapshot() -> MinimizedSnapshot? {
        defer { minimizedSnapshot = nil; hasMinimizedSession = false }
        return minimizedSnapshot
    }

    /// Re-apply a parked snapshot. `stage` is set LAST so AppDelegate's resize
    /// observer fires with the final stage already in place.
    func applySnapshot(_ s: MinimizedSnapshot) {
        isChipsExpanded     = s.isChipsExpanded
        isFollowupsExpanded = s.isFollowupsExpanded
        chipsTab            = s.chipsTab
        userDragOffset      = s.userDragOffset
        cachedResult        = s.cachedResult
        additionalFileURLs  = s.additionalFileURLs
        contentTruncated    = s.contentTruncated
        customPrompt        = s.customPrompt
        stage               = s.stage
    }

    // MARK: - Session URL remap

    /// Update every reference to `old` in the live session to `new` after a rename or
    /// move. Patches the primary stage URL (recomputing chip actions), the additional
    /// files, any cached result, and the parked minimized snapshot. No-op if equal.
    func remapSessionURL(from old: URL, to new: URL) {
        guard old != new else { return }
        func remap(_ u: URL) -> URL { u == old ? new : u }

        // Keep the active history record's paths in sync (best-effort).
        SessionHistoryStore.shared.remapPath(from: old, to: new)

        // Additional files first so chip recomputation below sees the new list.
        additionalFileURLs = additionalFileURLs.map(remap)

        switch stage {
        case .waitingForDrop:
            break
        case .chips(let u, _):
            let primary = remap(u)
            stage = .chips(url: primary,
                           actions: FileInspector.suggestedActions(forAll: [primary] + additionalFileURLs))
        case .loading(let u, let a):
            stage = .loading(url: remap(u), action: a)
        case .result(let u, let a, let t):
            stage = .result(url: remap(u), action: a, text: t)
        case .error(let u, let m):
            stage = .error(url: remap(u), message: m)
        }

        if let cached = cachedResult {
            switch cached {
            case .result(let u, let a, let t): cachedResult = .result(url: remap(u), action: a, text: t)
            case .chips(let u, let acts):      cachedResult = .chips(url: remap(u), actions: acts)
            default: break
            }
        }

        if var snap = minimizedSnapshot {
            snap.additionalFileURLs = snap.additionalFileURLs.map(remap)
            switch snap.stage {
            case .chips(let u, let acts):      snap.stage = .chips(url: remap(u), actions: acts)
            case .loading(let u, let a):       snap.stage = .loading(url: remap(u), action: a)
            case .result(let u, let a, let t): snap.stage = .result(url: remap(u), action: a, text: t)
            case .error(let u, let m):         snap.stage = .error(url: remap(u), message: m)
            case .waitingForDrop:              break
            }
            minimizedSnapshot = snap
        }
    }

    /// Partial reset: clears transient interaction flags without touching `stage`.
    /// Called at the START of hideOverlay() so the fade animation plays over the
    /// current stage's UI — not over a prematurely-switched WaitingPillView.
    func partialReset() {
        isDragHovering      = false
        isDraggingOut       = false
        handoffProviderName = nil
        pendingSecondFileURL = nil
        jellyX              = 1.0
        jellyY              = 1.0
    }

    /// Full state reset. Called once the dismiss animation completes (window hidden)
    /// or when a fading window is recycled by ensureOverlayVisible().
    /// Restores isChipsExpanded / isFollowupsExpanded from the persisted preference
    /// so the next session starts in the state the user left it.
    func reset() {
        stage         = .waitingForDrop
        chipsTab       = .suggested
        isDragHovering = false
        isDraggingOut  = false
        customPrompt   = ""
        cachedResult        = nil
        handoffProviderName = nil
        pendingSecondFileURL  = nil
        additionalFileURLs    = []
        userDragOffset        = .zero
        contentTruncated      = false
        jellyX              = 1.0
        jellyY         = 1.0
        isCollapsing   = false
        // Restore saved preferences so each new session matches the last one.
        isChipsExpanded     = UserDefaults.standard.object(forKey: Self.keyChipsExpanded)     as? Bool ?? true
        isFollowupsExpanded = UserDefaults.standard.object(forKey: Self.keyFollowupsExpanded) as? Bool ?? false
    }
}

/// Shared geometry for the stage-2 prompt-tab content. The chips window is sized in
/// AppDelegate independently of SwiftUI layout, so BOTH the SwiftUI content region
/// (OverlayView) and the window-height calc (AppDelegate) must derive their height
/// from the same numbers — any drift would clip content or leave a gap. All values
/// are UNSCALED; multiply by the UI scale at the call site.
enum ChipsLayout {
    static let rowStride:    CGFloat = 36   // per-row height budget (chip + slack)
    static let rowSpacing:   CGFloat = 6
    static let tabBarHeight: CGFloat = 28
    static let maxVisibleRows = 5           // beyond this the content region scrolls

    /// Height of the (scrollable) tab content region for `rows` rows.
    static func contentHeight(rows: Int) -> CGFloat {
        let n = max(1, min(rows, maxVisibleRows))
        return CGFloat(n) * rowStride + CGFloat(n - 1) * rowSpacing
    }

    /// Logical row count for a tab BEFORE clamping. History shows a 1-row empty
    /// placeholder; Custom always includes the trailing "+ add" row.
    static func rows(for tab: OverlayViewModel.ChipsTab,
                     suggested: Int, history: Int, custom: Int) -> Int {
        switch tab {
        case .suggested: return max(suggested, 1)
        case .history:   return history == 0 ? 1 : history
        case .custom:    return custom + 1
        }
    }
}
