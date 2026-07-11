import Foundation
import Combine

// THESIS (L2) — feature detectors: typed evidence out of the raw event stream.
// See docs/thesis/ARCHITECTURE.md §8. Every detector is a small state machine over
// event-carried timestamps (never wall clock — the replay invariant).
//
// M2 implements 8 of the 10 spec'd detectors. Deferred with reasons:
//   copy_to_search   — needs reliable focused-field role detection (M3)
//   entity_overlap   — NER output is content-adjacent; needs the content-tier
//                      consent flow (M5) before names may leave the sensor layer

// MARK: - Intent classes & features

enum IntentClass: String, Codable, CaseIterable {
    case translation      // Translation / Transformation
    case comprehension    // Comprehension
    case discovery        // Discovery / Cross-Reference
}

enum FeatureID: String, Codable, CaseIterable {
    // translation
    case foreignLanguageClip      = "foreign_language_clip"
    case copyThenTranslatorSwitch = "copy_then_translator_switch"
    case formatMismatch           = "format_mismatch"
    // comprehension
    case reReading                = "re_reading"
    case denseDwell               = "dense_dwell"
    case repeatSelection          = "repeat_selection"
    // discovery
    case collectMode              = "collect_mode"
    case topicCoherence           = "topic_coherence"

    var intentClass: IntentClass {
        switch self {
        case .foreignLanguageClip, .copyThenTranslatorSwitch, .formatMismatch:
            return .translation
        case .reReading, .denseDwell, .repeatSelection:
            return .comprehension
        case .collectMode, .topicCoherence:
            return .discovery
        }
    }
}

/// One piece of typed evidence. Strength ∈ [0,1]; the scorer multiplies it with the
/// feature's weight and time decay.
struct Evidence {
    let feature: FeatureID
    let strength: Double
    let t: TimeInterval
}

// MARK: - Extractor

final class FeatureExtractor {

    /// Wired by IntentEngine to IntentScorer.add(_:).
    var emit: ((Evidence) -> Void)?

    // Detector state (all trimmed against event time)
    private struct Copy {
        let t: TimeInterval
        let hash: String
        let source: String?
        let isText: Bool
        let embedding: [Double]?
    }
    private var copies: [Copy] = []                                  // 90 s window
    private var bursts: [(t: TimeInterval, app: String?, net: Double, flips: Int)] = []  // 60 s
    private var selections: [(t: TimeInterval, docID: String)] = []  // 60 s

    func handle(_ event: SignalEvent) {
        trim(before: event.t)
        switch event.kind {
        case .clipboard:   if let p = event.clipboard { onClipboard(p, t: event.t) }
        case .appFocus:    if let p = event.appFocus { onAppFocus(p, t: event.t) }
        case .scrollBurst: if let p = event.scroll { onScrollBurst(p, t: event.t) }
        case .dwell:       if let p = event.dwell { onDwell(p, t: event.t) }
        case .selection:   if let p = event.selection { onSelection(p, t: event.t) }
        }
    }

    func reset() {
        copies = []; bursts = []; selections = []
    }

    private func trim(before t: TimeInterval) {
        copies.removeAll { $0.t < t - 90 }
        bursts.removeAll { $0.t < t - 60 }
        selections.removeAll { $0.t < t - 60 }
    }

    // MARK: Clipboard → foreign_language_clip · format_mismatch(arm) · collect_mode · topic_coherence

    private func onClipboard(_ p: ClipboardPayload, t: TimeInterval) {
        guard p.contentClass == "text" || p.contentClass == "url" else { return }

        // Re-copy of identical content refreshes recency but shouldn't stack counts.
        if !copies.contains(where: { $0.hash == p.hashPrefix }) {
            copies.append(Copy(t: t, hash: p.hashPrefix, source: p.sourceApp,
                               isText: p.contentClass == "text", embedding: p.embedding))
        }

        if p.isForeignLanguage {
            // Strength: language confidence × snippet-length band (40–2000 chars is
            // the "worth translating" sweet spot — ARCHITECTURE §5 worked example).
            let band: Double = (40...2000).contains(p.charCount) ? 1.0 : 0.5
            emit?(Evidence(feature: .foreignLanguageClip,
                           strength: (p.langConfidence ?? 0.8) * band, t: t))
        }

        detectCollectMode(t: t)
    }

