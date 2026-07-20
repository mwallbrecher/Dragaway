import AppKit
import SwiftUI

// MARK: - Clipboard picker (⌃⌘V popup)
//
// A floating, borderless panel listing the last 10 clipboard captures. Opened by the
// Carbon ⌃⌘V hotkey (GlobalHotkey → ClipboardPicker.toggle). Pick a row — by click or by
// pressing its number key (1…9, 0 for the tenth) — to copy it back and return focus to
// the previously active app. Enhanced Access can then post one Command-V; without it,
// the user presses ⌘V themselves.
//
// Dismiss: Esc, a click outside the panel, or the panel losing key (app switch). The panel
// is `canBecomeKey` so a local keyDown monitor can claim the digit/Esc keys while it's open.

/// Borderless floating panel host for `ClipboardPickerView`. Clear background so the
/// SwiftUI liquid-glass surface shows through (same recipe as `OverlayWindow`).
final class ClipboardPickerPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel             = true
        level                       = .floating
        backgroundColor             = .clear
        isOpaque                    = false
        hasShadow                   = true
        isMovableByWindowBackground = false
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ClipboardPicker: NSObject, NSWindowDelegate {
    static let shared = ClipboardPicker()
    private override init() { super.init() }

    private var panel: ClipboardPickerPanel?
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    /// External app that was frontmost before the picker activated Dragaway.
    private var returnApplication: NSRunningApplication?
    /// One-shot state for an auto-paste waiting on the exact target app to activate.
    private var pendingPasteToken: UUID?
    private var pendingPasteTarget: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    /// Prevent a programmatic `orderOut` from being mistaken for a user focus change.
    private var isOrderingOut = false
    /// An app-modal alert temporarily takes key status but is still part of the picker flow.
    private var isPresentingModal = false

    private let baseWidth: CGFloat   = 380
    private let rowHeight: CGFloat   = 54
    private let headerHeight: CGFloat = 46
    private let vPadding: CGFloat    = 18

    // MARK: Show / hide / toggle

    func toggle() {
        guard !isPresentingModal else { return }
        if panel?.isVisible == true { cancel() } else { show() }
    }

    func show() {
        cancelPendingPaste()

        // Capture this BEFORE activating our panel. If Dragaway is already frontmost
        // (for example while Settings is open), there is no external app to restore.
        let currentPID = NSRunningApplication.current.processIdentifier
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != currentPID,
           !frontmost.isTerminated {
            returnApplication = frontmost
        } else {
            returnApplication = nil
        }

        let s = UIScale.current.multiplier
        let count = min(ClipboardHistoryStore.shared.items.count, 10)

        let contentH = count == 0
            ? 150 * s
            : (headerHeight + CGFloat(count) * rowHeight + vPadding * 2) * s
        let size = CGSize(width: baseWidth * s, height: contentH)

        let p = panel ?? makePanel()
        let host = NSHostingView(rootView:
            ClipboardPickerView()
                .environment(\.uiScale, s)
        )
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        p.contentView = host
        panel = p

        // Centre horizontally, sit a little above the screen's vertical centre.
        if let screen = NSScreen.main {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.midY - size.height / 2 + screen.frame.height * 0.12
            p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        } else {
            p.setContentSize(size)
        }

        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        // Recompute the drop shadow against the rounded-glass alpha mask (next runloop,
        // after the SwiftUI content has laid out) so the corners aren't rectangular.
        DispatchQueue.main.async { p.invalidateShadow() }
        startMonitors()
    }

    /// Passive dismissal (outside click / app switch): respect the user's new focus.
    func hide() {
        returnApplication = nil
        cancelPendingPaste()
        dismissPanel()
    }

    /// Explicit cancellation (Esc / second hotkey): return to the original app but
    /// never paste anything.
    func cancel() {
        let target = takeReturnApplication()
        cancelPendingPaste()
        dismissPanel()
        restoreFocus(to: target, autoPaste: false)
    }

    /// Preserve the return target while an NSAlert temporarily becomes key.
    func beginModalInteraction() {
        isPresentingModal = true
        stopMonitors()
    }

    func endModalInteraction() {
        isPresentingModal = false
        cancel()
    }

    private func dismissPanel() {
        stopMonitors()
        isOrderingOut = true
        panel?.orderOut(nil)
        isOrderingOut = false
    }

    /// Copy the chosen entry, dismiss, restore the previous app, then conditionally
    /// paste once after that exact app is confirmed frontmost.
    func pick(_ item: ClipItem) {
        let target = takeReturnApplication()
        cancelPendingPaste()
        let copied = ClipboardHistoryStore.shared.copyToPasteboard(item)
        dismissPanel()

        if !copied { NSSound.beep() }
        restoreFocus(to: target, autoPaste: copied && EnhancedAccess.canPostEvents)
    }

    private func takeReturnApplication() -> NSRunningApplication? {
        defer { returnApplication = nil }
        return returnApplication
    }

    private func restoreFocus(to target: NSRunningApplication?, autoPaste: Bool) {
        guard let target, !target.isTerminated else { return }

        let current = NSRunningApplication.current
        let token = autoPaste ? armPasteAfterActivation(of: target) : nil

        // macOS 14 cooperative activation: explicitly yield our active status, then
        // ask the remembered app to take it. This needs no Accessibility permission.
        NSApp.yieldActivation(to: target)
        let accepted = target.activate(from: current, options: [])
        guard accepted else {
            cancelPendingPaste()
            return
        }

        // Activation may already have completed before its workspace notification is
        // delivered. Check on the next main-runloop turn as well; the token makes both
        // paths mutually exclusive.
        if let token {
            DispatchQueue.main.async { [weak self] in
                self?.completePendingPasteIfReady(token: token)
            }
        }
    }

    private func armPasteAfterActivation(of target: NSRunningApplication) -> UUID {
        cancelPendingPaste()
        let token = UUID()
        pendingPasteToken = token
        pendingPasteTarget = target

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleActivationWhilePastePending(token: token)
            }
        }

        // A failed/blocked activation must never leave a future unrelated app switch
        // capable of triggering the stale paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard self?.pendingPasteToken == token else { return }
            self?.cancelPendingPaste()
        }
        return token
    }

    private func handleActivationWhilePastePending(token: UUID) {
        guard pendingPasteToken == token,
              let target = pendingPasteTarget,
              let frontmost = NSWorkspace.shared.frontmostApplication
        else { return }

        if frontmost.processIdentifier == target.processIdentifier {
            completePendingPasteIfReady(token: token)
        } else if frontmost.processIdentifier != NSRunningApplication.current.processIdentifier {
            // The user or the system chose a third app before the target was ready.
            // Cancel immediately so returning to the target later cannot paste stale data.
            cancelPendingPaste()
        }
    }

    private func completePendingPasteIfReady(token: UUID) {
        guard pendingPasteToken == token,
              let target = pendingPasteTarget,
              !target.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        else { return }

        // Clear first so an activation notification and the next-runloop check can
        // never both post. EnhancedAccess re-checks opt-in + TCC immediately after.
        cancelPendingPaste()
        EnhancedAccess.postPasteShortcut()
    }

    private func cancelPendingPaste() {
        if let observer = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            activationObserver = nil
        }
        pendingPasteToken = nil
        pendingPasteTarget = nil
    }

    // MARK: Panel + monitors

    private func makePanel() -> ClipboardPickerPanel {
        let p = ClipboardPickerPanel()
        p.delegate = self
        return p
    }

    private func startMonitors() {
        stopMonitors()
        // Number keys (1…9, 0 → tenth) select; Esc dismisses. Local monitor → only our
        // own key events, and only while the panel is key. Returning nil swallows the key.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // nil from handleKey means "swallow"; don't resurrect it with ?? event.
            return MainActor.assumeIsolated { self.handleKey(event) }
        }
        // A click anywhere outside the panel dismisses it.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in self?.hide() }
        }
    }

    private func stopMonitors() {
        if let m = keyMonitor          { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    /// Returns nil to swallow a handled key (digit / Esc); the event unchanged otherwise.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { cancel(); return nil }   // Esc
        // Ignore modified chords — only bare digits select.
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let d = Int(chars) else { return event }
        let idx = (d == 0) ? 9 : d - 1
        let items = Array(ClipboardHistoryStore.shared.items.prefix(10))
        guard items.indices.contains(idx) else { return event }
        pick(items[idx])
        return nil
    }

    // Losing key (app switch, ⌘Tab) dismisses — mirrors a menu's click-away behaviour.
    func windowDidResignKey(_ notification: Notification) {
        guard !isOrderingOut, !isPresentingModal, panel?.isVisible == true else { return }
        hide()
    }
}

