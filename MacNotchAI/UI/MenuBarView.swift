import SwiftUI

struct MenuBarView: View {

    @AppStorage("disabledUntil") private var disabledUntil: Double = 0
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var usage = UsageStore.shared

    private var isDisabled: Bool {
        disabledUntil > Date().timeIntervalSince1970
    }

    /// Which "version" the user is on, shown under the title. Reflects the
    /// persisted tier; today this is "Your own key" unless the backend is live.
    private var versionLabel: String {
        switch EntitlementStore.shared.tier {
        case .byok:       return "Your own key"
        case .freeHosted: return "AI Drop Free"
        case .pro:        return "AI Drop Pro"
        }
    }

    /// Smart remaining-time label handles minutes, hours, and "until re-enabled".
    private var pausedLabel: String {
        let secs = disabledUntil - Date().timeIntervalSince1970
        guard secs > 0 else { return "" }
        // Sentinel for "Until Re-Enabled" — more than one year away
        if secs > 365 * 24 * 3600 { return "Paused · until re-enabled" }
        if secs > 3600 { return "Paused · \(Int(secs / 3600))h left" }
        return "Paused · \(max(1, Int(ceil(secs / 60)))) min left"
    }

    var body: some View {
        VStack(spacing: 4) {

            // ── App title ──────────────────────────────────────────────────────
            VStack(spacing: 2) {
                Text("AI Drop")
                    .font(.headline)
                if isDisabled {
                    Text(pausedLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(versionLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if EntitlementStore.shared.tier == .freeHosted,
                       let usageLabel = usage.menuLabel {
                        Text(usageLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.bottom, 4)

            Divider()

            // ── Upgrade (locked until the hosted backend is live) ───────────────
            if BackendConfig.isBackendLive {
                Button("Upgrade to Pro") {
                    EntitlementStore.shared.startUpgrade()
                }
            } else {
                Button("Upgrade to Pro — coming soon") { }
                    .disabled(true)
            }

            Divider()

            // ── Provider / settings ────────────────────────────────────────────
            Button("Change Language Model") {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }

            Button("Settings…") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")

            Divider()

            // ── Disable / re-enable ────────────────────────────────────────────
            if isDisabled {
                Button("Re-enable Now") {
                    disabledUntil = 0
                }
            } else {
                Menu("Disable for…") {
                    // ── Timed presets ──────────────────────────────────────────
                    Button("5 minutes")  { disableFor(5)  }
                    Button("15 minutes") { disableFor(15) }
                    Button("30 minutes") { disableFor(30) }
                    Button("1 hour")     { disableFor(60) }

                    Divider()

                    // ── Session / day options ──────────────────────────────────
                    Button("For today") {
                        // Disable until midnight tonight (start of tomorrow)
                        let midnight = Calendar.current.date(
                            byAdding: .day, value: 1,
                            to: Calendar.current.startOfDay(for: Date())
                        ) ?? Date().addingTimeInterval(24 * 3600)
                        disabledUntil = midnight.timeIntervalSince1970
                    }

                    Button("Until Re-Enabled") {
                        // Sentinel: 10 years from now — isPillDisabled stays true
                        // until the user explicitly taps "Re-enable Now".
                        disabledUntil = Date().addingTimeInterval(10 * 365 * 24 * 3600)
                            .timeIntervalSince1970
                    }

                    Divider()

                    // ── Custom amount ──────────────────────────────────────────
                    Button("Custom…") {
                        NotificationCenter.default.post(name: .showCustomDisable, object: nil)
                    }
                }
            }

            // Hotkey button — morphs to show the active key when configured
            Button(HotkeyManager.shared.isEnabled
                    ? "Hotkey: \(HotkeyManager.shared.displayString)…"
                    : "Add Hotkey…") {
                NotificationCenter.default.post(name: .showHotkeyPicker, object: nil)
            }

            Divider()

            // ── Quit ───────────────────────────────────────────────────────────
            Button("Quit AI Drop") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(minWidth: 185)
    }

    // MARK: - Helpers

    private func disableFor(_ minutes: Int) {
        disabledUntil = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
    }
}
