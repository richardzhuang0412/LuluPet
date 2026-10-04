import Foundation
import LuluCore

public enum FirebaseError: Error, Equatable {
    case http(Int)
    /// Stream closed by the server via `cancel` / `auth_revoked` (rules deny access).
    case cancelled
    case badURL
}

/// Thin wrapper over the Firebase Realtime Database REST API for one pair.
/// Paths: `/pairs/<code>/messages/<pushId>` and `/pairs/<code>/presence/<role>`.
public final class FirebaseClient: Sendable {
    public let databaseURL: String
    public let pairCode: String
    private let session: URLSession

    public init(databaseURL: String, pairCode: String, session: URLSession = .shared) {
        self.databaseURL = databaseURL
        self.pairCode = pairCode
        self.session = session
    }

    // MARK: URL building

    /// `<normalized databaseURL>/pairs/<code>/<path>.json?<query>`. `query` must already be percent-encoded.
    public static func url(databaseURL: String, pairCode: String, path: String, query: String? = nil) throws -> URL {
        var base = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let code = pairCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? pairCode
        var s = "\(base)/pairs/\(code)/\(path).json"
        if let query, !query.isEmpty { s += "?" + query }
        guard base.hasPrefix("https://") || base.hasPrefix("http://"),
              let url = URL(string: s), url.host != nil else { throw FirebaseError.badURL }
        return url
    }

    /// Streaming URL for messages newer than `ts`: `orderBy="ts"&startAt=<ts+1>` (numbers are unquoted).
    public static func messageStreamURL(databaseURL: String, pairCode: String, since ts: Int64) throws -> URL {
        try url(databaseURL: databaseURL, pairCode: pairCode, path: "messages",
                query: "orderBy=%22ts%22&startAt=\(ts + 1)")
    }

    // MARK: Requests

    /// Appends the message; returns the push id the server assigned (`{"name": "-N..."}`), if any.
    @discardableResult
    public func post(_ m: Message) async throws -> String? {
        var req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = m.firebasePayload()
        let body = try await data(for: req)
        return (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["name"] as? String
    }

    /// Full message history of the pair (plain JSON GET, not a stream), sorted by ts.
    public func allMessages() async throws -> [Message] {
        let req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "messages"))
        return FirebaseDecode.messages(fromSnapshot: try await data(for: req))
    }

    /// v0.8: `{"lastSeen": ms, "dnd": {"mood", "until"}}` (`dnd` only while 勿扰 is on; old clients read
    /// only `presence/<role>/lastSeen`).
    /// v0.10: plus `"focus": {"phase", "until"}` while a pomodoro focus round runs (older clients ignore it).
    /// v0.11: plus optional `character` / `mode` / `device` (`PresenceIdentity`); older clients ignore them.
    /// v0.11.2: plus optional `app` (my app version string).
    /// v0.12: plus optional `place` (my city, coordinates at two decimals); the sign-off keeps it too, so TA still sees my weather.
    public func heartbeat(_ role: Role, dnd: DNDStatus? = nil, focus: FocusStatus? = nil, identity: PresenceIdentity? = nil, app: String? = nil, place: WeatherPlace? = nil) async throws {
        var req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "presence/\(role.rawValue)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = Self.presenceTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: PresenceInfo.payload(lastSeen: nowMs(), dnd: dnd, focus: focus,
                                                                                 character: identity?.character, mode: identity?.mode, device: identity?.device, app: app, place: place))
        _ = try await data(for: req)
    }

    /// Clean sign-off (quit / sleep): lastSeen = 0 reads as offline on every client version.
    public func markOffline(_ role: Role, dnd: DNDStatus? = nil, identity: PresenceIdentity? = nil, app: String? = nil, place: WeatherPlace? = nil) async throws {
        var req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "presence/\(role.rawValue)"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 2
        req.httpBody = try JSONSerialization.data(withJSONObject: PresenceInfo.payload(lastSeen: 0, dnd: dnd, character: identity?.character, mode: identity?.mode, device: identity?.device, app: app, place: place))
        _ = try await data(for: req)
    }

    public func lastSeen(_ role: Role) async throws -> Int64? {
        let req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "presence/\(role.rawValue)/lastSeen"))
        let body = try await data(for: req)
        let obj = try JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed])
        return (obj as? NSNumber)?.int64Value
    }

    /// v0.8: the whole `presence/<role>` object (lastSeen + optional dnd); nil = never written.
    public func presence(_ role: Role) async throws -> PresenceInfo? {
        var req = URLRequest(url: try Self.url(databaseURL: databaseURL, pairCode: pairCode, path: "presence/\(role.rawValue)"))
        req.timeoutInterval = Self.presenceTimeout
        return PresenceInfo.decode(try await data(for: req))
    }

    /// Server-Sent Events for messages with `ts > since`. The first `put` (path "/") holds the matching
    /// backlog; later `put`s are single children. Keep-alive events are yielded too, so callers can
    /// detect a silent connection. Ends with `.cancelled` on `cancel` / `auth_revoked`.
    public func messageStream(since ts: Int64) -> AsyncThrowingStream<SSEEvent, Error> {
        let session = session
        let databaseURL = databaseURL
        let pairCode = pairCode
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try Self.messageStreamURL(databaseURL: databaseURL, pairCode: pairCode, since: ts))
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.timeoutInterval = 120
                    let (bytes, response) = try await session.bytes(for: req)
                    try Self.checkStatus(response)
                    var parser = SSEParser()
                    for try await line in bytes.lines {
                        guard let ev = parser.feed(line: line) else { continue }
                        if FirebaseDecode.isAuthRevoked(ev) { throw FirebaseError.cancelled }
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    /// v0.8.1: heartbeat / presence reads share one loop, so a stalled request must not hold it for the
    /// 60 s URLSession default (it would delay the next heartbeat past the 75 s offline threshold).
    static let presenceTimeout: TimeInterval = 10

    private func data(for req: URLRequest) async throws -> Data {
        let (body, response) = try await session.data(for: req)
        try Self.checkStatus(response)
        return body
    }

    private static func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw FirebaseError.http(http.statusCode) }
    }
}
