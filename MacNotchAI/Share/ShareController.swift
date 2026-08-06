import AppKit
import Combine
import SwiftUI

/// Orchestrates exposing and importing a session. `docs/SHARE_ARCHITECTURE.md`.
///
/// THE PROMISE: nothing here runs, and nothing leaves the Mac, until the user performs the
/// explicit "Expose Session" action. There is no background upload, no pre-flight, no
/// telemetry on this path.
@MainActor
final class ShareController: ObservableObject {

    static let shared = ShareController()
    private init() {}

    enum Phase: Equatable {
        case idle
        case packing
        case uploading
        case exposed(code: String, expiresAt: Date, hasPassword: Bool)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// The file the panel describes — shown in the disclosure text so the user knows
    /// exactly what is about to leave the machine.
    @Published private(set) var pendingFileName: String = ""
    @Published private(set) var pendingSize: String = ""

    private var lastCode: String?

    // MARK: Expose

    /// Builds the bundle for the CURRENT session so the panel can name the file and size
    /// before anything is uploaded. Local only.
    func prepare(fileURL: URL, turns: [SessionTurn]) {
        pendingFileName = fileURL.lastPathComponent
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        pendingSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        phase = .idle
    }

    /// The one action that uploads. Everything before this stays on the Mac.
    func expose(fileURL: URL, turns: [SessionTurn], password: String?) {
        phase = .packing
        let hasPassword = !(password ?? "").isEmpty

        Task {
            do {
                let data = try Data(contentsOf: fileURL)
                guard data.count <= ShareBundle.maxFileBytes else {
                    phase = .failed(ShareClient.ShareError.tooLarge(ShareBundle.maxFileBytes)
                        .localizedDescription)
                    return
                }

                let bundle = ShareBundle(
                    fileName: fileURL.lastPathComponent,
                    fileData: data,
                    turns: turns.map { .init(actionRaw: $0.actionRaw, promptTitle: $0.promptTitle,
                                             resultText: $0.resultText, date: $0.date) },
                    exposedAt: Date())

                let sealed = try ShareCrypto.seal(bundle, password: password)
                phase = .uploading
                let created = try await ShareClient.create(sealed: sealed,
                                                           fileName: bundle.fileName,
                                                           hasPassword: hasPassword)
                lastCode = created.code
                phase = .exposed(code: created.code, expiresAt: created.expiresAt,
                                 hasPassword: hasPassword)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func revoke() {
        guard let code = lastCode else { return }
        Task {
            await ShareClient.revoke(code: code)
            lastCode = nil
            phase = .idle
        }
    }

    func reset() {
        phase = .idle
        lastCode = nil
    }

    // MARK: Import (recipient)

    enum ImportResult {
        case success(URL)
        case needsPassword
        case failure(String)
    }

    /// Downloads, decrypts, verifies, writes the file, and opens it as a NEW LOCAL SESSION.
    /// The recipient continues with their own provider and their own API key — this is a
    /// fork, not a synced session.
    ///
    /// The server is only acked AFTER the file is safely on disk, so a dropped connection
    /// can never destroy a share that never arrived (§3).
    func importShare(code: String, password: String?) async -> ImportResult {
        do {
            let fetched = try await ShareClient.fetch(code: code)

            if fetched.tier == .password, (password ?? "").isEmpty {
                return .needsPassword
            }

            let bundle = try ShareCrypto.open(payload: fetched.payload, tier: fetched.tier,
                                              key: fetched.key, salt: fetched.salt,
                                              password: password)

            let dest = uniqueDestination(for: bundle.fileName)
            try bundle.fileData.write(to: dest)

            // Replay the sender's history into a fresh local session. An unknown action
            // (older/newer app version) degrades to .freeform rather than dropping the turn —
            // the result text is the value, not the label.
            SessionHistoryStore.shared.beginSession(primary: dest)
            for turn in bundle.turns {
                SessionHistoryStore.shared.recordTurn(
                    primary: dest, additional: [],
                    action: AIAction(rawValue: turn.actionRaw) ?? .freeform,
                    prompt: turn.promptTitle,
                    result: turn.resultText)
            }

            await ShareClient.ack(code: code)   // only now may the server delete
            return .success(dest)
        } catch ShareCrypto.ShareCryptoError.wrongPassword {
            return .needsPassword
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Never overwrite an existing file — an import must not clobber the recipient's work.
    private func uniqueDestination(for name: String) -> URL {
        let dir = DropMaterializer.dropsDirectory()
        var candidate = dir.appendingPathComponent(name)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
