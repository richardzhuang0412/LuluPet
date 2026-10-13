import Foundation

/// v0.18 眼药水提醒 (docs/superpowers/specs/2026-10-12-eyedrops-and-web-v2.md §2). Pure rules; the app (Mac:
/// `EyeDropsController`, web: `web/js/core/eyedrops.js`, its twin) stores, syncs and shows. Shared vectors:
/// web/tests/vectors/wire.json `eyedrops` (checked by WebVectors.swift and by node).
///
/// Remote node `/pairs/{code}/tools/{seat}/eyedrops`:
///
///     {"settings": {"enabled", "times": ["08:00", …], "notify", "at": ms, "device"},
///      "days": {"2026-10-12": {"0800": {"done": ms, "device"}, …}}}
///
/// All instants are Unix milliseconds; a slot's day is the local date it belongs to in `tz` (the device's zone).

/// Settings, last writer (`at`) wins.
public struct EyeDropsSettings: Equatable, Sendable {
    public var enabled: Bool
    /// "HH:mm", sorted, deduplicated, at most `EyeDrops.maxSlots`.
    public var times: [String]
    /// Also post a system notification.
    public var notify: Bool
    /// When these settings were made (Unix ms).
    public var at: Int64
    /// Which device made them.
    public var device: String

    public init(enabled: Bool = false, times: [String] = [], notify: Bool = false, at: Int64 = 0, device: String = "") {
        self.enabled = enabled
        self.times = times
        self.notify = notify
        self.at = at
        self.device = device
    }

    /// Tolerant: not an object → nil; `enabled` / `notify` only a JSON `true` counts; bad times skipped.
    public init?(json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        enabled = EyeDrops.isTrue(d["enabled"])
        times = EyeDrops.normalizeTimes(d["times"] as? [Any] ?? [])
        notify = EyeDrops.isTrue(d["notify"])
        at = EyeDrops.int64(d["at"]) ?? 0
        device = (d["device"] as? String).map { WireLimits.clipUTF16($0, max: 64) } ?? ""
    }

    /// Body of `PUT …/eyedrops/settings.json`.
    public var json: [String: Any] { ["enabled": enabled, "times": times, "notify": notify, "at": at, "device": device] }
}

/// One check-in (`days/{day}/{HHmm}`).
public struct EyeDropsMark: Equatable, Sendable {
    public var done: Int64
    public var device: String

    public init(done: Int64, device: String) {
        self.done = done
        self.device = device
    }

    /// Needs a numeric `done`; `device` clipped to 64 (missing → "").
    public init?(json: Any?) {
        guard let d = json as? [String: Any], let done = EyeDrops.int64(d["done"]) else { return nil }
        self.done = done
        device = (d["device"] as? String).map { WireLimits.clipUTF16($0, max: 64) } ?? ""
    }

    public var json: [String: Any] { ["done": done, "device": device] }
}

/// day ("yyyy-MM-dd") → slot key ("HHmm") → check-in.
public typealias EyeDropsDays = [String: [String: EyeDropsMark]]

/// This device's reminder in progress (only one at a time). UserDefaults `eyedropsNag`.
public struct EyeDropsNag: Equatable, Sendable {
    /// "2026-10-12/1400".
    public var slot: String
    /// How many times it was shown (1…3).
    public var shown: Int
    /// Next show not before this (Unix ms).
    public var next: Int64

    public init(slot: String, shown: Int, next: Int64) {
        self.slot = slot
        self.shown = shown
        self.next = next
    }

    /// Tolerant read; `next` is clamped to ≤ now + 15 min (a clock set back never holds the reminder for long).
    public init?(json: Any?, nowMs: Int64) {
        guard let d = json as? [String: Any], let slot = d["slot"] as? String, EyeDrops.parseSlotId(slot) != nil,
              let shown = EyeDrops.int64(d["shown"]), let next = EyeDrops.int64(d["next"]) else { return nil }
        self.slot = slot
        self.shown = Int(min(Int64(EyeDrops.maxShows), max(0, shown)))
        self.next = min(next, nowMs + EyeDrops.nagEveryMs)
    }

