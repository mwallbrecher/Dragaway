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

    // MARK: - Internals

    private nonisolated static func webURL(on pb: NSPasteboard) -> URL? {
        // Non-file URL flavour (public.url) — readObjects without fileURLsOnly.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL],
           let first = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return first
        }
        // Or the dragged text itself is a bare http(s) link.
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.contains(" "), !s.contains("\n"),
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        return nil
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
