import AppKit
import Carbon.HIToolbox
import LuluCore

/// v0.4 global shortcuts via Carbon `RegisterEventHotKey` (works without Accessibility permission).
@MainActor
final class HotkeyCenter {
    /// toggle (⌃⌥L) / compose (⌃⌥M) / v0.7 quit (⌃⌥Q); raw value = Carbon hotkey id.
    typealias Action = ShortcutAction

    static let shared = HotkeyCenter()

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handlers: [Action: () -> Void] = [:]
    private var installed = false
    private static let signature: OSType = 0x4C554C55   // 'LULU'

    /// Registers (or re-registers) `shortcut` for `action`. Returns nil on success, else a readable error.
    @discardableResult
    func register(_ action: Action, _ shortcut: Shortcut, handler: @escaping () -> Void) -> String? {
        installHandler()
        unregister(action)
        handlers[action] = handler
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, Self.carbonModifiers(shortcut.modifiers), id,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("[lulu] hotkey: %@ %@ registration FAILED (OSStatus %d)", action.name, shortcut.display, status)
            return status == eventHotKeyExistsErr ? "\(shortcut.display) 已经被别的 App 占用了，换一个吧"
                                                  : "\(shortcut.display) 注册失败（错误 \(status)），换一个试试"
        }
        refs[action] = ref
        NSLog("[lulu] hotkey: %@ %@ registered", action.name, shortcut.display)
        return nil
    }

    func unregister(_ action: Action) {
        if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
    }

    /// While the Settings recorder listens, every hotkey is released so the keys reach the recorder.
    func suspend() { Action.allCases.forEach(unregister) }

    /// Same path as a real key press (also used by the hidden `--demo-hotkey` flag).
    func fire(_ action: Action) {
        NSLog("[lulu] hotkey: %@ pressed", action.name)
        handlers[action]?()
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard err == noErr, hk.signature == HotkeyCenter.signature, let action = Action(rawValue: hk.id) else { return err }
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(action) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private static func carbonModifiers(_ m: Shortcut.Modifiers) -> UInt32 {
        var r: UInt32 = 0
        if m.contains(.command) { r |= UInt32(cmdKey) }
        if m.contains(.option) { r |= UInt32(optionKey) }
        if m.contains(.control) { r |= UInt32(controlKey) }
        if m.contains(.shift) { r |= UInt32(shiftKey) }
        return r
    }

    /// AppKit modifier flags → our modifiers (recorder, menu display).
    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> Shortcut.Modifiers {
        var m: Shortcut.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    nonisolated static func flags(_ m: Shortcut.Modifiers) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if m.contains(.control) { f.insert(.control) }
        if m.contains(.option) { f.insert(.option) }
        if m.contains(.shift) { f.insert(.shift) }
        if m.contains(.command) { f.insert(.command) }
        return f
    }
}
