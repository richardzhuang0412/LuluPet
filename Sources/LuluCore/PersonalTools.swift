import Foundation

/// v0.10 personal tools (docs/superpowers/specs/2026-10-04-personal-tools-design.md): pomodoro, water /
/// stand reminders, today's water cups. Pure rules; the app drives timers (via `HousekeepingTask`), bubbles
/// and the pet. All persisted types decode tolerantly (missing keys = defaults) so later versions can add fields.

// MARK: - Pomodoro

public struct PomodoroConfig: Codable, Equatable, Sendable {
    public var focus: TimeInterval = 1500, shortBreak: TimeInterval = 300, longBreak: TimeInterval = 900
    /// A long break after this many focus rounds.
    public var roundsPerLong: Int = 4

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PomodoroConfig()
        focus = try c.decodeIfPresent(TimeInterval.self, forKey: .focus) ?? d.focus
        shortBreak = try c.decodeIfPresent(TimeInterval.self, forKey: .shortBreak) ?? d.shortBreak
        longBreak = try c.decodeIfPresent(TimeInterval.self, forKey: .longBreak) ?? d.longBreak
        roundsPerLong = max(1, try c.decodeIfPresent(Int.self, forKey: .roundsPerLong) ?? d.roundsPerLong)
    }
}

public enum PomodoroPhase: String, Codable, Sendable { case idle, focus, shortBreak, longBreak }

public enum PomodoroEvent: Equatable, Sendable { case focusDone(next: PomodoroPhase), breakDone }

/// What the partner sees while I focus (`presence/<role>/focus`): `{"phase": "focus", "until": epochMs}`.
public struct FocusStatus: Codable, Equatable, Sendable {
    public var phase: String
    /// Unix milliseconds (same unit as `DNDStatus.untilMs`).
    public var until: Int64

    public init(phase: String = "focus", until: Int64) {
        self.phase = phase
        self.until = until
    }

    /// Minutes left, rounded up, at least 1.
    public func minutesLeft(nowMs: Int64) -> Int {
        let ms = max(0, until - nowMs)
        return max(1, Int((ms + 59_999) / 60_000))
    }

    public func isActive(nowMs: Int64) -> Bool { nowMs < until }

    /// JSON object for the presence PUT.
    public var json: [String: Any] { ["phase": phase, "until": until] }

    /// Tolerant: needs an object with a numeric `until`; a missing `phase` reads as "focus".
    public init?(json: Any?) {
        guard let d = json as? [String: Any], let u = d["until"] as? NSNumber else { return nil }
        phase = d["phase"] as? String ?? "focus"
        until = u.int64Value
    }
}

public struct PomodoroState: Codable, Equatable, Sendable {
    public var phase: PomodoroPhase
    /// Unix seconds the phase ends; nil while paused (or idle).
    public var until: TimeInterval?
    /// Seconds left, only while paused.
    public var pausedRemaining: TimeInterval?
    /// Focus rounds finished since the last long break (decides the next break length).
    public var completedFocus: Int

    public static let idle = PomodoroState(phase: .idle, until: nil, pausedRemaining: nil, completedFocus: 0)

    public init(phase: PomodoroPhase, until: TimeInterval? = nil, pausedRemaining: TimeInterval? = nil, completedFocus: Int = 0) {
        self.phase = phase
        self.until = until
        self.pausedRemaining = pausedRemaining
        self.completedFocus = completedFocus
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = (try? c.decodeIfPresent(PomodoroPhase.self, forKey: .phase)) ?? .idle
        until = try? c.decodeIfPresent(TimeInterval.self, forKey: .until)
        pausedRemaining = try? c.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        completedFocus = (try? c.decodeIfPresent(Int.self, forKey: .completedFocus)) ?? 0
        // B13: a running phase with neither a deadline nor a paused remainder is corrupt (it would focus forever): idle.
        if phase != .idle, until == nil, pausedRemaining == nil { self = .idle }
    }

    /// B17: a phase that ended more than `grace` seconds ago (the app was off / the Mac slept) is moved on silently
    /// at launch instead of celebrating it with a 「专注完成」 bubble. False while paused / idle / not yet due.
    public func endedLongAgo(now: TimeInterval, grace: TimeInterval = PomodoroState.launchGrace) -> Bool {
        guard phase != .idle, let until, now >= until else { return false }
        return now - until > grace
    }

    /// How late a phase end may be and still be announced at launch.
    public static let launchGrace: TimeInterval = 600

    public var isPaused: Bool { phase != .idle && until == nil && pausedRemaining != nil }

    /// Seconds left in the running / paused phase; nil when idle.
    public func remaining(now: TimeInterval) -> TimeInterval? {
        guard phase != .idle else { return nil }
        if let pausedRemaining, until == nil { return pausedRemaining }
        return until.map { max(0, $0 - now) }
    }

