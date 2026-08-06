import AppKit

// THESIS (L1 sensor) — scroll bursts + mouse-stationary dwell, fully ungated.
//
// Scroll: a global `.scrollWheel` NSEvent monitor (pointer events don't require
// Accessibility — proven pattern from DragMonitor's mouse monitors). Raw scroll
// events are far too chatty for the bus, so they aggregate into BURSTS (gap > 0.8 s
// closes a burst). Direction changes per burst feed the M2 `re_reading` detector.
// If some system configuration doesn't deliver global scroll events, traces will
// show it immediately; the AX-based fallback lands with M2.
//
// Dwell: 2 Hz polling of `NSEvent.mouseLocation` (the DragMonitor fallback trick —
// no permission, no event tap). Stationary ≥ 10 s emits a dwell event when movement
// resumes. Mouse-quiet conflates reading and typing; AX disambiguates in M2.
final class DwellSensor: IntentSensor {

    let name = "dwell"

    private weak var bus: SignalBus?
    private var scrollMonitor: Any?
    private var housekeeping: Timer?

    // Scroll-burst accumulation
    private var burstOpen = false
    private var burstStart: TimeInterval = 0
    private var burstLast: TimeInterval = 0
    private var burstNet: Double = 0
    private var burstAbs: Double = 0
    private var burstFlips = 0
    private var burstLastSign = 0
    private var burstApp: String?

    // Mouse dwell
    private var lastMouse = NSEvent.mouseLocation
    private var stationarySince: TimeInterval?

    private let burstGap: TimeInterval = 0.8
    private let dwellMinimum: TimeInterval = 10
    private let jitterDeadband: CGFloat = 4      // pt of mouse jitter that still counts as "still"
    private let scrollDeadband: Double = 1       // |ΔY| below this doesn't flip direction

    func start(bus: SignalBus) {
        self.bus = bus
        lastMouse = NSEvent.mouseLocation
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event)
        }
        // .common mode (repo idiom, DragMonitor/ClipboardHistoryStore): default-mode
        // timers pause during menu tracking — fatal for a menu-bar app whose engine
        // is controlled FROM the status menu.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        housekeeping = t
    }

    func stop() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        housekeeping?.invalidate()
        housekeeping = nil
        closeBurstIfDue(force: true)
        stationarySince = nil
    }

    // MARK: Scroll bursts

    private func handleScroll(_ event: NSEvent) {
        let now = Date().timeIntervalSince1970
        let dy = Double(event.scrollingDeltaY)

        if burstOpen, now - burstLast > burstGap {
            closeBurstIfDue(force: true)
        }
        if !burstOpen {
            burstOpen = true
            burstStart = now
            burstNet = 0; burstAbs = 0; burstFlips = 0; burstLastSign = 0
            burstApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }

        burstLast = now
        burstNet += dy
        burstAbs += abs(dy)
        if abs(dy) > scrollDeadband {
            let sign = dy > 0 ? 1 : -1
            if burstLastSign != 0, sign != burstLastSign { burstFlips += 1 }
            burstLastSign = sign
        }
    }

    private func closeBurstIfDue(force: Bool = false) {
        guard burstOpen else { return }
        let now = Date().timeIntervalSince1970
        guard force || now - burstLast > burstGap else { return }
        burstOpen = false

        // Sub-4pt bursts are trackpad noise, not reading behaviour.
        guard burstAbs >= 4 else { return }
        // Stamped with PUBLISH time, not burstLast: the bus guarantees monotonic
        // event time (ARCHITECTURE §4), and a burst detected ≤ ~1.3 s late (gap +
        // tick) would otherwise time-travel behind already-published events. The
        // shift is noise at τ ≥ 60 s (<2% decay error); `duration` still describes
        // the gesture itself.
        bus?.publish(SignalEvent(t: now, kind: .scrollBurst, scroll: ScrollBurstPayload(
            app: burstApp,
            duration: ((burstLast - burstStart) * 100).rounded() / 100,
            netDeltaY: (burstNet * 10).rounded() / 10,
            totalAbsDeltaY: (burstAbs * 10).rounded() / 10,
            directionChanges: burstFlips)))
    }

    // MARK: Housekeeping tick (burst timeout + dwell detection)

    private func tick() {
        closeBurstIfDue()

        let now = Date().timeIntervalSince1970
        let loc = NSEvent.mouseLocation
        let moved = hypot(loc.x - lastMouse.x, loc.y - lastMouse.y) > jitterDeadband

        if moved {
            if let since = stationarySince, now - since >= dwellMinimum {
                bus?.publish(SignalEvent(t: now, kind: .dwell, dwell: DwellPayload(
                    app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                    seconds: ((now - since) * 10).rounded() / 10)))
            }
            stationarySince = nil
            lastMouse = loc
        } else if stationarySince == nil {
            stationarySince = now
        }
    }
}
