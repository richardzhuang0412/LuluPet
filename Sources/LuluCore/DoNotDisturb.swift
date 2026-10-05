import Foundation

/// v0.8 勿扰模式 (docs/superpowers/specs/2026-09-28-visits-design.md §15). Pure rules; the app drives
/// the menu, the quiet pet, the queue and the presence field.

/// Why I don't want to be disturbed (shown above my pet and on the partner's side).
public enum DNDMood: String, CaseIterable, Sendable {
    case angry, busy, resting
    /// 🤐 不说原因 (the default): the partner only sees "勿扰".
    case unsaid

    public static let `default` = DNDMood.unsaid

    public var emoji: String {
        switch self {
        case .angry: return "😤"
        case .busy: return "💼"
        case .resting: return "😴"
        case .unsaid: return "🤐"
        }
    }

    /// Menu title: "😤 生气中" … "🤐 不说原因".
    public var title: String {
        switch self {
        case .angry: return "😤 生气中"
        case .busy: return "💼 忙碌中"
        case .resting: return "😴 休息中"
        case .unsaid: return "🤐 不说原因"
        }
    }

    /// What the partner is told, nil = no reason given.
    public var reason: String? { self == .unsaid ? nil : title }

    /// The little sign above my pet: the reason, or "🔕 勿扰中".
    public var sign: String { reason ?? "🔕 勿扰中" }
}

/// How long 勿扰 lasts.
public enum DNDDuration: String, CaseIterable, Sendable {
    case thirtyMinutes, oneHour, today, untilOff

    public var title: String {
        switch self {
        case .thirtyMinutes: return "30 分钟"
        case .oneHour: return "1 小时"
        case .today: return "今天之内"
        case .untilOff: return "直到我关掉"
        }
    }

    /// End time in Unix seconds; 0 = until turned off. `today` ends at the next local midnight.
    public func until(now: Double, calendar: Calendar = .current) -> Double {
        switch self {
        case .thirtyMinutes: return now + 30 * 60
        case .oneHour: return now + 60 * 60
        case .untilOff: return 0
        case .today:
            let date = Date(timeIntervalSince1970: now)
            let start = calendar.startOfDay(for: date)
            return (calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)).timeIntervalSince1970
        }
    }
}

/// 勿扰 as published in presence (`presence/<role>/dnd`): `{"mood": "angry", "until": epochMs | 0}`.
/// `mood` is kept as a string so a newer client's mood survives (shown without a reason).
public struct DNDStatus: Equatable, Sendable {
    public var mood: String
    /// Unix ms; 0 = until turned off.
    public var untilMs: Int64

    public init(mood: String, untilMs: Int64) {
        self.mood = mood
        self.untilMs = untilMs
    }

    public var knownMood: DNDMood? { DNDMood(rawValue: mood) }
    /// "😤 生气中", nil when no (known) reason.
    public var reason: String? { knownMood?.reason }

    public func isActive(nowMs: Int64) -> Bool { untilMs == 0 || nowMs < untilMs }

    /// JSON object for the presence PUT.
    public var json: [String: Any] { ["mood": mood, "until": untilMs] }

    /// Tolerant: needs an object; a missing / odd `mood` becomes "" (no reason), a missing `until` 0.
    public init?(json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        mood = WireLimits.clipped(d["mood"] as? String) ?? ""   // prelaunch-A: partner data, capped
        untilMs = (d["until"] as? NSNumber)?.int64Value ?? 0
    }
}

/// My own 勿扰 (persisted: `dndUntil` / `dndMood` / `dndSince`, see docs/upgrade-compat.md).
public struct DNDState: Equatable, Sendable {
    /// Unix seconds; 0 = until turned off; nil = off.
    public private(set) var until: Double?
    /// The chosen mood (kept while off: the menu's radio selection).
    public var mood: DNDMood
    /// Unix seconds it was turned on (for the history divider).
    public private(set) var since: Double?

    public init(until: Double? = nil, mood: DNDMood = .default, since: Double? = nil) {
        self.until = until
        self.mood = mood
        self.since = since
    }

    public func isOn(now: Double) -> Bool {
        guard let until else { return false }
        return until == 0 || now < until
    }

    /// When the housekeeping timer must fire to end a timed 勿扰: the stored end, independent of `isOn`
    /// (once the end passes `isOn` is false, but the span still has to be closed). nil = off / until turned off.
    public var endDeadline: Double? {
        guard let until, until > 0 else { return nil }
        return until
    }

    /// 开启 (or re-set the end time while on; the start stays).
    public mutating func turnOn(_ d: DNDDuration, now: Double, calendar: Calendar = .current) {
        if !isOn(now: now) { since = now }
        until = d.until(now: now, calendar: calendar)
    }