    public var json: [String: Any] { ["slot": slot, "shown": shown, "next": next] }
}

public struct EyeDropsPlan: Equatable, Sendable {
    public enum Action: String, Sendable { case none, show, wait }
    public var action: Action
    /// The slot id ("2026-10-12/1400") for show / wait; nil for none.
    public var slot: String?
    /// When to run `plan` again (Unix ms).
    public var nextWakeMs: Int64

    public init(action: Action, slot: String?, nextWakeMs: Int64) {
        self.action = action
        self.slot = slot
        self.nextWakeMs = nextWakeMs
    }
}

public struct EyeDropsProgress: Equatable, Sendable {
    public enum State: String, Sendable { case done, showing, upcoming, missed, unconfirmed }
    public struct Slot: Equatable, Sendable {
        public var time: String
        public var state: State
        /// Who checked in (only for `.done`).
        public var device: String?

        public init(time: String, state: State, device: String? = nil) {
            self.time = time
            self.state = state
            self.device = device
        }
    }
    public var done: Int
    public var total: Int
    public var slots: [Slot]

    public init(done: Int, total: Int, slots: [Slot]) {
        self.done = done
        self.total = total
        self.slots = slots
    }

    /// Menu / title: 「👁️ 2/4」, or 「👁️ 该滴了」 while a slot is showing; "" without slots.
    public var badge: String {
        guard total > 0 else { return "" }
        return slots.contains { $0.state == .showing } ? "👁️ 该滴了" : "👁️ \(done)/\(total)"
    }
}

public struct EyeDropsValidation: Equatable, Sendable {
    public var ok: Bool
    public var times: [String]
    public var error: String?
}

public struct EyeDropsBubble: Equatable, Sendable {
    public var header: String
    public var line: String
    public var done: String
    public var later: String
}

public enum EyeDrops {
    public static let maxSlots = 8
    /// Two times at least this many minutes apart (checked when setting).
    public static let minGapMin = 30
    /// Ask again after this long (「等会儿」 / ignored).
    public static let nagEveryMs: Int64 = 900_000
    /// Shown at most this many times per slot (minutes 0, 15, 30).
    public static let maxShows = 3
    /// A slot never shown within this long after its time is missed.
    public static let catchUpMs: Int64 = 7_200_000
    /// Mac: idle this long = away (no show, poll each minute).
    public static let activeIdleS: TimeInterval = 300
    public static let inactivePollMs: Int64 = 60_000
    /// Longest sleep `plan` asks for.
    public static let maxWakeMs: Int64 = 86_400_000

    public static let header = "👁️💧 眼药水"
    public static let buttonDone = "滴了 ✓"
    public static let buttonLater = "等会儿"

    public enum Errors {
        public static let format = "时间格式不对"
        public static let empty = "至少要设一个时间"
        public static let tooMany = "一天最多 8 次"
        public static let gap = "相邻两次至少隔 30 分钟"
    }

    // MARK: JSON helpers (same tolerance as the JS twin)

    static func isBool(_ v: Any?) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func isTrue(_ v: Any?) -> Bool { isBool(v) && (v as! NSNumber).boolValue }

    /// A finite JSON number (not a bool), truncated toward zero.
    static func int64(_ v: Any?) -> Int64? {
        guard let n = v as? NSNumber, !isBool(v) else { return nil }
        let d = n.doubleValue
        guard d.isFinite, abs(d) < 9.0e18 else { return nil }
        return n.objCType.pointee == 0x64 || n.objCType.pointee == 0x66 ? Int64(d.rounded(.towardZero)) : n.int64Value
    }

    // MARK: Times

    private static func twoDigits(_ s: Substring) -> Int? {
        let u = Array(s.utf8)
        guard u.count == 2, (48...57).contains(u[0]), (48...57).contains(u[1]) else { return nil }
        return Int(u[0] - 48) * 10 + Int(u[1] - 48)
    }

