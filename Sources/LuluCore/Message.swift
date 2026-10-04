import Foundation

/// One message. Wire format (Firebase `/pairs/<code>/messages/<pushId>`):
/// `{from, kind, text?, stickerId?, ts, v?, outfit?, trip?, remind?, ackOf?}` plus any fields a newer app version adds.
/// Upgrade rule (docs/upgrade-compat.md): fields may only be ADDED, never renamed or removed, and
/// decoding must never fail on data written by a newer version.
public struct Message: Codable, Equatable, Sendable, Identifiable {
    /// Unknown kinds (written by a newer app) are kept as `.unknown(raw)` and re-encoded unchanged.
    public enum Kind: RawRepresentable, Codable, Hashable, Sendable {
        case text, sticker, poke
        /// v0.2 "去找TA": the sender's character runs over to the partner's desktop. Clients older
        /// than v0.2 decode it as `.unknown("visit")` and show the upgrade placeholder.
        case visit
        /// v0.10 「叫 TA 喝水 / 起来动动」 (`remind` = water | stand; `ackOf` set on the "done" receipt). Clients
        /// older than v0.10 decode it as `.unknown("remind")`: shown with the upgrade placeholder, kept in history.
        case remind
        case unknown(String)

        public init(rawValue: String) {
            switch rawValue {
            case "text": self = .text
            case "sticker": self = .sticker
            case "poke": self = .poke
            case "visit": self = .visit
            case "remind": self = .remind
            default: self = .unknown(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .text: return "text"
            case .sticker: return "sticker"
            case .poke: return "poke"
            case .visit: return "visit"
            case .remind: return "remind"
            case .unknown(let raw): return raw
            }
        }

        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    public static let maxTextLength = 500
    /// Written as `v` on send; a message without `v` is version 1.
    public static let currentSchemaVersion = 1
    /// Shown instead of a message whose kind this version doesn't understand.
    public static let unknownKindPlaceholder = "［新版本消息，请升级噜噜桌宠查看］"

    public var id: String
    public var from: Role
    public var kind: Kind
    public var text: String?
    public var stickerId: String?
    /// Unix milliseconds (sender's clock).
    public var ts: Int64
    /// Schema version of the sender; nil means 1.
    public var v: Int?
    /// v0.5 (optional): the outfit the sender's pet was wearing when it was sent, so the receiver's
    /// visitor can wear the same one. Older clients keep it in `extra`; nil = unknown / older sender.
    public var outfit: String?
    /// v0.6 (optional): `"deliver"` when the sender's pet actually ran off its desk to deliver this message,
    /// `"local"` when it didn't (a local meeting with the visitor, the pet was already out, or the partner was
    /// offline). Missing (older senders) or unknown values count as `"deliver"` (`Message.isDeliveryTrip`).
    /// Older clients keep it in `extra`.
    public var trip: String?
    /// v0.10 (optional, kind `remind`): `"water"` / `"stand"`, kept as the raw string so a newer client's value
    /// survives a re-encode; `remind` is the typed view (unknown value → nil). Older clients keep it in `extra`.
    public var remindRaw: String?
    /// v0.10 (optional): on a `remind` receipt, the id of the reminder it answers.
    public var ackOf: String?
    /// v0.14.4 (optional, on a `remind` reply): `"now"` | `"later"` (see `RemindReply`). Missing = `"now"` (a v0.10–v0.14.3 receipt).
    /// Older clients keep it in `extra`.
    public var answer: String?
    /// v0.14.4 (optional, on a `"now"` reply): true = TA did it after first pressing 等会儿. Older clients keep it in `extra`.
    public var late: Bool?
    /// v0.11 (optional): the character the sender's pet is drawn as. An unknown value (a future character) reads as
    /// nil and its raw string stays in `extra["character"]`, re-encoded unchanged. Older clients keep it in `extra`.
    public var character: PetCharacter?
    /// Local only (history file, never sent): the client id a sent message had before the server
    /// assigned its push id.
    public var localId: String?
    /// Fields this version doesn't know, preserved verbatim so nothing is lost on re-encode.
    public var extra: [String: JSONValue]

    public var schemaVersion: Int { v ?? 1 }

    public var remind: ReminderKind? {
        get { remindRaw.flatMap(ReminderKind.init(rawValue:)) }
        set { remindRaw = newValue?.rawValue }
    }

    /// v0.6 `trip` values.
    public static let tripDeliver = "deliver"
    public static let tripLocal = "local"
    /// Whether the sender's pet ran over with this message (`trip` missing / unknown = yes, as older
    /// clients' messages were all "deliveries" from the receiver's point of view).
    public var isDeliveryTrip: Bool { trip != Message.tripLocal }

    public init(id: String = UUID().uuidString, from: Role, kind: Kind, text: String? = nil, stickerId: String? = nil,
                ts: Int64, v: Int? = Message.currentSchemaVersion, outfit: String? = nil, trip: String? = nil, localId: String? = nil,
                remind: ReminderKind? = nil, ackOf: String? = nil, character: PetCharacter? = nil, extra: [String: JSONValue] = [:]) {
        self.id = id
        self.from = from
        self.kind = kind
        self.text = text.map { String($0.prefix(Message.maxTextLength)) }
        self.stickerId = stickerId
        self.ts = ts
        self.v = v
        self.outfit = outfit
        self.trip = trip
        self.remindRaw = remind?.rawValue
        self.ackOf = ackOf
        self.character = character
        self.localId = localId
        self.extra = extra
    }

    public static func text(_ text: String, from: Role, ts: Int64 = nowMs()) -> Message {
        Message(from: from, kind: .text, text: text, ts: ts)
    }

    public static func sticker(_ id: String, from: Role, ts: Int64 = nowMs()) -> Message {
        Message(from: from, kind: .sticker, stickerId: id, ts: ts)
    }

    public static func poke(from: Role, ts: Int64 = nowMs()) -> Message {
        Message(from: from, kind: .poke, ts: ts)
    }

    public static func visit(from: Role, ts: Int64 = nowMs()) -> Message {
        Message(from: from, kind: .visit, ts: ts)
    }

    /// v0.10: ask the partner to drink water / stand up; with `ackOf` (the reminder's id) it is the receipt.
    public static func remind(_ kind: ReminderKind, from: Role, ackOf: String? = nil, ts: Int64 = nowMs()) -> Message {
        Message(from: from, kind: .remind, ts: ts, remind: kind, ackOf: ackOf)
    }

    // MARK: Codable (flat object: known fields + `extra`)

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    private static let knownKeys: Set<String> = ["id", "from", "kind", "text", "stickerId", "ts", "v", "outfit", "trip", "localId", "remind", "ackOf", "answer", "late", "character"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(String.self, forKey: Key("id")) ?? ""
        from = try c.decode(Role.self, forKey: Key("from"))
        kind = try c.decode(Kind.self, forKey: Key("kind"))
        text = try? c.decodeIfPresent(String.self, forKey: Key("text"))
        stickerId = try? c.decodeIfPresent(String.self, forKey: Key("stickerId"))
        ts = try c.decode(Int64.self, forKey: Key("ts"))
        v = try? c.decodeIfPresent(Int.self, forKey: Key("v"))
        outfit = try? c.decodeIfPresent(String.self, forKey: Key("outfit"))
        trip = try? c.decodeIfPresent(String.self, forKey: Key("trip"))
        remindRaw = try? c.decodeIfPresent(String.self, forKey: Key("remind"))
        ackOf = try? c.decodeIfPresent(String.self, forKey: Key("ackOf"))
        answer = try? c.decodeIfPresent(String.self, forKey: Key("answer"))
        late = try? c.decodeIfPresent(Bool.self, forKey: Key("late"))
        localId = try? c.decodeIfPresent(String.self, forKey: Key("localId"))
        var extra: [String: JSONValue] = [:]
        for k in c.allKeys where !Self.knownKeys.contains(k.stringValue) {
            extra[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        if let raw = try? c.decodeIfPresent(JSONValue.self, forKey: Key("character")), raw != .null {
            if case .string(let s) = raw, let known = PetCharacter(rawValue: s) { character = known } else { extra["character"] = raw }
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        try encode(to: encoder, local: true)
    }

    fileprivate func encode(to encoder: Encoder, local: Bool) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (k, value) in extra where !Self.knownKeys.contains(k) { try c.encode(value, forKey: Key(k)) }
        if local { try c.encode(id, forKey: Key("id")) }
        try c.encode(from, forKey: Key("from"))
        try c.encode(kind, forKey: Key("kind"))
        try c.encodeIfPresent(text, forKey: Key("text"))
        try c.encodeIfPresent(stickerId, forKey: Key("stickerId"))
        try c.encode(ts, forKey: Key("ts"))
        try c.encodeIfPresent(v, forKey: Key("v"))
        try c.encodeIfPresent(outfit, forKey: Key("outfit"))
        try c.encodeIfPresent(trip, forKey: Key("trip"))
        try c.encodeIfPresent(remindRaw, forKey: Key("remind"))
        try c.encodeIfPresent(ackOf, forKey: Key("ackOf"))
        try c.encodeIfPresent(answer, forKey: Key("answer"))
        try c.encodeIfPresent(late, forKey: Key("late"))
        if let character { try c.encode(character, forKey: Key("character")) }
        else if let raw = extra["character"] { try c.encode(raw, forKey: Key("character")) }   // unknown value, kept verbatim
        if local { try c.encodeIfPresent(localId, forKey: Key("localId")) }
    }

    /// JSON body for Firebase; the key (push id) is assigned by the server, so `id` (and `localId`) are omitted.
    public func firebasePayload() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try! enc.encode(WirePayload(message: self))
    }

    /// Decodes one Firebase child (`value` of `/messages/<key>`); nil if it lacks from/kind/ts.
    public static func decode(firebaseKey key: String, value: Any) -> Message? {
        guard JSONSerialization.isValidJSONObject(value),
              let json = try? JSONSerialization.data(withJSONObject: value),
              var m = try? JSONDecoder().decode(Message.self, from: json) else { return nil }
        m.id = key
        m.localId = nil
        return m
    }
}

private struct WirePayload: Encodable {
    let message: Message
    func encode(to encoder: Encoder) throws { try message.encode(to: encoder, local: false) }
}

/// Any JSON value, used to carry fields from newer app versions through unchanged.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