    /// 关闭 by hand. Returns the finished span (nil when it wasn't on).
    @discardableResult
    public mutating func turnOff(now: Double) -> DNDSpan? {
        guard let u = until else { return nil }
        let end = u == 0 ? now : min(now, u)
        let span = since.map { DNDSpan(startMs: Int64($0 * 1000), endMs: Int64(max($0, end) * 1000), mood: mood.rawValue) }
        until = nil
        since = nil
        return span
    }

    /// Ends a timed 勿扰 whose time is up (also after the Mac slept through it, or on launch).
    /// Returns the finished span when that happened.
    public mutating func expire(now: Double) -> DNDSpan? {
        guard let until, until > 0, now >= until else { return nil }
        return turnOff(now: until)
    }

    /// For presence: nil while off.
    public func status(now: Double) -> DNDStatus? {
        guard isOn(now: now), let until else { return nil }
        return DNDStatus(mood: mood.rawValue, untilMs: until == 0 ? 0 : Int64(until * 1000))
    }

    /// Menu: "关闭勿扰（15:10 结束）" / "关闭勿扰（手动关闭）" ("24:00" for 今天之内).
    public func offTitle(calendar: Calendar = .current) -> String {
        "关闭勿扰（\(endLabel(calendar: calendar))）"
    }

    /// Status line: "🔕 我勿扰中（😤 生气中 · 15:10 结束）".
    public func statusLine(calendar: Calendar = .current) -> String {
        "🔕 我勿扰中（\(mood.reason.map { "\($0) · " } ?? "")\(endLabel(calendar: calendar))）"
    }

    private func endLabel(calendar: Calendar) -> String {
        guard let until, until > 0 else { return "手动关闭" }
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: until))
        // Midnight (今天之内): "24:00" reads better than "00:00".
        let hh = c.hour == 0 && c.minute == 0 ? 24 : c.hour ?? 0
        return String(format: "%02d:%02d 结束", hh, c.minute ?? 0)
    }
}

/// A finished 勿扰 stretch, for the「记录」tab divider (`dndLog`, JSON array).
public struct DNDSpan: Codable, Equatable, Sendable {
    public var startMs: Int64
    public var endMs: Int64
    public var mood: String

    public init(startMs: Int64, endMs: Int64, mood: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.mood = mood
    }

    enum CodingKeys: String, CodingKey { case startMs = "start", endMs = "end", mood }

    /// "😤 勿扰中 14:05–15:10" (no reason: "🔕 勿扰中 …").
    public func label(calendar: Calendar = .current) -> String {
        let emoji = DNDMood(rawValue: mood).flatMap { $0 == .unsaid ? nil : $0.emoji } ?? "🔕"
        return "\(emoji) 勿扰中 \(HistoryTimeline.timeLabel(startMs, calendar: calendar))–\(HistoryTimeline.timeLabel(endMs, calendar: calendar))"
    }

    /// Log kept in UserDefaults: at most this many spans (oldest dropped).
    public static let maxLog = 500

    public static func appending(_ span: DNDSpan, to log: [DNDSpan]) -> [DNDSpan] {
        Array((log + [span]).suffix(maxLog))
    }
}

public enum DND {
    /// Partner's status line: "TA 勿扰中（😤 生气中）" / "TA 勿扰中".
    public static func partnerStatusLine(_ s: DNDStatus) -> String {
        s.reason.map { "TA 勿扰中（\($0)）" } ?? "TA 勿扰中"
    }

    /// Our pet is back from a partner in 勿扰 (everything was sent and is stored for them).
    public static func bounceLine(_ s: DNDStatus?) -> String {
        (s?.reason).map { "TA 开了勿扰（\($0)），先放在 TA 那儿啦" } ?? "TA 开了勿扰，先放在 TA 那儿啦"
    }

    /// 诚意清单 title when 勿扰 ends.
    public static func cardTitle(count: Int) -> String { "你勿扰的时候，TA 来找过你 \(count) 次～" }
}

/// What a send finds on the partner's side (v0.8): decides the trip (`PetLocation.planSend`).
public enum PartnerReach: Equatable, Sendable {
    case online
    /// Partner has 勿扰 on: our pet runs out, waits, comes back; everything is sent (pokes / visits too).
    case dnd(DNDStatus)
    case offline
    /// Never came online with this pair code.
    case notPaired

    public var isReachable: Bool { self == .online }
}

