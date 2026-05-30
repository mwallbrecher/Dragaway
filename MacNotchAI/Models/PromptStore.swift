import SwiftUI
import Combine

/// Local persistence for the prompt section's two user-data tabs:
/// - **History**: typed free-text prompts that were actually run (auto-recorded,
///   most-recent first, capped + de-duplicated).
/// - **Custom**: user-curated prompts added via the `+` row or in Settings.
///
/// Both lists are plain `[String]` persisted as native UserDefaults string arrays
/// (no Codable needed). The store is the single source of truth for the History /
/// Custom tabs in `ChipsColumnView` and for the "Custom Prompts" Settings section.
@MainActor
final class PromptStore: ObservableObject {
    static let shared = PromptStore()

    private static let keyHistory = "prompt.history"
    private static let keyCustom  = "prompt.custom"

    /// Most-recent-first, de-duplicated, capped at `historyCap`.
    @Published private(set) var history: [String] = []
    /// User-curated prompts, in insertion order.
    @Published private(set) var customPrompts: [String] = []

    private let historyCap = 20

    private init() {
        let d = UserDefaults.standard
        history       = d.stringArray(forKey: Self.keyHistory) ?? []
        customPrompts = d.stringArray(forKey: Self.keyCustom)  ?? []
    }

    // MARK: - History

    /// Record a freshly-run typed prompt. Moves an existing duplicate to the top
    /// (case-insensitive) rather than adding a second copy, then trims to the cap.
    func recordHistory(_ raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        history.removeAll { $0.caseInsensitiveCompare(prompt) == .orderedSame }
        history.insert(prompt, at: 0)
        if history.count > historyCap { history.removeLast(history.count - historyCap) }
        UserDefaults.standard.set(history, forKey: Self.keyHistory)
    }

    func clearHistory() {
        history.removeAll()
        UserDefaults.standard.set(history, forKey: Self.keyHistory)
    }

    // MARK: - Custom

    /// Add a curated prompt. Ignores blanks and case-insensitive duplicates.
    func addCustom(_ raw: String) {
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty,
              !customPrompts.contains(where: { $0.caseInsensitiveCompare(prompt) == .orderedSame })
        else { return }
        customPrompts.append(prompt)
        UserDefaults.standard.set(customPrompts, forKey: Self.keyCustom)
    }

    func removeCustom(_ prompt: String) {
        customPrompts.removeAll { $0 == prompt }
        UserDefaults.standard.set(customPrompts, forKey: Self.keyCustom)
    }

    /// Index-based delete for SwiftUI `.onDelete` in Settings.
    func removeCustom(at offsets: IndexSet) {
        customPrompts.remove(atOffsets: offsets)
        UserDefaults.standard.set(customPrompts, forKey: Self.keyCustom)
    }
}
