import Foundation
import Combine

// MARK: - Session history
//
// Remembers the last `maxSessions` sessions — the file(s) dropped plus the full
// AI conversation (every action/result turn). Surfaced as the "Recent Sessions"
// submenu in the menu-bar dropdown; clicking a row reopens the session.
//
// A "session" is one DROP. OverlayViewModel.setChips() calls beginSession() on
// every fresh drop, which arms a pending id. The record is only PERSISTED on the
// first recordTurn(), so a file that was dropped but never run never clutters the
// list. Adding files / running more actions within the same drop append to the
// same record.
//
// Persisted as JSON in Application Support (conversation text is far too large for
// UserDefaults). All access is @MainActor — the store is mutated from the overlay
// run-loop and read by the menu builder, both on the main thread.

/// One AI turn: the action that ran and the text it produced.
struct SessionTurn: Codable, Hashable {
    /// `AIAction` rawValue, so the action can be restored on reopen.
    let actionRaw: String
    /// Human-facing label: the typed question for a freeform query, otherwise the
    /// action's title. Shown if we ever surface a transcript.
    let promptTitle: String
    let resultText: String
    let date: Date
}

/// One session: the file(s) used and the conversation that happened over them.
struct SessionRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var primaryPath: String
    var additionalPaths: [String]
    var turns: [SessionTurn]
    var updatedAt: Date

    var fileURL: URL { URL(fileURLWithPath: primaryPath) }
    var fileName: String { (primaryPath as NSString).lastPathComponent }

    /// The most recent turn — what gets shown when the session is reopened.
    var lastTurn: SessionTurn? { turns.last }
    /// The turn before the last, restored into the back-arrow cache (if any).
    var previousTurn: SessionTurn? { turns.count >= 2 ? turns[turns.count - 2] : nil }
}

@MainActor
final class SessionHistoryStore: ObservableObject {
    static let shared = SessionHistoryStore()

    /// Newest-first. Capped at `maxSessions`.
    @Published private(set) var sessions: [SessionRecord] = []

    private let maxSessions = 10

    /// Identity of the drop currently in progress. Armed by beginSession(); the
    /// record itself isn't created until the first turn is recorded.
    private var pendingSessionID: UUID?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let dir = base.appendingPathComponent(bundle, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session_history.json")
    }()

    private init() { load() }

    // MARK: - Lifecycle

    /// Begin a new session for a fresh drop. Arms a pending id; the record is
    /// created lazily on the first recordTurn() so unused drops don't persist.
    func beginSession(primary: URL) {
        pendingSessionID = UUID()
    }

    /// Continue an existing session (e.g. reopened from the menu) so any further
    /// turns append to it instead of spawning a duplicate record.
    func resumeSession(id: UUID) {
        pendingSessionID = sessions.contains { $0.id == id } ? id : nil
    }

    /// Append a turn to the current session, creating the record if this is the
    /// first turn of the drop. Moves the session to the front, trims, and saves.
    func recordTurn(primary: URL, additional: [URL],
                    action: AIAction, prompt: String?, result: String) {
        let id = pendingSessionID ?? UUID()
        pendingSessionID = id

        let turn = SessionTurn(
            actionRaw: action.rawValue,
            promptTitle: (prompt?.isEmpty == false) ? prompt! : action.rawValue,
            resultText: result,
            date: Date())

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            var rec = sessions.remove(at: idx)
            rec.primaryPath = primary.path
            rec.additionalPaths = additional.map(\.path)
            rec.turns.append(turn)
            rec.updatedAt = turn.date
            sessions.insert(rec, at: 0)
        } else {
            let rec = SessionRecord(
                id: id,
                primaryPath: primary.path,
                additionalPaths: additional.map(\.path),
                turns: [turn],
                updatedAt: turn.date)
            sessions.insert(rec, at: 0)
        }

        if sessions.count > maxSessions { sessions.removeLast(sessions.count - maxSessions) }
        save()
    }

    /// Keep the active record's paths fresh after a rename/move (best-effort).
    func remapPath(from old: URL, to new: URL) {
        guard let id = pendingSessionID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var rec = sessions[idx]
        if rec.primaryPath == old.path { rec.primaryPath = new.path }
        rec.additionalPaths = rec.additionalPaths.map { $0 == old.path ? new.path : $0 }
        sessions[idx] = rec
        save()
    }

    // MARK: - Mutation

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        if pendingSessionID == id { pendingSessionID = nil }
        save()
    }

    func clear() {
        sessions.removeAll()
        pendingSessionID = nil
        save()
    }

    func record(for id: UUID) -> SessionRecord? { sessions.first { $0.id == id } }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let decoded = try? JSONDecoder().decode([SessionRecord].self, from: data) {
            sessions = Array(decoded.prefix(maxSessions))
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
