import Foundation

public enum Presence {
    /// v0.7: 20 s heartbeat; offline after 75 s of silence (still > one v0.6 60 s heartbeat, so an
    /// un-upgraded partner doesn't flap). A clean quit / sleep writes lastSeen = 0 = offline at once.
    public static let heartbeatInterval: TimeInterval = 20
    public static let thresholdMs: Int64 = 75_000
    /// v0.8.1: 15 s on AC (was 10 s); battery uses `PowerProfile.battery` (30 s). A send always does a
    /// fresh check first (`PairChannel.refreshPartnerPresence`), so the poll only drives the status display.
    public static let pollInterval: TimeInterval = 15

    public static func isOnline(lastSeen: Int64?, now: Int64, thresholdMs: Int64 = Presence.thresholdMs) -> Bool {
        guard let lastSeen, lastSeen > 0 else { return false }   // 0 = signed off (quit / sleep)
        return now - lastSeen <= thresholdMs
    }

    /// v0.8.1: tolerance for the presence / stream-watchdog sleeps: 10 % of the delay, at most 3 s.
    /// Worst heartbeat gap on battery = 30 + 3 s, so two in a row (66 s) still fit in the 75 s threshold.
    public static func tolerance(for delay: TimeInterval) -> TimeInterval { min(3, max(0, delay) * 0.1) }
}

/// v0.8.1 省电: one wake-up drives both the presence heartbeat (PUT) and the partner poll (GET).
/// A job due within `window` of another fires early in the same wake-up (never late), so on AC
/// (20 s heartbeat / 15 s poll) both run together every 15 s: 4 wake-ups a minute instead of 9;
/// on battery (30 s / 30 s) they always share one: 2 a minute instead of up to 4.
public struct PresenceSchedule: Equatable, Sendable {
    public struct Due: Equatable, Sendable {
        public var heartbeat: Bool
        public var poll: Bool
        public init(heartbeat: Bool, poll: Bool) { self.heartbeat = heartbeat; self.poll = poll }
    }

    public private(set) var nextHeartbeat: TimeInterval
    public private(set) var nextPoll: TimeInterval

    /// Both jobs are due at `start`.
    public init(start: TimeInterval) {
        nextHeartbeat = start
        nextPoll = start
    }

    /// A job due this close to the wake-up joins it: a third of the shorter interval.
    public static func window(heartbeat: TimeInterval, poll: TimeInterval) -> TimeInterval {
        max(0, min(heartbeat, poll)) / 3
    }

    /// The jobs to run at `now` (all that are due, plus any due within `window`), rescheduling them.
    /// An interval that got shorter since the last run (battery → AC) takes effect at once.
    public mutating func fire(now: TimeInterval, heartbeat: TimeInterval, poll: TimeInterval) -> Due {
        nextHeartbeat = min(nextHeartbeat, now + heartbeat)
        nextPoll = min(nextPoll, now + poll)
        let w = Self.window(heartbeat: heartbeat, poll: poll)
        let due = Due(heartbeat: nextHeartbeat <= now + w, poll: nextPoll <= now + w)
        if due.heartbeat { nextHeartbeat = now + max(heartbeat, 0.5) }
        if due.poll { nextPoll = now + max(poll, 0.5) }
        return due
    }

    /// Seconds until the next job is due (≥ 0).
    public func delay(now: TimeInterval) -> TimeInterval { max(0, min(nextHeartbeat, nextPoll) - now) }
}

/// v0.8.1: the message stream's idle watchdog sleeps until the connection would be idle for `timeout`
/// instead of checking every 10 s (Firebase keep-alives every ~30 s keep pushing the deadline out).
public enum StreamWatchdog {
    /// nil = the stream has been silent for `timeout` (reconnect); else how long to sleep (≥ 1 s).
    public static func sleep(idle: TimeInterval, timeout: TimeInterval) -> TimeInterval? {
        let left = timeout - idle
        return left <= 0 ? nil : max(1, left)
    }
}

/// `FullscreenWatcher` reacts to space / app / screen changes, with a few re-checks after each event (the
/// window list settles late — entering full screen can take several seconds), plus a slow safety poll:
/// v0.8.1 had no poll while not fullscreen and missed some full-screen entries (pet stayed visible).
public enum FullscreenFallback {
    /// Safety poll while NOT fullscreen (catches entries whose notifications came too early / not at all).
    public static let idlePollInterval: TimeInterval = 10
    /// Poll while fullscreen (catches a missed "left fullscreen").
    public static let pollInterval: TimeInterval = 15
    /// Poll interval for the current state.
    public static func pollInterval(isFullscreen: Bool) -> TimeInterval? { isFullscreen ? pollInterval : idlePollInterval }
    /// One-shot re-checks after an event.
    public static let settleDelays: [TimeInterval] = [0.3, 1.0, 2.5, 5.0, 8.0]
}
