import Foundation

// v0.17: rules for a second client on my own seat (the web version, docs/superpowers/specs/2026-10-06-web-design.md
// §4–5). Everything here is additive: 0.16 never reads `read/<seat>` and ignores presence `client`.

/// `/pairs/<code>/read/<seat>` = `{"ts": ms, "device": "<deviceId>", "at": ms}`: the highest message ts read on
/// this seat by any of its devices (my Mac, my web tabs). Only my own seat's devices read / write it; TA never does.
public struct SharedReadCursor: Equatable, Sendable {
    public var ts: Int64
    /// Who wrote it (`deviceId`; web devices start with `web-`); nil = not given.
    public var device: String?
    /// When it was written (ms); nil = not given.
    public var at: Int64?

    public init(ts: Int64, device: String? = nil, at: Int64? = nil) {
        self.ts = ts
        self.device = device
        self.at = at
    }

    /// Body of `GET read/<seat>`: null / garbage / no numeric `ts` / negative → nil (= nothing shared yet).
    /// A bare number (never written by any client, tolerated) reads as `ts`. Unknown fields are ignored.
    public static func decode(_ data: Data) -> SharedReadCursor? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        func number(_ v: Any?) -> Int64? {
            // `NSNumber(1) is Bool` is true in Swift; tell JSON booleans apart by their CF type instead.
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            return n.int64Value
        }
        if let ts = number(obj) { return ts >= 0 ? SharedReadCursor(ts: ts) : nil }
        guard let d = obj as? [String: Any], let ts = number(d["ts"]), ts >= 0 else { return nil }
        return SharedReadCursor(ts: ts,
                                device: WireLimits.clipped(d["device"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                at: number(d["at"]))
    }

    /// Body of the PUT.
    public var payload: [String: Any] {
        var out: [String: Any] = ["ts": ts]
        if let device { out["device"] = device }
        if let at { out["at"] = at }
        return out
    }
}

public enum SharedRead {
    /// At most one write per this many seconds while reading (a flush on quit / sleep comes on top).
    public static let writeInterval: TimeInterval = 10
    /// The GET before opening the stream gives up after this long (then the local cursor is used alone).
    public static let readTimeout: TimeInterval = 5

    /// Where the message stream starts: `max(local, shared)`. A shared value from the far future (a bad clock on
    /// another device: more than `WireLimits.futureSlackMs` ahead) is ignored — it would hide a day of messages.
    /// A far-future local value is reset to `now`, as 0.16 already did at start.
    public static func startCursor(local: Int64, shared: Int64?, now: Int64) -> Int64 {
        let l = WireLimits.isFuture(ts: local, now: now) ? now : local
        guard let s = shared, !WireLimits.isFuture(ts: s, now: now) else { return l }
        return max(l, s)
    }

    /// Read-modify-write: only PUT when mine is ahead of what the server holds (the cursor never moves backwards;
    /// losing a race to another device's write only means a few messages may show again).
    public static func shouldPut(mine: Int64, remote: Int64?) -> Bool {
        mine > 0 && mine > (remote ?? 0)
    }
}

/// Throttle for writing my read cursor back (`SharedRead.writeInterval`). Times are any monotonic seconds.
public struct SharedReadThrottle: Equatable, Sendable {
    /// Highest ts the server is known to hold (from a read or my own write); 0 = unknown / none.
    public private(set) var remote: Int64 = 0
    private var lastWrite: TimeInterval?
    public let interval: TimeInterval

    public init(interval: TimeInterval = SharedRead.writeInterval) { self.interval = interval }

    /// True when the local cursor is ahead of what the server is known to hold.
    public func needsWrite(local: Int64) -> Bool { SharedRead.shouldPut(mine: local, remote: remote) }

    /// nil = nothing to write; else seconds to wait before writing (0 = now).
    public func delay(local: Int64, now: TimeInterval) -> TimeInterval? {
        guard needsWrite(local: local) else { return nil }
        guard let last = lastWrite else { return 0 }
        return max(0, last + interval - now)
    }

    /// A read or a successful write showed the server holds `ts` (never lowers what is known).
    public mutating func noteRemote(_ ts: Int64) { remote = max(remote, ts) }

    /// A write was attempted at `now` (successful or not: the gap applies either way).
    public mutating func noteWrite(at now: TimeInterval) { lastWrite = now }
}

/// v0.17: the web version (device ids `web-…`) shares my seat and yields to my Mac (it doesn't heartbeat while the Mac
/// is online), so its presence on my seat is never another machine fighting for the seat.
public enum WebClient {
    public static let devicePrefix = "web-"
    /// Presence field `client` the web version writes.
    public static let presenceClient = "web"

    public static func isWebDevice(_ device: String?) -> Bool {
        device?.hasPrefix(devicePrefix) == true
    }
}
