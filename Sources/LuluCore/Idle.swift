import Foundation

/// v0.3 idle behaviour of the home pet: random fidgets while idle, and a doze after a long time
/// without any interaction. Pure rules; PetWindow / AppDelegate drive the timers.
public enum IdleRules {
    /// No interaction for this long → the home pet dozes. `--doze-seconds N` overrides it.
    public static let dozeAfter: TimeInterval = 15 * 60
    /// v0.8 省电: no interaction (and no visit / bubble) for this long → the home pet stops animating and
    /// holds its outfit's quiet frame (no fidgets). One constant to tune. `--quiet-seconds N` overrides it.
    public static let quietAfter: TimeInterval = 120
    /// Random pause between two fidgets. `--fidget-seconds N` makes it fixed.
    public static let fidgetInterval: ClosedRange<TimeInterval> = 45...120
    /// When a doze / fidget is due but the pet is busy, try again after this long.
    public static let retry: TimeInterval = 5

    /// Seconds until the next fidget: `fixed` if given, else `range` at `unit` (0…1).
    public static func fidgetDelay(fixed: TimeInterval?, unit: Double, range: ClosedRange<TimeInterval> = fidgetInterval) -> TimeInterval {
        if let fixed { return max(0.5, fixed) }
        let u = min(1, max(0, unit))
        return range.lowerBound + (range.upperBound - range.lowerBound) * u
    }

    /// Index of the fidget to play out of `count`, never `last` again when there is a choice.
    /// `roll(n)` returns a random integer in `0..<n`.
    public static func pickFidget(count: Int, last: Int?, roll: (Int) -> Int) -> Int? {
        guard count > 0 else { return nil }
        let candidates = (0..<count).filter { $0 != last || count == 1 }
        return candidates[min(max(0, roll(candidates.count)), candidates.count - 1)]
    }
}

/// Tracks the last interaction and whether the home pet is dozing.
public struct DozeClock: Sendable {
    public enum Step: Equatable, Sendable {
        /// Check again after this many seconds.
        case wait(TimeInterval)
        /// Start dozing now.
        case doze
        /// Already dozing; nothing to do until the next activity.
        case none
    }

    public let threshold: TimeInterval
    public private(set) var lastActivity: TimeInterval
    public private(set) var dozing = false

    /// `now` is any monotonic clock in seconds.
    public init(threshold: TimeInterval = IdleRules.dozeAfter, now: TimeInterval) {
        self.threshold = threshold
        self.lastActivity = now
    }

    /// An interaction (click, drag, compose, menu) or an incoming visit / message.
    /// Returns true when this woke the pet up.
    @discardableResult
    public mutating func activity(now: TimeInterval) -> Bool {
        lastActivity = now
        defer { dozing = false }
        return dozing
    }

    /// True once the threshold has passed without activity (dozing or about to): fidgets hold off.
    public func isDue(now: TimeInterval) -> Bool { dozing || now >= lastActivity + threshold }

    /// Timer check. `blocked` = the pet is doing something (visit, bubble, clip, drag, compose open):
    /// a due doze then waits `IdleRules.retry` seconds.
    public mutating func check(now: TimeInterval, blocked: Bool) -> Step {
        if dozing { return .none }
        let remaining = lastActivity + threshold - now
        if remaining > 0 { return .wait(remaining) }
        if blocked { return .wait(IdleRules.retry) }
        dozing = true
        return .doze
    }
}

/// v0.8 省电: what the home pet shows when it isn't doing anything else.
public enum RestPose: String, Sendable {
    /// Looping idle animation (and fidgets now and then).
    case idle
    /// A still frame (the outfit's `quiet` frame, else idle frame 0): quiet mode or 勿扰.
    case quiet
    /// A still eyes-closed frame (the outfit's doze frame) with a slow Zzz.
    case doze

    /// Dozing wins; 勿扰 is always quiet; otherwise quiet mode after `IdleRules.quietAfter`.
    public static func pick(dozing: Bool, quiet: Bool, dnd: Bool) -> RestPose {
        if dozing { return .doze }
        return quiet || dnd ? .quiet : .idle
    }

    /// Fidgets only while the pet is animating normally.
    public var allowsFidgets: Bool { self == .idle }
}

/// v0.8 battery-aware timing (`PowerMonitor`: on battery or Low Power Mode).
public struct PowerProfile: Equatable, Sendable {
    public var heartbeat: TimeInterval
    public var presencePoll: TimeInterval
    /// Hover watch for the resize handle / quiet wake-up.
    public var hoverInterval: TimeInterval
    /// FullscreenWatcher fallback poll.
    public var fullscreenPoll: TimeInterval

    public init(heartbeat: TimeInterval, presencePoll: TimeInterval, hoverInterval: TimeInterval, fullscreenPoll: TimeInterval) {
        self.heartbeat = heartbeat
        self.presencePoll = presencePoll
        self.hoverInterval = hoverInterval
        self.fullscreenPoll = fullscreenPoll
    }

    public static let ac = PowerProfile(heartbeat: Presence.heartbeatInterval, presencePoll: Presence.pollInterval,
                                        hoverInterval: 0.1, fullscreenPoll: 3)
    public static let battery = PowerProfile(heartbeat: 30, presencePoll: 30, hoverInterval: 0.25, fullscreenPoll: 8)

    public static func current(onBattery: Bool) -> PowerProfile { onBattery ? .battery : .ac }

    /// Tolerance for a repeating timer: 10 % of its interval, at most 1 s (lets macOS coalesce wake-ups).
    public static func tolerance(for interval: TimeInterval) -> TimeInterval { min(1, interval * 0.1) }
}
