import AppKit
import ApplicationServices

// THESIS (L1 sensor, M2) — text selection + focused-window context via the
// Accessibility API. THE ONLY permission-gated sensor in the pipeline.
//
// ⚠ Accessibility policy: the released app (main) uses no gated APIs — that rule
// stands. This sensor exists ONLY on the thesis branch, is opt-in behind
// IntentEngine.axSensorKey, and is the sanctioned exception documented in
// docs/thesis/ARCHITECTURE.md §3 (research prototype, transparent first-use grant).
//
// PRIVACY: selected text, window title, and document path are classified at
// capture (IntentText) and discarded. The bus sees scalars, a selection hash,
// a document-identity hash, and a translator-context boolean — never content.
//
// Mechanism: 1 Hz polling of the system-wide focused UI element. AXObserver
// subscriptions would be push-based but need per-app plumbing; polling is fine
// at this rate and works uniformly across apps that expose AX at all (native ✓,
// Chromium ✓, some Electron ✗, secure fields never — ARCHITECTURE §3 caveat).
final class SelectionSensor: IntentSensor {

    let name = "selection"

    private weak var bus: SignalBus?
    private var timer: Timer?
    private var lastSelectionHash = ""
    private var lastTranslatorContext = false

    /// Focused-window title/document markers that make a translator context.
    /// Checked at capture; the strings themselves are discarded.
    private static let translatorMarkers = [
        "deepl", "translate", "translator", "linguee", "dict.cc", "leo.org",
        "reverso", "übersetzer", "wörterbuch", "dictionary",
    ]

    func start(bus: SignalBus) {
        self.bus = bus
        guard AXIsProcessTrusted() else { return }   // dormant without the grant
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Polling

    private func poll() {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide,
                kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let ref = focusedRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return }
        let focused = ref as! AXUIElement

        let (docID, translator) = windowContext(of: focused)
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Context-only event when the translator context flips ON — this is how
        // "user went to deepl.com" becomes visible without any selection there
        // (feeds copy_then_translator_switch alongside AppFocusSensor's category).
        if translator, !lastTranslatorContext {
            publish(payload: SelectionPayload(
                app: app, charCount: 0, wordCount: 0,
                language: nil, langConfidence: nil, isForeignLanguage: false,
                shape: "", hashPrefix: "", docID: docID, isTranslatorContext: true))
        }
        lastTranslatorContext = translator

        // Selection change?
        var selRef: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &selRef)
        guard let text = (selRef as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              text.count >= 3
        else { return }

        let hash = IntentText.hashPrefix(text)
        guard hash != lastSelectionHash else { return }
        lastSelectionHash = hash

        // Selections don't need embeddings (topic_coherence runs on copies).
        let s = IntentText.scalars(for: text, withEmbedding: false)
        publish(payload: SelectionPayload(
            app: app, charCount: s.charCount, wordCount: s.wordCount,
            language: s.language, langConfidence: s.langConfidence,
            isForeignLanguage: s.isForeignLanguage, shape: s.shape,
            hashPrefix: s.hashPrefix, docID: docID, isTranslatorContext: translator))
    }

    private func publish(payload: SelectionPayload) {
        bus?.publish(SignalEvent(t: Date().timeIntervalSince1970, kind: .selection,
                                 selection: payload))
    }

    /// Document identity + translator context from the focused element's window.
    /// Title and document path are hashed/matched here and never stored.
    private func windowContext(of element: AXUIElement) -> (docID: String?, translator: Bool) {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,
                kAXWindowAttribute as CFString, &windowRef) == .success,
              let wRef = windowRef,
              CFGetTypeID(wRef) == AXUIElementGetTypeID()
        else { return (nil, false) }
        let window = wRef as! AXUIElement

        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
        let document = docRef as? String

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String

        let identity = document ?? title
        let docID = identity.map { IntentText.hashPrefix($0) }

        let haystack = ((document ?? "") + " " + (title ?? "")).lowercased()
        let translator = Self.translatorMarkers.contains { haystack.contains($0) }

        return (docID, translator)
    }
}
