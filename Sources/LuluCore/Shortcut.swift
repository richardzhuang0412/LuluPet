import Foundation

/// v0.4 global keyboard shortcut (registered with Carbon `RegisterEventHotKey` by the app).
/// Stored as JSON under the UserDefaults keys `hotkeyToggle` / `hotkeyCompose` / `hotkeyQuit` (v0.7)
/// (docs/upgrade-compat.md).
public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// macOS virtual key code (`kVK_*`), layout independent.
    public var keyCode: UInt32
    public var modifiers: Modifiers
    /// What the key shows as ("L", "Space", "F5"…), captured when the shortcut was recorded.
    public var key: String

    public init(keyCode: UInt32, modifiers: Modifiers, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// ⌃⌥L: show / hide the pet ("L" for Lulu).
    public static let defaultToggle = Shortcut(keyCode: 37, modifiers: [.control, .option], key: "L")
    /// ⌃⌥M: open the compose panel ("M" for message).
    public static let defaultCompose = Shortcut(keyCode: 46, modifiers: [.control, .option], key: "M")

    /// v0.7 ⌃⌥Q: quit the app (the 🍊 menu's 退出 shows it; ⌘Q is deliberately not used).
    public static let defaultQuit = Shortcut(keyCode: 12, modifiers: [.control, .option], key: "Q")

    /// Symbols in the standard macOS order: ⌃⌥⇧⌘.
    public var modifierSymbols: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    /// "⌃⌥L".
    public var display: String { modifierSymbols + key }

    /// A global shortcut needs at least one of ⌃ / ⌥ / ⌘ (⇧ alone would swallow normal typing).
    public var hasRequiredModifier: Bool { !modifiers.intersection([.control, .option, .command]).isEmpty }

    /// Validation message for a freshly recorded shortcut, nil when it can be used.
    /// `other` is the app's other shortcut (the two must differ).
    public func problem(conflictingWith other: Shortcut?) -> String? {
        problem(conflictingWith: other.map { [$0] } ?? [])
    }

    /// v0.7: same check against all of the app's other shortcuts (toggle / compose / quit).
    public func problem(conflictingWith others: [Shortcut]) -> String? {
        if !hasRequiredModifier { return "至少要按住 ⌃、⌥ 或 ⌘ 其中一个哦" }
        if others.contains(where: { sameKeys(as: $0) }) { return "和另一个快捷键重复了，换一个吧" }
        return nil
    }

    /// Same key and modifiers (the display name doesn't matter).
    public func sameKeys(as other: Shortcut) -> Bool { other.keyCode == keyCode && other.modifiers == modifiers }

    /// Readable name for a key: special keys by code, otherwise the typed character, upper-cased.
    public static func keyName(keyCode: UInt32, characters: String?) -> String {
        if let name = specialKeys[keyCode] { return name }
        let c = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return c.isEmpty ? "#\(keyCode)" : c
    }

    private static let specialKeys: [UInt32: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Character for `NSMenuItem.keyEquivalent` (lower-case letter / digit / punctuation), nil for
    /// keys a menu can't display as a plain character.
    public var menuKeyEquivalent: String? {
        guard key.count == 1, Self.specialKeys[keyCode] == nil else { return nil }
        return key.lowercased()
    }
}

/// v0.7: the app's global shortcuts (raw value = Carbon hotkey id, stable).
public enum ShortcutAction: UInt32, CaseIterable, Sendable {
    case toggle = 1, compose = 2, quit = 3

    /// For logs / `--demo-hotkey`.
    public var name: String {
        switch self {
        case .toggle: return "toggle"
        case .compose: return "compose"
        case .quit: return "quit"
        }
    }

    public var defaultShortcut: Shortcut {
        switch self {
        case .toggle: return .defaultToggle
        case .compose: return .defaultCompose
        case .quit: return .defaultQuit
        }
    }
}

/// The current shortcut of every action; checks a newly recorded one against all the others.
public struct ShortcutSet: Equatable, Sendable {
    public var toggle: Shortcut
    public var compose: Shortcut
    public var quit: Shortcut

    public init(toggle: Shortcut = .defaultToggle, compose: Shortcut = .defaultCompose, quit: Shortcut = .defaultQuit) {
        self.toggle = toggle
        self.compose = compose
        self.quit = quit
    }

    public subscript(_ a: ShortcutAction) -> Shortcut {
        get {
            switch a {
            case .toggle: return toggle
            case .compose: return compose
            case .quit: return quit
            }
        }
        set {
            switch a {
            case .toggle: toggle = newValue
            case .compose: compose = newValue
            case .quit: quit = newValue
            }
        }
    }

    /// Why `s` can't be used for `action` (needs a modifier / same as another action's), nil = fine.
    /// Re-recording an action's own current shortcut is fine.
    public func problem(_ s: Shortcut, for action: ShortcutAction) -> String? {
        s.problem(conflictingWith: ShortcutAction.allCases.filter { $0 != action }.map { self[$0] })
    }
}

/// v0.4 "隐藏" choices (status menu / right-click menu). The hidden state is never persisted:
/// a restart always shows the pet again.
public enum HideOption: String, CaseIterable, Sendable {
    case fiveMinutes, thirtyMinutes, oneHour, untilReopened

    public var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .untilReopened: return "直到我再打开"
        }
    }

    /// nil = until shown again by hand (menu / hotkey / compose hotkey).
    public var duration: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .untilReopened: return nil
        }
    }
}

/// Why the pet is hidden: by hand (maybe until a time) and/or because a fullscreen app is in front.
public struct HideState: Equatable, Sendable {
    /// Manual hide; `until` (monotonic seconds) nil = until shown again by hand.
    public private(set) var manual = false
    public private(set) var until: TimeInterval?
    /// A fullscreen app covers the pet's screen (and auto-hide is on).
    public var fullscreen = false

    public init() {}

    public var isHidden: Bool { manual || fullscreen }

    public mutating func hide(_ option: HideOption, now: TimeInterval) {
        manual = true
        until = option.duration.map { now + $0 }
    }

    public mutating func showManually() {
        manual = false
        until = nil
    }

    /// Seconds until a timed hide ends (nil when not timed).
    public func remaining(now: TimeInterval) -> TimeInterval? {
        guard manual, let until else { return nil }
        return max(0, until - now)
    }

    /// Ends a timed hide whose time is up. Returns true when that happened.
    public mutating func expire(now: TimeInterval) -> Bool {
        guard manual, let until, now >= until else { return false }
        showManually()
        return true
    }
}
