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

    // MARK: v0.18 eye drops (docs/upgrade-compat.md §17; spec 2026-10-12 §2.3). Bad / missing data = defaults.

    /// `eyedrops`: same shape as the remote node — `{"settings": {...}, "days": {last 14 days}}`. Solo: the only copy;
    /// paired: the local mirror of `/pairs/{code}/tools/{seat}/eyedrops` (works offline). Decoded like the remote.
    public var eyedrops: EyeDropsLocal {
        get {
            let d = EyeDrops.decode(json: defaults.data(forKey: "eyedrops").flatMap { try? JSONSerialization.jsonObject(with: $0) })
            return EyeDropsLocal(settings: d.settings, days: d.days)
        }
        set {
            var o: [String: Any] = ["days": EyeDrops.daysJSON(newValue.days)]
            if let s = newValue.settings { o["settings"] = s.json }
            if let data = try? JSONSerialization.data(withJSONObject: o) { defaults.set(data, forKey: "eyedrops") }
        }
    }

    /// `eyedropsNag`: this Mac's nag state `{"slot": "yyyy-MM-dd/HHmm", "shown", "next": Unix ms}` (at most one);
    /// read with `next` clamped to ≤ now + 15 min.
    public func eyedropsNag(nowMs: Int64) -> EyeDropsNag? {
        defaults.data(forKey: "eyedropsNag").flatMap { try? JSONSerialization.jsonObject(with: $0) }.flatMap { EyeDropsNag(json: $0, nowMs: nowMs) }
    }

    public func setEyedropsNag(_ nag: EyeDropsNag?) {
        if let nag, let data = try? JSONSerialization.data(withJSONObject: nag.json) {
            defaults.set(data, forKey: "eyedropsNag")
        } else {
            defaults.removeObject(forKey: "eyedropsNag")
        }
    }

    /// `eyedropsPending`: writes that have not reached the server yet (offline), retried by housekeeping.
    public var eyedropsPending: EyeDropsPending {
        get { load("eyedropsPending") ?? EyeDropsPending() }
        set { save(newValue, "eyedropsPending") }
    }
}

/// v0.18 local copy of the eye-drop node (`eyedrops` key).
public struct EyeDropsLocal: Equatable, Sendable {
    public var settings: EyeDropsSettings?
    public var days: EyeDropsDays
    public init(settings: EyeDropsSettings? = nil, days: EyeDropsDays = [:]) {
        self.settings = settings
        self.days = days
    }
}

/// v0.18 `eyedropsPending`: `{"settings": true?, "done": [{"day", "slot", "done", "device"}], "undo": [{"day", "slot"}]}`.
/// `settings` = upload the local settings (whatever they are by then); a check-in and its undo cancel out.
public struct EyeDropsPending: Codable, Equatable, Sendable {
    public struct Leaf: Codable, Equatable, Sendable {
        public var day: String
        public var slot: String
        public var done: Int64?
        public var device: String?
        public init(day: String, slot: String, done: Int64? = nil, device: String? = nil) {
            self.day = day
            self.slot = slot
            self.done = done
            self.device = device
        }
    }
    public var settings: Bool?
    public var done: [Leaf]
    public var undo: [Leaf]

    public init(settings: Bool? = nil, done: [Leaf] = [], undo: [Leaf] = []) {
        self.settings = settings
        self.done = done
        self.undo = undo
    }

    public var isEmpty: Bool { settings != true && done.isEmpty && undo.isEmpty }

    /// A check-in to upload (replaces a pending undo of the same leaf).
    public mutating func addDone(_ l: Leaf) {
        undo.removeAll { $0.day == l.day && $0.slot == l.slot }
        done.removeAll { $0.day == l.day && $0.slot == l.slot }
        done.append(l)
    }

    /// An undo to upload; a check-in that never left this Mac just disappears.
    public mutating func addUndo(day: String, slot: String) {
        let hadPendingDone = done.contains { $0.day == day && $0.slot == slot }
        done.removeAll { $0.day == day && $0.slot == slot }
        if !hadPendingDone, !undo.contains(where: { $0.day == day && $0.slot == slot }) { undo.append(Leaf(day: day, slot: slot)) }
    }
}
