import AppKit
import Combine
import SwiftUI

// MARK: - Controller

/// Drives the radial app launcher — the "second drag mode". When a file drag starts
/// with the radial modifier (⇧ by default) held, this shows a full-screen transparent
/// panel with a wheel of the user's favorite apps centred on the cursor. Flick toward a
/// wedge and release to open the dragged file in that app.
///
/// The panel is an `NSDraggingDestination`, so it intercepts the drop (the file never
/// lands on whatever is behind the cursor) and gives us live cursor tracking via
/// `draggingUpdated` plus a single commit point in `performDragOperation`.
@MainActor
final class RadialLauncherController: ObservableObject {
    static let shared = RadialLauncherController()
    private init() {}

    // Geometry (points, view space).
    static let innerRadius: CGFloat = 66
    static let outerRadius: CGFloat = 150
    static let iconRadius:  CGFloat = 108
    static let iconSize:    CGFloat = 44

    /// One slot on the wheel: a favorite app, or the special "Dragaway" slot that routes
    /// the file into the pill/chips flow.
    enum Item {
        case app(FavoriteTool)
        case aiDrop
    }

    @Published private(set) var items: [Item] = []
    /// Index of the wedge the cursor is currently over (nil = centre dead-zone = cancel).
    @Published var highlighted: Int? = nil
    /// True (coexist mode only) when the cursor is approaching the notch pill — the
    /// wedge highlight drops and a release here hands the file to the pill, not an app.
    @Published var pillTargeted = false

    /// Wheel centre in SwiftUI view space (top-left origin, y-down).
    private(set) var centerView: CGPoint = .zero

    private var urls: [URL] = []
    private var windowFrame: CGRect = .zero
    private var window: RadialWindow?
    private var committed = false
    // Failsafe: the wheel is a full-screen, mouse-catching panel that normally tears
    // down via the drag callbacks (performDragOperation / draggingEnded). If a drag
    // ever ends WITHOUT those firing (released before the panel got its first
    // draggingEntered, drag cancelled oddly), the invisible panel would swallow every
    // click on screen. This timer polls the physical button state in .common mode
    // (fires inside AppKit's drag loop) and force-dismisses shortly after release.
    private var failsafeTimer: Timer?
    private var buttonUpTicks = 0
    /// Sharing the drag with the notch pill — enables the pill-approach zone + handoff.
    private var coexist = false
    private var pillCenter: CGPoint = .zero   // view space
    private var pillRadius: CGFloat = 0

    var isActive: Bool { window != nil }

    // MARK: Lifecycle

    /// Show the wheel for `urls`. Returns false (caller should fall back to the pill)
    /// when there are no favorite apps to show.
    @discardableResult
    func begin(urls: [URL], coexistWithPill: Bool = false) -> Bool {
        guard !isActive, !urls.isEmpty else { return false }
        let apps = FavoriteToolsStore.shared.resolvedTools(for: urls)
        let showAIDrop = HotkeyManager.shared.radialShowsAIDrop
        var items: [Item] = apps.map { .app($0) }
        // Dragaway takes the top-centre slot (index 0 = -90° = straight up).
        if showAIDrop { items.insert(.aiDrop, at: 0) }
        guard !items.isEmpty else { return false }   // nothing to show → fall back to pill

        let mouse = NSEvent.mouseLocation                       // screen coords, y-up
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return false }

        // Always full-screen so the window keeps tracking the cursor (and catching the
        // drop) however far it flicks toward an app. When coexisting with the pill, a
        // zone near the notch hands the drop to the pill instead — see updateLocation.
        let frame = screen.frame

