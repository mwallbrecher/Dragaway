import Foundation

/// Local, private "frecency" (frequency + recency) of AI actions per file category.
/// Learns which actions the user actually runs so the suggested chips can lead with
/// them. No network, no AI, no telemetry — just decayed counts in UserDefaults.
///
/// UserDefaults is thread-safe, so every method is nonisolated (reads happen during
/// SwiftUI body renders + the off-main smart-reorder; the single write is on the main
/// actor when an action runs).
enum ActionFrecency {
    private static let storeKey = "actionFrecency.v1"
    private static let halfLifeDays = 30.0

    private struct Entry: Codable { var score: Double; var last: TimeInterval }

    /// Record that the user ran `action` on a file of `category`.
    static func record(_ action: AIAction, category: FileCategory?) {
        guard action != .freeform else { return }
        var map = load()
        let k = key(action, category)
        var e = map[k] ?? Entry(score: 0, last: 0)
        e.score += 1
        e.last = Date().timeIntervalSince1970
        map[k] = e
        if map.count > 200 {                                   // bound growth
            let keep = map.sorted { $0.value.score > $1.value.score }.prefix(150)
            map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        save(map)
    }

    /// Top learned actions for `category`, most-frecent first. Recency-decayed (30-day
    /// half-life) so stale favourites fade; a single old try is filtered out.
    static func topActions(for category: FileCategory?, limit: Int = 2) -> [AIAction] {
        let prefix = keyPrefix(category)
        let now = Date().timeIntervalSince1970
        return load()
            .filter { $0.key.hasPrefix(prefix) }
            .compactMap { (k, e) -> (AIAction, Double)? in
                guard let action = AIAction(rawValue: String(k.dropFirst(prefix.count)))
                else { return nil }
                let ageDays = max(0, (now - e.last) / 86_400)
                let decayed = e.score * pow(0.5, ageDays / halfLifeDays)
                return decayed >= 0.75 ? (action, decayed) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    // MARK: - Storage

    private static func keyPrefix(_ c: FileCategory?) -> String { "\(c?.rawValue ?? "general")|" }
    private static func key(_ a: AIAction, _ c: FileCategory?) -> String { keyPrefix(c) + a.rawValue }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return map
    }
    private static func save(_ map: [String: Entry]) {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
