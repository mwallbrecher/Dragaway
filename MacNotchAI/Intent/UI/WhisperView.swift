import AppKit
import SwiftUI

// THESIS (L5) — the whisper surface: a thesis-owned, non-activating panel just
// below the notch. Deliberately NOT the main overlay window / stage machine:
// zero churn on main-owned UI, and the research layer stays visibly separate.
// (The main pill needs drag-snapshot immortality; this panel receives no drops,
// so it can be created and torn down freely.)
//
// Two contents, one surface — the two exposure channels of ARCHITECTURE §7:
//   · .suggestion — the PASSIVE whisper (gated by θ/policy)
//   · .ticker     — the SUMMONED top-3 view (no gate; solicited can't annoy)

@MainActor
final class WhisperWindow: NSPanel {

    init(contentSize: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: contentSize),
                   styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Never steal focus — the user's keyboard stays in their app; accept rides
    /// a Carbon hotkey, dismiss is a click or the auto-fade.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Center below the notch, mirroring the main pill's anchor (notch bottom ≈ 37pt).
    func place(size: CGSize) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.height - 37 - size.height
        setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }
}

// MARK: - Content model

enum WhisperContent {
    case suggestion(IntentSuggestion)
    case ticker([TickerRow])
}

struct TickerRow: Identifiable {
    let id = UUID()
    let intentClass: IntentClass
    let probability: Double
    /// One-line "why": the strongest evidence contributions, humanised.
    let evidenceLine: String
    /// Only translation rows are actionable in M3.
    let suggestion: IntentSuggestion?
}

// MARK: - Views

struct WhisperSuggestionView: View {
    let suggestion: IntentSuggestion
    let onAccept: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            Text(suggestion.phrase)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button(action: onAccept) {
                HStack(spacing: 5) {
                    Text("Translate")
                        .font(.system(size: 12, weight: .semibold))
                    Text("⌥⏎")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.18)))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.accentColor.opacity(0.85)))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(
            Capsule().fill(Color.black.opacity(0.92))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
        .onHover(perform: onHover)
    }
}

struct WhisperTickerView: View {
    let rows: [TickerRow]
    let onAccept: (IntentSuggestion) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current intent estimates")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Text(label(for: row.intentClass))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 108, alignment: .leading)

                    // Honest calibrated confidence — a bar, not a verdict.
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12))
                            Capsule().fill(Color.accentColor.opacity(0.85))
                                .frame(width: max(3, geo.size.width * row.probability))
                        }
                    }
                    .frame(height: 6)

                    Text(String(format: "%.0f%%", row.probability * 100))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 34, alignment: .trailing)

                    if let s = row.suggestion {
                        Button("Go") { onAccept(s) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                    } else {
                        Text("—")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                            .frame(width: 26)
                    }
                }
                Text(row.evidenceLine)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        )
    }

    private func label(for c: IntentClass) -> String {
        switch c {
        case .translation:   return "Translation"
        case .comprehension: return "Comprehension"
        case .discovery:     return "Discovery"
        }
    }
}