        self.urls         = urls
        self.items        = items
        self.highlighted  = nil
        self.pillTargeted = false
        self.committed    = false
        self.coexist      = coexistWithPill
        self.windowFrame  = frame
        // Convert the cursor (y-up screen) into SwiftUI view space (y-down).
        self.centerView   = CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)

        // Notch pill approach zone (view space): the pill sits top-centre, its top
        // edge 37pt below the screen top, height 96·scale. A generous radius makes the
        // highlight release as the cursor *approaches* the pill, not only over it.
        let s = UIScale.current.multiplier
        self.pillCenter = CGPoint(x: frame.width / 2, y: 37 + (96 * s) / 2)
        self.pillRadius = 150 * s

        let panel = RadialWindow(frame: frame)
        let drop  = RadialDropView(frame: NSRect(origin: .zero, size: frame.size))
        let host  = NSHostingView(rootView: RadialMenuView())
        host.frame = drop.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        drop.addSubview(host)
        panel.contentView = drop
        panel.orderFrontRegardless()
        self.window = panel
        startFailsafe()
        NotificationCenter.default.post(name: .tutorialEvent, object: "radial")
        return true
    }

    /// See `failsafeTimer`. 0.1 s ticks; 3 consecutive button-up ticks (~0.3 s) leave
    /// plenty of room for a normal drop's performDragOperation (which arrives within
    /// milliseconds of release and cancels this via dismiss()).
    private func startFailsafe() {
        failsafeTimer?.invalidate()
        buttonUpTicks = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self.buttonUpTicks += 1
                    if self.buttonUpTicks >= 3 { self.dragEnded() }
                } else {
                    self.buttonUpTicks = 0
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        failsafeTimer = t
    }

    /// Live cursor update from the drag session. `screenPoint` is y-up screen coords.
    func updateLocation(_ screenPoint: CGPoint) {
        let p = CGPoint(x: screenPoint.x - windowFrame.minX,
                        y: windowFrame.maxY - screenPoint.y)

        // Coexisting with the pill: once the cursor approaches the notch pill, drop the
        // wedge highlight so a release there is handed to the pill (not a launch). The
        // highlight otherwise PERSISTS for outward flicks, however far past the wheel —
        // it only releases near the pill.
        if coexist {
            let pdx = p.x - pillCenter.x
            let pdy = p.y - pillCenter.y
            if (pdx * pdx + pdy * pdy).squareRoot() < pillRadius {
                if !pillTargeted { pillTargeted = true }
                if highlighted != nil { highlighted = nil }
                return
            }
            if pillTargeted { pillTargeted = false }
        }

        let dx = p.x - centerView.x
        let dy = p.y - centerView.y
        let r  = (dx * dx + dy * dy).squareRoot()
        let n  = items.count
        guard n > 0, r >= Self.innerRadius else { highlighted = nil; return }

        let sector = (2 * Double.pi) / Double(n)
        let phi    = atan2(Double(dy), Double(dx))              // 0 = +x, +π/2 = down
        // θ_0 = -π/2 (top). idx = round((phi - θ_0)/sector).
        var idx = Int(((phi + .pi / 2) / sector).rounded()) % n
        if idx < 0 { idx += n }
        if highlighted != idx { highlighted = idx }
    }

    /// Launch the highlighted app, route to the pill, or cancel — then tear down.
    func commit() {
        committed = true
        let urls = self.urls                       // capture before dismiss() clears it
        if coexist && pillTargeted {
            routeToPill(urls)
        } else if let i = highlighted, items.indices.contains(i) {
            switch items[i] {
            case .app(let tool): FavoriteToolsStore.shared.launch(tool, with: urls)
            case .aiDrop:        routeToPill(urls)
            }
        }
        dismiss()
    }

    /// Open the file in Dragaway itself — drive the pill/chips flow via the AppDelegate
    /// (which reuses the same proven window bring-up as the Finder Quick Action).
    ///
    /// Routed through NotificationCenter (the app's standard AppDelegate channel) rather
    /// than an `NSApp.delegate` cast, and deferred one run-loop tick: this runs inside the
    /// radial window's performDragOperation, so we let the drag fully conclude and the
    /// radial window tear down before the overlay is built. `urls` captured by value.
    private func routeToPill(_ urls: [URL]) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .radialOpenSession, object: urls)
        }
    }

    /// Drag ended without a drop on us (e.g. Esc) — cancel if still showing.
    func dragEnded() {
        guard isActive, !committed else { return }
        dismiss()
    }

    private func dismiss() {
        failsafeTimer?.invalidate()
        failsafeTimer = nil
        window?.orderOut(nil)
        window = nil
        highlighted = nil
        pillTargeted = false
        coexist = false
        urls = []
        items = []
    }

    // MARK: Layout + item helpers (view space)

    func iconCenter(_ i: Int) -> CGPoint {
        let n = max(items.count, 1)
        let theta = -Double.pi / 2 + Double(i) * (2 * Double.pi / Double(n))
        return CGPoint(x: centerView.x + Self.iconRadius * CGFloat(cos(theta)),
                       y: centerView.y + Self.iconRadius * CGFloat(sin(theta)))
    }

    func icon(for item: Item) -> NSImage {
        switch item {
        case .app(let tool): return FavoriteToolsStore.shared.icon(for: tool)
        case .aiDrop:        return NSApp.applicationIconImage ?? NSImage()
        }
    }

    func name(for item: Item) -> String {
        switch item {
        case .app(let tool): return tool.name
        case .aiDrop:        return "Start Session"
        }
    }
}

// MARK: - Window

