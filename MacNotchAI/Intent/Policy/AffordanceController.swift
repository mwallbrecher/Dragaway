import AppKit
import Carbon.HIToolbox
import SwiftUI

// THESIS (L4/L5 glue) — drives both exposure channels over one scorer:
//
//   PASSIVE  scorer top-1 ≥ θ → AffordancePolicy guardrails → resolver freshness
//            → whisper below the notch. Accept = ⌥⏎ or click; dismiss = ×;
//            no reaction = auto-fade after 8 s (logged as weak negative).
//   ACTIVE   ⌃⌥⌘I (or debug menu) → top-3 ticker, NO gate — a solicited
//            suggestion cannot annoy. Every summon is a labelled ground-truth
//            moment; a summon while the passive channel was silent is a logged
//            false negative (RQ1 gold, ARCHITECTURE §7/§10).
//
// Every lifecycle event appends to affordance-log.jsonl (content-free, next to
// the traces): shows, outcomes, summons, and above-θ-but-blocked decisions.

extension Notification.Name {
    /// THESIS hook: posted after a whisper accept opened the clipboard session;
    /// the chips view runs the resolved action as soon as it is on screen.
    static let intentAutoRunAction = Notification.Name("com.aidrop.thesis.intentAutoRunAction")
}

@MainActor
final class AffordanceController {

    private unowned let scorer: IntentScorer
    private unowned let extractor: FeatureExtractor

    private var policy: AffordancePolicy
    private var window: WhisperWindow?
    private var current: IntentSuggestion?
    private var shownAt: TimeInterval = 0
    private var fadeTimer: Timer?
    private var tickerVisible = false

    private let acceptHotkey = GlobalHotkey()   // ⌥⏎, live only while a whisper shows
    private let summonHotkey = GlobalHotkey()   // ⌃⌥⌘I, live while the engine runs
    private var logHandle: FileHandle?

    /// Whisper auto-fade (ignore) window; hover pauses it.
    private let fadeSeconds: TimeInterval = 8

    init(scorer: IntentScorer, extractor: FeatureExtractor) {
        self.scorer = scorer
        self.extractor = extractor
        self.policy = AffordancePolicy(mutes: scorer.config.mutes)
    }

    // MARK: Lifecycle (engine start/stop)

    func start() {
        openLog()
        // Rare-by-design default chord (conflict-safe, three modifiers); becomes
        // user-configurable with the M4 user-control surface.
        summonHotkey.register(keyCode: UInt32(kVK_ANSI_I),
                              modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            self?.toggleTicker()
        }
    }

    func stop() {
        summonHotkey.unregister()
        hideWindow(recordIgnoreIfPending: false)
        try? logHandle?.close()
        logHandle = nil
    }

    /// Config was reloaded — re-seed the mutes (tier/θ are read live per decision).
    func configReloaded() {
        policy = AffordancePolicy(mutes: scorer.config.mutes)
    }

    // MARK: Passive channel — called by the engine after each scored event

    func evaluate(at t: TimeInterval) {
        guard current == nil, !tickerVisible else { return }   // one surface at a time
        guard let top = scorer.scores(at: t).first else { return }
        guard top.probability >= scorer.config.exposureThreshold else { return }

        // Quiet-context probe only AFTER the cheap θ gate (CGWindowList costs ~ms).
        // M3 quiet = frontmost-window-fullscreen (presentation/video); screen-share
        // detection is an M5 TODO (needs ScreenCaptureKit polling).
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let verdict = policy.decide(intentClass: top.intentClass,
                                    probability: top.probability,
                                    frontApp: frontApp,
                                    quietContext: QuietContext.isQuiet(),
                                    at: t, config: scorer.config)

        guard verdict.isShow else {
            // Above θ but blocked — analytically interesting, so log it (silent
            // below-θ moments are the score log's job, M5).
            if case .silent(let reason) = verdict {
                log(event: "blocked", intentClass: top.intentClass,
                    p: top.probability, t: t, extra: ["reason": reason])
            }
            return
        }

        // M3: translation only ⇒ resolve via the clipboard candidate.
        guard let candidate = extractor.translationCandidate,
              let suggestion = TaskResolver.resolveTranslation(candidate: candidate,
                                                               probability: top.probability)
        else {
            log(event: "blocked", intentClass: top.intentClass,
                p: top.probability, t: t, extra: ["reason": "stale candidate"])
            return
        }

        policy.confirmShown(at: t)
        current = suggestion
        shownAt = t
        showWhisper(suggestion)
        log(event: "shown", intentClass: suggestion.intentClass,
            p: suggestion.probability, t: t,
            extra: ["action": suggestion.action.rawValue])
    }

    // MARK: Active channel — summon ticker

    func toggleTicker() {
        if tickerVisible { hideWindow(recordIgnoreIfPending: false); return }
        hideWindow(recordIgnoreIfPending: true)   // a live whisper counts as ignored

        let t = Date().timeIntervalSince1970
        let top3 = Array(scorer.scores(at: t).prefix(3))
        let theta = scorer.config.exposureThreshold
        let rows = top3.map { b -> TickerRow in
            let evidence = b.contributions.prefix(2)
                .map { "\($0.feature.rawValue) +\(String(format: "%.1f", $0.value))" }
                .joined(separator: " · ")
            var suggestion: IntentSuggestion?
            if b.intentClass == .translation, let c = extractor.translationCandidate {
                suggestion = TaskResolver.resolveTranslation(candidate: c, probability: b.probability)
            }
            return TickerRow(intentClass: b.intentClass, probability: b.probability,
                             evidenceLine: evidence.isEmpty ? "no live evidence" : evidence,
                             suggestion: suggestion)
        }

        // Ground-truth labelling: the user summoned NOW. If the passive channel
        // had nothing above θ, that is a recorded false negative (RQ1).
        let passiveSilent = (top3.first?.probability ?? 0) < theta
        log(event: "summon", intentClass: top3.first?.intentClass ?? .translation,
            p: top3.first?.probability ?? 0, t: t,
            extra: ["passive_was_silent": passiveSilent ? "true" : "false"])

        tickerVisible = true
        show(content: .ticker(rows), size: CGSize(width: 420, height: 150))
    }

