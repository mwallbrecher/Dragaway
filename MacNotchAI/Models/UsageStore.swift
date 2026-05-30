import SwiftUI
import Combine

/// Decoded usage block returned by the proxy (`/v1/complete` and `/v1/usage`).
struct HostedUsage: Decodable {
    let tier: String
    let inTrial: Bool
    let trialRemaining: Int
    let dailyRemaining: Int
    let remaining: Int
    let resetAt: String?
}

/// Client-side mirror of the hosted free-tier usage. The server is the source of
/// truth; this exists so the menu can show "X of N free left" instantly without a
/// round-trip. Updated from every `/v1/complete` response and `refresh()`.
@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    private static let keyRemaining = "usage.remaining"
    private static let keyInTrial   = "usage.inTrial"

    /// Interactions remaining (trial count while in trial, else today's daily count).
    @Published var remaining: Int?
    /// True while the device is still inside its one-time trial allowance.
    @Published var inTrial: Bool = true
    /// Next reset (ISO-8601, UTC) for the daily cap. Nil while in trial.
    @Published var resetAt: String?

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyRemaining) != nil {
            remaining = d.integer(forKey: Self.keyRemaining)
        }
        inTrial = d.object(forKey: Self.keyInTrial) as? Bool ?? true
    }

    /// Apply a fresh usage snapshot from the proxy and persist the mirror.
    func apply(_ usage: HostedUsage) {
        remaining = usage.remaining
        inTrial   = usage.inTrial
        resetAt   = usage.resetAt
        let d = UserDefaults.standard
        d.set(usage.remaining, forKey: Self.keyRemaining)
        d.set(usage.inTrial,   forKey: Self.keyInTrial)
    }

    /// Short label for the menu bar, e.g. "8 of 10 free today" / "27 free left".
    var menuLabel: String? {
        guard let remaining else { return nil }
        return inTrial ? "\(remaining) free left" : "\(remaining) free today"
    }

    /// Fetch current usage without consuming quota. No-op until the backend is live.
    func refresh() async {
        guard let base = BackendConfig.proxyBaseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("v1/usage"))
        req.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(UsageOnly.self, from: data),
              let usage = decoded.usage else { return }
        apply(usage)
    }

    private struct UsageOnly: Decodable { let usage: HostedUsage? }
}