/// Full-screen, transparent, non-activating panel that hosts the wheel and catches the drop.
final class RadialWindow: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel    = true
        level              = .popUpMenu
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        setFrame(frame, display: false)
    }
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Drop view (NSDraggingDestination)

/// The registered drag destination. Tracks the cursor and commits the launch on drop.
final class RadialDropView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Same flavours the pill accepts — modern + legacy fallback.
        registerForDraggedTypes([
            .fileURL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
            NSPasteboard.PasteboardType("public.file-url"),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func screenPoint(_ sender: NSDraggingInfo) -> CGPoint {
        // draggingLocation is window base coords (y-up). Offset by the window origin.
        let origin = window?.frame.origin ?? .zero
        let loc = sender.draggingLocation
        return CGPoint(x: origin.x + loc.x, y: origin.y + loc.y)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        RadialLauncherController.shared.updateLocation(screenPoint(sender))
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        RadialLauncherController.shared.updateLocation(screenPoint(sender))
        return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        RadialLauncherController.shared.updateLocation(screenPoint(sender))
        RadialLauncherController.shared.commit()
        return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        RadialLauncherController.shared.dragEnded()
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Cursor left our (full-screen) area — nothing selectable. Clear highlight.
        RadialLauncherController.shared.highlighted = nil
    }
}

// MARK: - SwiftUI wheel

private struct RadialMenuView: View {
    @ObservedObject private var c = RadialLauncherController.shared

    private var inner: CGFloat { RadialLauncherController.innerRadius }
    private var outer: CGFloat { RadialLauncherController.outerRadius }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Donut ring + highlighted wedge (vector, absolute coords).
            Canvas { ctx, _ in
                let center = c.centerView

                // Ring background (dark glass-ish), with a hole via even-odd fill.
                var ring = Path()
                ring.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer,
                                           width: outer * 2, height: outer * 2))
                ring.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                                           width: inner * 2, height: inner * 2))
                ctx.fill(ring, with: .color(Color.black.opacity(0.55)), style: FillStyle(eoFill: true))

                // Highlighted wedge.
                if let i = c.highlighted, c.items.indices.contains(i) {
                    let n = c.items.count
                    let sector = (2 * Double.pi) / Double(n)
                    let theta  = -Double.pi / 2 + Double(i) * sector
                    let start  = theta - sector / 2
                    let end    = theta + sector / 2
                    var seg = Path()
                    seg.addArc(center: center, radius: outer,
                               startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                    seg.addArc(center: center, radius: inner,
                               startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
                    seg.closeSubpath()
                    ctx.fill(seg, with: .color(Color.accentColor.opacity(0.9)))
                }

                // Subtle outer + inner rim strokes.
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer,
                                                  width: outer * 2, height: outer * 2)),
                           with: .color(.white.opacity(0.12)), lineWidth: 1)
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - inner, y: center.y - inner,
                                                  width: inner * 2, height: inner * 2)),
                           with: .color(.white.opacity(0.10)), lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 8)

            // App icons + the "Start Session" slot.
            ForEach(Array(c.items.enumerated()), id: \.offset) { idx, item in
                let selected = c.highlighted == idx
                marker(for: item, selected: selected)
                    .scaleEffect(selected ? 1.18 : 1.0)
                    .shadow(color: .black.opacity(0.5), radius: selected ? 6 : 3, y: 1)
                    .position(c.iconCenter(idx))
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: selected)
            }

            // Centre label — pill-handoff hint, the slot you're about to open into, or a prompt.
            Text(c.pillTargeted
                 ? "↑ Notch pill"
                 : (c.highlighted.flatMap { c.items.indices.contains($0) ? c.name(for: c.items[$0]) : nil }
                    ?? "Open in…"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(c.highlighted == nil && !c.pillTargeted ? 0.45 : 0.95))
                .lineLimit(1)
                .frame(maxWidth: inner * 1.7)
                .position(c.centerView)
                .animation(.easeInOut(duration: 0.12), value: c.highlighted)
                .animation(.easeInOut(duration: 0.12), value: c.pillTargeted)
        }
        .ignoresSafeArea()
    }

    /// One wheel slot: app icons stay icons; the Dragaway slot is a larger pill-shaped
    /// "Start Session" label (no icon) instead.
    @ViewBuilder
    private func marker(for item: RadialLauncherController.Item, selected: Bool) -> some View {
        switch item {
        case .app:
            Image(nsImage: c.icon(for: item))
                .resizable()
                .interpolation(.high)
                .frame(width: RadialLauncherController.iconSize,
                       height: RadialLauncherController.iconSize)
        case .aiDrop:
            Text("Start Session")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(selected ? 0.95 : 0.6))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
        }
    }
}
