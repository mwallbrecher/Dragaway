import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey via Carbon `RegisterEventHotKey`.
///
/// Unlike an `NSEvent` global monitor this **consumes** the keystroke (so the combo
/// never leaks into the frontmost app) and needs **no Accessibility permission**.
/// Used for the ⌃⌘V clipboard-history picker. One key per instance.
final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    /// Called on the main thread when the hotkey fires.
    fileprivate var onFire: (() -> Void)?

    // 'AIDR' — any non-zero signature; pairs with a UNIQUE per-instance id so several
    // GlobalHotkey instances can coexist (⌃⌘V picker + ⌃⌘N new-session). The callback
    // matches the event's id against the instance's own and passes mismatches along.
    private static var nextID: UInt32 = 0
    fileprivate let hotKeyID: EventHotKeyID

    init() {
        Self.nextID += 1
        hotKeyID = EventHotKeyID(signature: 0x4149_4452, id: Self.nextID)
    }

    /// Register `keyCode` (virtual key, e.g. `kVK_ANSI_V`) with Carbon modifier mask
    /// (`cmdKey` / `controlKey` / `optionKey` / `shiftKey`). Replaces any prior key.
    func register(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        unregister()
        self.onFire = onFire

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyCallback,
                            1, &spec, selfPtr, &eventHandler)

        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        onFire = nil
    }

    deinit { unregister() }
}

/// Free C callback (Carbon needs a bare function pointer, no captured context). The
/// instance arrives via `userData`. Carbon hotkey events are delivered on the main
/// runloop, so it's safe to assume main-actor isolation and call the stored closure.
private func hotkeyCallback(_ next: EventHandlerCallRef?,
                            _ event: EventRef?,
                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }

    // Which registered hotkey fired? Each handler instance sees every hotkey event on
    // the app target, so match the event's id against THIS instance's — otherwise
    // pass it along the handler chain to the owning instance.
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                      EventParamType(typeEventHotKeyID), nil,
                      MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    let instance = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
    guard hkID.id == instance.hotKeyID.id else { return OSStatus(eventNotHandledErr) }

    MainActor.assumeIsolated { instance.onFire?() }
    return noErr
}
