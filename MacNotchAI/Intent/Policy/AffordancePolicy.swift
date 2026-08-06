import Foundation

// THESIS (L4) — the pure decision core of the passive channel. ARCHITECTURE §7.
//
// Deliberately a VALUE TYPE with injected time and no I/O: every guardrail
// (threshold, cooldown, rate limit, mutes, quiet context, ticker-only classes)
// is golden-checkable without windows, hotkeys, or wall clock. The controller
// wraps this with the actual UI and logging.
//
// Show iff expected utility beats interruption cost: P·V > (1−P)·C. The user's
// sensitivity tier sets C, expressed as the exposure threshold θ — the tier
// gates EXPOSURE only; scores stay calibrated and comparable (§7).
struct AffordancePolicy {

    enum Verdict: Equatable {
        case show
        case silent(reason: String)
        var isShow: Bool { self == .show }
    }

    enum Outcome: String {
        case accepted, dismissed, ignored
    }

    /// M3: the passive channel speaks for translation only — the noisier classes
    /// stay ticker-only until they are calibrated on real traces (ARCHITECTURE §11).
    static let passiveClasses: Set<IntentClass> = [.translation]

    private(set) var cooldownUntil: [String: TimeInterval] = [:]
    private(set) var recentShows: [TimeInterval] = []
    private(set) var mutedPairs: Set<String>          // "class|bundleID"

    init(mutes: [String] = []) {
        mutedPairs = Set(mutes)
    }

    // MARK: Decision (read-only — confirmShown() commits the rate-limit slot)

    func decide(intentClass: IntentClass, probability: Double,
                frontApp: String?, quietContext: Bool,
                at t: TimeInterval, config: IntentConfig) -> Verdict {
        guard Self.passiveClasses.contains(intentClass) else {
            return .silent(reason: "class is ticker-only in M3")
        }
        guard probability >= config.exposureThreshold else {
            return .silent(reason: "below θ(\(config.tier))")
        }
        if quietContext {
            return .silent(reason: "quiet context")
        }
        if let app = frontApp, mutedPairs.contains("\(intentClass.rawValue)|\(app)") {
            return .silent(reason: "muted for this app")
        }
        if let until = cooldownUntil[intentClass.rawValue], t < until {
            return .silent(reason: "cooldown after dismiss/ignore")
        }
        if recentShows.filter({ $0 > t - 3600 }).count >= config.rateLimitPerHour {
            return .silent(reason: "hourly rate limit (\(config.rateLimitPerHour)/h)")
        }
        return .show
    }

    /// Commit a shown affordance into the rate-limit window. Separate from
    /// decide() so a stale resolver result (pasteboard moved on) never burns
    /// one of the user's hourly slots.
    mutating func confirmShown(at t: TimeInterval) {
        recentShows.removeAll { $0 < t - 3600 }
        recentShows.append(t)
    }

    // MARK: Outcomes

    mutating func record(_ outcome: Outcome, intentClass: IntentClass,
                         at t: TimeInterval, config: IntentConfig) {
        switch outcome {
        case .dismissed:
            cooldownUntil[intentClass.rawValue] = t + config.dismissCooldownSeconds
        case .ignored:
            // Non-reaction is a WEAK negative (§7): half the dismiss cooldown.
            // Full learning semantics (weight updates) arrive with M4.
            cooldownUntil[intentClass.rawValue] = t + config.dismissCooldownSeconds / 2
        case .accepted:
            cooldownUntil[intentClass.rawValue] = nil
        }
    }

    mutating func mute(intentClass: IntentClass, app: String) {
        mutedPairs.insert("\(intentClass.rawValue)|\(app)")
    }
}
