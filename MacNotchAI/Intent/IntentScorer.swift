import Foundation

// THESIS (L3) — the log-linear Bayes scorer. docs/thesis/ARCHITECTURE.md §5.
//
//   S_c(t) = basePrior + priorOffset_c + Σ_i w_i · strength_i · e^−(t−t_i)/τ_i
//   P(c|E) = σ(S_c)
//
// Weights are log-likelihood-ratios (w = +2.2 ⇒ signal ~9× likelier under real
// intent). The prior (≈ −3.9 = logit 0.02) makes silence the ground state. Decay is
// ANALYTIC AND LAZY: a pure function of the read time — no timers tick for scoring,
// and replayed traces score identically because everything runs on event time.
//
// The additive breakdown IS the explanation ("why this suggestion?") — the
// transparency requirement as an architectural property, not an afterthought.

// MARK: - Config (all tunables live here — values are data, not architecture)

struct IntentConfig: Codable {
    var v = 1
    /// "lazy" | "balanced" | "aggressive" — exposure tier (M3 policy reads this).
    var tier = "balanced"
    /// logit(0.02) ≈ −3.89 — "assistable intent right now" is rare by default.
    var basePriorLogOdds = -3.89
    /// Per-class prior shifts. USER-owned (preference, M4 compiler writes these);
    /// the learner never touches them — see the §9 ownership split.
    var priorOffsets: [String: Double] = [:]
    /// Per-feature log-likelihood-ratio weights. LEARNER-owned from M4 on.
    var weights: [String: Double] = IntentConfig.defaultWeights
    /// Per-feature decay constants τ (seconds).
    var taus: [String: Double] = IntentConfig.defaultTaus
    /// Exposure thresholds per tier (probability domain).
    var thresholds: [String: Double] = ["lazy": 0.85, "balanced": 0.70, "aggressive": 0.55]
    /// Cooldown after an explicit dismiss (ignore = half of this) — ARCHITECTURE §7.
    var dismissCooldownSeconds: Double = 600
    /// Passive-channel rate limit per tier (shows per hour).
    var rateLimits: [String: Int] = ["lazy": 3, "balanced": 6, "aggressive": 12]
    /// "class|bundleID" pairs the user muted ("do not suggest again").
    var mutes: [String] = []

    // Initial values, calibrated against the synthetic design targets (validated by
    // the standalone scorer test; refine against golden traces):
    //   · translation: foreign clip + translator switch ⇒ fires on balanced (~73%);
    //     either signal alone stays silent (12% / 29%). The switch is the strongest
    //     tell (w=3.0 ⇒ LR ≈ e^3 ≈ 20 — the user literally opened a translator).
    //   · comprehension/discovery: noisier signal families — deliberately need
    //     near-max combined evidence to speak unprompted; below that they surface
    //     through the summon ticker until personalization lifts their priors (§9).
    static let defaultWeights: [String: Double] = [
        "foreign_language_clip":        2.2,
        "copy_then_translator_switch":  3.0,
        "format_mismatch":              0.8,
        "re_reading":                   2.4,
        "dense_dwell":                  1.6,
        "repeat_selection":             2.0,
        "collect_mode":                 2.2,
        "topic_coherence":              2.6,
    ]
    static let defaultTaus: [String: Double] = [
        "foreign_language_clip":        60,
        "copy_then_translator_switch":  60,
        "format_mismatch":              60,
        "re_reading":                  180,
        "dense_dwell":                 180,
        "repeat_selection":            120,
        "collect_mode":                 90,
        "topic_coherence":             120,
    ]

    func weight(for f: FeatureID) -> Double { weights[f.rawValue] ?? Self.defaultWeights[f.rawValue] ?? 1.0 }
    func tau(for f: FeatureID) -> Double { taus[f.rawValue] ?? Self.defaultTaus[f.rawValue] ?? 90 }
    func priorOffset(for c: IntentClass) -> Double { priorOffsets[c.rawValue] ?? 0 }
    var exposureThreshold: Double { thresholds[tier] ?? 0.70 }
    var rateLimitPerHour: Int { rateLimits[tier] ?? 6 }