/// `presence/<role>` as read by v0.8: `{"lastSeen": ms, "dnd": {...}}`. Older clients write only
/// `{"lastSeen": ms}` (and read only `presence/<role>/lastSeen`), so `dnd` is additive.
public struct PresenceInfo: Equatable, Sendable {
    public var lastSeen: Int64?
    public var dnd: DNDStatus?
    /// v0.10: the partner is in a pomodoro focus round (`presence/<role>/focus`).
    public var focus: FocusStatus?
    /// v0.11: the character the partner draws (`presence/<role>/character`); nil = not published (older client).
    public var character: PetCharacter?
    /// v0.11: the partner's mode (`presence/<role>/mode`); nil = not published → treated as couple.
    public var mode: PairMode?
    /// v0.11: the partner machine's `deviceId` (`presence/<role>/device`); nil = older client.
    public var device: String?
    /// v0.11.2: the partner's app version (`presence/<role>/app`, e.g. "0.11.2"); nil = older client / not a bundle.
    public var app: String?
    /// v0.12: the city the partner set (`presence/<role>/place`, coordinates at two decimals); nil = none / older client.
    public var place: WeatherPlace?
    /// v0.14.2: the outfit the partner's pet wears (`presence/<role>/outfit`); nil = older client / not published.
    public var outfit: String?
    /// v0.14.2: what the partner's pet is doing on their desk (`presence/<role>/pose`); nil = not published; an
    /// unknown word reads as `.idle`.
    public var pose: PetPose?

    public init(lastSeen: Int64?, dnd: DNDStatus? = nil, focus: FocusStatus? = nil,
                character: PetCharacter? = nil, mode: PairMode? = nil, device: String? = nil, app: String? = nil,
                place: WeatherPlace? = nil, outfit: String? = nil, pose: PetPose? = nil) {
        self.lastSeen = lastSeen
        self.dnd = dnd
        self.focus = focus
        self.character = character
        self.mode = mode
        self.device = device
        self.app = app
        self.place = place
        self.outfit = outfit
        self.pose = pose
    }

    /// JSON body of `GET presence/<role>`: null → nil; an object → its fields; a bare number (never
    /// written by any version, tolerated) → lastSeen.
    public static func decode(_ data: Data) -> PresenceInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        if let n = obj as? NSNumber, !(obj is Bool) { return PresenceInfo(lastSeen: n.int64Value) }
        guard let d = obj as? [String: Any] else { return nil }
        return PresenceInfo(lastSeen: (d["lastSeen"] as? NSNumber)?.int64Value, dnd: DNDStatus(json: d["dnd"]),
                            focus: FocusStatus(json: d["focus"]),
                            character: (d["character"] as? String).flatMap(PetCharacter.init(rawValue:)),
                            mode: (d["mode"] as? String).flatMap(PairMode.init(rawValue:)),
                            device: WireLimits.clipped(d["device"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            app: WireLimits.clipped(d["app"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                            place: WeatherPlace(json: d["place"]),
                            outfit: PresenceLook.cleanOutfit(WireLimits.clipped(d["outfit"] as? String)),
                            pose: WireLimits.clipped(d["pose"] as? String).map(PetPose.init(raw:)))
    }

    /// Body of the presence PUT (heartbeat / sign-off).
    public static func payload(lastSeen: Int64, dnd: DNDStatus?, focus: FocusStatus? = nil,
                               character: PetCharacter? = nil, mode: PairMode? = nil, device: String? = nil,
                               app: String? = nil, place: WeatherPlace? = nil, look: PresenceLook? = nil) -> [String: Any] {
        var out: [String: Any] = ["lastSeen": lastSeen]
        if let dnd { out["dnd"] = dnd.json }
        if let focus { out["focus"] = focus.json }
        if let character { out["character"] = character.rawValue }
        if let mode { out["mode"] = mode.rawValue }
        if let device { out["device"] = device }
        if let app { out["app"] = app }
        if let place { out["place"] = place.json }
        if let outfit = PresenceLook.cleanOutfit(look?.outfit) { out["outfit"] = outfit }
        if let pose = look?.pose { out["pose"] = pose.raw }
        return out
    }
}

extension Presence {
    /// The send decision: not connected → offline (we can't know); never seen → not paired; 勿扰 on
    /// (even if their Mac is asleep: it is still on when they come back) → dnd; else online / offline.
    public static func reach(connected: Bool, info: PresenceInfo?, nowMs: Int64,
                             thresholdMs: Int64 = Presence.thresholdMs) -> PartnerReach {
        guard connected else { return .offline }
        guard let info, info.lastSeen != nil || info.dnd != nil else { return .notPaired }
        if let d = info.dnd, d.isActive(nowMs: nowMs) { return .dnd(d) }
        return isOnline(lastSeen: info.lastSeen, now: nowMs, thresholdMs: thresholdMs) ? .online : .offline
    }
}