    /// Starts a focus round (also restarts one in progress; the round count is kept).
    public mutating func start(now: TimeInterval, config: PomodoroConfig) {
        if phase == .longBreak { completedFocus = 0 }
        phase = .focus
        until = now + config.focus
        pausedRemaining = nil
    }

    public mutating func pause(now: TimeInterval) {
        guard phase != .idle, !isPaused, let until else { return }
        pausedRemaining = max(0, until - now)
        self.until = nil
    }

    public mutating func resume(now: TimeInterval) {
        guard isPaused, let left = pausedRemaining else { return }
        until = now + left
        pausedRemaining = nil
    }

    /// Back to idle; the round count restarts.
    public mutating func stop() { self = .idle }

    /// Skip a break: idle until the user starts the next round.
    public mutating func skipBreak() {
        guard phase == .shortBreak || phase == .longBreak else { return }
        endBreak()
    }

    private mutating func endBreak() {
        if phase == .longBreak { completedFocus = 0 }
        phase = .idle
        until = nil
        pausedRemaining = nil
    }

    /// Moves on when the phase is over: focus → short / long break (`.focusDone`), break → idle (`.breakDone`).
    /// Nothing when it isn't due, paused or idle. Several phases missed during sleep advance ONE step; the
    /// next phase counts from `now`.
    public mutating func advance(now: TimeInterval, config: PomodoroConfig) -> PomodoroEvent? {
        guard phase != .idle, let until, now >= until else { return nil }
        switch phase {
        case .focus:
            completedFocus += 1
            let next: PomodoroPhase = completedFocus >= config.roundsPerLong ? .longBreak : .shortBreak
            phase = next
            self.until = now + (next == .longBreak ? config.longBreak : config.shortBreak)
            return .focusDone(next: next)
        case .shortBreak, .longBreak:
            endBreak()
            return .breakDone
        case .idle:
            return nil
        }
    }

    /// Shared with the partner: only while focusing and not paused.
    public var focusStatus: FocusStatus? {
        guard phase == .focus, let until else { return nil }
        return FocusStatus(phase: "focus", until: Int64((until * 1000).rounded()))
    }
}

// MARK: - Water / stand reminders

public enum ReminderKind: String, Codable, Sendable, CaseIterable { case water, stand }

/// Reminds after `interval` seconds of ACTIVE computer time (idle >= `awayThreshold` resets it).
public struct ActiveTimeReminder: Codable, Equatable, Sendable {
    public var interval: TimeInterval
    public var activeSeconds: TimeInterval
    /// Unix seconds of the previous tick.
    public var lastTick: TimeInterval?
    public var snoozeUntil: TimeInterval?
    /// The bubble is on screen: don't pop another.
    public var showing: Bool

    public static let awayThreshold: TimeInterval = 300
    public static let snoozeDelay: TimeInterval = 600
    /// Extra time beyond `awayThreshold` between two ticks before the gap counts as sleep.
    public static let sleepSlack: TimeInterval = 120

