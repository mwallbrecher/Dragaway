import Foundation

/// Paste-later configuration for the hosted backend + payments.
///
/// Everything here is intentionally empty until the Cloudflare Worker proxy and
/// Paddle checkout are set up (see `tasks/todo.md` → Phase 2). While
/// `proxyBaseURL == nil` the whole app stays in pure BYOK mode: the "Dragaway Free"
/// version and the Pro upgrade render as *locked / coming soon* and NEVER attempt a
/// network call. The day the backend is live you only fill in the two URLs below —
/// the locked affordances enable themselves via `isBackendLive`.
enum BackendConfig {

    /// Base URL of the metering proxy (Cloudflare Worker), e.g. `https://api.aidrop.app`.
    // TODO: paste after backend setup. Keep `nil` to stay BYOK-only.
    static let proxyBaseURL = URL(string: "https://aidrop.aidrop.workers.dev")

    /// Paddle-hosted checkout URL opened by "Upgrade". Opened in the browser.
    // TODO: paste after payment setup.
    static let paddleCheckoutURL: URL? = nil

    /// App Attest key id, if pre-provisioned. Normally minted at runtime by the
    /// attestation manager; left here only as an explicit paste-later slot.
    // TODO: optional — paste after App Attest registration, else leave nil.
    static let appAttestKeyId: String? = nil

    /// True once the hosted proxy URL is filled in. Gates every hosted/Pro
    /// affordance in the UI — the single switch that turns the locked surfaces on.
    static var isBackendLive: Bool { proxyBaseURL != nil }
}
