import Foundation

/// Talks to the share Worker. Protocol: `docs/SHARE_ARCHITECTURE.md` §4.
///
/// The server only ever sees ciphertext and opaque metadata — that is what makes it
/// replaceable. `BackendConfig.shareBaseURL` points anywhere, so a company can run its
/// own instance and change one setting.
enum ShareClient {

    struct Created {
        let code: String
        let expiresAt: Date
    }

    struct Fetched {
        let payload: Data
        let tier: ShareCrypto.Tier
        let key: Data?
        let salt: Data?
    }

    enum ShareError: LocalizedError {
        case notConfigured
        case tooLarge(Int)
        case notFound
        case locked
        case rateLimited
        case expired
        case server(String)
        case offline

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Sharing is not configured in this build."
            case .tooLarge(let n):
                let limit = ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
                return "This file is too large to share (limit \(limit))."
            case .notFound: return "No session found for that code."
            case .locked:   return "Too many wrong attempts — this code is locked."
            case .rateLimited:
                return "You've shared a lot in the last hour. Try again shortly."
            case .expired:  return "That share has expired."
            case .offline:  return "No connection to the sharing service."
            case .server(let m): return m
            }
        }
    }

    // MARK: Expose

    static func create(sealed: ShareCrypto.Sealed, fileName: String,
                       hasPassword: Bool) async throws -> Created {
        guard let base = BackendConfig.shareBaseURL else { throw ShareError.notConfigured }
        guard sealed.payload.count <= ShareBundle.maxFileBytes else {
            throw ShareError.tooLarge(ShareBundle.maxFileBytes)
        }

        var body: [String: Any] = [
            "payload": sealed.payload.base64EncodedString(),
            "tier": sealed.tier.rawValue,
            "has_password": hasPassword,
            // Shown to the recipient BEFORE they decrypt, so they know what they are accepting.
            "file_name": fileName,
        ]
        if let key = sealed.uploadKey { body["key"] = key.base64EncodedString() }
        if let salt = sealed.salt { body["salt"] = salt.base64EncodedString() }

        let json = try await post(base.appendingPathComponent("v1/share"), body: body)
        guard let code = json["code"] as? String else { throw ShareError.server("Malformed response.") }
        let expires = (json["expires_at"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) }
            ?? Date().addingTimeInterval(24 * 3600)
        return Created(code: code, expiresAt: expires)
    }

    // MARK: Redeem

    static func fetch(code: String) async throws -> Fetched {
        guard let base = BackendConfig.shareBaseURL else { throw ShareError.notConfigured }
        let url = base.appendingPathComponent("v1/share/\(code)")
        let json = try await get(url)

        guard let b64 = json["payload"] as? String, let payload = Data(base64Encoded: b64) else {
            throw ShareError.server("Malformed response.")
        }
        let tier = ShareCrypto.Tier(rawValue: json["tier"] as? String ?? "") ?? .codeOnly
        let key = (json["key"] as? String).flatMap { Data(base64Encoded: $0) }
        let salt = (json["salt"] as? String).flatMap { Data(base64Encoded: $0) }
        return Fetched(payload: payload, tier: tier, key: key, salt: salt)
    }

    /// Confirms a successful decrypt+write so the server can delete. Deliberately NOT
    /// triggered by the download itself: a dropped connection or a crash must not destroy
    /// the share before the recipient actually has it (§3).
    static func ack(code: String) async {
        guard let base = BackendConfig.shareBaseURL else { return }
        _ = try? await post(base.appendingPathComponent("v1/share/\(code)/ack"), body: [:])
    }

    /// Sender-initiated revoke.
    static func revoke(code: String) async {
        guard let base = BackendConfig.shareBaseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("v1/share/\(code)"))
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: Transport

    private static func post(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 60
        return try await send(req)
    }

    private static func get(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        req.timeoutInterval = 60
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ShareError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        switch status {
        case 200...299: return json
        case 404:       throw ShareError.notFound
        case 410:       throw ShareError.expired
        case 423:       throw ShareError.locked
        case 429:       throw ShareError.rateLimited
        default:
            throw ShareError.server(json["error"] as? String ?? "Sharing failed (\(status)).")
        }
    }
}
