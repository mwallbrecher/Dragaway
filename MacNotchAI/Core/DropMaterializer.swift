import AppKit
import UniformTypeIdentifiers

/// "Drag anything": turns non-file drags — a text selection, a web link, an image
/// dragged straight out of a browser — into small local files, so the entire existing
/// file pipeline (chips, AI actions, utilities, session history, drag-out) just works.
///
/// Capture happens at `draggingEntered` (the drag pasteboard is fully open and fast
/// while the drag is in flight); the file is only WRITTEN at drop time. Files land in
/// Application Support/<bundle>/Drops, newest 50 kept, so session history can reopen
/// them later.
@MainActor
enum DropMaterializer {

    /// A non-file drag payload captured mid-drag.
    enum Payload {
        case text(String)
        case webURL(URL)
        case image(Data)          // PNG data

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    private nonisolated static var jpegType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("public.jpeg")
    }

    /// True when the drag pasteboard carries something we can materialize (used by the
    /// DragMonitor gate to wake the pill for non-file drags).
    nonisolated static func hasPayload(on pb: NSPasteboard) -> Bool {
        if declaresImage(on: pb) { return true }
        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if webURL(on: pb) != nil { return true }
        return false
    }

    /// Capture the best payload from the drag pasteboard. Preference order:
    /// image (the visual thing being dragged) → web link → plain text.
    nonisolated static func capture(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }

        let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // A dragged link (URL flavour, or the text itself IS a bare link).
        if let url = webURL(on: pb) {
            // Prefer the text when the user dragged a real selection that merely
            // CONTAINS a link; prefer the URL when the text is just the link/title.
            if text.isEmpty || text == url.absoluteString || !text.contains(" ") {
                return .webURL(url)
            }
        }
        if !text.isEmpty { return .text(text) }
        return nil
    }

    /// Browser drags frequently expose several representations of the same visual
    /// object. The thing being dragged wins: bitmap bytes first, then its URL, then
    /// ordinary text. In particular, Google Images offers BOTH JPEG/TIFF bytes and an
    /// `imgres` page URL — treating URL as authoritative silently turned images into TXT.
    nonisolated static func preferredBrowserPayload(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }
        if let url = webURL(on: pb) { return .webURL(url) }
        return capture(from: pb)
    }

    /// The late-window fallback deliberately stays narrow: it may claim an image or
    /// HTTP(S) URL, but never broad text selections that should use AppKit normally.
    nonisolated static func browserFallbackPayload(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }
        if let url = webURL(on: pb) { return .webURL(url) }
        return nil
    }

    /// True from declared flavours alone — safe for deciding whether a failed bitmap
    /// read should defer to an NSFilePromiseReceiver instead of degrading to the URL.
    nonisolated static func declaresImage(on pb: NSPasteboard) -> Bool {
        let types = Set((pb.types ?? []).map(\.rawValue))
        return types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains(jpegType.rawValue)
    }

    /// Read browser bitmap flavours in compressed-first order and normalize to PNG so
    /// the existing image/vision pipeline receives one stable representation.
    private nonisolated static func captureImage(from pb: NSPasteboard) -> Payload? {
        if let png = pb.data(forType: .png) { return .image(png) }
        if let jpeg = pb.data(forType: jpegType),
           let rep = NSBitmapImageRep(data: jpeg),
           let png = rep.representation(using: .png, properties: [:]) { return .image(png) }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return .image(png) }
        return nil
    }

    /// Write the payload to the Drops folder; returns the file URL to session on.
    static func materialize(_ payload: Payload) -> URL? {
        let dir = dropsDir()
        let stamp = Self.stamp()
        do {
            switch payload {
            case .image(let png):
                let url = uniqueDropURL(
                    dir.appendingPathComponent("Dropped Image \(stamp).png")
                )
                try png.write(to: url)
                prune(dir)
                return url
            case .webURL(let link):
                let name = (link.host ?? "Link").replacingOccurrences(of: "www.", with: "")
                let url = uniqueDropURL(
                    dir.appendingPathComponent("\(sanitize(name)) \(stamp).txt")
                )
                try link.absoluteString.data(using: .utf8)?.write(to: url)
                FilePresentation.markAsWebDrop(url)
                prune(dir)
                // The drop stays instant. The file-scoped task upgrades this URL-only
                // placeholder in the background; a fast AI action awaits that exact
                // task at the shared content-builder choke point.
                WebDropPreparation.start(file: url, link: link)
                return url
            case .text(let text):
                let url = uniqueDropURL(
                    dir.appendingPathComponent("\(titleWords(text)) \(stamp).txt")
                )
                try text.data(using: .utf8)?.write(to: url)
                prune(dir)
                return url
            }
        } catch {
            return nil
        }
    }

    // MARK: - Internals

    /// Best HTTP(S) URL offered by a browser-style drag. Internal so the global
    /// drag fallback can cache the URL before a late-created AppKit destination
    /// has had a chance to enter the drag session.
    nonisolated static func webURL(on pb: NSPasteboard) -> URL? {
        // Non-file URL flavour (public.url) — readObjects without fileURLsOnly.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL],
           let first = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return first
        }
        // Raw public.url string — Safari link/tab drags often vend ONLY this flavour,
        // which readObjects doesn't always surface.
        if let s = pb.string(forType: NSPasteboard.PasteboardType("public.url"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        // Safari's legacy WebURLsWithTitles plist: [[url, …], [title, …]].
        if let plist = pb.propertyList(
               forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]],
           let s = plist.first?.first,
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        // Or the dragged text itself is a bare http(s) link.
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.contains(" "), !s.contains("\n"),
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        return nil
    }

    /// Destination for received file PROMISES (Safari tabs, Photos, Mail) — the
    /// promising app writes the real file here on drop.
    static func dropsDirectory() -> URL { dropsDir() }

    /// Post-process a promised file: Safari tabs deliver a `.webloc` — unwrap it to
    /// the link and route through the normal web path (materialize + page fetch), so
    /// a tab drop behaves exactly like a URL drop. Anything else passes through.
    static func normalizeReceived(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let s = (plist as? [String: Any])?["URL"] as? String,
              let link = URL(string: s), link.scheme == "http" || link.scheme == "https",
              let materialized = materialize(.webURL(link))
        else { return url }
        try? FileManager.default.removeItem(at: url)   // keep only the enriched .txt
        return materialized
    }

    private static func dropsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let d = base.appendingPathComponent(bundle, isDirectory: true)
                    .appendingPathComponent("Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// First few words of the text as a readable filename ("Quarterly results were…").
    private static func titleWords(_ text: String) -> String {
        let words = text.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        let head = words.prefix(4).joined(separator: " ")
        let cleaned = sanitize(String(head.prefix(32)))
        return cleaned.isEmpty ? "Dropped Text" : cleaned
    }

    private static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// A multi-item browser drag can materialize several payloads within the same
    /// timestamp second. Never let one placeholder overwrite another before its
    /// file-scoped web preparation has even started.
    private static func uniqueDropURL(_ candidate: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let directory = candidate.deletingLastPathComponent()
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let filename = ext.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(ext)"
            let proposed = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: proposed.path) { return proposed }
            suffix += 1
        }
    }

    /// Keep the newest 50 drops so the folder can't grow forever.
    private static func prune(_ dir: URL, keep: Int = 50) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        guard files.count > keep else { return }
        let dated = files.compactMap { url -> (URL, Date)? in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return d.map { (url, $0) }
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keep) { try? fm.removeItem(at: url) }
    }
}
