#if DEBUG
import Foundation

// THESIS — golden smoke checks: an executable floor under the M2 pipeline.
//
// NOT the scientific evaluation (that is RQ1 on real traces, M5). This is a
// regression tripwire: when M3 adds policy, resolver, and UI, "the affordance is
// wrong" must be distinguishable from "the scoring regressed". Run from the debug
// menu (Intent Engine → Run Golden Checks); every check reports expected vs actual.
//
// Checks run on IN-MEMORY defaults (`IntentConfig()`), never the user's tweaked
// IntentConfig.json — otherwise every hand-tune would "fail" the suite.
enum IntentGoldenChecks {

    struct Check {
        let name: String
        let pass: Bool
        let detail: String
    }

    // MARK: Scenario plumbing

    /// A fresh, isolated extractor+scorer pair per scenario — no engine, no disk.
    private final class Pipeline {
        let extractor = FeatureExtractor()
        let scorer = IntentScorer(config: IntentConfig())
        init() { extractor.emit = { [scorer] in scorer.add($0) } }
        func feed(_ e: SignalEvent) { extractor.handle(e) }
        func p(_ c: IntentClass, at t: TimeInterval) -> Double {
            scorer.scores(at: t).first { $0.intentClass == c }?.probability ?? 0
        }
        func has(_ f: FeatureID) -> Bool {
            scorer.evidence.contains { $0.feature == f }
        }
    }

    private static func textClip(t: TimeInterval, foreign: Bool, conf: Double = 0.9,
                                 chars: Int = 200, shape: String = "prose",
                                 source: String, hash: String,
                                 embedding: [Double]? = nil) -> SignalEvent {
        SignalEvent(t: t, kind: .clipboard, clipboard: ClipboardPayload(
            contentClass: "text", charCount: chars, wordCount: chars / 6,
            language: foreign ? "fr" : "en", langConfidence: conf,
            isForeignLanguage: foreign, shape: shape, hasURL: false,
            hashPrefix: hash, sourceApp: source, fileExtensions: nil,
            embedding: embedding))
    }

