import SwiftUI
import Combine
import AppKit

/// A user-chosen application that staged files can be opened in from the chips
/// stage (Pillar 1 — "Open With," supercharged). The app is referenced by its
/// bundle path; the icon is resolved on demand (never persisted).
struct FavoriteTool: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Absolute path to the .app bundle, e.g. `/Applications/Figma.app`.
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }

    var url: URL { URL(fileURLWithPath: path) }
}

/// Per-category favorites: the apps for one `FileCategory`, plus whether that
/// category should instead fall back to the shared **General** list.
struct CategoryFavorites: Codable, Hashable {
    /// When true, files of this category use the General list (the category's own
    /// `tools` are kept but ignored until the user turns this off).
    var useGeneral: Bool = true
    var tools: [FavoriteTool] = []
}

/// Single source of truth for the user's favorite apps, shown as a numbered launch
/// row in the chips stage and configured in Settings. Manual favorites (the user
/// picks the apps).
///
/// Apps are organised into a shared **General** list plus one list per `FileCategory`
/// (image / video / audio / text). For a dropped file the row resolves to the
/// category's own list, or — when that category has `useGeneral` on — to General.
/// Each list is capped at 9 (the `Option+1…9` hotkey range); the resolved list's
/// index `i` maps to the `Option+(i+1)` hotkey.
///
/// Same persistence pattern as `PromptStore`: a small Codable value in UserDefaults.
@MainActor
final class FavoriteToolsStore: ObservableObject {
    static let shared = FavoriteToolsStore()

    /// Hard cap = the number of `Option+N` slots (1…9). Applies per list.
    static let maxTools = 9
    /// Legacy flat list (pre-categories). Read once for migration into `general`.
    private static let keyV1 = "favoriteTools.v1"
    private static let keyV2 = "favoriteTools.v2"

    /// Shared list used by any category whose `useGeneral` is on.
    @Published private(set) var general: [FavoriteTool] = []
    /// Per-category lists + their Use-General flags. Always has an entry for every case.
    @Published private(set) var categories: [FileCategory: CategoryFavorites] = {
        var d: [FileCategory: CategoryFavorites] = [:]
        for c in FileCategory.allCases { d[c] = CategoryFavorites() }
        return d
    }()

    private init() { load() }

    // MARK: - Read

    /// The raw list for a scope (`nil` = General), ignoring Use-General resolution.
    func tools(for category: FileCategory?) -> [FavoriteTool] {
        guard let c = category else { return general }
        return categories[c]?.tools ?? []
    }

    /// Whether `category` currently defers to the General list.
    func useGeneral(for category: FileCategory) -> Bool {
        categories[category]?.useGeneral ?? true
    }

    /// The effective launch list for the dropped file(s): the primary file's category
    /// list, or General when that category defers. Empty input → General.
    func resolvedTools(for urls: [URL]) -> [FavoriteTool] {
        guard let first = urls.first else { return general }
        let c = FileInspector.category(for: first)
        let cfg = categories[c] ?? CategoryFavorites()
        return cfg.useGeneral ? general : cfg.tools
    }

    /// Tool mapped to `Option+number` (1-based) for the given session files. nil if out
    /// of range. Resolves through the same Use-General logic as the visible row.
    func tool(forNumber number: Int, for urls: [URL]) -> FavoriteTool? {
        let list = resolvedTools(for: urls)
        let i = number - 1
        return list.indices.contains(i) ? list[i] : nil
    }

    // MARK: - Mutations

