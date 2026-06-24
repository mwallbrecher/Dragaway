import SwiftUI
import AppKit

// MARK: - Hotkey picker sheet

struct HotkeyPickerView: View {
    var onDismiss: () -> Void

    @State private var selectedMods:  NSEvent.ModifierFlags = HotkeyManager.shared.requiredModifiers
    @State private var requiresSpace: Bool                  = HotkeyManager.shared.requiresSpacebar
    @State private var radialMods:    NSEvent.ModifierFlags = HotkeyManager.shared.radialModifiers
    @State private var pillEnabled:   Bool = HotkeyManager.shared.pillEnabled
    @State private var radialEnabled: Bool = HotkeyManager.shared.radialEnabled
    @State private var showAIDrop:    Bool = HotkeyManager.shared.radialShowsAIDrop

    private var pillNone:   Bool { selectedMods.isEmpty && !requiresSpace }
    private var radialNone: Bool { radialMods.isEmpty }

    private var pillPreview: String {
        if !pillEnabled { return "Pill: off." }
        return pillNone ? "Pill: appears by default (no key)."
                        : "Pill: hold \(HotkeyManager.displayString(for: selectedMods, space: requiresSpace))."
    }
    private var radialPreview: String {
        if !radialEnabled { return "Wheel: off." }
        return radialNone ? "Wheel: appears by default (no key)."
                          : "Wheel: hold \(HotkeyManager.displayString(for: radialMods))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ──────────────────────────────────────────────────────────
            VStack(alignment: .center, spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.accentColor)

                Text("Drag Hotkeys")
                    .font(.title2.bold())

                Text("Turn each drag mode on or off, and give it an optional key to\nhold at the start of a drag. No key = the mode appears by default;\nwith both on and keyless, the pill and the wheel both appear.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 28)
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 18)

            // ── Section 1: notch pill ────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Notch pill (AI & utilities)").font(.headline)
                    Spacer()
                    Toggle("", isOn: $pillEnabled).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ModifierToggle(symbol: "⌃", label: "Control",
                                       flag: .control, selection: $selectedMods)
                        ModifierToggle(symbol: "⌥", label: "Option",
                                       flag: .option,  selection: $selectedMods)
                        ModifierToggle(symbol: "⇧", label: "Shift",
                                       flag: .shift,   selection: $selectedMods)
                        ModifierToggle(symbol: "⌘", label: "Command",
                                       flag: .command, selection: $selectedMods)
                    }
                    SpacebarToggle(isOn: $requiresSpace)
                }
                .disabled(!pillEnabled)
                .opacity(pillEnabled ? 1 : 0.4)
            }
            .padding(.horizontal, 28)

            Divider()
                .padding(.vertical, 16)

            // ── Section 2: radial launcher ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Radial launcher (open in a favorite app)").font(.headline)
                    Spacer()
                    Toggle("", isOn: $radialEnabled).labelsHidden()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ModifierToggle(symbol: "⌃", label: "Control",
                                       flag: .control, selection: $radialMods)
                        ModifierToggle(symbol: "⌥", label: "Option",
                                       flag: .option,  selection: $radialMods)
                        ModifierToggle(symbol: "⇧", label: "Shift",
                                       flag: .shift,   selection: $radialMods)
                        ModifierToggle(symbol: "⌘", label: "Command",
                                       flag: .command, selection: $radialMods)
                    }
                    Toggle("Show AI Drop in Launcher", isOn: $showAIDrop)
                }
                .disabled(!radialEnabled)
                .opacity(radialEnabled ? 1 : 0.4)
            }
            .padding(.horizontal, 28)

            // ── Combined preview ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 4) {
                Label(pillPreview, systemImage: "rectangle.portrait.topthird.inset.filled")
                    .foregroundColor(pillEnabled ? .accentColor : .secondary)
                Label(radialPreview, systemImage: "circle.dashed")
                    .foregroundColor(radialEnabled ? .accentColor : .secondary)
            }
            .font(.callout)
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .animation(.easeInOut(duration: 0.15), value: pillEnabled)
            .animation(.easeInOut(duration: 0.15), value: radialEnabled)

            Spacer(minLength: 22)

            // ── Action buttons ───────────────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Clear Keys") {
                    selectedMods  = []
                    requiresSpace = false
                    radialMods    = []
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("Save") {
                    HotkeyManager.shared.pillEnabled       = pillEnabled
                    HotkeyManager.shared.radialEnabled     = radialEnabled
                    HotkeyManager.shared.requiredModifiers = selectedMods
                    HotkeyManager.shared.requiresSpacebar  = requiresSpace
                    HotkeyManager.shared.radialModifiers   = radialMods
                    HotkeyManager.shared.radialShowsAIDrop = showAIDrop
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(width: 420)
    }
}

// MARK: - Modifier key toggle (⌃ ⌥ ⇧ ⌘)

private struct ModifierToggle: View {
    let symbol: String
    let label:  String
    let flag:   NSEvent.ModifierFlags
    @Binding var selection: NSEvent.ModifierFlags

    private var isOn: Bool { selection.contains(flag) }

    var body: some View {
        Button {
            var updated = selection
            if isOn { updated.remove(flag) } else { updated.insert(flag) }
            selection = updated
        } label: {
            VStack(spacing: 5) {
                Text(symbol)
                    .font(.system(size: 20, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.primary)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}

// MARK: - Spacebar toggle

private struct SpacebarToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                Text("␣")
                    .font(.system(size: 22, weight: .medium))
                Text("Space Bar")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .foregroundColor(isOn ? .accentColor : .primary)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? Color.accentColor : Color.primary)
        .background(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isOn)
    }
}