// MARK: - SwiftUI list

struct ClipboardPickerView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @Environment(\.uiScale) private var scale

    private var rows: [ClipItem] { Array(store.items.prefix(10)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if rows.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, item in
                        ClipboardRow(item: item, number: numberLabel(idx))
                        if idx < rows.count - 1 {
                            Divider().background(Color.white.opacity(0.08))
                                .padding(.horizontal, 14 * scale)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 18 * scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .liquidGlass(cornerRadius: 22 * scale, tintOpacity: 0.7)
    }

    private var header: some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 13 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("Clipboard History")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            if !store.items.isEmpty {
                Button(action: clearHistory) {
                    HStack(spacing: 4 * scale) {
                        Image(systemName: "trash")
                            .font(.system(size: 10 * scale, weight: .semibold))
                        Text("Clear History")
                            .font(.system(size: 11 * scale, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.28))
                    .padding(.horizontal, 8 * scale)
                    .padding(.vertical, 4 * scale)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.red.opacity(0.14))
                            .overlay(Capsule(style: .continuous)
                                .strokeBorder(Color.red.opacity(0.30), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .help("Clear all clipboard history")
            }
            Text("⌃⌘V")
                .font(.system(size: 11 * scale, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 18 * scale)
        .padding(.bottom, 12 * scale)
    }

    /// Confirm-then-wipe all clipboard history (no undo), then dismiss the picker.
    private func clearHistory() {
        ClipboardPicker.shared.beginModalInteraction()
        defer { ClipboardPicker.shared.endModalInteraction() }
        if confirmDestructive(title: "Clear Clipboard History?", confirmTitle: "Clear History") {
            ClipboardHistoryStore.shared.clear()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6 * scale) {
            Image(systemName: "tray")
                .font(.system(size: 22 * scale, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
            Text("No clipboard history yet")
                .font(.system(size: 12 * scale))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22 * scale)
    }

    /// 1…9 then 0 for the tenth row — matches the number-key shortcuts.
    private func numberLabel(_ idx: Int) -> String { idx == 9 ? "0" : "\(idx + 1)" }
}

// MARK: - Row

private struct ClipboardRow: View {
    let item: ClipItem
    let number: String
    @Environment(\.uiScale) private var scale
    @State private var hovering = false

    var body: some View {
        Button { ClipboardPicker.shared.pick(item) } label: {
            HStack(spacing: 11 * scale) {
                Text(number)
                    .font(.system(size: 12 * scale, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 20 * scale, height: 20 * scale)
                    .background(Circle().fill(Color.white.opacity(0.12)))

                thumbnail
                    .frame(width: 30 * scale, height: 30 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 5 * scale, style: .continuous))

                VStack(alignment: .leading, spacing: 2 * scale) {
                    Text(item.preview)
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.relative(item.date))
                        .font(.system(size: 10.5 * scale))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16 * scale)
            .padding(.vertical, 8 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.10 : 0))
                    .padding(.horizontal, 8 * scale)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// Kind-appropriate icon. Real bitmaps (image thumbnails, colourful file icons) render
    /// via `Image(nsImage:)`; the text/empty cases use white SF Symbols so a template glyph
    /// isn't lost (black-on-dark) the way `store.icon`'s symbol fallback would be.
    @ViewBuilder private var thumbnail: some View {
        switch item.kind {
        case .image:
            if let img = ClipboardHistoryStore.shared.loadImage(item) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                symbol("photo")
            }
        case .files:
            Image(nsImage: ClipboardHistoryStore.shared.icon(for: item, size: 30 * scale))
                .resizable().aspectRatio(contentMode: .fit)
        case .text:
            symbol("text.alignleft")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16 * scale, weight: .regular))
            .foregroundStyle(.white.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.08))
    }

    private static let fmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private static func relative(_ date: Date) -> String {
        fmt.localizedString(for: date, relativeTo: Date())
    }
}
