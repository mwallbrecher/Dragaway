import AppKit

// THESIS (L4) — intent class + evidence → one concrete, phrased suggestion.
// M3 scope: translation only (the primary MVP case). The resolver is the ONLY
// pipeline component that may touch raw content, and only in two narrow ways:
//   · at SHOW time: hash the current pasteboard to verify the evidence object is
//     still there (read → hash → discard);
//   · at ACCEPT time: hand off to the existing clipboard-session path, which
//     reads the pasteboard itself — raw text enters a session only after the
//     user explicitly said yes.

/// What the whisper offers: the action to run, phrased as the one sentence the
/// user would have asked. (LLM phrasing arrives with M4; M3 uses templates.)
struct IntentSuggestion {
    let intentClass: IntentClass
    let action: AIAction
    let phrase: String
    let candidateHash: String
    let probability: Double
}

enum TaskResolver {

    /// Best translate target from the catalog (en/de/fr/es): the user's most
    /// preferred language that is NOT the detected source language.
    static func translateAction(avoiding sourceLanguage: String?) -> AIAction {
        let catalog: [String: AIAction] = ["en": .translateEnglish, "de": .translateGerman,
                                           "fr": .translateFrench, "es": .translateSpanish]
        let source = sourceLanguage.map { String($0.prefix(2)) }
        for preferred in Locale.preferredLanguages.map({ String($0.prefix(2)) }) {
            if preferred == source { continue }
            if let action = catalog[preferred] { return action }
        }
        return .translateEnglish
    }

    /// nil when the pasteboard no longer holds the evidence text — a suggestion
    /// must never point at content the user has already replaced.
    static func resolveTranslation(candidate: FeatureExtractor.ClipCandidate,
                                   probability: Double) -> IntentSuggestion? {
        guard pasteboardMatches(candidate.hash) else { return nil }
        let sourceName = candidate.language.flatMap {
            Locale.current.localizedString(forLanguageCode: String($0.prefix(2)))
        }
        return IntentSuggestion(
            intentClass: .translation,
            action: translateAction(avoiding: candidate.language),
            phrase: sourceName.map { "Translate this \($0) text?" } ?? "Translate this text?",
            candidateHash: candidate.hash,
            probability: probability)
    }

    /// Hash-only freshness check: read → hash → discard, nothing retained.
    static func pasteboardMatches(_ hash: String) -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        return IntentText.hashPrefix(text) == hash
    }
}
