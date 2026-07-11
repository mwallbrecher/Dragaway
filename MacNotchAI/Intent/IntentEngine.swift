import Foundation
import Combine

// THESIS — coordinator of the Computational Intent Pipeline (docs/thesis/ARCHITECTURE.md).
//
// M1 scope: owns the SignalBus, the L1 sensors, and the trace recorder. The engine is
// INERT unless explicitly enabled — the app behaves exactly like the released main-branch
// build otherwise (this is also what the study's condition switcher will toggle in M5).
//
// Enable via the Debug menu (Intent Engine) or:
//   defaults write com.wallbrecher.dragaway intentEngineEnabled -bool YES
//
// M1 uses zero permissions: clipboard polling, NSWorkspace notifications, and pointer
// events only. The Accessibility-gated selection sensor arrives opt-in with M2.
@MainActor
final class IntentEngine {

    static let shared = IntentEngine()

    static let enabledKey = "intentEngineEnabled"
    static let verboseKey = "intentEngineVerbose"

    let bus = SignalBus()
    let recorder = TraceRecorder()

    private var sensors: [IntentSensor] = []
    private var verboseSink: AnyCancellable?
    private(set) var isRunning = false

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
        sensors.forEach { $0.start(bus: bus) }
        isRunning = true

#if DEBUG
        if UserDefaults.standard.bool(forKey: Self.verboseKey) {
            verboseSink = bus.events.sink { event in
                print("[intent] \(event.kind.rawValue) t=\(event.t)")
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
}
