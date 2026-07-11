import AppKit
import CryptoKit
import NaturalLanguage

// THESIS (L1 sensor) — clipboard observation via changeCount polling.
//
// Same ungated mechanism as ClipboardHistoryStore, but deliberately independent:
// the history store is a user-facing feature with its own settings/lifecycle on
// main; this sensor must keep working (and merging) regardless of what happens
// to that feature. Polling an Int at 2 Hz is negligible.
//
// PRIVACY: the pasteboard string is classified here and discarded — only derived
// scalars are published (see IntentSignal.swift). Concealed/transient pasteboards
// (password managers) are skipped entirely.
final class ClipboardSensor: IntentSensor {

    let name = "clipboard"

    private weak var bus: SignalBus?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    /// User's languages ("de", "en", …) — anything else counts as foreign.
    private let userLanguages: Set<String> = Set(
        Locale.preferredLanguages.compactMap { $0.split(separator: "-").first.map(String.init) }
    )

    func start(bus: SignalBus) {
        self.bus = bus
        lastChangeCount = NSPasteboard.general.changeCount   // ignore pre-existing content
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        let types = pb.types ?? []
        // Respect the de-facto pasteboard privacy markers (1Password & co).
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        guard !types.contains(concealed), !types.contains(transient) else { return }

        guard let payload = classify(pb, types: types) else { return }
        bus?.publish(SignalEvent(t: Date().timeIntervalSince1970, kind: .clipboard,
                                 clipboard: payload))
    }

    // MARK: Classification (content in, scalars out, content dropped)

    private func classify(_ pb: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> ClipboardPayload? {
        let sourceApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Files first — a Finder copy also carries a string representation.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return ClipboardPayload(
                contentClass: "files", charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hasURL: false,
                hashPrefix: hashPrefix(urls.map(\.path).joined(separator: "\n")),
                sourceApp: sourceApp,
                fileExtensions: urls.map { $0.pathExtension.lowercased() })
        }

        if let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return classifyText(text, sourceApp: sourceApp)
        }

        if types.contains(.tiff) || types.contains(.png) {
            return ClipboardPayload(
                contentClass: "image", charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hasURL: false, hashPrefix: "",
                sourceApp: sourceApp, fileExtensions: nil)
        }

        return nil   // nothing we understand — emit nothing rather than noise
    }

    private func classifyText(_ text: String, sourceApp: String?) -> ClipboardPayload {
        let words = text.split(whereSeparator: \.isWhitespace).count

        // Whole-string URL ⇒ its own content class (link drops are their own world).
        let isWholeURL = !text.contains(" ")
            && (text.hasPrefix("http://") || text.hasPrefix("https://"))
            && URL(string: text) != nil

        // Language detection on a bounded prefix (cost control; 1000 chars is plenty).
        var language: String?
        var confidence: Double?
        if !isWholeURL, text.count >= 4 {
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

        return ClipboardPayload(
            contentClass: isWholeURL ? "url" : "text",
            charCount: text.count,
            wordCount: words,
            language: language,
            langConfidence: confidence.map { (($0 * 100).rounded()) / 100 },
            isForeignLanguage: isForeign,
            shape: isWholeURL ? "" : shape(of: text, words: words),
            hasURL: text.contains("http://") || text.contains("https://") || text.contains("www."),
            hashPrefix: hashPrefix(text),
            sourceApp: sourceApp,
            fileExtensions: nil)
    }

    /// Cheap structural shape heuristics (FileSignals spirit): good enough as scorer
    /// features, never shown to the user as fact.
    private func shape(of text: String, words: Int) -> String {
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

    private func hashPrefix(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
    }
}