    private static func focus(t: TimeInterval, bundle: String, category: String) -> SignalEvent {
        SignalEvent(t: t, kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: bundle, appName: bundle, category: category,
            previousBundleID: "com.apple.Preview", secondsInPrevious: 30))
    }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    // MARK: The suite

    static func run() -> [Check] {
        var checks: [Check] = []
        let t0: TimeInterval = 1_000_000
        let balanced = IntentConfig().thresholds["balanced"] ?? 0.70

        // 1 · No evidence → every class sits at the prior.
        do {
            let pl = Pipeline()
            let ps = IntentClass.allCases.map { pl.p($0, at: t0) }
            let pass = ps.allSatisfy { abs($0 - 0.02) < 0.005 }
            checks.append(Check(name: "1 no evidence → prior (~2%)", pass: pass,
                                detail: "expected all ≈2%, got \(ps.map(pct).joined(separator: "/"))"))
        }

        // 2 · Foreign clip alone stays silent (< 0.45, well under balanced).
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a1"))
            let p = pl.p(.translation, at: t0 + 1)
            checks.append(Check(name: "2 foreign clip alone silent", pass: p < 0.45,
                                detail: "expected <45%, got \(pct(p))"))
        }

        // 3 · Translator switch alone (no copy) stays at the prior.
        do {
            let pl = Pipeline()
            pl.feed(focus(t: t0, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 1)
            checks.append(Check(name: "3 translator switch alone silent", pass: p < 0.05,
                                detail: "expected ≈prior, got \(pct(p))"))
        }

        // 4 · Foreign clip + translator switch crosses balanced.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a2"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 3)
            checks.append(Check(name: "4 foreign clip + translator switch fires", pass: p >= balanced,
                                detail: "expected ≥\(pct(balanced)), got \(pct(p))"))
        }

        // 5 · Same evidence, read 5 min later → decayed back under threshold.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a3"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 300)
            checks.append(Check(name: "5 evidence decays to silence", pass: p < 0.10,
                                detail: "expected <10% after 5 min, got \(pct(p))"))
        }

        // 6 · Ordinary english prose → Notes: format_mismatch must NOT fire.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: false, shape: "prose",
                             source: "com.apple.Safari", hash: "a4"))
            pl.feed(focus(t: t0 + 5, bundle: "com.apple.Notes", category: "notes"))
            let fired = pl.has(.formatMismatch)
            checks.append(Check(name: "6 prose → Notes: no format_mismatch", pass: !fired,
                                detail: fired ? "format_mismatch fired for prose" : "correctly silent"))
        }

        // 7 · code → Notes: format_mismatch DOES fire (positive control for 6).
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: false, shape: "code",
                             source: "com.apple.dt.Xcode", hash: "a5"))
            pl.feed(focus(t: t0 + 5, bundle: "com.apple.Notes", category: "notes"))
            let fired = pl.has(.formatMismatch)
            checks.append(Check(name: "7 code → Notes: format_mismatch fires", pass: fired,
                                detail: fired ? "fired as designed" : "did NOT fire"))
        }

        // 8 · Identical re-copy refreshes recency (translator switch 65 s after the
        //     ORIGINAL copy but 5 s after the RE-copy must fire) without inflating
        //     collect_mode. This check fails on the pre-fix extractor.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a6"))
            pl.feed(textClip(t: t0 + 60, foreign: true, source: "com.apple.Preview", hash: "a6"))
            pl.feed(focus(t: t0 + 65, bundle: "com.deepl.macos", category: "translator"))
            let p = pl.p(.translation, at: t0 + 65)
            let collect = pl.has(.collectMode)
            checks.append(Check(name: "8 re-copy refreshes recency, no collect stacking",
                                pass: p >= balanced && !collect,
                                detail: "translation \(pct(p)) (≥\(pct(balanced))?), collect_mode fired: \(collect)"))
        }

        // 9 · Pipeline reset returns to the pure prior.
        do {
            let pl = Pipeline()
            pl.feed(textClip(t: t0, foreign: true, source: "com.apple.Preview", hash: "a7"))
            pl.feed(focus(t: t0 + 3, bundle: "com.deepl.macos", category: "translator"))
            pl.extractor.reset(); pl.scorer.reset()
            let p = pl.p(.translation, at: t0 + 4)
            checks.append(Check(name: "9 reset → prior", pass: abs(p - 0.02) < 0.005,
                                detail: "expected ≈2%, got \(pct(p))"))
        }

        // 10 · A trace with a >1 s time regression is visibly rejected, not sorted.
        do {
            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent("golden-nonmonotonic.jsonl")
            let encoder = JSONEncoder()
            let e1 = textClip(t: t0 + 100, foreign: false, source: "x", hash: "b1")
            let e2 = textClip(t: t0, foreign: false, source: "x", hash: "b2")   // 100 s backwards
            let lines = [e1, e2].compactMap { try? encoder.encode($0) }
                .compactMap { String(data: $0, encoding: .utf8) }
                .joined(separator: "\n")
            try? lines.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            var rejected = false
            do { _ = try TraceReplayer.load(url) } catch { rejected = true }
            checks.append(Check(name: "10 non-monotonic trace rejected", pass: rejected,
                                detail: rejected ? "rejected with error, as designed"
                                                 : "loaded without complaint"))
        }

        return checks
    }

    static func report() -> String {
        let checks = run()
        let failed = checks.filter { !$0.pass }
        let head = failed.isEmpty
            ? "ALL \(checks.count) CHECKS PASSED"
            : "⚠️ \(failed.count) OF \(checks.count) CHECKS FAILED"
        let lines = checks.map { "\($0.pass ? "✓" : "✗ FAILED") \($0.name)\n    \($0.detail)" }
        return head + "\n\n" + lines.joined(separator: "\n")
    }
}
#endif