    /// "HH:mm" (24 h, two digits each) → minutes after midnight.
    public static func parseTime(_ t: String) -> Int? {
        let parts = t.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let h = twoDigits(parts[0]), let m = twoDigits(parts[1]), h < 24, m < 60 else { return nil }
        return h * 60 + m
    }

    public static func formatTime(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// 1 → 09:00; 2 → 09 21; 3 → 08 14 20; 4 → 08 12 16 20; 5–8 → 08:00…22:00 evenly, rounded to 30 minutes.
    public static func suggestedTimes(_ n: Int) -> [String] {
        let k = min(maxSlots, max(1, n))
        switch k {
        case 1: return ["09:00"]
        case 2: return ["09:00", "21:00"]
        case 3: return ["08:00", "14:00", "20:00"]
        case 4: return ["08:00", "12:00", "16:00", "20:00"]
        default:
            let step = Double(22 * 60 - 8 * 60) / Double(k - 1)
            return (0..<k).map { formatTime(8 * 60 + Int((Double($0) * step / 30).rounded()) * 30) }
        }
    }

    /// Settings check. Errors in this order: format, empty, too many, gap < 30 min. `times` comes back sorted.
    public static func validateTimes(_ times: [String]) -> EyeDropsValidation {
        let mins = times.map(parseTime)
        let sorted = mins.compactMap { $0 }.sorted().map(formatTime)
        func fail(_ e: String) -> EyeDropsValidation { EyeDropsValidation(ok: false, times: sorted, error: e) }
        if mins.contains(where: { $0 == nil }) { return fail(Errors.format) }
        if sorted.isEmpty { return fail(Errors.empty) }
        if sorted.count > maxSlots { return fail(Errors.tooMany) }
        let m = sorted.compactMap(parseTime)
        for i in 1..<max(1, m.count) where m[i] - m[i - 1] < minGapMin { return fail(Errors.gap) }
        return EyeDropsValidation(ok: true, times: sorted, error: nil)
    }

    /// Valid times only, deduplicated, sorted, at most 8.
    public static func normalizeTimes(_ raw: [Any]) -> [String] {
        let mins = Set(raw.compactMap { ($0 as? String).flatMap(parseTime) })
        return Array(mins.sorted().prefix(maxSlots)).map(formatTime)
    }

    /// "08:00" → "0800".
    public static func slotKey(_ time: String) -> String? {
        guard parseTime(time) != nil else { return nil }
        return String(time.prefix(2)) + String(time.suffix(2))
    }

    /// "0800" → "08:00".
    public static func slotTime(_ key: String) -> String? {
        guard key.utf8.count == 4 else { return nil }
        let t = String(key.prefix(2)) + ":" + String(key.suffix(2))
        return parseTime(t) != nil ? t : nil
    }

    /// "2026-10-12" + "14:00" → "2026-10-12/1400".
    public static func slotId(day: String, time: String) -> String { "\(day)/\(slotKey(time) ?? "")" }

    public static func parseSlotId(_ id: String) -> (day: String, key: String, time: String)? {
        let p = id.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count == 2, LocalClock.parseDay(String(p[0])) != nil, let time = slotTime(String(p[1])) else { return nil }
        return (String(p[0]), String(p[1]), time)
    }

    /// Local date "yyyy-MM-dd" of `ms` in `tz`.
    public static func dayKey(_ ms: Int64, tz: TimeZone) -> String { LocalClock.dayString(ms, tz: tz) }

    /// The instant of `time` on local `day` (a skipped time → the jump; a repeated time → its first occurrence).
    public static func slotInstant(day: String, time: String, tz: TimeZone) -> Int64? {
        guard let d = LocalClock.parseDay(day), let m = parseTime(time) else { return nil }
        return LocalClock.localToMs(year: d.year, month: d.month, day: d.day, hour: m / 60, minute: m % 60, tz: tz)
    }

    // MARK: Decoding

    public static func decodeDays(json: Any?) -> EyeDropsDays {
        guard let d = json as? [String: Any] else { return [:] }
        var out: EyeDropsDays = [:]
        for (day, v) in d where LocalClock.parseDay(day) != nil {
            guard let rec = v as? [String: Any] else { continue }
            var marks: [String: EyeDropsMark] = [:]
            for (key, leaf) in rec where slotTime(key) != nil {
                if let m = EyeDropsMark(json: leaf) { marks[key] = m }
            }
            if !marks.isEmpty { out[day] = marks }
        }
        return out
    }

    /// The whole node → settings (nil when absent / bad) and days.
    public static func decode(json: Any?) -> (settings: EyeDropsSettings?, days: EyeDropsDays) {
        let d = json as? [String: Any]
        return (EyeDropsSettings(json: d?["settings"]), decodeDays(json: d?["days"]))
    }

    public static func daysJSON(_ days: EyeDropsDays) -> [String: Any] { days.mapValues { $0.mapValues(\.json) } }

    /// Newer `at` wins; a tie keeps `local`.
    public static func mergeSettings(local: EyeDropsSettings?, remote: EyeDropsSettings?) -> EyeDropsSettings? {
        guard let remote else { return local }
        guard let local else { return remote }
        return remote.at > local.at ? remote : local
    }

    // MARK: Planning

    struct Candidate {
        var day: String, time: String, key: String, id: String, inst: Int64
    }

    static func slots(on day: String, times: [String], tz: TimeZone) -> [Candidate] {
        times.compactMap { t in
            guard let key = slotKey(t), let inst = slotInstant(day: day, time: t, tz: tz) else { return nil }
            return Candidate(day: day, time: t, key: key, id: "\(day)/\(key)", inst: inst)
        }
    }

    /// A slot that had already passed when the settings were changed that same day is not caught up.
    static func counts(_ c: Candidate, _ s: EyeDropsSettings, tz: TimeZone) -> Bool {
        !(dayKey(s.at, tz: tz) == c.day && c.inst < s.at)
    }

    static func nextSlot(after now: Int64, times: [String], tz: TimeZone) -> Int64 {
        let today = dayKey(now, tz: tz)
        let later = (slots(on: today, times: times, tz: tz) + slots(on: LocalClock.addDays(today, 1) ?? today, times: times, tz: tz))
            .map(\.inst).filter { $0 > now }
        return min(now + maxWakeMs, later.min() ?? Int64.max)
    }

    static func currentSlot(_ s: EyeDropsSettings, now: Int64, tz: TimeZone, catchUpMs: Int64 = EyeDrops.catchUpMs) -> Candidate? {
        let today = dayKey(now, tz: tz)
        let all = slots(on: LocalClock.addDays(today, -1) ?? today, times: s.times, tz: tz) + slots(on: today, times: s.times, tz: tz)
        var best: Candidate?
        for c in all where c.inst <= now && now < c.inst + catchUpMs && counts(c, s, tz: tz) {
            if best == nil || c.inst >= best!.inst { best = c }
        }
        return best
    }

    /// What to do now (spec §2.4). Only the newest arrived slot inside its 2 h window is nagged (an older one still
    /// nagging is superseded); it is skipped once checked in (`today` = the days map, today and yesterday) or shown 3
    /// times; it waits for `nag.next`, or polls each minute while the user is away; otherwise it shows.
    /// `nagMs` / `catchUp` override `nagEveryMs` / `catchUpMs` (only the Mac's hidden test flags pass them).
    public static func plan(settings: EyeDropsSettings?, today: EyeDropsDays, nag: EyeDropsNag?, now: Int64, active: Bool,
                            tz: TimeZone, nagMs: Int64 = EyeDrops.nagEveryMs, catchUp: Int64 = EyeDrops.catchUpMs) -> EyeDropsPlan {
        let times = settings?.enabled == true ? settings!.times : []
        guard let settings, !times.isEmpty else {
            return EyeDropsPlan(action: .none, slot: nil, nextWakeMs: nextSlot(after: now, times: settings?.times ?? [], tz: tz))
        }
        let next = nextSlot(after: now, times: times, tz: tz)
        guard let s = currentSlot(settings, now: now, tz: tz, catchUpMs: catchUp) else { return EyeDropsPlan(action: .none, slot: nil, nextWakeMs: next) }
        let mine = nag?.slot == s.id ? nag : nil
        if today[s.day]?[s.key] != nil || (mine?.shown ?? 0) >= maxShows {
            return EyeDropsPlan(action: .none, slot: nil, nextWakeMs: next)
        }
        if let m = mine {
            let nagNext = min(m.next, now + nagMs)
            if nagNext > now { return EyeDropsPlan(action: .wait, slot: s.id, nextWakeMs: min(nagNext, next)) }
        }
        if !active { return EyeDropsPlan(action: .wait, slot: s.id, nextWakeMs: min(now + inactivePollMs, next)) }
        return EyeDropsPlan(action: .show, slot: s.id, nextWakeMs: min(now + nagMs, next))
    }

    /// The nag after showing `slot` (another slot's nag is replaced).
    public static func afterShow(_ nag: EyeDropsNag?, slot: String, now: Int64, nagMs: Int64 = EyeDrops.nagEveryMs) -> EyeDropsNag {
        EyeDropsNag(slot: slot, shown: (nag?.slot == slot ? nag!.shown : 0) + 1, next: now + nagMs)
    }

    /// 「滴了」: no nag any more.
    public static func afterDone(_ nag: EyeDropsNag?) -> EyeDropsNag? { nil }

    /// Today's card. States: done (+ device), upcoming, showing (the current slot: due / nagged), unconfirmed (nagged
    /// 3 times, or an older nagged slot that was superseded), missed (passed without a reminder).
    public static func progress(settings: EyeDropsSettings?, today: EyeDropsDays, now: Int64, tz: TimeZone,
                                nag: EyeDropsNag? = nil, catchUp: Int64 = EyeDrops.catchUpMs) -> EyeDropsProgress {
        guard let settings else { return EyeDropsProgress(done: 0, total: 0, slots: []) }
        let day = dayKey(now, tz: tz)
        let rec = today[day] ?? [:]
        let list = slots(on: day, times: settings.times, tz: tz)
        let latest = list.lastIndex { $0.inst <= now }
        var done = 0
        let out: [EyeDropsProgress.Slot] = list.enumerated().map { i, c in
            if let mark = rec[c.key] {
                done += 1
                return .init(time: c.time, state: .done, device: mark.device)
            }
            if c.inst > now { return .init(time: c.time, state: .upcoming, device: nil) }
            let nagged = nag?.slot == c.id ? nag : nil
            if settings.enabled, i == latest, now < c.inst + catchUp, counts(c, settings, tz: tz) {
                let over = nagged.map { $0.shown >= maxShows && now >= $0.next } ?? false
                return .init(time: c.time, state: over ? .unconfirmed : .showing, device: nil)
            }
            return .init(time: c.time, state: (nagged?.shown ?? 0) >= 1 ? .unconfirmed : .missed, device: nil)
        }
        return EyeDropsProgress(done: done, total: list.count, slots: out)
    }

    /// The pet bubble: 「该滴眼药水啦（14:00 · 今天第 3 次）」 (`slot` = slot id or "HH:mm"; `index` 1-based of `total`).
    public static func bubbleCopy(slot: String, index: Int, total: Int) -> EyeDropsBubble {
        let time = parseSlotId(slot)?.time ?? (parseTime(slot) != nil ? slot : "")
        return EyeDropsBubble(header: header, line: "该滴眼药水啦（\(time) · 今天第 \(index) 次）", done: buttonDone, later: buttonLater)
    }
}

/// Wall-clock arithmetic with `TimeZone.secondsFromGMT(for:)` only (no `Calendar`), so it matches the web twin
/// (`web/js/core/tz.js`) exactly: a skipped local time maps to the jump, a repeated one to its first occurrence.
public enum LocalClock {
    static let dayMs: Int64 = 86_400_000

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 { a >= 0 ? a / b : -((-a + b - 1) / b) }