    // MARK: schema-evolution-safe decoding
    //
    // Synthesized Codable would reject any config file missing a newly added key
    // (keyNotFound) and shunt the user's hand-tuned file into the .broken backup
    // path on every schema growth. decodeIfPresent per field keeps old files valid.

    init() {}

    private enum CodingKeys: String, CodingKey {
        case v, tier, basePriorLogOdds, priorOffsets, weights, taus, thresholds,
             dismissCooldownSeconds, rateLimits, mutes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IntentConfig()
        v                      = try c.decodeIfPresent(Int.self, forKey: .v) ?? d.v
        tier                   = try c.decodeIfPresent(String.self, forKey: .tier) ?? d.tier
        basePriorLogOdds       = try c.decodeIfPresent(Double.self, forKey: .basePriorLogOdds) ?? d.basePriorLogOdds
        priorOffsets           = try c.decodeIfPresent([String: Double].self, forKey: .priorOffsets) ?? d.priorOffsets
        weights                = try c.decodeIfPresent([String: Double].self, forKey: .weights) ?? d.weights
        taus                   = try c.decodeIfPresent([String: Double].self, forKey: .taus) ?? d.taus
        thresholds             = try c.decodeIfPresent([String: Double].self, forKey: .thresholds) ?? d.thresholds
        dismissCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .dismissCooldownSeconds) ?? d.dismissCooldownSeconds
        rateLimits             = try c.decodeIfPresent([String: Int].self, forKey: .rateLimits) ?? d.rateLimits
        mutes                  = try c.decodeIfPresent([String].self, forKey: .mutes) ?? d.mutes
    }

    // MARK: persistence — a hand-editable JSON next to the traces

    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Dragaway", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("IntentConfig.json")
    }

    /// Field-wise validation with clamping. A hand-edited file can contain a
    /// negative τ, an out-of-range threshold, an unknown tier, or (via "1e999")
    /// infinities — none of that may reach the scorer, and none of it may destroy
    /// the user's file. Corrections apply IN MEMORY only; the file stays untouched.
    func validated() -> (config: IntentConfig, corrections: [String]) {
        var c = self
        var notes: [String] = []
        if c.thresholds[c.tier] == nil {
            notes.append("tier '\(c.tier)' unknown → balanced"); c.tier = "balanced"
        }
        if !c.basePriorLogOdds.isFinite || !(-10...2).contains(c.basePriorLogOdds) {
            notes.append("basePriorLogOdds \(c.basePriorLogOdds) → -3.89")
            c.basePriorLogOdds = -3.89
        }
        for (k, v) in c.weights where !v.isFinite || abs(v) > 4 {
            let fixed = v.isFinite ? max(-4, min(4, v)) : (Self.defaultWeights[k] ?? 1)
            notes.append("weight \(k)=\(v) → \(fixed)"); c.weights[k] = fixed
        }
        for (k, v) in c.taus where !v.isFinite || v <= 0 || v > 3600 {
            let fixed = Self.defaultTaus[k] ?? 90
            notes.append("tau \(k)=\(v) → \(fixed)"); c.taus[k] = fixed
        }
        for (k, v) in c.thresholds where !v.isFinite || !(0.01...0.99).contains(v) {
            let fixed = k == "lazy" ? 0.85 : (k == "aggressive" ? 0.55 : 0.70)
            notes.append("threshold \(k)=\(v) → \(fixed)"); c.thresholds[k] = fixed
        }
        for (k, v) in c.priorOffsets where !v.isFinite || abs(v) > 1.5 {
            // ±1.5 is the preference-compiler clamp (ARCHITECTURE §9) — hand edits
            // don't get to exceed what the user-control surface allows.
            let fixed = v.isFinite ? max(-1.5, min(1.5, v)) : 0
            notes.append("priorOffset \(k)=\(v) → \(fixed)"); c.priorOffsets[k] = fixed
        }
        if !c.dismissCooldownSeconds.isFinite || !(30...86_400).contains(c.dismissCooldownSeconds) {
            notes.append("dismissCooldownSeconds \(c.dismissCooldownSeconds) → 600")
            c.dismissCooldownSeconds = 600
        }
        for (k, v) in c.rateLimits where !(1...60).contains(v) {
            let fixed = k == "lazy" ? 3 : (k == "aggressive" ? 12 : 6)
            notes.append("rateLimit \(k)=\(v) → \(fixed)"); c.rateLimits[k] = fixed
        }
        return (c, notes)
    }

    /// Loads the config, writing the defaults file on first use so there is always
    /// a concrete JSON to hand-tweak. Invalid FIELDS are corrected in memory (file
    /// untouched); an UNDECODABLE file is backed up — never silently overwritten —
    /// before defaults are regenerated.
    static func load() -> IntentConfig {
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            let fresh = IntentConfig(); fresh.save(); return fresh
        }
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(IntentConfig.self, from: data) {
            let (config, corrections) = decoded.validated()
#if DEBUG
            if !corrections.isEmpty {
                print("[intent] config corrections (file left untouched):")
                corrections.forEach { print("  · \($0)") }
            }
#endif
            return config
        }
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("IntentConfig.broken-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: backup)
#if DEBUG
        print("[intent] ⚠️ IntentConfig.json undecodable — backed up as \(backup.lastPathComponent), defaults regenerated")
#endif
        let fresh = IntentConfig(); fresh.save(); return fresh
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.fileURL())
        }
    }
}

