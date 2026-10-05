import Foundation

// prelaunch-A: pure rules for data that crosses the wire (sync hardening). Everything here is additive
// and tolerant: nothing changes what an old client writes or reads (docs/upgrade-compat.md).

/// Size / time limits for partner-controlled data. They mirror the Firebase rules in docs/firebase-setup.md.
public enum WireLimits {
    /// Message text, counted in UTF-16 code units (what the rules' `.length` counts).
    public static let maxText = 500
    /// stickerId / outfit / trip / remind / ackOf / answer, presence place name / mood / app / device.
    public static let maxField = 64
    /// A message whose JSON is larger than this is dropped on receive.
    public static let maxEncodedMessageBytes = 4096
    /// `ts` more than this far ahead of now is ignored on receive (rules: `ts <= now + 86400000`).
    public static let futureSlackMs: Int64 = 86_400_000
    /// Bubble / away queue length; the rest is folded into a "+N".
    public static let queueCap = 50

    /// `s` cut to at most `max` UTF-16 units, never inside a character (emoji / combining sequences stay whole).
    public static func clipUTF16(_ s: String, max: Int) -> String {
        guard s.utf16.count > max else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let n = ch.utf16.count
            if used + n > max { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// Optional field: nil stays nil; over `max` units reads as nil (a cut id would name something else).
    public static func field(_ s: String?, max: Int = maxField) -> String? {
        guard let s, s.utf16.count <= max else { return nil }
        return s
    }

    /// Presence strings: cut (still useful, just shorter).
    public static func clipped(_ s: String?, max: Int = maxField) -> String? {
        s.map { clipUTF16($0, max: max) }
    }

    /// True when `ts` is further ahead of `now` than a skewed clock can explain.
    public static func isFuture(ts: Int64, now: Int64) -> Bool {
        ts > now &+ futureSlackMs
    }

    /// The unread cursor can never sit beyond what the rules allow, so a bad value can't stall the stream.
    public static func clampCursor(_ ts: Int64, now: Int64) -> Int64 {
        min(ts, now &+ futureSlackMs)
    }
}

/// Fold a long queue: keep the newest `cap`, the older ones are only counted ("+N").
public enum QueueFold {
    public static func split<T>(_ items: [T], cap: Int = WireLimits.queueCap) -> (folded: [T], kept: [T]) {
        guard cap >= 0, items.count > cap else { return ([], items) }
        let cut = items.count - cap
        return (Array(items[..<cut]), Array(items[cut...]))
    }
}

/// Client-generated Firebase push key (20 chars, time-ordered like `POST` would assign), so a send can be
/// retried as an idempotent `PUT /messages/<key>`.
public enum PushKey {
    static let alphabet = Array("-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz")

    public static func generate(at ms: Int64, using rng: inout some RandomNumberGenerator) -> String {
        var t = UInt64(max(0, ms))
        var head = [Character](repeating: "-", count: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            head[i] = alphabet[Int(t % 64)]
            t /= 64
        }
        let tail = (0..<12).map { _ in alphabet[Int.random(in: 0..<64, using: &rng)] }
        return String(head) + String(tail)
    }

    public static func generate(at ms: Int64) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(at: ms, using: &rng)
    }

    public static func isValid(_ s: String) -> Bool {
        s.utf8.count == 20 && s.allSatisfy { alphabet.contains($0) }
    }
}

/// What to do with the head of the outbox after a failed send.
public enum OutboxVerdict: Equatable, Sendable { case retry, park }

public enum OutboxPolicy {
    /// `status` = the HTTP status of the failed request (nil for network errors: always retry).
    /// 400 / 413 / 422: this message itself is bad → park. 401 / 403: rules refused it; only park when the
    /// stream is connected (read works, so the rules, not the setup, reject this message) — otherwise the setup
    /// is wrong for everything and a fix (new rules) should still deliver what is waiting.
    public static func verdict(status: Int?, streamConnected: Bool) -> OutboxVerdict {
        switch status {
        case 400, 413, 422: return .park
        case 401, 403: return streamConnected ? .park : .retry
        default: return .retry
        }
    }
}

/// Reconnect delay: the doubling is only reset by a connection that actually lived for a while, not by
/// keep-alives of a server that drops us again at once.
public enum StreamBackoff {
    public static let stableAfter: TimeInterval = 30
    public static func afterConnection(current: TimeInterval, livedFor: TimeInterval) -> TimeInterval {
        livedFor >= stableAfter ? 1 : current
    }
}

/// Splits an SSE byte stream into lines on `\n` / `\r` only. (`AsyncBytes.lines` also splits on U+2028 / U+2029 /
/// U+0085, which can occur inside a JSON string, and would cut an event in two.) Empty lines are dropped.
public struct SSELineSplitter {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ byte: UInt8) -> String? {
        if byte == 0x0A || byte == 0x0D {
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        buffer.append(byte)
        return nil
    }

    public mutating func feed(_ bytes: [UInt8]) -> [String] {
        var out: [String] = []
        for b in bytes { if let l = feed(b) { out.append(l) } }
        return out
    }
}

/// The unsent messages, persisted next to `history.jsonl` as `outbox.json` so a quit / crash / update restart /
/// config change doesn't lose them. Tied to one pair code and seat: anything else is dropped on load.
/// Additive file: older apps never look at it.
public struct OutboxStore: Sendable {
    public struct Snapshot: Equatable, Sendable {
        public var pending: [Message]
        /// Ids of messages the server refused for good (parked): shown as 「没发出去」.
        public var failed: [String]
        public init(pending: [Message] = [], failed: [String] = []) { self.pending = pending; self.failed = failed }
    }

    private struct File: Codable {
        var pairCode: String
        var role: Role
        var messages: [Message]
        var failed: [String]?
    }

    public static let maxFailedKept = 200
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("outbox.json")
    }

    public func load(pairCode: String, role: Role) -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let f = try? JSONDecoder().decode(File.self, from: data),
              f.pairCode == pairCode, f.role == role else { return Snapshot() }
        return Snapshot(pending: f.messages.filter { !$0.id.isEmpty }, failed: f.failed ?? [])
    }

    public func save(_ s: Snapshot, pairCode: String, role: Role) {
        if s.pending.isEmpty && s.failed.isEmpty {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        let f = File(pairCode: pairCode, role: role, messages: s.pending, failed: Array(s.failed.suffix(Self.maxFailedKept)))
        guard let data = try? JSONEncoder().encode(f) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600])
        _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }
}