    // MARK: Outcomes

    private func accept(_ suggestion: IntentSuggestion) {
        let t = Date().timeIntervalSince1970
        policy.record(.accepted, intentClass: suggestion.intentClass, at: t, config: scorer.config)
        log(event: "accepted", intentClass: suggestion.intentClass,
            p: suggestion.probability, t: t,
            extra: ["action": suggestion.action.rawValue,
                    "latency_s": String(format: "%.1f", t - shownAt)])
        hideWindow(recordIgnoreIfPending: false)

        // Freshness re-check at the moment of consent, then hand off to the
        // EXISTING clipboard-session path (⌃⌘N) — raw text enters a session only
        // now. The chips view auto-runs the resolved action once it's on screen.
        guard TaskResolver.pasteboardMatches(suggestion.candidateHash) else { NSSound.beep(); return }
        (NSApp.delegate as? AppDelegate)?.openSessionFromClipboard()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NotificationCenter.default.post(name: .intentAutoRunAction, object: suggestion.action)
        }
    }

    private func dismiss(_ suggestion: IntentSuggestion) {
        let t = Date().timeIntervalSince1970
        policy.record(.dismissed, intentClass: suggestion.intentClass, at: t, config: scorer.config)
        log(event: "dismissed", intentClass: suggestion.intentClass,
            p: suggestion.probability, t: t, extra: [:])
        hideWindow(recordIgnoreIfPending: false)
    }

    private func fadeExpired() {
        guard let s = current else { return }
        let t = Date().timeIntervalSince1970
        policy.record(.ignored, intentClass: s.intentClass, at: t, config: scorer.config)
        log(event: "ignored", intentClass: s.intentClass, p: s.probability, t: t, extra: [:])
        hideWindow(recordIgnoreIfPending: false)
    }

    // MARK: Window plumbing

    private func showWhisper(_ suggestion: IntentSuggestion) {
        show(content: .suggestion(suggestion), size: CGSize(width: 460, height: 44))
        acceptHotkey.register(keyCode: UInt32(kVK_Return),
                              modifiers: UInt32(optionKey)) { [weak self] in
            guard let self, let s = self.current else { return }
            self.accept(s)
        }
        armFade()
    }

    private func show(content: WhisperContent, size: CGSize) {
        let win = window ?? WhisperWindow(contentSize: size)
        window = win

        let root: AnyView
        switch content {
        case .suggestion(let s):
            root = AnyView(WhisperSuggestionView(
                suggestion: s,
                onAccept: { [weak self] in self?.accept(s) },
                onDismiss: { [weak self] in self?.dismiss(s) },
                onHover: { [weak self] hovering in
                    hovering ? self?.fadeTimer?.invalidate() : self?.armFade()
                }))
        case .ticker(let rows):
            root = AnyView(WhisperTickerView(
                rows: rows,
                onAccept: { [weak self] s in self?.accept(s) },
                onClose: { [weak self] in self?.hideWindow(recordIgnoreIfPending: false) }))
        }

        win.contentView = NSHostingView(rootView: root)
        win.setContentSize(size)
        win.place(size: size)
        win.alphaValue = 0
        win.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            win.animator().alphaValue = 1
        }
    }

    private func hideWindow(recordIgnoreIfPending: Bool) {
        fadeTimer?.invalidate(); fadeTimer = nil
        acceptHotkey.unregister()
        if recordIgnoreIfPending, let s = current {
            let t = Date().timeIntervalSince1970
            policy.record(.ignored, intentClass: s.intentClass, at: t, config: scorer.config)
            log(event: "ignored", intentClass: s.intentClass, p: s.probability, t: t, extra: [:])
        }
        current = nil
        tickerVisible = false
        guard let win = window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            win.animator().alphaValue = 0
        }) {
            win.orderOut(nil)
        }
    }

    private func armFade() {
        fadeTimer?.invalidate()
        let t = Timer(timeInterval: fadeSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeExpired() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    // MARK: Affordance log (content-free JSONL beside the traces)

    private func openLog() {
        let url = TraceRecorder.tracesDirectory().appendingPathComponent("affordance-log.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: url)
        _ = try? logHandle?.seekToEnd()
    }

    private func log(event: String, intentClass: IntentClass, p: Double,
                     t: TimeInterval, extra: [String: String]) {
        var record: [String: String] = [
            "t": String(format: "%.2f", t),
            "event": event,
            "class": intentClass.rawValue,
            "p": String(format: "%.3f", p),
        ]
        record.merge(extra) { a, _ in a }
        guard let data = try? JSONEncoder().encode(record) else { return }
        logHandle?.write(data)
        logHandle?.write(Data("\n".utf8))
    }
}

// MARK: - Quiet contexts (ARCHITECTURE §7)

enum QuietContext {
    /// M3: frontmost window covers the whole screen ⇒ presentation / video / focus
    /// work — never speak into that. Uses window GEOMETRY only (no Screen Recording
    /// permission needed; only window NAMES are TCC-gated).
    /// TODO(M5): screen-sharing/recording detection via ScreenCaptureKit.
    static func isQuiet() -> Bool {
        guard let screen = NSScreen.main,
              let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return false }

        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == frontPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            if bounds.width >= screen.frame.width, bounds.height >= screen.frame.height {
                return true
            }
        }
        return false
    }
}
