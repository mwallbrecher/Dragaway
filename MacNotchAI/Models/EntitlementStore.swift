import SwiftUI
import AppKit
import Combine

/// Single source of truth for *which version of Dragaway the user is on* and what's
/// unlocked. Today only `.byok` is functional; `.freeHosted` and `.pro` are gated
/// behind `BackendConfig.isBackendLive` and render as "coming soon" until the proxy
/// + Paddle are wired (see `tasks/todo.md` → Phase 2).
@MainActor
final class EntitlementStore: ObservableObject {
    static let shared = EntitlementStore()

    /// The two "versions" the user picks between, plus the paid upgrade.
    enum Tier: String {
        case byok        // user's own API key — works today; later unlocks Pro for free
        case freeHosted  // our hosted backend, metered (10 free trial → daily token budget)
        case pro         // paid subscription, higher caps + better models — coming soon
    }

    private static let keyTier = "entitlement.tier"

    /// Persisted so the chosen version carries across launches. Defaults to `.byok`
    /// (the only functional path today).
    @Published var tier: Tier {
        didSet { UserDefaults.standard.set(tier.rawValue, forKey: Self.keyTier) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.keyTier)
        tier = Tier(rawValue: raw ?? "") ?? .byok
    }

    /// True when paid Pro features are unlocked. Hard-locked until the backend is
    /// live and a real entitlement check (via `/v1/usage`) exists.
    var isPremiumUnlocked: Bool {
        // TODO: when isBackendLive, resolve from the proxy's entitlement response.
        false
    }

    /// Whether the hosted "Dragaway Free" version can be selected yet.
    /// False today → onboarding shows it locked / "coming soon".
    var isHostedAvailable: Bool { BackendConfig.isBackendLive }

    /// Refresh entitlement + usage from the proxy. No-op until the backend exists.
    func refreshEntitlement() {
        // TODO: when BackendConfig.isBackendLive, GET /v1/usage and update tier.
    }

    /// Open the Paddle checkout if configured. No-op otherwise — callers gate the
    /// button on `BackendConfig.isBackendLive` and show "coming soon" instead.
    func startUpgrade() {
        guard let url = BackendConfig.paddleCheckoutURL else { return }
        NSWorkspace.shared.open(url)
    }
}
