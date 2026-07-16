import AppKit
import ApplicationServices
import Combine

// THESIS — coordinator of the Computational Intent Pipeline (docs/thesis/ARCHITECTURE.md).
//
// M1: SignalBus + L1 sensors + trace recorder. M2: L2 feature extractor + L3 scorer,
// permanently wired to the bus so BOTH live events and replayed traces flow through
// scoring identically (that's the whole point of the replay harness). Sensors and
// recorder start/stop with the engine; the pipeline itself is always attached.
//
// The engine is INERT unless explicitly enabled — the app behaves exactly like the
// released main-branch build otherwise (this becomes the study's condition switcher
// in M5). Enable via the Debug menu (Intent Engine) or:
//   defaults write com.wallbrecher.dragaway intentEngineEnabled -bool YES
//
// Permissions: the base sensors use none. The M2 SelectionSensor (Accessibility) is
// a SEPARATE opt-in (axSensorKey) — the single sanctioned gated API on this branch.
@MainActor
final class IntentEngine {

    static let shared = IntentEngine()

    static let enabledKey     = "intentEngineEnabled"
    static let verboseKey     = "intentEngineVerbose"
    static let axSensorKey    = "intentAXSensorEnabled"
    static let axPromptedKey  = "intentAXPromptRequested"
    static let readOnlyKey    = "intentReadOnly"

    let bus = SignalBus()
    let recorder = TraceRecorder()
    let extractor = FeatureExtractor()
    let scorer: IntentScorer
    let affordances: AffordanceController

    private var sensors: [IntentSensor] = []
    private var pipelineSink: AnyCancellable?
    private var verboseSink: AnyCancellable?
    private var activeObserver: NSObjectProtocol?
    private(set) var isRunning = false

