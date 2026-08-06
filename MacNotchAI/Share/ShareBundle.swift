import Foundation

/// What actually travels when a session is exposed. See `docs/SHARE_ARCHITECTURE.md` §1.
///
/// FORK SEMANTICS: the recipient gets a *copy*. They continue with their own provider and
/// their own API key, in their own local session. Nothing syncs back to the sender.
struct ShareBundle: Codable {

    /// Bundle format version — lets a future app refuse or migrate an unknown payload
    /// instead of failing obscurely.
    var v = 1

    /// The primary file: name + bytes. Only the primary file travels in v1 (§8).
    let fileName: String
    let fileData: Data

    /// The session's AI history, in order. Mirrors `SessionTurn` but is decoupled on
    /// purpose: the wire format must not break when the local model changes.
    let turns: [Turn]

    /// When the sender exposed it (informational; expiry is enforced server-side).
    let exposedAt: Date

    struct Turn: Codable {
        let actionRaw: String
        let promptTitle: String
        let resultText: String
        let date: Date
    }

    /// Human-readable size of the payload, for the disclosure UI.
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileData.count), countStyle: .file)
    }

    /// v1 ceiling. Kept in sync with the server's own limit — the client checks first so
    /// the user gets a clear message instead of a rejected upload.
    static let maxFileBytes = 25 * 1024 * 1024
}
