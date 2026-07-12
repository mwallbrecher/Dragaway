import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Clipboard history
//
// A lightweight clipboard manager. Polls `NSPasteboard.general.changeCount` and
// records each new copy — text, image, or file(s) — newest-first, capped at 20.
// Surfaced two ways: the menu-bar "Clipboard History" submenu (last 20) and the
// ⌃⌘V picker popup (last 10). Picking an item COPIES it back to the clipboard
// (the user then presses ⌘V); we never synthesise keystrokes.
//
// Privacy: pasteboard items flagged sensitive/concealed/transient by the source app
// (password managers set these) are NEVER captured. Everything else persists as JSON
// in Application Support (image bytes as sibling PNGs), surviving relaunch.
//
// All access is @MainActor — the poll timer fires on the main runloop and the menu /
// picker read on the main thread.

enum ClipKind: String, Codable { case text, image, files }

/// One captured clipboard entry. Exactly one payload field is populated per `kind`.
struct ClipItem: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ClipKind
    var text: String?               // .text
    var filePaths: [String]?        // .files
    var imageFile: String?          // .image — filename within clip_images/
    var imageW: Int?                 // .image pixel size (for the preview label)
    var imageH: Int?
    let date: Date
    /// Stable de-dupe key (survives relaunch — no per-process hashing).
    let signature: String

    /// Single-line label for the menu / picker rows.
    var preview: String {
        switch kind {
        case .text:
            let collapsed = (text ?? "")
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return collapsed.isEmpty ? "(empty)" : collapsed
        case .files:
            let names = (filePaths ?? []).map { ($0 as NSString).lastPathComponent }
            if names.count <= 2 { return names.joined(separator: ", ") }
            return "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
        case .image:
            if let w = imageW, let h = imageH { return "Image · \(w) × \(h)" }
            return "Image"
        }
    }
}

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    /// Newest-first. Capped at `maxItems`.
    @Published private(set) var items: [ClipItem] = []

    private let maxItems = 20

    /// UserDefault gate (default ON). The menu "Track Clipboard" toggle flips it.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardHistoryEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardHistoryEnabled") }
    }

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// changeCount of OUR OWN pasteboard write (copyToPasteboard) — skipped by the poll.
    private var ignoreChangeCount = -1

    private let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let d = base.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var jsonURL: URL { dir.appendingPathComponent("clipboard_history.json") }
    private var imagesDir: URL {
        let d = dir.appendingPathComponent("clip_images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private init() { load() }

    // MARK: - Monitoring

    /// Start the 0.5 s changeCount poll. `.common` mode so it fires even while the user
    /// is dragging / tracking inside another app. No-op when capture is disabled.
    func startMonitoring() {
        guard Self.isEnabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        guard cc != ignoreChangeCount else { return }   // ignore our own write
        capture(from: pb)
    }

    // MARK: - Capture

    private func capture(from pb: NSPasteboard) {
        // Privacy: never record sensitive / transient items (PasteboardPrivacy is
        // the shared single source of truth for every clipboard-reading path).
        guard !PasteboardPrivacy.isSensitive(pb.types) else { return }

        guard let item = buildItem(from: pb) else { return }

        // Already the newest item → nothing to do.
        if items.first?.signature == item.signature { return }

        // Re-copy of an older item → move it to the front (drop the fresh duplicate).
        if let idx = items.firstIndex(where: { $0.signature == item.signature }) {
            let existing = items.remove(at: idx)
            items.insert(existing, at: 0)
            if item.kind == .image { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(item.imageFile ?? "")) }
            save()
            return
        }

        items.insert(item, at: 0)
        trim()
        save()
    }

    /// Build a `ClipItem` from the pasteboard. File URLs win over image data win over text.
    private func buildItem(from pb: NSPasteboard) -> ClipItem? {
        let id = UUID()

        // 1. Files (Finder copy) — file URLs only.
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let paths = urls.map(\.path)
            return ClipItem(id: id, kind: .files, filePaths: paths, date: Date(),
                            signature: "F:" + paths.joined(separator: "\n"))
        }

        // 2. Image bitmap (not a file) — persist a PNG sibling.
        if pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier]),
           let img = NSImage(pasteboard: pb),
           let png = pngData(from: img) {
            let name = id.uuidString + ".png"
            try? png.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
            let px = pixelSize(of: img)
            return ClipItem(id: id, kind: .image, imageFile: name,
                            imageW: px?.width, imageH: px?.height, date: Date(),
                            signature: "I:\(png.count)x\(px?.width ?? 0)x\(px?.height ?? 0)")
        }

        // 3. Plain text.
        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ClipItem(id: id, kind: .text, text: s, date: Date(), signature: "T:" + s)
        }

        return nil
    }

    // MARK: - Copy back (picker / menu selection)

    /// Write `item` back to the system pasteboard and move it to the front. Copy-only —
    /// the user presses ⌘V themselves. The change is tagged so the poll won't re-add it.
    func copyToPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if let t = item.text { pb.setString(t, forType: .string) }
        case .files:
            let urls = (item.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            if !urls.isEmpty { pb.writeObjects(urls) }
        case .image:
            if let img = loadImage(item), let tiff = img.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
        ignoreChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount

        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            let it = items.remove(at: idx)
            items.insert(it, at: 0)
            save()
        }
    }

    // MARK: - Images

    /// Load a captured image item from disk (for the picker thumbnail / copy-back).
    func loadImage(_ item: ClipItem) -> NSImage? {
        guard item.kind == .image, let name = item.imageFile else { return nil }
        return NSImage(contentsOf: imagesDir.appendingPathComponent(name))
    }

    /// 32-pt icon for a menu / picker row: the image itself, the file's type icon, or a
    /// generic text glyph.
    func icon(for item: ClipItem, size: CGFloat = 32) -> NSImage {
        let img: NSImage
        switch item.kind {
        case .image:
            img = loadImage(item) ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage()
        case .files:
            img = NSWorkspace.shared.icon(forFile: item.filePaths?.first ?? "")
        case .text:
            img = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
        img.size = NSSize(width: size, height: size)
        return img
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func pixelSize(of image: NSImage) -> (width: Int, height: Int)? {
        guard let rep = image.representations.first as? NSBitmapImageRep else {
            return image.size.width > 0 ? (Int(image.size.width), Int(image.size.height)) : nil
        }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    // MARK: - Mutation

    func remove(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let it = items.remove(at: idx)
        deleteImageFile(of: it)
        save()
    }

    func clear() {
        for it in items { deleteImageFile(of: it) }
        items.removeAll()
        save()
    }

    /// Drop items beyond the cap and delete their orphaned image files.
    private func trim() {
        guard items.count > maxItems else { return }
        for it in items[maxItems...] { deleteImageFile(of: it) }
        items.removeLast(items.count - maxItems)
    }

    private func deleteImageFile(of item: ClipItem) {
        guard item.kind == .image, let name = item.imageFile else { return }
        try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: jsonURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = Array(decoded.prefix(maxItems))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }
}