    private init() {
        let scorer = IntentScorer(config: .load())
        self.scorer = scorer
        affordances = AffordanceController(scorer: scorer, extractor: extractor)
        Self.applyLanguageConfig(scorer.config)
        // L2/L3 are ALWAYS attached: live capture and trace replay take the same
        // path. L4/L5 (the affordance surface) only reacts while the engine is
        // RUNNING — a replay must never pop UI out of historical events.
        extractor.emit = { [weak self] evidence in self?.scorer.add(evidence) }
        pipelineSink = bus.events.sink { [weak self] event in
            guard let self else { return }
            self.extractor.handle(event)
            // Read-only mode: sensors + scorer + recorder run, but the affordance
            // surface never reacts — pure capture, no whisper. This is the formative
            // (Phase 1) and general data-collection mode; observing behaviour must
            // not be perturbed by the thing we're studying.
            if self.isRunning, !self.isReadOnly { self.affordances.evaluate(at: event.t) }
        }
        // Re-check the AX grant whenever the app becomes active — the user coming
        // back after granting in System Settings is exactly this moment (there is
        // no dedicated "returned from Settings" notification). No permission polling.
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSensors() }
        }
    }

    // MARK: Lifecycle

    /// Persisted research flag; setting it also starts/stops the live engine.
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? start() : stop()
        }
    }

    func startIfEnabled() {
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { start() }
    }

    /// Read-only (capture-only) mode: sensors + scorer + trace recorder run; the
    /// affordance surface (passive whisper, summon hotkey, affordance log) is fully
    /// suppressed. THE mode for formative observation and any data collection where
    /// the system must not influence what the user does. Persisted; toggling it while
    /// running attaches/detaches the affordance layer WITHOUT stopping a live
    /// recording.
    var isReadOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.readOnlyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.readOnlyKey)
            guard isRunning else { return }
            if newValue {
                affordances.stop()          // tear down whisper/summon/log now
            } else {
                affordances.start()         // re-arm the affordance surface
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        sensors = [ClipboardSensor(), AppFocusSensor(), DwellSensor()]
        sensors.forEach { $0.start(bus: bus) }
        isRunning = true
        reconcileSensors()   // attaches the SelectionSensor when flag + grant align
        if !isReadOnly { affordances.start() }   // summon hotkey + affordance log

#if DEBUG
        if UserDefaults.standard.bool(forKey: Self.verboseKey) {
            verboseSink = bus.events.sink { [weak self] event in
                guard let self else { return }
                let top = self.scorer.scores(at: event.t).first
                let topDesc = top.map {
                    "\($0.intentClass.rawValue) \(String(format: "%.0f%%", $0.probability * 100))"
                } ?? "-"
                print("[intent] \(event.kind.rawValue)  → top: \(topDesc)")
            }
        }
#endif
    }

    /// Stops sensors AND any running recording. Also used to quiesce the live
    /// pipeline before a trace replay (live + replayed timelines must not mix).
    func stop() {
        affordances.stop()
        recorder.stop()
        sensors.forEach { $0.stop() }
        sensors = []
        verboseSink = nil
        isRunning = false
    }

    /// Aligns the running sensor set with the desired one. Idempotent and cheap —
    /// called on engine start, on axSensorEnabled changes, whenever the app becomes
    /// active, and on debug-menu open. This fixes the grant-after-enable dead end:
    /// the SelectionSensor attaches the moment flag AND trust are actually true,
    /// without restarting the engine (a restart would kill a running recording).
    func reconcileSensors() {
        guard isRunning else { return }
        let wantSelection = axSensorEnabled && AXIsProcessTrusted()
        let haveIndex = sensors.firstIndex { $0 is SelectionSensor }
        if wantSelection, haveIndex == nil {
            let sensor = SelectionSensor()
            sensor.start(bus: bus)
            sensors.append(sensor)
        } else if !wantSelection, let i = haveIndex {
            sensors[i].stop()
            sensors.remove(at: i)
        }
    }

    /// Clean slate for detectors, evidence AND the bus buffer — call before
    /// replaying a trace (stale live events carry timestamps far ahead of the
    /// recorded timeline and would corrupt windowing/dedup).
    func resetPipeline() {
        bus.reset()
        extractor.reset()
        scorer.reset()
    }

    func reloadConfig() {
        scorer.config = .load()
        Self.applyLanguageConfig(scorer.config)
        affordances.configReloaded()   // re-seed mutes; tier/θ are read live
    }

    /// Push the configured language repertoire into IntentText. Empty config ⇒ nil
    /// override ⇒ IntentText falls back to the machine locale (right for a distributed
    /// build, wrong for a study session — see IntentConfig.userLanguages).
    private static func applyLanguageConfig(_ config: IntentConfig) {
        let langs = config.normalisedUserLanguages
        IntentText.userLanguagesOverride = langs.isEmpty ? nil : langs
    }

    /// What "foreign" currently means, for the debug menu — the study operator must be
    /// able to see, before a session, whose languages the flag is judging against.
    var languageSourceDescription: String {
        let langs = IntentText.userLanguages.sorted().joined(separator: ", ")
        return IntentText.userLanguagesOverride == nil
            ? "⚠️ from THIS MACHINE's locale: [\(langs)] — set userLanguages in IntentConfig for a study session"
            : "from IntentConfig (explicit): [\(langs)]"
    }

    /// Score snapshot with "why" decomposition. `at` defaults to now, which equals
    /// event time for live capture; pass the trace's last event time after a replay
    /// (using wall clock there would decay everything to zero).
    func scoresDescription(at t: TimeInterval? = nil) -> String {
        scorer.describeScores(at: t ?? Date().timeIntervalSince1970)
    }

    // MARK: Accessibility opt-in (SelectionSensor only)

    var axSensorEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.axSensorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.axSensorKey)
            reconcileSensors()   // NEVER stop()/start() here — that killed recordings
        }
    }

    /// One system dialog on first request (registers the app in the Accessibility
    /// list); afterwards deep-link to the pane — macOS never re-shows the dialog.
    /// Same single-dialog flow the released app used before going permission-free.
    func requestAXPermission() {
        if !UserDefaults.standard.bool(forKey: Self.axPromptedKey) {
            UserDefaults.standard.set(true, forKey: Self.axPromptedKey)
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        } else {
            NSWorkspace.shared.open(URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }
}