    /// Add an app by its bundle URL to a scope (`nil` = General). Ignores duplicates
    /// (same path within that list) and respects the per-list cap.
    func add(appURL: URL, to category: FileCategory?) {
        let path = appURL.standardizedFileURL.path
        // Display name without the ".app" suffix (Finder-style).
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name.removeLast(4) }
        let tool = FavoriteTool(name: name, path: path)
        mutate(category) { list in
            guard list.count < Self.maxTools,
                  !list.contains(where: { $0.path == path }) else { return }
            list.append(tool)
        }
    }

    func remove(_ tool: FavoriteTool, from category: FileCategory?) {
        mutate(category) { $0.removeAll { $0.id == tool.id } }
    }

    func move(from source: IndexSet, to destination: Int, in category: FileCategory?) {
        mutate(category) { $0.move(fromOffsets: source, toOffset: destination) }
    }

    /// Toggle whether `category` defers to the General list.
    func setUseGeneral(_ value: Bool, for category: FileCategory) {
        var cfg = categories[category] ?? CategoryFavorites()
        cfg.useGeneral = value
        categories[category] = cfg
        persist()
    }

    /// Apply `transform` to the list for `category` (`nil` = General) and persist.
    private func mutate(_ category: FileCategory?, _ transform: (inout [FavoriteTool]) -> Void) {
        if let c = category {
            var cfg = categories[c] ?? CategoryFavorites()
            transform(&cfg.tools)
            categories[c] = cfg
        } else {
            transform(&general)
        }
        persist()
    }

    // MARK: - Launch

    /// Open the given file(s) in `tool`. Multi-file aware. The launched app is brought
    /// to the front — even if it was already running — while the notch session stays
    /// OPEN but COLLAPSES to its compact pill so it floats unobtrusively above the app
    /// (the user can re-expand, open in another app, or dismiss it). Non-sandboxed app →
    /// plain `NSWorkspace.open`, no security-scoped bookmark needed.
    func launch(_ tool: FavoriteTool, with urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .tutorialEvent, object: "toolLaunched")

        // Collapse the session to its compact pill so it tucks out of the way once the
        // file is handed off. Deferred one runloop tick inside `withAnimation` per the
        // window-resize invariant (synchronous stage/expansion writes abort the layout).
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                OverlayViewModel.shared.isChipsExpanded = false
            }
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: tool.url, configuration: config) { app, error in
            if let error {
                NSLog("Dragaway: could not open in \(tool.name): \(error.localizedDescription)")
                return
            }
            // `config.activates` only raises the app on a *fresh* launch; an already-running
            // target needs an explicit activate to come forward. The overlay window is
            // `.floating`, so it keeps sitting above the raised app.
            DispatchQueue.main.async {
                app?.activate()
            }
        }
    }

    // MARK: - Icons

    /// App icon, resolved on demand (NSWorkspace caches internally). Never persisted.
    func icon(for tool: FavoriteTool) -> NSImage {
        NSWorkspace.shared.icon(forFile: tool.path)
    }

    // MARK: - Persistence

    /// On-disk shape (v2). String-keyed so the JSON is a plain object, not a flattened
    /// array (which is how `JSONEncoder` would render an enum-keyed dictionary).
    private struct PersistedConfig: Codable {
        var general: [FavoriteTool]
        var categories: [String: CategoryFavorites]
    }

    private func persist() {
        var dict: [String: CategoryFavorites] = [:]
        for (c, cfg) in categories { dict[c.rawValue] = cfg }
        let config = PersistedConfig(general: general, categories: dict)
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.keyV2)
        }
    }

    private func load() {
        // Preferred: the v2 categorised config.
        if let data = UserDefaults.standard.data(forKey: Self.keyV2),
           let config = try? JSONDecoder().decode(PersistedConfig.self, from: data) {
            general = Array(config.general.prefix(Self.maxTools))
            var cats: [FileCategory: CategoryFavorites] = [:]
            for c in FileCategory.allCases {
                var cfg = config.categories[c.rawValue] ?? CategoryFavorites()
                cfg.tools = Array(cfg.tools.prefix(Self.maxTools))
                cats[c] = cfg
            }
            categories = cats
            return
        }
        // Migrate the legacy flat list → General; every category keeps useGeneral = on,
        // so existing users see no behaviour change. Write v2 so this runs only once.
        if let data = UserDefaults.standard.data(forKey: Self.keyV1),
           let saved = try? JSONDecoder().decode([FavoriteTool].self, from: data) {
            general = Array(saved.prefix(Self.maxTools))
            persist()
        }
    }
}
