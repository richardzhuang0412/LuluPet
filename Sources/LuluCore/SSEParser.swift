import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String
    public init(event: String, data: String) { self.event = event; self.data = data }
}

/// Line-based Server-Sent-Events parser. Firebase always sends `event:` then a single `data:` line,
/// so an event is emitted as soon as its data line arrives (blank separator lines are optional,
/// which matters because `URLSession.AsyncBytes.lines` drops empty lines).
public struct SSEParser {
    private var pendingEvent = "message"

    public init() {}

    public mutating func feed(line: String) -> SSEEvent? {
        if line.hasPrefix("event:") {
            pendingEvent = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if line.hasPrefix("data:") {
            let data = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            defer { pendingEvent = "message" }
            return SSEEvent(event: pendingEvent, data: data)
        }
        return nil
    }
}

/// Turns Firebase REST streaming events on `/pairs/<code>/messages` into messages.
public enum FirebaseDecode {
    private struct Envelope: Decodable {
        let path: String
        let data: AnyJSON?
    }

    /// Wrapper so we can decode arbitrary JSON and re-encode sub-trees.
    private struct AnyJSON: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = NSNull() }
            else if let v = try? c.decode([String: AnyJSON].self) { value = v.mapValues(\.value) }
            else if let v = try? c.decode([AnyJSON].self) { value = v.map(\.value) }
            else if let v = try? c.decode(Bool.self) { value = v }
            else if let v = try? c.decode(Int64.self) { value = v }
            else if let v = try? c.decode(Double.self) { value = v }
            else { value = try c.decode(String.self) }
        }
    }

    public static func messages(from ev: SSEEvent) -> [Message] {
        guard ev.event == "put" || ev.event == "patch",
              let env = try? JSONDecoder().decode(Envelope.self, from: Data(ev.data.utf8)),
              let payload = env.data?.value as? [String: Any] else { return [] }
        let parts = env.path.split(separator: "/").map(String.init)
        let entries: [String: Any]
        switch parts.count {
        case 0: entries = payload                       // snapshot or multi-child patch
        case 1: entries = [parts[0]: payload]           // one new message
        default: return []                              // nested field update; we never write those
        }
        return messages(fromChildren: entries)
    }

    /// Plain `GET /pairs/<code>/messages.json` body (`{pushId: message}` or `null`), sorted by ts.
    public static func messages(fromSnapshot data: Data) -> [Message] {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let children = obj as? [String: Any] else { return [] }
        return messages(fromChildren: children)
    }

    private static func messages(fromChildren entries: [String: Any]) -> [Message] {
        entries.compactMap { key, value in Message.decode(firebaseKey: key, value: value) }
            .sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
    }

    /// True for an event that replaces the whole list (path "/"): the first `put` of a stream holds
    /// the backlog (messages that arrived while we were away), not live messages.
    public static func isBacklog(_ ev: SSEEvent) -> Bool {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: Data(ev.data.utf8)) else { return false }
        return env.path.split(separator: "/").isEmpty
    }

    /// Firebase closes the stream with these when rules deny access.
    public static func isAuthRevoked(_ ev: SSEEvent) -> Bool {
        ev.event == "cancel" || ev.event == "auth_revoked"
    }
}
