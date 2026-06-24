import AppKit
import CoreGraphics

/// Stores and checks the optional hotkey that gates pill appearance.
///
/// When a hotkey is set the pill only appears when the user holds the required
/// combination while starting a drag.  Supports modifier keys (⌃ ⌥ ⇧ ⌘) and
/// the spacebar, individually or combined.  When nothing is configured every
/// drag shows the pill normally.
final class HotkeyManager {
    static let shared = HotkeyManager()
    private init() {}

    private let modifiersKey  = "hotkeyModifierFlags"
    private let spacebarKey   = "hotkeyRequiresSpacebar"
    private let radialModifiersKey  = "radialLauncherModifierFlags"
    private let pillEnabledKey       = "pillModeEnabled"
    private let radialEnabledKey     = "radialModeEnabled"
    private let radialShowsAIDropKey = "radialShowsAIDrop"

    // MARK: - Storage

    /// Required modifier flags.  Empty set = no modifier required.
    var requiredModifiers: NSEvent.ModifierFlags {
        get {
            let raw = UInt(bitPattern: UserDefaults.standard.integer(forKey: modifiersKey))
            return NSEvent.ModifierFlags(rawValue: raw)
        }
        set {
            UserDefaults.standard.set(Int(bitPattern: newValue.rawValue), forKey: modifiersKey)
        }
    }

    /// Whether spacebar must also be held during the drag.
    var requiresSpacebar: Bool {
        get { UserDefaults.standard.bool(forKey: spacebarKey) }
        set { UserDefaults.standard.set(newValue, forKey: spacebarKey) }
    }

    /// True when at least one key constraint is configured.
    var isEnabled: Bool { !requiredModifiers.isEmpty || requiresSpacebar }

    // MARK: - Mode master switches

    /// Whether the notch pill mode is active at all. Off = the pill never appears.
    var pillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: pillEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: pillEnabledKey) }
    }

    /// Whether the radial launcher mode is active at all. Off = the wheel never appears.
    var radialEnabled: Bool {
        get { UserDefaults.standard.object(forKey: radialEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: radialEnabledKey) }
    }

    /// Whether the radial wheel includes an "AI Drop" slot that routes the file into
    /// the pill/chips flow instead of an external app.
    var radialShowsAIDrop: Bool {
        get { UserDefaults.standard.object(forKey: radialShowsAIDropKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: radialShowsAIDropKey) }
    }

    // MARK: - Radial launcher (second drag mode)

    /// Modifier(s) that arm the radial launcher. Defaults to ⌃ Control. Empty set =
    /// "no key" → the radial launcher becomes a default mode (see the drag router).
    var radialModifiers: NSEvent.ModifierFlags {
        get {
            guard let raw = UserDefaults.standard.object(forKey: radialModifiersKey) as? Int else {
                return .control
            }
            return NSEvent.ModifierFlags(rawValue: UInt(bitPattern: raw))
        }
        set { UserDefaults.standard.set(Int(bitPattern: newValue.rawValue), forKey: radialModifiersKey) }
    }

    var radialDisplayString: String { Self.displayString(for: radialModifiers) }

    /// True when the radial launcher's modifier(s) are non-empty and held right now.
    /// (Empty = "no key", which is handled as a default mode by the drag router.)
    func radialModifiersHeld() -> Bool {
        guard !radialModifiers.isEmpty else { return false }
        let live = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return live.contains(radialModifiers)
    }

    /// True when the pill gate's modifier(s)/spacebar are configured and held right now.
    func pillHotkeyHeld() -> Bool { isEnabled && isHotkeyHeld() }

    // MARK: - Display

    var displayString: String {
        Self.displayString(for: requiredModifiers, space: requiresSpacebar)
    }

    static func displayString(for flags: NSEvent.ModifierFlags, space: Bool = false) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        if space                    { parts.append("Space") }
        return parts.isEmpty ? "None" : parts.joined(separator: " ")
    }

    // MARK: - Runtime check

    /// Returns true when the hotkey constraint is satisfied.
    ///
    /// If nothing is configured this is always true (pill works normally).
    /// Modifier state is read from `NSEvent.modifierFlags` (live system-wide).
    /// Spacebar state is polled via `CGEventSource.keyState` (no permissions needed).
    func isHotkeyHeld() -> Bool {
        guard isEnabled else { return true }

        let modsOK: Bool = {
            guard !requiredModifiers.isEmpty else { return true }
            let live = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return live.contains(requiredModifiers)
        }()

        // CGKeyCode 49 = kVK_Space (spacebar) — physical HID state, no entitlement needed
        let spaceOK: Bool = !requiresSpacebar ||
            CGEventSource.keyState(.hidSystemState, key: CGKeyCode(49))

        return modsOK && spaceOK
    }

    // MARK: - Mutation

    func clear() {
        requiredModifiers = []
        requiresSpacebar  = false
    }
}
