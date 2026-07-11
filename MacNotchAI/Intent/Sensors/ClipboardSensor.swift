import AppKit

// THESIS (L1 sensor) — clipboard observation via changeCount polling.
//
// Same ungated mechanism as ClipboardHistoryStore, but deliberately independent:
// the history store is a user-facing feature with its own settings/lifecycle on
// main; this sensor must keep working (and merging) regardless of what happens
// to that feature. Polling an Int at 2 Hz is negligible.
//
// PRIVACY: the pasteboard string is classified (IntentText) and discarded — only
// derived scalars are published. Concealed/transient pasteboards (password
// managers) are skipped entirely.
final class ClipboardSensor: IntentSensor {

    let name = "clipboard"

    private weak var bus: SignalBus?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

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
                hashPrefix: IntentText.hashPrefix(urls.map(\.path).joined(separator: "\n")),
                sourceApp: sourceApp,
                fileExtensions: urls.map { $0.pathExtension.lowercased() })
        }

        if let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {

            // Whole-string URL ⇒ its own content class (link drops are their own world).
            let isWholeURL = !text.contains(" ")
                && (text.hasPrefix("http://") || text.hasPrefix("https://"))
                && URL(string: text) != nil
            if isWholeURL {
                return ClipboardPayload(
                    contentClass: "url", charCount: text.count, wordCount: 1,
                    language: nil, langConfidence: nil, isForeignLanguage: false,
                    shape: "", hasURL: true,
                    hashPrefix: IntentText.hashPrefix(text),
                    sourceApp: sourceApp, fileExtensions: nil)
            }

            let s = IntentText.scalars(for: text)
            return ClipboardPayload(
                contentClass: "text",
                charCount: s.charCount, wordCount: s.wordCount,
                language: s.language, langConfidence: s.langConfidence,
                isForeignLanguage: s.isForeignLanguage,
                shape: s.shape,
                hasURL: text.contains("http://") || text.contains("https://") || text.contains("www."),
                hashPrefix: s.hashPrefix,
                sourceApp: sourceApp, fileExtensions: nil,
                embedding: s.embedding)
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
}
