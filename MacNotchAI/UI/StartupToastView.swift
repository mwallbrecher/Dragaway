import SwiftUI
import Combine

// MARK: - State model

/// Reference-type wrapper so AppDelegate can trigger the fade-out from outside SwiftUI.
@MainActor
final class StartupToastState: ObservableObject {
    @Published var appeared = false

    func show() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
            appeared = true
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            appeared = false
        }
        // Give the spring time to reach scale 0 before the window is removed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42, execute: completion)
    }
}

// MARK: - View

/// Compact "Dragaway is ready" banner that appears just below the notch for ~5 s.
struct StartupToastView: View {

    @ObservedObject var state: StartupToastState

    var body: some View {
        HStack(spacing: 11) {

            // ── Pulse dot ──────────────────────────────────────────────────
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.22))
                    .frame(width: 26, height: 26)
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                    .shadow(color: .green.opacity(0.9), radius: 5, x: 0, y: 0)
            }

            // ── Text block ─────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text("Dragaway is ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)

                Text("Drag any file toward the Notch  ·  Add a Hotkey in Settings to avoid auto-popup")
                    .font(.system(size: 10.5))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 390)
        // ── LiquidGlass background ──────────────────────────────────────────
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Color.black.opacity(0.52)
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.10), location: 0.00),
                        .init(color: .clear,               location: 0.55),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.38), location: 0.00),
                                .init(color: .white.opacity(0.08), location: 0.55),
                                .init(color: .white.opacity(0.02), location: 1.00),
                            ],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // ── Spring in / spring out ──────────────────────────────────────────
        .scaleEffect(state.appeared ? 1.0 : 0.80, anchor: .top)
        .opacity(state.appeared ? 1.0 : 0.0)
    }
}
