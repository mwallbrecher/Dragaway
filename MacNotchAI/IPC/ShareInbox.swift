import AppKit

/// Cross-process hand-off from the (sandboxed) "Add to Dragaway" Finder Quick Action
/// extension to the (non-sandboxed, always-on) main app.
///
/// The extension can't message the main app directly across the sandbox boundary, so it
/// drops the selected file URLs onto a **named pasteboard** (shared via the system
/// pasteboard server — no App Group / entitlement required) and posts a **Darwin
/// notification**. The main app observes that notification (see AppDelegate
/// `registerShareInboxObserver`) and drains the pasteboard here.
///
/// A named pasteboard + Darwin notification is the lightest IPC that crosses the sandbox
/// boundary with no special capability, so it works regardless of signing tier.
enum ShareInbox {
    /// Darwin notification posted by the extension after it writes the pasteboard.
    static let darwinNotification = "com.wallbrecher.MacNotchAI.addFiles"
    /// Private pasteboard both processes agree on. Not the general pasteboard.
    static let pasteboardName = NSPasteboard.Name("com.wallbrecher.MacNotchAI.share")

    /// Drain the hand-off: read the queued file URLs off the named pasteboard.
    /// Returns an empty array when nothing is queued.
    static func drain() -> [URL] {
        let pb = NSPasteboard(name: pasteboardName)
        let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls
    }
}
