import Foundation
import CryptoKit

/// Encryption for exposed sessions. See `docs/SHARE_ARCHITECTURE.md` §2.
///
/// TWO HONEST TIERS — the difference is *where the key lives*, and the UI says which is active:
///
///   • codeOnly  — random 256-bit key, uploaded alongside the ciphertext. The server
///                 releases it on the correct code. Protects against a storage breach and
///                 network interception; the server itself COULD decrypt. Never call this
///                 end-to-end encrypted.
///   • password  — key derived from the user's password. The key never leaves the Mac and
///                 is never uploaded. Genuine end-to-end encryption.
///
/// Why the 6-digit code is never the key: it carries ~20 bits. A KDF stretches entropy, it
/// does not create it, so a code-derived key would fall to an offline brute force in seconds.
/// The code's security comes from server-side attempt limits (§2), not from cryptography.
enum ShareCrypto {

    enum Tier: String, Codable {
        case codeOnly
        case password
    }

    struct Sealed {
        /// Nonce ‖ ciphertext ‖ GCM tag — what gets uploaded.
        let payload: Data
        /// Only for `.codeOnly`: the key the server must store and hand back.
        /// nil for `.password` — nothing key-related is uploaded in that tier.
        let uploadKey: Data?
        /// Only for `.password`: the KDF salt, stored server-side (public by design).
        let salt: Data?
        let tier: Tier
    }

    enum ShareCryptoError: LocalizedError {
        case badPayload
        case wrongPassword
        case missingKeyMaterial

        var errorDescription: String? {
            switch self {
            case .badPayload:         return "The shared data is damaged or incomplete."
            case .wrongPassword:      return "Wrong password."
            case .missingKeyMaterial: return "The share is missing its key material."
            }
        }
    }

    // MARK: Seal

    static func seal(_ bundle: ShareBundle, password: String?) throws -> Sealed {
        let plaintext = try JSONEncoder().encode(bundle)

        if let password, !password.isEmpty {
            let salt = randomBytes(16)
            let key = derive(password: password, salt: salt)
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else { throw ShareCryptoError.badPayload }
            return Sealed(payload: combined, uploadKey: nil, salt: salt, tier: .password)
        }

        let keyData = randomBytes(32)
        let key = SymmetricKey(data: keyData)
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw ShareCryptoError.badPayload }
        return Sealed(payload: combined, uploadKey: keyData, salt: nil, tier: .codeOnly)
    }

    // MARK: Open

    /// Decrypts and verifies. The GCM tag is checked by `AES.GCM.open`, so a corrupted or
    /// tampered payload throws instead of yielding garbage — this is what makes it safe to
    /// only ack (and let the server delete) after a successful open.
    static func open(payload: Data, tier: Tier, key: Data?, salt: Data?,
                     password: String?) throws -> ShareBundle {
        let symmetric: SymmetricKey
        switch tier {
        case .codeOnly:
            guard let key else { throw ShareCryptoError.missingKeyMaterial }
            symmetric = SymmetricKey(data: key)
        case .password:
            guard let salt else { throw ShareCryptoError.missingKeyMaterial }
            guard let password, !password.isEmpty else { throw ShareCryptoError.wrongPassword }
            symmetric = derive(password: password, salt: salt)
        }

        guard let box = try? AES.GCM.SealedBox(combined: payload) else {
            throw ShareCryptoError.badPayload
        }
        guard let plaintext = try? AES.GCM.open(box, using: symmetric) else {
            // An auth-tag failure in the password tier almost always means a wrong password;
            // in the code tier it means the payload is damaged.
            throw tier == .password ? ShareCryptoError.wrongPassword : ShareCryptoError.badPayload
        }
        guard let bundle = try? JSONDecoder().decode(ShareBundle.self, from: plaintext) else {
            throw ShareCryptoError.badPayload
        }
        return bundle
    }

    // MARK: Key derivation
    //
    // HKDF-SHA256 with a high iteration count is NOT a memory-hard KDF — Argon2id would be
    // the textbook choice, but it is not in CryptoKit and this project ships no third-party
    // dependencies (see AGENTS.md). PBKDF2-style stretching via repeated HKDF gives a real
    // but bounded cost increase against offline guessing. The password tier's strength
    // therefore rests primarily on the password itself; the UI asks for a strong one.
    // TODO: switch to Argon2id if a vetted, dependency-free implementation lands.

    private static let iterations = 100_000

    private static func derive(password: String, salt: Data) -> SymmetricKey {
        var material = Data(password.utf8)
        for _ in 0..<iterations {
            material = Data(HMAC<SHA256>.authenticationCode(for: material, using: SymmetricKey(data: salt)))
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material),
                                         salt: salt,
                                         info: Data("dragaway.share.v1".utf8),
                                         outputByteCount: 32)
        return key
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
