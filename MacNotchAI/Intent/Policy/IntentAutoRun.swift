import Foundation

// THESIS (L5 handoff latch) — robust delivery of "run this action" from a whisper
// accept into the freshly opened session.
//
// Why a latch and not just a notification: the overlay window/view is immortal
// (drag-snapshot design), so `.onAppear` does NOT fire when a parked window is
// reused, and a fire-and-forget NotificationCenter.post is lost if the chips view
// isn't listening yet. The latch survives that race: the controller arms it BEFORE
// opening the session; the chips view consumes it whenever it next renders (driven
// by the reliable `windowShown` signal), take() clearing it so it runs exactly once.
// A short expiry means a stale arm (session never opened) can't fire into an
// unrelated later session.
@MainActor
final class IntentAutoRun {
    static let shared = IntentAutoRun()
    private init() {}

    private var action: AIAction?
    private var expiry: Date?

    func arm(_ action: AIAction, ttl: TimeInterval = 4) {
        self.action = action
        self.expiry = Date().addingTimeInterval(ttl)
    }

    /// Returns the armed action once, if still valid, then clears it.
    func take() -> AIAction? {
        defer { action = nil; expiry = nil }
        guard let action, let expiry, Date() < expiry else { return nil }
        return action
    }
}