    /// Offset of `tz` at `ms` (local = UTC + offset), in ms.
    public static func offsetMs(_ ms: Int64, tz: TimeZone) -> Int64 {
        let secs = floorDiv(ms, 1000)
        return Int64(tz.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(secs)))) * 1000
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (H. Hinnant's algorithm).
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int64 {
        let y = Int64(m <= 2 ? y0 - 1 : y0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = Int64((m + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ z0: Int64) -> (year: Int, month: Int, day: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (Int(yoe + era * 400 + (m <= 2 ? 1 : 0)), Int(m), Int(d))
    }

    static func utcMs(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int64 {
        daysFromCivil(y, mo, d) * dayMs + Int64(h) * 3_600_000 + Int64(mi) * 60_000
    }

    /// Local fields of `ms` in `tz`.
    public static func parts(_ ms: Int64, tz: TimeZone) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int) {
        let local = floorDiv(ms, 1000) * 1000 + offsetMs(ms, tz: tz)
        let days = floorDiv(local, dayMs)
        let c = civilFromDays(days)
        let rest = local - days * dayMs
        return (c.year, c.month, c.day, Int(rest / 3_600_000), Int(rest % 3_600_000 / 60_000))
    }

    /// The instant of local `y-mo-d h:mi` in `tz`.
    public static func localToMs(year y: Int, month mo: Int, day d: Int, hour h: Int, minute mi: Int, tz: TimeZone) -> Int64 {
        let naive = utcMs(y, mo, d, h, mi)
        var offsets: [Int64] = []
        for o in [offsetMs(naive - dayMs, tz: tz), offsetMs(naive, tz: tz), offsetMs(naive + dayMs, tz: tz)] where !offsets.contains(o) {
            offsets.append(o)
        }
        let valid = offsets.map { naive - $0 }.filter { offsetMs($0, tz: tz) == naive - $0 }
        if let first = valid.min() { return first }
        var lo = naive - offsets.max()!, hi = naive - offsets.min()!
        let before = offsetMs(lo, tz: tz)
        while hi - lo > 60_000 {
            let mid = lo + max(1, (hi - lo) / 120_000) * 60_000
            if offsetMs(mid, tz: tz) == before { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// "yyyy-MM-dd" of `ms` in `tz`.
    public static func dayString(_ ms: Int64, tz: TimeZone) -> String {
        let p = parts(ms, tz: tz)
        return String(format: "%04d-%02d-%02d", p.year, p.month, p.day)
    }

    /// "yyyy-MM-dd" → fields; nil when malformed or not a real date.
    public static func parseDay(_ s: String) -> (year: Int, month: Int, day: Int)? {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == 45, u[7] == 45,
              [0, 1, 2, 3, 5, 6, 8, 9].allSatisfy({ (48...57).contains(u[$0]) }) else { return nil }
        let num = { (r: [Int]) in r.reduce(0) { $0 * 10 + Int(u[$1] - 48) } }
        let y = num([0, 1, 2, 3]), m = num([5, 6]), d = num([8, 9])
        let c = civilFromDays(daysFromCivil(y, m, d))
        guard m >= 1, m <= 12, c.year == y, c.month == m, c.day == d else { return nil }
        return (y, m, d)
    }

    /// Calendar arithmetic on "yyyy-MM-dd".
    public static func addDays(_ day: String, _ n: Int) -> String? {
        guard let p = parseDay(day) else { return nil }
        let c = civilFromDays(daysFromCivil(p.year, p.month, p.day) + Int64(n))
        return String(format: "%04d-%02d-%02d", c.year, c.month, c.day)
    }

    /// Whole days from `a` to `b`.
    public static func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let p = parseDay(a), let q = parseDay(b) else { return nil }
        return Int(daysFromCivil(q.year, q.month, q.day) - daysFromCivil(p.year, p.month, p.day))
    }
}
