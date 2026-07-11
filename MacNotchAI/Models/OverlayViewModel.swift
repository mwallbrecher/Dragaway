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
        case suggested, history, custom, utilities, scripts
    }

    enum Stage {
        case waitingForDrop
        case chips(url: URL, actions: [AIAction])
        case loading(url: URL, action: AIAction)
        case result(url: URL, action: AIAction, text: String)
        case error(url: URL, message: String)
        /// "Second result stage" (Pillar 2): a file utility produced `output` from
        /// `original`. Shows both files' details side-by-side with a size delta and a
        /// Reveal-in-Finder action. `output` may be a folder (split/pdf→images).
        case fileResult(original: URL, output: URL, tool: FileTool)

        var showsRightColumn: Bool {
            switch self {
            case .loading, .result, .error: return true
            default: return false
            }
        }

        var fileURL: URL? {
            switch self {
            case .chips(let u, _), .loading(let u, _),
                 .result(let u, _, _), .error(let u, _),
                 .fileResult(let u, _, _): return u
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
            case .fileResult:     return 5
            }
        }
    }

    // MARK: - Conversation (multi-turn chat transcript)
    //
    // The result stage is a real chat transcript, not a single answer. Every chip /
    // typed prompt appends a turn instead of replacing the result, so follow-ups keep
    // the same document context. Only restartConversation() clears it.

    enum ChatRole { case user, assistant }

    /// One rendered transcript line. `display` is what the UI shows (the user's prompt
    /// title, or the assistant's Markdown answer); `modelText` is what is sent to the
    /// model for that turn (the action's system prompt, or the assistant's answer).
    struct ChatMessage: Identifiable, Hashable {
        let id: UUID
        let role: ChatRole
        let display: String
        let modelText: String

        // Explicit id so a streamed bubble can be UPDATED in place (same identity →
        // SwiftUI diffs the text instead of recreating the row on every delta).
        init(id: UUID = UUID(), role: ChatRole, display: String, modelText: String) {
            self.id = id
            self.role = role
            self.display = display
            self.modelText = modelText
        }
    }

    /// The extracted document context, built once per session and reused for every
    /// turn so the file is never re-read / re-extracted. Cleared when the file set
    /// changes (didSet on additionalFileURLs) or on restart.
    struct BaseContext {
        let content: String
        let imageURL: URL?
        let truncated: Bool
    }

    @Published var conversation: [ChatMessage] = []

    // MARK: Streaming replies
    //
    // While a provider streams, deltas grow ONE assistant bubble in place (tracked by
    // id). `finalizeStreamedReply` swaps in the definitive full text at the end;
    // non-streaming providers never create the bubble, so the caller falls back to a
    // plain append.
    private var streamingMessageID: UUID?

    /// Append a streamed text delta. First delta: leaves the loading/thinking state
    /// and creates the assistant bubble (flipping to the result stage if needed).
    func appendStreamDelta(_ delta: String, url: URL, action: AIAction) {
        isAwaitingReply = false
        if case .result = stage {} else {
            withAnimation(.easeInOut(duration: 0.20)) {
                stage = .result(url: url, action: action, text: "")
            }
        }
        if let id = streamingMessageID,
           let i = conversation.firstIndex(where: { $0.id == id }) {
            let old = conversation[i]
            conversation[i] = ChatMessage(id: old.id, role: .assistant,
                                          display: old.display + delta, modelText: "")
        } else {
            let msg = ChatMessage(role: .assistant, display: delta, modelText: "")
            streamingMessageID = msg.id
            conversation.append(msg)
        }
    }

    /// Replace the streamed bubble's text with the definitive full reply.
    /// Returns false when no stream bubble exists (provider didn't stream) —
    /// the caller appends a fresh message instead.
    @discardableResult
    func finalizeStreamedReply(_ full: String) -> Bool {
        defer { streamingMessageID = nil }
        guard let id = streamingMessageID,
              let i = conversation.firstIndex(where: { $0.id == id }) else { return false }
        let old = conversation[i]
        conversation[i] = ChatMessage(id: old.id, role: .assistant,
                                      display: full, modelText: full)
        return true
    }

    /// Stream failed mid-flight: stop tracking the bubble (any partial text stays
    /// visible; the error note is appended separately by the caller).
    func abortStreamedReply() { streamingMessageID = nil }
    /// True while a follow-up turn is in flight (transcript already on screen). Drives
    /// the "Thinking…" row. The FIRST turn uses the .loading stage instead.
    @Published var isAwaitingReply = false
    /// Cached extracted document context for the current session (see BaseContext).
    var baseContext: BaseContext? = nil

    @Published var stage: Stage = .waitingForDrop
    // Active tab in the stage-2 prompt section. Reset to .suggested on each fresh
    // drop so a new file always opens on its suggested actions.
    @Published var chipsTab: ChipsTab = .suggested

    /// Advance the chips-stage tab selection — driven by the Tab / Shift+Tab keys.
    /// Media files expose only Utilities + Scripts (no AI path), so cycling skips
    /// the three AI tabs for them. Wraps around at either end.
    func cycleChipsTab(reverse: Bool = false) {
        let media = sessionFileURLs.first.map(FileInspector.isMediaFile) ?? false
        let tabs: [ChipsTab] = media
            ? [.utilities, .scripts]
            : [.suggested, .history, .custom, .utilities, .scripts]
        let idx = tabs.firstIndex(of: chipsTab) ?? 0
        let next = reverse ? (idx - 1 + tabs.count) % tabs.count
                           : (idx + 1) % tabs.count
        withAnimation(.easeInOut(duration: 0.22)) { chipsTab = tabs[next] }
    }

    @Published var isDragHovering = false
    /// True while the immortal overlay window is un-parked (visible). The window now
    /// lives forever (drag-snapshot fix), so the pill's entry animation replays off
    /// this flag instead of .onAppear — see OverlayView.onChange(of: windowShown).
    @Published var windowShown = false
    // True when the current result was produced from content cut to fit the
    // extractor's char/page cap. Drives the "analysed the first part" hint.
    @Published var contentTruncated = false
    @Published var isDraggingOut  = false
    @Published var customPrompt: String = ""

    // Last AI result snapshot — saved when the user taps ← back so they can
    // restore it via → without re-running the AI call. Cleared on fresh drop,
    // new action start, or full reset.
    @Published var cachedResult: Stage? = nil

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
        var conversation: [ChatMessage]
        var baseContext: BaseContext?
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

    /// File(s) dropped while an active session is running. Shown as a batch-aware
    /// banner prompt: "Add N file(s) to session" or "New session". Cleared when the
    /// user picks an option or dismisses. (Supersedes the old single `pendingSecondFileURL`.)
    @Published var pendingDroppedURLs: [URL] = []

    /// Files added to the current session via "Add to session".
    /// Their content is concatenated with the primary file's content in AI calls.
    /// Cleared on reset() and setChips() (fresh session). Changing the file set
    /// invalidates the cached BaseContext so the next turn re-extracts.
    @Published var additionalFileURLs: [URL] = [] {
        didSet { baseContext = nil }
    }

    /// Every file in the current session — primary (the stage URL) first, then any
    /// files added via "Add to session". Empty when nothing is staged. Used by the
    /// tool launch row to open the whole batch in a favorite app.
    var sessionFileURLs: [URL] {
        guard let primary = stage.fileURL else { return [] }
        return [primary] + additionalFileURLs
    }

    /// Where file-utility outputs go FOR THIS SESSION (overrides the persisted
    /// `OutputDirectoryStore`). `.inherit` = follow the store; `.sibling` = force "next to
    /// the original" (the × reset, even over a persisted default); `.folder` = a folder the
    /// user picked this session. Reset to `.inherit` on a fresh session.
    enum SessionOutput: Equatable {
        case inherit
        case sibling
        case folder(URL)
    }
    @Published var sessionOutputOverride: SessionOutput = .inherit

    /// User's preferred order of the Utilities rows (by `FileTool.title`). Tools not listed
    /// fall back to catalogue order, after the listed ones. Persisted across launches.
    @Published var utilityOrder: [String] =
        UserDefaults.standard.stringArray(forKey: "utility.order") ?? [] {
        didSet { UserDefaults.standard.set(utilityOrder, forKey: "utility.order") }
    }

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
        // Media (video/audio) has no AI actions — open it straight on Utilities so the
        // first thing shown is useful, not an empty Suggested list.
        chipsTab = FileInspector.isMediaFile(url) ? .utilities : .suggested
        // Fresh drop — previous session's cached result no longer relevant.
        cachedResult = nil
        // Fresh drop re-anchors the window at the notch; discard any manual nudge.
        userDragOffset = .zero
        contentTruncated = false
        // Fresh drop = a brand-new conversation.
        conversation = []
        baseContext = nil
        isAwaitingReply = false
        // Fresh drop = a new history session (record persisted on the first turn).
        SessionHistoryStore.shared.beginSession(primary: url)
        // Instant base actions, then async content-aware reorder (see applySmartActions).
        let base = FileInspector.baseActions(for: url)
        stage = .chips(url: url, actions: base)
        customPrompt = ""
        applySmartActions(base: base, primary: url)
    }

    /// Open Stage 2 for a batch of dropped files in ONE session: the first supported
    /// file is the primary, the rest become additional session files. Unsupported
    /// files are skipped; if NONE are supported the stage routes to `.error`. Used by
    /// multi-file drag-drop and the Finder "Add to Dragaway" Quick Action.
    func setChips(urls: [URL]) {
        let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
        guard let primary = supported.first else {
            // Nothing analysable in the batch.
            let name = urls.first?.lastPathComponent ?? "These files"
            minimizedSnapshot = nil
            hasMinimizedSession = false
            stage = .error(
                url: urls.first ?? URL(fileURLWithPath: "/"),
                message: "\"\(name)\" can't be analysed.\nDragaway supports PDF, text, images, and code files.")
            return
        }
        let extras = Array(supported.dropFirst())

        minimizedSnapshot = nil
        hasMinimizedSession = false
        // Media primary → open on Utilities (no AI actions for video/audio).
        chipsTab = FileInspector.isMediaFile(primary) ? .utilities : .suggested
        cachedResult = nil
        userDragOffset = .zero
        contentTruncated = false
        conversation = []
        baseContext = nil
        isAwaitingReply = false
        // Set additionals BEFORE the stage so chip actions reflect the whole batch.
        additionalFileURLs = extras
        SessionHistoryStore.shared.beginSession(primary: primary)
        // Show the card INSTANTLY with the no-peek base actions, then upgrade to the
        // content-aware order once the (file-IO) peek finishes off the main thread.
        // The bounded peek (esp. PDF text extraction) was costing the visible "few ms"
        // before the session appeared.
        let allURLs = [primary] + extras
        let base = FileInspector.baseActions(forAll: allURLs)
        stage = .chips(url: primary, actions: base)
        customPrompt = ""
        applySmartActions(base: base, primary: primary)
    }

    /// Off-main content peek → main-thread reorder → patch the live chips actions if the
    /// order actually changed and the session is still on the same primary file.
    private func applySmartActions(base: [AIAction], primary: URL) {
        guard !base.isEmpty, !FileInspector.isMediaFile(primary) else { return }
        Task.detached(priority: .userInitiated) {
            let signals = FileInspector.peekSignals(primary)
            await MainActor.run {
                // Warm the main-actor peek cache so later synchronous
                // suggestedActions() calls don't re-peek the file on the main thread.
                FileInspector.seedPeekCache(for: primary, signals: signals)
                guard case .chips(let u, let current) = OverlayViewModel.shared.stage,
                      u == primary else { return }
                let reordered = FileInspector.smartReorder(base, primary: primary, signals: signals)
                if reordered != current {
                    OverlayViewModel.shared.stage = .chips(url: primary, actions: reordered)
                }
            }
        }
    }

    /// Restart (↻) scope: "clear chat, keep file". Wipes the transcript and cached
    /// context but keeps the same document(s) and returns to the suggested actions —
    /// a fresh conversation on the same file without re-dropping it.
    func restartConversation(url: URL) {
        conversation = []
        baseContext = nil
        isAwaitingReply = false
        cachedResult = nil
        contentTruncated = false
        customPrompt = ""
        chipsTab = .suggested
        stage = .chips(url: url,
                       actions: FileInspector.suggestedActions(forAll: [url] + additionalFileURLs))
    }

    /// Return to the chips stage from the file-utility result stage. Rebuilds the
    /// suggested actions for the whole session so the user can run another tool or an
    /// AI action on the same file(s). The output file is not added to the session.
    /// Caches the result (like the AI path's `navigateBackToChips`) so the chips header's
    /// → button can restore the utility result without re-running the tool.
    func returnToChips() {
        guard let primary = stage.fileURL else { return }
        cachedResult = stage   // keep the utility result so → can bring it back
        stage = .chips(url: primary,
                       actions: FileInspector.suggestedActions(forAll: [primary] + additionalFileURLs))
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
        // No session at waitingForDrop; never park a turn that is still in flight
        // (the async reply would land into a torn-down session).
        guard stage.tag != 0, !isAwaitingReply else { return false }
        minimizedSnapshot = MinimizedSnapshot(
            stage: stage, chipsTab: chipsTab,
            isChipsExpanded: isChipsExpanded, isFollowupsExpanded: isFollowupsExpanded,
            userDragOffset: userDragOffset, cachedResult: cachedResult,
            additionalFileURLs: additionalFileURLs, contentTruncated: contentTruncated,
            customPrompt: customPrompt, conversation: conversation, baseContext: baseContext)
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
        additionalFileURLs  = s.additionalFileURLs   // didSet clears baseContext…
        contentTruncated    = s.contentTruncated
        customPrompt        = s.customPrompt
        conversation        = s.conversation
        isAwaitingReply     = false
        baseContext         = s.baseContext          // …so restore it AFTER the line above
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
        case .fileResult(let o, let out, let t):
            stage = .fileResult(original: remap(o), output: remap(out), tool: t)
        }

        if let cached = cachedResult {
            switch cached {
            case .result(let u, let a, let t): cachedResult = .result(url: remap(u), action: a, text: t)
            case .chips(let u, let acts):      cachedResult = .chips(url: remap(u), actions: acts)
            case .fileResult(let o, let out, let t):
                cachedResult = .fileResult(original: remap(o), output: remap(out), tool: t)
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
            case .fileResult(let o, let out, let t):
                snap.stage = .fileResult(original: remap(o), output: remap(out), tool: t)
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
        pendingDroppedURLs  = []
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
        pendingDroppedURLs    = []
        additionalFileURLs    = []
        userDragOffset        = .zero
        contentTruncated      = false
        conversation          = []
        baseContext           = nil
        isAwaitingReply       = false
        sessionOutputOverride = .inherit   // fresh session → follow the persisted store
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
    static let maxVisibleRows = 5           // beyond this the content region scrolls

    // ── Tab bar: two captioned groups ("AI Insights" / "Utilities") ───────────
    // The bar is a tiny caption row sitting above the row of tab-icon buttons.
    // `tabBarHeight` is the FULL region (caption + gap + icons) — both the SwiftUI
    // bar and AppDelegate.sizeForStage size off it, so they must stay in lock-step.
    static let tabIconRowHeight: CGFloat = 28   // the icon buttons' row
    static let tabCaptionHeight: CGFloat = 12   // the tiny group caption above them
    static let tabCaptionGap:    CGFloat = 3    // caption → icons spacing
    static let tabBarHeight: CGFloat = tabCaptionHeight + tabCaptionGap + tabIconRowHeight

    /// Tool launch row ("Open in") shown below the chips when the user has favorites:
    /// a small "OPEN IN" caption + a row of app icons. Empty state collapses to a
    /// single muted hint line (`toolHintHeight`). Both are fixed so the SwiftUI
    /// content (ToolRow) and the AppDelegate window-height calc stay in lock-step.
    static let toolRowHeight:  CGFloat = 58   // populated: caption + icon row
    static let toolHintHeight: CGFloat = 24   // empty: one muted line

    /// Height of the (scrollable) tab content region for `rows` rows.
    static func contentHeight(rows: Int) -> CGFloat {
        let n = max(1, min(rows, maxVisibleRows))
        return CGFloat(n) * rowStride + CGFloat(n - 1) * rowSpacing
    }

    /// Logical row count for a tab BEFORE clamping. History shows a 1-row empty
    /// placeholder; Custom always includes the trailing "+ add" row.
    static func rows(for tab: OverlayViewModel.ChipsTab,
                     suggested: Int, history: Int, custom: Int, utilities: Int, scripts: Int) -> Int {
        switch tab {
        case .suggested: return max(suggested, 1)
        case .history:   return history == 0 ? 1 : history + 1   // +1 = "Clear All" footer row
        case .custom:    return custom + 1
        case .utilities: return max(utilities, 1) + 1   // +1 ≈ the output-folder row
        case .scripts:   return max(scripts, 1) + 1     // +1 = "Add / edit in Settings" row
        }
    }
}
