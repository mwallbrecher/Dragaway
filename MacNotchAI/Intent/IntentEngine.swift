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

    let bus = SignalBus()
    let recorder = TraceRecorder()
    let extractor = FeatureExtractor()
    let scorer: IntentScorer

    private var sensors: [IntentSensor] = []
    private var pipelineSink: AnyCancellable?
    private var verboseSink: AnyCancellable?
    private(set) var isRunning = false

    private init() {
        scorer = IntentScorer(config: .load())
        // L2/L3 are ALWAYS attached: live capture and trace replay take the same path.
        extractor.emit = { [weak self] evidence in self?.scorer.add(evidence) }
        pipelineSink = bus.events.sink { [weak self] event in
            self?.extractor.handle(event)
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

    func start() {
        guard !isRunning else { return }
        sensors = [ClipboardSensor(), AppFocusSensor(), DwellSensor()]
        if axSensorEnabled, AXIsProcessTrusted() {
            sensors.append(SelectionSensor())
        }
        sensors.forEach { $0.start(bus: bus) }
        isRunning = true

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
        recorder.stop()
        sensors.forEach { $0.stop() }
        sensors = []
        verboseSink = nil
        isRunning = false
    }

    /// Clean slate for detectors + evidence — call before replaying a trace.
    func resetPipeline() {
        extractor.reset()
        scorer.reset()
    }

    func reloadConfig() {
        scorer.config = .load()
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
            if isRunning { stop(); start() }   // rebuild the sensor set
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
