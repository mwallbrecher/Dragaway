import AppKit

/// "Snip → session" without fighting the system: macOS's own ⇧⌘4 / ⇧⌘5 shortcuts are
/// symbolic hotkeys consumed before any app hotkey, so they can't be overridden
/// programmatically. Instead this watches Spotlight for freshly written screenshot
/// files (`kMDItemIsScreenCapture == 1` — set by screencapture on every shot) and
/// opens each new one straight into an Dragaway session. Native shortcuts keep working,
/// the file still lands wherever the user saves screenshots, no extra permissions.
@MainActor
final class ScreenshotWatcher: NSObject {
    static let shared = ScreenshotWatcher()
    private override init() { super.init() }

    /// Settings toggle (default off — auto-opening windows should be opt-in).
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "screenshotsToSession") }
        set { UserDefaults.standard.set(newValue, forKey: "screenshotsToSession") }
    }

    private var query: NSMetadataQuery?
    /// Paths already known when the watcher started (or already handled) — only
    /// genuinely NEW screenshots open a session.
    private var seen = Set<String>()

    func start() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(
            self, selector: #selector(initialGatherDone(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(
            self, selector: #selector(queryUpdated(_:)),
            name: .NSMetadataQueryDidUpdate, object: q)
        seen = []
        q.start()
        query = q
    }

    func stop() {
        guard let q = query else { return }
        q.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        query = nil
        seen = []
    }

    /// Baseline: everything that existed before the watcher armed is not "new".
    @objc private func initialGatherDone(_ note: Notification) {
        guard let q = query else { return }
        q.disableUpdates()
        for i in 0..<q.resultCount { seen.insert(path(at: i)) }
        q.enableUpdates()
    }

    @objc private func queryUpdated(_ note: Notification) {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        for i in 0..<q.resultCount {
            let p = path(at: i)
            guard !p.isEmpty, !seen.contains(p) else { continue }
            seen.insert(p)
            let url = URL(fileURLWithPath: p)
            // Small delay so screencapture has definitely finished writing the file
            // (the metadata hit can precede the final bytes).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                NotificationCenter.default.post(name: .radialOpenSession, object: [url])
            }
        }
    }

    private func path(at index: Int) -> String {
        (query?.result(at: index) as? NSMetadataItem)?
            .value(forAttribute: NSMetadataItemPathKey) as? String ?? ""
    }
}

/// macOS's floating screenshot thumbnail (bottom-right preview) delays the file write
/// by ~5 s — the watcher can only fire once the file exists. This flips the same
/// per-user preference as ⇧⌘5 → Options → "Show Floating Thumbnail"
/// (`com.apple.screencapture show-thumbnail`), so saves become instant. Writable
/// because the app is not sandboxed; screencaptureui reads it per capture.
enum ScreenCapturePrefs {
    private static let domain = "com.apple.screencapture" as CFString
    private static let key    = "show-thumbnail" as CFString

    /// True when the floating thumbnail is turned OFF (missing key = macOS default ON).
    static var thumbnailDisabled: Bool {
        guard let v = CFPreferencesCopyValue(key, domain,
                                             kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost) as? Bool else { return false }
        return !v
    }

    static func setThumbnailDisabled(_ disabled: Bool) {
        CFPreferencesSetValue(key, (!disabled) as CFBoolean, domain,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
