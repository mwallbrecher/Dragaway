import Foundation
import CryptoKit
import NaturalLanguage

// THESIS (L1 shared) — text → content-derived scalars, used by ClipboardSensor and
// SelectionSensor. This is where raw text dies: everything returned here is safe to
// put on the bus / into traces (the privacy invariant, ARCHITECTURE §4).
enum IntentText {

    struct Scalars {
        let charCount: Int
        let wordCount: Int
        let language: String?
        let langConfidence: Double?
        let isForeignLanguage: Bool
        let shape: String
        let hashPrefix: String
        let embedding: [Double]?
    }

    /// User's languages ("de", "en", …) — anything else counts as foreign.
    static let userLanguages: Set<String> = Set(
        Locale.preferredLanguages.compactMap { $0.split(separator: "-").first.map(String.init) }
    )

    static func scalars(for text: String, withEmbedding: Bool = true) -> Scalars {
        let words = text.split(whereSeparator: \.isWhitespace).count

        // Language detection on a bounded prefix (cost control; 1000 chars is plenty).
        var language: String?
        var confidence: Double?
        if text.count >= 4 {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(String(text.prefix(1000)))
            if let (lang, conf) = recognizer.languageHypotheses(withMaximum: 1).first {
                language = lang.rawValue
                confidence = conf
            }
        }
        // Foreign only when confident AND long enough to matter (short strings are
        // unreliable AND rarely worth translating) — thresholds from ARCHITECTURE §8.
        let isForeign = (confidence ?? 0) > 0.6
            && text.count >= 20
            && language.map { !userLanguages.contains(String($0.prefix(2))) } == true

        return Scalars(
            charCount: text.count,
            wordCount: words,
            language: language,
            langConfidence: confidence.map { (($0 * 100).rounded()) / 100 },
            isForeignLanguage: isForeign,
            shape: shape(of: text, words: words),
            hashPrefix: hashPrefix(text),
            embedding: withEmbedding ? embedding(for: text, language: language) : nil)
    }

    /// Cheap structural shape heuristics (FileSignals spirit): good enough as scorer
    /// features, never shown to the user as fact.
    static func shape(of text: String, words: Int) -> String {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if lines.count >= 2 {
            let tabbed = lines.filter { $0.contains("\t") }.count
            if tabbed * 2 >= lines.count { return "table" }

            let markers = ["{", "}", ";", "func ", "def ", "import ", "let ", "var ",
                           "class ", "=>", "();", "return "]
            let codeLines = lines.filter { l in markers.contains { l.contains($0) } }.count
            if codeLines * 2 >= lines.count { return "code" }

            let bullets = lines.filter { l in
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("-") || t.hasPrefix("•") || t.hasPrefix("*") { return true }
                if let f = t.first, f.isNumber,
                   t.dropFirst().first == "." || t.dropFirst().first == ")" { return true }
                return false
            }.count
            if lines.count >= 3, bullets * 2 >= lines.count { return "list" }
        }

        if text.contains("?") && text.count < 300 { return "question" }
        if words < 8 { return "fragment" }
        return "prose"
    }

    static func hashPrefix(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }

    // MARK: Embeddings (topic_coherence raw material)
    //
    // Apple NLEmbedding, on-device, language-specific — the pluggable backbone from
    // ARCHITECTURE §8/§12. Interface is deliberately "text in, [Double]? out" so a
    // MiniLM CoreML model is a drop-in replacement if NLEmbedding discriminates too
    // weakly on real traces. Rounded to 3 decimals to keep JSONL traces compact.
    static func embedding(for text: String, language: String?) -> [Double]? {
        guard text.count >= 20, text.count <= 4000 else { return nil }
        let lang = NLLanguage(language ?? "en")
        guard let model = NLEmbedding.sentenceEmbedding(for: lang)
                       ?? NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        guard let vector = model.vector(for: String(text.prefix(500))) else { return nil }
        return vector.map { ($0 * 1000).rounded() / 1000 }
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / ((na * nb).squareRoot())
    }
}