    private func detectCollectMode(t: TimeInterval) {
        let recent = copies.filter { $0.t > t - 90 }
        let sources = Set(recent.compactMap(\.source))
        guard recent.count >= 3, sources.count >= 2 else { return }

        // ≥3 distinct copies from ≥2 sources in 90 s ⇒ the user is collecting.
        emit?(Evidence(feature: .collectMode,
                       strength: min(1.0, 0.5 + 0.25 * Double(recent.count - 3)), t: t))

        // Are the collected snippets ONE research thread? Mean pairwise cosine of
        // their embeddings, mapped so 0.35 → 0 and 0.75+ → 1 (ARCHITECTURE §8).
        let vectors = recent.compactMap(\.embedding).suffix(4)
        guard vectors.count >= 2 else { return }
        var sims: [Double] = []
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                sims.append(IntentText.cosine(vectors[i], vectors[j]))
            }
        }
        let mean = sims.reduce(0, +) / Double(sims.count)
        let strength = min(1.0, max(0.0, (mean - 0.35) / 0.4))
        if strength > 0 {
            emit?(Evidence(feature: .topicCoherence, strength: strength, t: t))
        }
    }

    // MARK: App focus → copy_then_translator_switch · format_mismatch(fire)

    private func onAppFocus(_ p: AppFocusPayload, t: TimeInterval) {
        guard let lastTextCopy = copies.last(where: { $0.isText }) else { return }
        let sinceCopy = t - lastTextCopy.t

        // copy → translator app within 10 s: the strongest translation tell.
        if p.category == "translator", sinceCopy <= 10 {
            emit?(Evidence(feature: .copyThenTranslatorSwitch, strength: 1.0, t: t))
        }

        // code/table copied, then straight into a prose app: format mismatch.
        // (Weak evidence by design — weight stays low; see initial weights table.)
        if sinceCopy <= 10, ["mail", "notes", "messaging"].contains(p.category) {
            emit?(Evidence(feature: .formatMismatch, strength: 0.8, t: t))
        }
    }

    // MARK: Selection → copy_then_translator_switch (web) · repeat_selection

    private func onSelection(_ p: SelectionPayload, t: TimeInterval) {
        // Translator context in a browser tab (deepl.com …) — AppFocusSensor can't
        // see tabs; the AX window title (hashed away at capture) can.
        if p.isTranslatorContext,
           let lastTextCopy = copies.last(where: { $0.isText }),
           t - lastTextCopy.t <= 10 {
            emit?(Evidence(feature: .copyThenTranslatorSwitch, strength: 0.9, t: t))
        }

        guard let docID = p.docID, p.charCount > 0 else { return }
        selections.append((t, docID))
        let sameDoc = selections.filter { $0.docID == docID && $0.t > t - 60 }.count
        if sameDoc >= 2 {
            emit?(Evidence(feature: .repeatSelection,
                           strength: min(1.0, Double(sameDoc - 1) / 3.0), t: t))
        }
    }

    // MARK: Scroll → re_reading

    private func onScrollBurst(_ p: ScrollBurstPayload, t: TimeInterval) {
        bursts.append((t, p.app, p.netDeltaY, p.directionChanges))

        // Within one burst: ≥3 direction flips is oscillation (re-reading a passage).
        if p.directionChanges >= 3 {
            emit?(Evidence(feature: .reReading,
                           strength: min(1.0, Double(p.directionChanges) / 6.0), t: t))
            return
        }

        // Across bursts (same app, 60 s): alternating net directions ≥3 times —
        // scroll down, back up, down again = the classic "read it again" pattern.
        let sameApp = bursts.filter { $0.app == p.app && abs($0.net) > 4 }
        guard sameApp.count >= 3 else { return }
        var alternations = 0
        for i in 1..<sameApp.count where sameApp[i].net.sign != sameApp[i - 1].net.sign {
            alternations += 1
        }
        if alternations >= 2 {
            emit?(Evidence(feature: .reReading,
                           strength: min(1.0, 0.4 + 0.2 * Double(alternations)), t: t))
        }
    }

    // MARK: Dwell → dense_dwell

    private func onDwell(_ p: DwellPayload, t: TimeInterval) {
        // Reading-shaped apps only; mouse-quiet in a terminal means something else.
        let category = p.app.map { AppFocusSensor.category(for: $0) } ?? "other"
        guard ["pdf", "browser", "editor", "notes"].contains(category) else { return }
        emit?(Evidence(feature: .denseDwell,
                       strength: min(1.0, p.seconds / 60.0), t: t))
    }
}
