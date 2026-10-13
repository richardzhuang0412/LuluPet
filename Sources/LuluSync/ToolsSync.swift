import Foundation
import LuluCore

/// v0.18 personal-tool sync between MY devices (spec 2026-10-12 §2.2, upgrade-compat §17):
/// `/pairs/{code}/tools/{seat}/eyedrops`. Only this seat's devices read or write it (TA's app never does). Plain REST,
/// no stream: settings are read at launch / every 10 min / when the 小工具 tab opens, today's check-ins right before a
/// reminder is shown. Every call throws on failure; the caller queues the write in `eyedropsPending`.
public final class ToolsSync: Sendable {
    public let client: FirebaseClient
    public let pair: String
    public let seat: Role
    private let session: URLSession

    /// Writes / settings reads give up after 5 s; the read right before a reminder after 3 s (then the local copy rules).
    public static let timeout: TimeInterval = 5
    public static let dayTimeout: TimeInterval = 3

    public init(client: FirebaseClient, pair: String? = nil, seat: Role, session: URLSession = .shared) {
        self.client = client
        self.pair = pair ?? client.pairCode
        self.seat = seat
        self.session = session
    }

    private func url(_ sub: String) throws -> URL {
        try FirebaseClient.url(databaseURL: client.databaseURL, pairCode: pair, path: "tools/\(seat.rawValue)/eyedrops/\(sub)")
    }

    private func send(_ method: String, _ sub: String, body: Any? = nil, timeout: TimeInterval = ToolsSync.timeout) async throws -> Data {
        var req = URLRequest(url: try url(sub))
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw FirebaseError.http(http.statusCode) }
        return data
    }

    private static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    /// nil = never written (or unreadable: decoding is tolerant, a bad node reads as nothing).
    public func getSettings() async throws -> EyeDropsSettings? {
        EyeDropsSettings(json: Self.json(try await send("GET", "settings")))
    }

    /// The whole settings object (last writer wins by `at`, decided by the caller).
    public func putSettings(_ s: EyeDropsSettings) async throws {
        _ = try await send("PUT", "settings", body: s.json)
    }

    /// Check-ins of one local day (`yyyy-MM-dd`): `HHmm` → done.
    public func getDay(_ day: String) async throws -> [String: EyeDropsMark] {
        EyeDrops.decodeDays(json: [day: Self.json(try await send("GET", "days/\(day)", timeout: Self.dayTimeout)) ?? NSNull()])[day] ?? [:]
    }

    /// One leaf `days/{day}/{HHmm}` = `{"done", "device"}` (idempotent).
    public func putDone(day: String, slot: String, device: String, done: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) async throws {
        _ = try await send("PUT", "days/\(day)/\(slot)", body: ["done": done, "device": device] as [String: Any])
    }

    /// Undo: removes the leaf (the caller only deletes check-ins this device wrote).
    public func deleteDone(day: String, slot: String) async throws {
        _ = try await send("DELETE", "days/\(day)/\(slot)")
    }
}
