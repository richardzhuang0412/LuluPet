import Foundation

/// v0.8.1 省电: everything the home pet has to do "later" runs from ONE one-shot timer aimed at the
/// earliest due deadline (instead of a timer per job plus a 2 s hide poller). Pure rules; the
/// `HousekeepingScheduler` in LuluPet owns the timer and re-arms it on state changes, wake and clock changes.
public enum HousekeepingTask: String, CaseIterable, Sendable {
    // Declaration order = run order when several are due at once (勿扰 / hide end first, fidget last).
    case dndEnd, hideEnd, quiet, doze, rotation, fidget
    // v0.10 personal tools: pomodoro phase end (wall clock), water / stand reminder checks (monotonic).
    case pomodoro, water, stand
    // v0.12 weather refresh (wall clock: 30 min after the last fetch, or at once when the data is overdue).
    case weather

    /// Wall-clock deadlines (Unix seconds) keep their time across sleep and clock changes;
    /// the others are monotonic (system uptime, which stops while the Mac sleeps — like `Timer`).
    public var isWallClock: Bool { self == .dndEnd || self == .hideEnd || self == .pomodoro || self == .weather }
}

/// The pending deadlines; nil = not armed.
public struct HousekeepingDeadlines: Equatable, Sendable {
    /// Monotonic (`ProcessInfo.systemUptime` seconds).
    public var quiet: TimeInterval?
    public var doze: TimeInterval?
    public var rotation: TimeInterval?
    public var fidget: TimeInterval?
    /// v0.10 reminder checks (monotonic).
    public var water: TimeInterval?
    public var stand: TimeInterval?
    /// Wall clock (Unix seconds).
    public var dndEnd: TimeInterval?
    public var hideEnd: TimeInterval?
    /// v0.10 pomodoro phase end / countdown refresh (wall clock).
    public var pomodoro: TimeInterval?
    /// v0.12 next weather refresh (wall clock).
    public var weather: TimeInterval?

    public init(quiet: TimeInterval? = nil, doze: TimeInterval? = nil, rotation: TimeInterval? = nil,
                fidget: TimeInterval? = nil, dndEnd: TimeInterval? = nil, hideEnd: TimeInterval? = nil,
                pomodoro: TimeInterval? = nil, water: TimeInterval? = nil, stand: TimeInterval? = nil,
                weather: TimeInterval? = nil) {
        self.quiet = quiet
        self.doze = doze
        self.rotation = rotation
        self.fidget = fidget
        self.dndEnd = dndEnd
        self.hideEnd = hideEnd
        self.pomodoro = pomodoro
        self.water = water
        self.stand = stand
        self.weather = weather
    }

    public subscript(task: HousekeepingTask) -> TimeInterval? {
        switch task {
        case .quiet: return quiet
        case .doze: return doze
        case .rotation: return rotation
        case .fidget: return fidget
        case .dndEnd: return dndEnd
        case .hideEnd: return hideEnd
        case .pomodoro: return pomodoro
        case .water: return water
        case .stand: return stand
        case .weather: return weather
        }
    }

    /// Seconds from now until `task` is due (negative = overdue); nil when not armed.
    public func delay(_ task: HousekeepingTask, uptime: TimeInterval, wall: TimeInterval) -> TimeInterval? {
        self[task].map { $0 - (task.isWallClock ? wall : uptime) }
    }
}

/// What the single timer should look like: fire after `delay`, allowed to be `tolerance` late.
public struct HousekeepingPlan: Equatable, Sendable {
    public var delay: TimeInterval
    public var tolerance: TimeInterval
    /// The tasks this firing is expected to handle (the earliest + those coalesced into its window), run order.
    public var tasks: [HousekeepingTask]
}

public enum Housekeeping {
    /// A deadline this close counts as due when the timer fires (float noise between clocks).
    public static let dueSlack: TimeInterval = 0.05
    /// Upper bound of the idle tolerance (a 30 min outfit rotation may be up to a minute late).
    public static let maxTolerance: TimeInterval = 60

    /// How late `task` may run: 1 s for the wall-clock ends (勿扰 / hide, shown as a time in the menu);
    /// 10 % of the wait, at least 1 s and at most `maxTolerance`, for the idle jobs.
    public static func tolerance(for task: HousekeepingTask, delay: TimeInterval) -> TimeInterval {
        if task.isWallClock { return 1 }
        return min(maxTolerance, max(1, delay * 0.1))
    }

    /// The single timer for these deadlines, or nil when nothing is armed. The timer fires at the earliest
    /// deadline; its tolerance stretches as far as every task's own window allows, so deadlines that fall
    /// inside it are handled by the same wake-up.
    public static func plan(_ d: HousekeepingDeadlines, uptime: TimeInterval, wall: TimeInterval) -> HousekeepingPlan? {
        let pending = HousekeepingTask.allCases.compactMap { t in d.delay(t, uptime: uptime, wall: wall).map { (t, max(0, $0)) } }
        guard let earliest = pending.map(\.1).min() else { return nil }
        let windowEnd = pending.map { $0.1 + tolerance(for: $0.0, delay: $0.1) }.min()!
        return HousekeepingPlan(delay: earliest, tolerance: max(0, windowEnd - earliest),
                                tasks: pending.filter { $0.1 <= windowEnd }.map(\.0))
    }

    /// The tasks due now, in run order.
    public static func due(_ d: HousekeepingDeadlines, uptime: TimeInterval, wall: TimeInterval) -> [HousekeepingTask] {
        HousekeepingTask.allCases.filter { t in (d.delay(t, uptime: uptime, wall: wall) ?? .infinity) <= dueSlack }
    }

    /// Fidgets are only scheduled while the pet animates normally and can be seen: nothing ticks in quiet,
    /// doze, 勿扰 (quiet pose), hidden, or while animations are paused (locked / asleep / occluded).
    public static func fidgetsArmed(pose: RestPose, hidden: Bool, paused: Bool) -> Bool {
        pose.allowsFidgets && !hidden && !paused
    }

    /// The fidget deadline: keeps a pending one, draws a fresh one (`delay`) when fidgets become armed,
    /// drops it when they are not.
    public static func fidgetDeadline(current: TimeInterval?, armed: Bool, now: TimeInterval,
                                      delay: @autoclosure () -> TimeInterval) -> TimeInterval? {
        guard armed else { return nil }
        return current ?? now + delay()
    }

    /// A due quiet / doze / rotation finds the pet busy (clip, bubble waiting to be read, visit, compose):
    /// retry after 5 s, 5 s, 10 s, 20 s, then every 30 s. The streak restarts when something that was
    /// blocking ends (bubble read, visit over, interaction), so the usual case behaves exactly like v0.8.
    public static func blockedRetry(attempt: Int) -> TimeInterval {
        let base = IdleRules.retry
        guard attempt > 2 else { return base }
        return min(30, base * pow(2, Double(attempt - 2)))
    }
}
