import Foundation

/// v0.14.4: TA's answer to 「叫 TA 喝水 / 起来动动」 comes back — 马上 (`now`), 等会儿 (`later`), or 「后来做到了」
/// (`now` + `late`). Pure rules, tested in LuluCoreTests.
///
/// Wire encoding (docs/upgrade-compat.md §6):
/// - `now`:   `{kind:"remind", remind:"water", ackOf:<id>, answer:"now"}` — identical to a v0.10 receipt plus `answer`,
///            so older clients show 「TA 喝啦」, which is true.
/// - `later`: `{kind:"remind", remind:"water.later", ackOf:<id>, answer:"later"}` — the `remind` value is deliberately
///            NOT a `ReminderKind`, so older clients (v0.10–v0.14.3: `isRemindAck(m) && m.remind != nil`) never treat
///            it as 「TA 喝啦」: no receipt bubble, no cup line; only a bubble-less visitor + 「［新版本消息］」 history line.
/// - late:    a `now` reply with `late: true` (older clients: 「TA 喝啦」, true as well).
public struct RemindReply: Equatable, Sendable {
    public enum Answer: String, Sendable { case now, later }

    public var kind: ReminderKind
    public var answer: Answer
    /// True = done after first answering 等会儿.
    public var late: Bool

    public init(kind: ReminderKind, answer: Answer, late: Bool = false) {
        self.kind = kind
        self.answer = answer
        self.late = late && answer == .now
    }

    /// Suffix on the wire `remind` value of a 「等会儿」 reply.
    public static let laterSuffix = ".later"
    /// 「等会儿」 → a snooze counts as the cause of a re-reminder for this long.
    public static let lateWindow: TimeInterval = 2 * 3600

    /// The wire `remind` value.
    public var wireRemind: String { answer == .later ? kind.rawValue + Self.laterSuffix : kind.rawValue }

    /// The reply message answering reminder `ackOf`.
    public func message(from: Role, ackOf: String, ts: Int64 = nowMs()) -> Message {
        var m = Message(from: from, kind: .remind, ts: ts, ackOf: ackOf)
        m.remindRaw = wireRemind
        m.answer = answer.rawValue
        m.late = late ? true : nil
        return m
    }

    /// Reads a `remind` message with `ackOf` as a reply (nil = not a reply / unknown remind value).
    /// A receipt without `answer` (v0.10–v0.14.3) is a plain `now`.
    public static func decode(_ m: Message) -> RemindReply? {
        guard m.kind == .remind, m.ackOf != nil, let raw = m.remindRaw else { return nil }
        if raw.hasSuffix(laterSuffix) {
            guard let kind = ReminderKind(rawValue: String(raw.dropLast(laterSuffix.count))) else { return nil }
            return RemindReply(kind: kind, answer: .later)
        }
        guard let kind = ReminderKind(rawValue: raw) else { return nil }
        let answer = m.answer.flatMap(Answer.init(rawValue:)) ?? .now
        return RemindReply(kind: kind, answer: answer == .later ? .now : answer, late: m.late ?? false)
    }

    /// The line on my side (return toast / home bubble).
    public var line: String {
        switch (kind, answer, late) {
        case (.water, _, true): return "TA 终于喝啦 💧"
        case (.stand, _, true): return "TA 终于起来动啦"
        case (.water, .now, _): return "TA 说马上喝 💧"
        case (.stand, .now, _): return "TA 说马上起来动动"
        case (.water, .later, _): return "TA 说等会儿再喝 ⏰"
        case (.stand, .later, _): return "TA 说等会儿再动"
        }
    }

    /// A 「喝了 / 好的」 on a local re-reminder counts as 「后来做到了」 when the partner-remind snooze that caused it
    /// is at most `lateWindow` old.
    public static func isWithinLateWindow(snoozedAt: TimeInterval, now: TimeInterval) -> Bool {
        let d = now - snoozedAt
        return d >= 0 && d <= lateWindow
    }

    /// History line (`icon text`, icon one character), nil for a plain `now` (the v0.10 lines stay).
    public func historyLine(fromMe: Bool) -> String? {
        let icon = kind == .water ? "💧" : "🧍"
        if late { return icon + " " + (fromMe ? (kind == .water ? "你终于喝啦" : "你终于起来动啦") : (kind == .water ? "TA 终于喝啦" : "TA 终于起来动啦")) }
        if answer == .later { return "⏰ " + (fromMe ? "你说等会儿" : "TA 说等会儿") }
        return nil
    }
}

/// Which partner reminder a local 「等会儿」 answered, and when (Unix seconds).
public struct RemindSnoozeOrigin: Codable, Equatable, Sendable {
    public var ackOf: String
    public var at: TimeInterval
    public init(ackOf: String, at: TimeInterval) { self.ackOf = ackOf; self.at = at }
}
