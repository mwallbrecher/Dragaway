import SwiftUI
import AppKit

// MARK: - Backdrop blur

/// NSVisualEffectView wrapper that blurs content BEHIND the window.
/// Works because OverlayWindow has isOpaque=false and backgroundColor=.clear.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    /// Emphasized = a heavier/more-frosted variant. False = a slighter, lighter frost.
    var isEmphasized: Bool = true

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = material
        v.blendingMode = blendingMode
        v.state        = .active
        v.isEmphasized = isEmphasized
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blendingMode
        v.isEmphasized = isEmphasized
    }
}

// MARK: - Glass fill layer

/// Layered background: blur → dark tint → optional colour tint → specular → rim border.
/// `tintOpacity` controls depth: higher = darker = easier to read white text.
/// `colorTint`   overlays a translucent colour (e.g. accentColor on hover) between the
///               dark tint and the specular highlight — at low opacity it adds a subtle
///               hue without washing out the glassy look.
struct LiquidGlassFill: View {
    var cornerRadius: CGFloat
    var tintOpacity: Double = 0.55
    var colorTint: Color    = .clear
    /// When true, the dark tint is a vertical gradient — translucent at the top, fading to
    /// fully clear at the bottom so the blurred desktop shows through (the Apple-Intelligence /
    /// Siri panel look). When false, a uniform tint at `tintOpacity`.
    var verticalFade: Bool  = false
    /// Backdrop blur material (the "frost"). Tunable per call site.
    var material: NSVisualEffectView.Material = .hudWindow
    /// Emphasized frost (heavier) vs a slighter, lighter frost.
    var emphasized: Bool = true

    var body: some View {
        ZStack {
            // 1. Backdrop blur — desktop/windows show through, blurred (the "frost")
            VisualEffectBlur(material: material, blendingMode: .behindWindow, isEmphasized: emphasized)

            // 2. Dark tint — uniform, or a top→bottom fade into transparent glass.
            if verticalFade {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.72), location: 0.00),
                        .init(color: .black.opacity(0.60), location: 0.50),
                        .init(color: .black.opacity(0.28), location: 0.80),
                        .init(color: .black.opacity(0.00), location: 1.00),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                Color.black.opacity(tintOpacity)
            }

            // 3. Optional colour tint (e.g. system blue on hover) — stays subtle at 0.22
            colorTint.opacity(0.22)

            // 4. Specular highlight — minimal white sheen at the very top
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.11), location: 0.00),
                    .init(color: .white.opacity(0.04), location: 0.45),
                    .init(color: .clear,               location: 1.00),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // 5. Rim border — bright top-leading, fades bottom-trailing
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.40), location: 0.00),
                            .init(color: .white.opacity(0.12), location: 0.50),
                            .init(color: .white.opacity(0.03), location: 1.00),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Convenience modifiers

extension View {
    /// Liquid Glass panel. **macOS 26+** uses the real `glassEffect` (refraction, adaptive,
    /// light); earlier macOS falls back to the custom blur+tint+rim (`LiquidGlassFill`).
    @ViewBuilder
    func liquidGlass(cornerRadius: CGFloat,
                     tintOpacity: Double = 0.55,
                     colorTint: Color = .clear,
                     verticalFade: Bool = false,
                     material: NSVisualEffectView.Material = .hudWindow,
                     emphasized: Bool = true) -> some View {
        if #available(macOS 26.0, *) {
            self
                // Dark→clear tint over the glass (behind content): dark-frosted top →
                // transparent low-frost bottom. Only when verticalFade is requested.
                .background {
                    if verticalFade {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black.opacity(0.82), location: 0.00),
                                        .init(color: .black.opacity(0.66), location: 0.45),
                                        .init(color: .black.opacity(0.22), location: 0.80),
                                        .init(color: .black.opacity(0.00), location: 1.00),
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                }
                .glassEffect(colorTint == .clear ? .regular : .regular.tint(colorTint),
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                // Hard-clip the whole composite to the rounded shape too, so a shadowed
                // window's alpha mask is rounded (otherwise the corners show a rectangle).
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(LiquidGlassFill(cornerRadius: cornerRadius,
                                             tintOpacity: tintOpacity,
                                             colorTint: colorTint,
                                             verticalFade: verticalFade,
                                             material: material,
                                             emphasized: emphasized))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    /// Liquid Glass circle (close/share/window buttons). macOS 26+ uses an interactive `glassEffect`.
    @ViewBuilder
    func liquidGlassCircle(tintOpacity: Double = 0.50,
                            colorTint: Color = .clear) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect((colorTint == .clear ? Glass.regular : Glass.regular.tint(colorTint)).interactive(),
                             in: Circle())
        } else {
            self
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        Color.black.opacity(tintOpacity)
                        colorTint.opacity(0.22)
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.11), location: 0.0),
                                .init(color: .clear,               location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.38), .white.opacity(0.04)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    }
                    .clipShape(Circle())
                )
                .clipShape(Circle())
        }
    }

    /// Liquid Glass capsule (chips, handoff button). macOS 26+ uses an interactive `glassEffect`.
    @ViewBuilder
    func liquidGlassCapsule(tintOpacity: Double = 0.45,
                             colorTint: Color = .clear) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect((colorTint == .clear ? Glass.regular : Glass.regular.tint(colorTint)).interactive(),
                             in: Capsule(style: .continuous))
        } else {
            self
                .background(
                    ZStack {
                        VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                        Color.black.opacity(tintOpacity)
                        colorTint.opacity(0.22)
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.10), location: 0.0),
                                .init(color: .clear,               location: 1.0),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .white.opacity(0.04)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.75
                            )
                    }
                    .clipShape(Capsule(style: .continuous))
                )
                .clipShape(Capsule(style: .continuous))
        }
    }
}
