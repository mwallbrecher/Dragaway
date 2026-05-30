import Foundation

/// Anonymous per-install identifier sent to the hosted proxy as `X-Device-Id` so
/// the server can meter free-tier usage. Stored in the Keychain (survives app
/// re-launches; cleared on full uninstall).
///
/// This is best-effort identity: a determined user can reset it for a fresh trial.
/// The Worker's global daily cap is the hard budget guard. Stronger identity
/// (App Attest + DeviceCheck) is the planned hardening step — see tasks/todo.md.
enum DeviceIdentity {
    private static let service = "com.aidrop.deviceid"

    /// The stable device id, generating + persisting one on first access.
    static var current: String {
        if let existing = KeychainManager.shared.load(service: service), !existing.isEmpty {
            return existing
        }
        let new = UUID().uuidString
        KeychainManager.shared.save(key: new, service: service)
        return new
    }
}