// MARK: - Scorer

final class IntentScorer {

    var config: IntentConfig

    /// Decayed-evidence window; trimmed against evidence time (replay-safe).
    private(set) var evidence: [Evidence] = []
    private let window: TimeInterval = 300   // beyond 5 min everything has decayed to ~0

    init(config: IntentConfig = .load()) {
        self.config = config
    }

    func add(_ e: Evidence) {
        // A detector re-firing the same feature within 5 s refreshes rather than
        // stacks — scroll bursts would otherwise pile up evidence for one behaviour.
        if let last = evidence.lastIndex(where: { $0.feature == e.feature && e.t - $0.t < 5 }) {
            if e.strength >= evidence[last].strength {
                evidence[last] = e
            }
        } else {
            evidence.append(e)
        }
        evidence.removeAll { $0.t < e.t - window }
    }

    func reset() { evidence = [] }

    // MARK: Reading scores (lazy decay — evaluated at read time)

    struct Contribution {
        let feature: FeatureID
        let value: Double        // w · strength · decay — one summand of S_c
    }

    struct Breakdown {
        let intentClass: IntentClass
        let logOdds: Double
        let probability: Double
        let contributions: [Contribution]   // sorted, strongest first
    }

    func scores(at t: TimeInterval) -> [Breakdown] {
        IntentClass.allCases.map { c in
            var contributions: [Contribution] = []
            for e in evidence where e.feature.intentClass == c {
                let decay = exp(-(t - e.t) / config.tau(for: e.feature))
                let value = config.weight(for: e.feature) * e.strength * decay
                if value > 0.01 { contributions.append(Contribution(feature: e.feature, value: value)) }
            }
            contributions.sort { $0.value > $1.value }
            let logOdds = config.basePriorLogOdds + config.priorOffset(for: c)
                        + contributions.reduce(0) { $0 + $1.value }
            return Breakdown(intentClass: c,
                             logOdds: logOdds,
                             probability: 1.0 / (1.0 + exp(-logOdds)),
                             contributions: contributions)
        }
        .sorted { $0.probability > $1.probability }
    }

    /// Human-readable score snapshot — the "why" decomposition (M2 acceptance).
    func describeScores(at t: TimeInterval) -> String {
        scores(at: t).map { b in
            let pct = String(format: "%.0f%%", b.probability * 100)
            let s = String(format: "%+.2f", b.logOdds)
            if b.contributions.isEmpty {
                return "\(b.intentClass.rawValue)  \(pct)  (S=\(s), no evidence)"
            }
            let parts = b.contributions.prefix(4)
                .map { "\($0.feature.rawValue) +\(String(format: "%.2f", $0.value))" }
                .joined(separator: ", ")
            return "\(b.intentClass.rawValue)  \(pct)  (S=\(s): \(parts))"
        }
        .joined(separator: "\n")
    }
}
