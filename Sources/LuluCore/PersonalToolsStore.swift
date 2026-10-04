import Foundation

/// v0.10 persistence for the personal tools, in the same defaults domain as `ConfigStore`
/// (`ConfigStore(profile:).defaults`). Keys (docs/upgrade-compat.md): `toolsSettings`, `pomodoroState`,
/// `waterLog`, `reminder.water`, `reminder.stand`; all JSON, bad / missing data = defaults.
public final class PersonalToolsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    public var settings: ToolsSettings {
        get { load("toolsSettings") ?? ToolsSettings() }
        set { save(newValue, "toolsSettings") }
    }

    public var pomodoro: PomodoroState {
        get { load("pomodoroState") ?? .idle }
        set { save(newValue, "pomodoroState") }
    }

    public var waterLog: WaterLog {
        get { load("waterLog") ?? WaterLog() }
        set { save(newValue, "waterLog") }
    }

    public func reminder(_ kind: ReminderKind) -> ActiveTimeReminder? { load("reminder.\(kind.rawValue)") }

    public func setReminder(_ r: ActiveTimeReminder?, for kind: ReminderKind) { save(r, "reminder.\(kind.rawValue)") }

    /// v0.14.4 key `remindSnooze.water` / `remindSnooze.stand` (JSON `{"ackOf", "at"}`; absent = none): which partner
    /// reminder the current 「等会儿」 answers. Additive; older versions ignore it.
    public func remindSnooze(_ kind: ReminderKind) -> RemindSnoozeOrigin? { load("remindSnooze.\(kind.rawValue)") }

    public func setRemindSnooze(_ o: RemindSnoozeOrigin?, for kind: ReminderKind) { save(o, "remindSnooze.\(kind.rawValue)") }
}
