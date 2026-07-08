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
    }

    /// True when the drag pasteboard carries something we can materialize (used by the
    /// DragMonitor gate to wake the pill for non-file drags).
    nonisolated static func hasPayload(on pb: NSPasteboard) -> Bool {
        let types = Set((pb.types ?? []).map(\.rawValue))
        if types.contains(NSPasteboard.PasteboardType.png.rawValue) ||
           types.contains(NSPasteboard.PasteboardType.tiff.rawValue) { return true }
        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if webURL(on: pb) != nil { return true }
        return false
    }

    /// Capture the best payload from the drag pasteboard. Preference order:
    /// image (the visual thing being dragged) → web link → plain text.
    nonisolated static func capture(from pb: NSPasteboard) -> Payload? {
        // Image data (e.g. an image dragged out of a browser — no file behind it).
        if let png = pb.data(forType: .png) { return .image(png) }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return .image(png) }

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

    /// Write the payload to the Drops folder; returns the file URL to session on.
    static func materialize(_ payload: Payload) -> URL? {
        let dir = dropsDir()
        let stamp = Self.stamp()
        do {
            switch payload {
            case .image(let png):
                let url = dir.appendingPathComponent("Dropped Image \(stamp).png")
                try png.write(to: url)
                prune(dir)
                return url
            case .webURL(let link):
                let name = (link.host ?? "Link").replacingOccurrences(of: "www.", with: "")
                let url = dir.appendingPathComponent("\(sanitize(name)) \(stamp).txt")
                try link.absoluteString.data(using: .utf8)?.write(to: url)
                prune(dir)
                // The drop stays instant; the page content arrives in the background
                // so "summarise this website" works on the next AI turn.
                enrichWebDrop(file: url, link: link)
                return url
            case .text(let text):
                let url = dir.appendingPathComponent("\(titleWords(text)) \(stamp).txt")
                try text.data(using: .utf8)?.write(to: url)
                prune(dir)
                return url
            }
        } catch {
            return nil
        }
    }

    // MARK: - Web-page enrichment

    /// Upgrade a dropped link in the background: fetch the page (bounded), strip it to
    /// readable text, rewrite the materialized file, and invalidate the session's
    /// cached extraction so the NEXT AI turn reads the real page — this is what makes
    /// "summarise this website" actually work on a URL / Safari-tab drop.
    /// Failures leave the URL-only file in place (the drop never breaks).
    private static func enrichWebDrop(file: URL, link: URL) {
        Task.detached(priority: .userInitiated) {
            guard let page = await fetchReadableText(from: link) else { return }
            let content = """
            \(page.title ?? link.absoluteString)
            URL: \(link.absoluteString)

            \(page.text)
            """
            await MainActor.run {
                guard (try? content.write(to: file, atomically: true, encoding: .utf8)) != nil
                else { return }
                // If this file is the live session, drop the cached extraction so the
                // next turn re-reads the enriched content.
                let vm = OverlayViewModel.shared
                if vm.sessionFileURLs.contains(where: { $0.path == file.path }) {
                    vm.baseContext = nil
                }
            }
        }
    }

    /// Bounded fetch + crude readability pass (regex, fully off-main — no WebKit).
    /// Good enough as summarisation source text; not a rendering engine.
    private nonisolated static func fetchReadableText(from link: URL)
        async -> (title: String?, text: String)? {
        var req = URLRequest(url: link, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X) Dragaway/1.1",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty else { return nil }

        let capped = data.prefix(3_000_000)
        guard var html = String(data: capped, encoding: .utf8)
                ?? String(data: capped, encoding: .isoLatin1) else { return nil }

        var title: String?
        if let r = html.range(of: "<title[^>]*>([\\s\\S]*?)</title>",
                              options: [.regularExpression, .caseInsensitive]) {
            title = String(html[r])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop non-content blocks, convert structural tags to line breaks, strip the rest.
        for block in ["script", "style", "noscript", "svg", "head", "nav", "footer"] {
            html = html.replacingOccurrences(
                of: "<\(block)[\\s\\S]*?</\(block)>", with: " ",
                options: [.regularExpression, .caseInsensitive])
        }
        html = html.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</h[1-6]>|</li>|</tr>",
                                         with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        html = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                       "&#39;": "'", "&nbsp;": " "] {
            html = html.replacingOccurrences(of: k, with: v)
        }
        html = html.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\n[ ]*", with: "\n", options: .regularExpression)
        html = html.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        let text = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 80 else { return nil }        // nothing useful extracted
        return (title, String(text.prefix(40_000)))
    }

    // MARK: - Internals

    private nonisolated static func webURL(on pb: NSPasteboard) -> URL? {
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
