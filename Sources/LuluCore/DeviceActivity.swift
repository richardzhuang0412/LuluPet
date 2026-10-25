import Foundation

/// v0.19: per-device activity record at `/pairs/{code}/devices/{seat}/{deviceId}` = `{kind, activeAt, at}`, so the
/// cloud push function can tell whether the user is really using this Mac (not just whether the app runs).
/// `activeAt` = ms of the last real user input (now − HID idle seconds); `at` = ms of the write. Only paired modes
/// write it; it rides on the presence heartbeat (no timer of its own). Pure rules; `PairChannel` does the I/O.
public struct DeviceActivityRecord: Equatable, Sendable {
    public var kind: String
    public var activeAt: Int64
    public var at: Int64

    public init(kind: String = DeviceActivity.macKind, activeAt: Int64, at: Int64) {
        self.kind = kind
        self.activeAt = activeAt
        self.at = at
    }

    public var payload: [String: Any] { ["kind": kind, "activeAt": activeAt, "at": at] }
}

public enum DeviceActivity {
    /// Frozen wire value for a Mac (web clients would write their own kind).
    public static let macKind = "mac"
    /// Write again when `activeAt` moved by at least this much since the last write…
    public static let activeStepMs: Int64 = 60_000
    /// …or when the last write is this old (keeps `at` fresh while the user is away).
    public static let refreshMs: Int64 = 5 * 60_000

    /// Last real input in ms: `now − idle`, never after `now`, never before an earlier known value (input times only
    /// move forward; sub-second jitter between two reads must not move it back).
    public static func activeAt(nowMs: Int64, idleSeconds: TimeInterval, previous: Int64? = nil) -> Int64 {
        let idle = idleSeconds.isFinite ? max(0, idleSeconds) : 0
        let fresh = nowMs - Int64((idle * 1000).rounded())
        return min(nowMs, max(fresh, previous ?? Int64.min))
    }

    /// Whether a heartbeat should also write the record. `last` = the last record that was written successfully.
    public static func shouldWrite(activeAt: Int64, nowMs: Int64, last: DeviceActivityRecord?) -> Bool {
        guard let last else { return true }
        if abs(activeAt - last.activeAt) >= activeStepMs { return true }
        return nowMs - last.at >= refreshMs || nowMs < last.at   // a clock that jumped back: rewrite too
    }
}

/// Remembers what was last written; one per channel run.
public struct DeviceActivityThrottle: Sendable {
    public private(set) var lastWritten: DeviceActivityRecord?
    /// Newest `activeAt` seen (written or not), so the sign-off never reports an older one.
    public private(set) var lastActiveAt: Int64?

    public init() {}

    /// The record to write at this heartbeat, or nil when nothing changed enough.
    public mutating func due(nowMs: Int64, idleSeconds: TimeInterval) -> DeviceActivityRecord? {
        let a = DeviceActivity.activeAt(nowMs: nowMs, idleSeconds: idleSeconds, previous: lastActiveAt)
        lastActiveAt = a
        guard DeviceActivity.shouldWrite(activeAt: a, nowMs: nowMs, last: lastWritten) else { return nil }
        return DeviceActivityRecord(activeAt: a, at: nowMs)
    }

    /// The final record on sleep / sign-off: always written; `activeAt` is the real last input (it is not bumped to now).
    public mutating func signOff(nowMs: Int64, idleSeconds: TimeInterval?) -> DeviceActivityRecord? {
        let a: Int64
        if let idleSeconds { a = DeviceActivity.activeAt(nowMs: nowMs, idleSeconds: idleSeconds, previous: lastActiveAt) }
        else if let known = lastActiveAt { a = known }
        else { return nil }
        lastActiveAt = a
        return DeviceActivityRecord(activeAt: a, at: nowMs)
    }

    /// A write succeeded.
    public mutating func written(_ record: DeviceActivityRecord) { lastWritten = record }
}
