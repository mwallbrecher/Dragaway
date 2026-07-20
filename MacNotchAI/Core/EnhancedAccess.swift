import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Explicit, default-off gate for the small set of features that synthesize input
/// in another application. Core Dragaway behavior never depends on this permission.
@MainActor
enum EnhancedAccess {
    static let enabledKey = "enhancedAccessibilityEnabled"

    /// The user's intent is separate from macOS authorization: permission can be
    /// denied or revoked externally while this preference remains enabled.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var isAuthorized: Bool { CGPreflightPostEventAccess() }
    static var canPostEvents: Bool { isEnabled && isAuthorized }

    /// Ask only after an explicit OFF → ON gesture in Settings.
    @discardableResult
    static func requestAuthorization() -> Bool {
        CGRequestPostEventAccess()
    }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Post one Command-V chord. The gate is deliberately re-checked immediately
    /// before event creation so revoking access falls back to copy-only behavior.
    @discardableResult
    static func postPasteShortcut() -> Bool {
        guard canPostEvents,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
              ) else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