    public init(interval: TimeInterval) {
        self.interval = interval
        activeSeconds = 0
        lastTick = nil
        snoozeUntil = nil
        showing = false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .interval)) ?? 3600
        activeSeconds = (try? c.decodeIfPresent(TimeInterval.self, forKey: .activeSeconds)) ?? 0
        lastTick = try? c.decodeIfPresent(TimeInterval.self, forKey: .lastTick)
        snoozeUntil = try? c.decodeIfPresent(TimeInterval.self, forKey: .snoozeUntil)
        showing = (try? c.decodeIfPresent(Bool.self, forKey: .showing)) ?? false
    }

    /// Adds the active time since the last tick (at most `max(120, 2 × secondsUntilNextCheck)`, so a sleep
    /// is not counted as work); `idleSeconds >= awayThreshold` resets everything. True (and `showing`
    /// becomes true) when the reminder is due, not `blocked` and not already showing. Due but blocked stays
    /// pending until a later tick finds it unblocked.
    public mutating func tick(now: TimeInterval, idleSeconds: TimeInterval, blocked: Bool) -> Bool {
        let cap = max(120, 2 * secondsUntilNextCheck())
        let gap = lastTick.map { max(0, now - $0) }
        let dt = gap.map { min($0, cap) } ?? 0
        lastTick = now
        // B2: a gap longer than the away threshold plus slack means the Mac slept (or the app was off): that time was
        // not work, and the person was away from the computer, so the cycle starts over.
        let slept = (gap ?? 0) > Self.awayThreshold + Self.sleepSlack
        if idleSeconds >= Self.awayThreshold || slept {
            activeSeconds = 0
            snoozeUntil = nil
            return false
        }
        activeSeconds += dt
        let due = snoozeUntil.map { now >= $0 } ?? (activeSeconds >= interval)
        guard due, !blocked, !showing else { return false }
        showing = true
        return true
    }

    /// B2: called when a saved reminder is loaded at launch. The last tick is forgotten (the first tick after launch
    /// adds nothing), and if the app was off longer than a normal check gap the cycle starts over.
    public mutating func resume(now: TimeInterval) {
        if let last = lastTick, now - last > Self.awayThreshold + Self.sleepSlack || now < last {
            activeSeconds = 0
            snoozeUntil = nil
        }
        lastTick = nil
        showing = false
    }

    /// 「喝了 / 好的」 or the bubble was dismissed: start over.
    public mutating func done(now: TimeInterval) {
        activeSeconds = 0
        showing = false
        snoozeUntil = nil
        lastTick = now
    }

    /// 「等会儿」: ask again after `snoozeDelay`; the active time stays.
    public mutating func snooze(now: TimeInterval) {
        showing = false
        snoozeUntil = now + Self.snoozeDelay
        lastTick = now
    }

    /// v0.13.1 where this cycle stands, for the 小工具 tab (read-only: the state only changes on `tick`).
    public enum Status: Equatable, Sendable {
        case showing                         // the bubble is up
        case snoozed(left: TimeInterval)     // 「等会儿」: asks again in `left` s
        case away                            // idle ≥ awayThreshold: starts over on return
        case waiting(left: TimeInterval)     // due, held back (full screen / 勿扰 / focus)
        case counting(left: TimeInterval)    // active computer time still to go
    }

    /// The live estimate between ticks: the active time since the last tick is counted as on the next `tick`.
    public func status(now: TimeInterval, idleSeconds: TimeInterval, blocked: Bool) -> Status {
        if showing { return .showing }
        if idleSeconds >= Self.awayThreshold { return .away }
        if let s = snoozeUntil { return .snoozed(left: max(0, s - now)) }
        let cap = max(120, 2 * secondsUntilNextCheck())
        let active = activeSeconds + (lastTick.map { min(max(0, now - $0), cap) } ?? 0)
        let left = max(0, interval - active)
        return left == 0 && blocked ? .waiting(left: 0) : .counting(left: left)
    }

    /// How long housekeeping may sleep before the next check: 60 s … `interval`.
    public func secondsUntilNextCheck() -> TimeInterval {
        let upper = max(60, interval)
        if showing { return upper }
        let left = activeSeconds >= interval ? 0 : interval - activeSeconds
        return min(upper, max(60, left))
    }
}

// MARK: - Water log

public struct WaterLog: Codable, Equatable, Sendable {
    /// Local date "yyyy-MM-dd".
    public var day: String
    public var cups: Int

    public init(day: String = "", cups: Int = 0) {
        self.day = day
        self.cups = cups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = (try? c.decodeIfPresent(String.self, forKey: .day)) ?? ""
        cups = max(0, (try? c.decodeIfPresent(Int.self, forKey: .cups)) ?? 0)
    }

    static func dayString(_ now: Date, calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
    }

    /// One more cup today (a new day starts at 1).
    public mutating func add(now: Date, calendar: Calendar = .current) {
        let today = Self.dayString(now, calendar: calendar)
        if day != today { day = today; cups = 0 }
        cups += 1
    }

    /// Today's cups; 0 when the log is from another day.
    public func cups(on now: Date, calendar: Calendar = .current) -> Int {
        day == Self.dayString(now, calendar: calendar) ? cups : 0
    }
}

// MARK: - Settings

public struct ToolsSettings: Codable, Equatable, Sendable {
    public var pomodoro = PomodoroConfig()
    public var waterEnabled = false, standEnabled = false
    public var waterInterval: TimeInterval = 3600, standInterval: TimeInterval = 2700

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ToolsSettings()
        pomodoro = (try? c.decodeIfPresent(PomodoroConfig.self, forKey: .pomodoro)) ?? d.pomodoro
        waterEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .waterEnabled)) ?? d.waterEnabled
        standEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .standEnabled)) ?? d.standEnabled
        waterInterval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .waterInterval)) ?? d.waterInterval
        standInterval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .standInterval)) ?? d.standInterval
    }
}

public enum PersonalToolsNotification {
    /// userInfo: ["kind": ReminderKind.rawValue]. Posted when the partner's "drink / stand up" was accepted
    /// (「喝了 / 好的」); the tools controller resets that timer and counts a cup for water.
    public static let didComply = Notification.Name("lulu.tools.didComply")
    /// userInfo: ["kind": ...]. Posted when the partner's reminder got 「等会儿」; the controller snoozes the local one.
    /// (v0.14.4: userInfo also has "ackOf": the id of the partner's reminder, so the controller can remember that this
    /// snooze came from it.)
    public static let didSnooze = Notification.Name("lulu.tools.didSnooze")
    /// v0.14.4. userInfo: ["kind", "ackOf"]. Posted by the controller when 「喝了 / 好的」 is pressed on the local
    /// re-reminder that a partner-remind snooze caused (within `RemindReply.lateWindow`); AppDelegate sends the
    /// 「终于做到了」 reply.
    public static let didCompleteLate = Notification.Name("lulu.tools.didCompleteLate")
}
