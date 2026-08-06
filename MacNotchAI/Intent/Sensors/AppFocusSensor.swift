import AppKit

// THESIS (L1 sensor) — frontmost-application changes via NSWorkspace notifications.
// Ungated, event-driven, effectively free. The app-switch sequence is the backbone
// of the M2 detectors `copy_then_translator_switch` and `collect_mode` (sources).
final class AppFocusSensor: IntentSensor {

    let name = "appFocus"

    private weak var bus: SignalBus?
    private var observer: NSObjectProtocol?
    private var current: (bundleID: String, since: TimeInterval)?

    func start(bus: SignalBus) {
        self.bus = bus
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            current = (app, Date().timeIntervalSince1970)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            self?.handleActivation(app)
        }
    }

    func stop() {
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observer = nil
    }

    private func handleActivation(_ app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        guard bundleID != current?.bundleID else { return }   // spurious re-activation

        let t = Date().timeIntervalSince1970
        let previous = current
        current = (bundleID, t)

        bus?.publish(SignalEvent(t: t, kind: .appFocus, appFocus: AppFocusPayload(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            category: Self.category(for: bundleID),
            previousBundleID: previous?.bundleID,
            secondsInPrevious: previous.map { ((t - $0.since) * 10).rounded() / 10 })))
    }

    // MARK: Coarse app categories
    //
    // Deliberately coarse: the scorer needs "switched toward a translator-ish thing",
    // not an app census. Unknowns fall through keyword heuristics to "other".
    // Translator *websites* (deepl.com in a browser tab) need the window title — AX, M2.

    private static let knownCategories: [String: String] = [
        // browsers
        "com.apple.Safari": "browser", "com.google.Chrome": "browser",
        "org.mozilla.firefox": "browser", "com.microsoft.edgemac": "browser",
        "company.thebrowser.Browser": "browser", "com.brave.Browser": "browser",
        // translators / dictionaries
        "com.linguee.DeepLCopyTranslator": "translator", "com.deepl.macos": "translator",
        // documents & reading
        "com.apple.Preview": "pdf", "com.apple.iBooksX": "pdf",
        "com.apple.Notes": "notes", "com.apple.TextEdit": "editor",
        "com.apple.iWork.Pages": "editor", "com.microsoft.Word": "editor",
        "md.obsidian": "notes", "notion.id": "notes",
        // mail & messaging
        "com.apple.mail": "mail", "com.microsoft.Outlook": "mail",
        "com.tinyspeck.slackmacgap": "messaging", "net.whatsapp.WhatsApp": "messaging",
        // dev
        "com.apple.dt.Xcode": "ide", "com.microsoft.VSCode": "ide",
        "com.apple.Terminal": "terminal", "com.googlecode.iterm2": "terminal",
        // spreadsheets
        "com.apple.iWork.Numbers": "spreadsheet", "com.microsoft.Excel": "spreadsheet",
    ]

    static func category(for bundleID: String) -> String {
        if let known = knownCategories[bundleID] { return known }
        let lower = bundleID.lowercased()
        if lower.contains("mail") { return "mail" }
        if lower.contains("translat") || lower.contains("dict") { return "translator" }
        if lower.contains("browser") { return "browser" }
        if lower.contains("pdf") { return "pdf" }
        if lower.contains("note") { return "notes" }
        return "other"
    }
}
