import Foundation

/// v0.3 per-message reactions, from `Resources/reactions.json` (built from the optional
/// `assets/reactions.json`):
///
///     { "<stickerId, message kind or *>": {"couple": <names>, "visitor": <names> | {"lulu": <names>, "lumei": <names>}} }
///
/// `<names>` is one name or (v0.3.1) a list of names = a pool one is picked from at random, never the
/// previous pick again when there is a choice. `couple` picks the meeting clip (couples.json keys, or
/// "none"); `visitor` is a clip the visitor plays once for the message: an action (`happy`, `wave`, …)
/// or a named clip of its outfit (fidgets / stay / clips), for any character or per character.
/// The `"*"` entry is the default for every message without its own (sticker or kind) value.
/// v0.5: `"sound": <names>` (optional) = sounds.json keys played at the meeting instead of the
/// couple clip's sound.
public struct Reaction: Equatable, Sendable {
    /// Pool of couples.json keys (may include `Visits.noCouple`); empty = no preference.
    public var couples: [String]
    /// Pool of visitor clips per visiting character (`Role.rawValue`), `"*"` = any character.
    public var visitor: [String: [String]]
    /// v0.5 pool of sounds.json keys for the meeting; empty = the couple clip's sound.
    public var sounds: [String]

    /// One couple / one visitor clip for any character (the pre-pool format).
    public init(couple: String? = nil, visitor: String? = nil) {
        self.init(couples: couple.map { [$0] } ?? [], visitors: visitor.map { ["*": [$0]] } ?? [:])
    }

    public init(couples: [String], visitors: [String: [String]] = [:], sounds: [String] = []) {
        self.couples = couples
        self.visitor = visitors
        self.sounds = sounds
    }

    /// The only (or first) couple name.
    public var couple: String? { couples.first }

    /// The visitor clip pool for the visiting `character`.
    public func visitorClips(for character: Role) -> [String] { visitor[character.rawValue] ?? visitor["*"] ?? [] }

    /// The only (or first) visitor clip for `character`.
    public func visitorClip(for character: Role) -> String? { visitorClips(for: character).first }
}

public struct ReactionTable: Sendable {
    /// Key of the default entry.
    public static let defaultKey = "*"

    public let entries: [String: Reaction]

    public init(entries: [String: Reaction] = [:]) { self.entries = entries }

    /// Missing or unreadable file = no reactions (the built-in defaults apply).
    public init(url: URL) {
        self.init(entries: (try? Data(contentsOf: url)).map(Self.parse) ?? [:])
    }

    /// Tolerant: non-object entries, non-string names and empty names / lists are ignored. Each name
    /// field is a string or an array of strings.
    public static func parse(_ data: Data) -> [String: Reaction] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: Reaction] = [:]
        for (key, value) in obj {
            guard let d = value as? [String: Any] else { continue }
            var visitors: [String: [String]] = [:]
            if let v = names(d["visitor"]) {
                visitors["*"] = v
            } else if let per = d["visitor"] as? [String: Any] {
                for (character, v) in per { if let v = names(v) { visitors[character] = v } }
            }
            let r = Reaction(couples: names(d["couple"]) ?? [], visitors: visitors, sounds: names(d["sound"]) ?? [])
            if !r.couples.isEmpty || !r.visitor.isEmpty || !r.sounds.isEmpty { out[key] = r }
        }
        return out
    }

    /// A non-empty string, or the non-empty strings of an array (duplicates dropped); nil if none.
    private static func names(_ v: Any?) -> [String]? {
        var list: [String] = []
        if let s = v as? String { list = [s] } else if let a = v as? [Any] { list = a.compactMap { $0 as? String } }
        var seen = Set<String>()
        list = list.filter { !$0.isEmpty && seen.insert($0).inserted }
        return list.isEmpty ? nil : list
    }

    /// The reaction for a message, field by field: the sticker's own entry first, then the entry for
    /// its kind (`text` / `sticker` / `poke` / `visit` / …), then the `"*"` default. Nil when none exists.
    public func reaction(kind: Message.Kind, stickerId: String?) -> Reaction? {
        let layers = [stickerId.flatMap { entries[$0] }, entries[kind.rawValue], entries[Self.defaultKey]].compactMap { $0 }
        guard !layers.isEmpty else { return nil }
        var visitors: [String: [String]] = [:]
        for layer in layers.reversed() { visitors.merge(layer.visitor) { _, specific in specific } }
        return Reaction(couples: layers.first { !$0.couples.isEmpty }?.couples ?? [], visitors: visitors,
                        sounds: layers.first { !$0.sounds.isEmpty }?.sounds ?? [])
    }
}

extension ReactionTable {
    /// v0.9: the pseudo-entry `"click"` (a visitor pool per character, like any other entry) holds the funny clips
    /// a single click on a pet sometimes plays instead of its plain `react` clip.
    public static let clickKey = "click"
    /// Chance (0…1) that a click plays one of the `"click"` clips (when the pet's outfit has one).
    public static let clickChance = 0.2

    /// The click clip pool for `character`.
    public func clickClips(for character: Role) -> [String] { entries[Self.clickKey]?.visitorClips(for: character) ?? [] }
}

/// Random picks from a pool that avoid repeating the previous pick when there is a choice.
public enum PoolPick {
    public static func pick<G: RandomNumberGenerator>(_ pool: [String], last: String?, using rng: inout G) -> String? {
        guard !pool.isEmpty else { return nil }
        let fresh = pool.filter { $0 != last }
        return (fresh.isEmpty ? pool : fresh).randomElement(using: &rng)
    }
}

/// Small deterministic generator (SplitMix64) for tests and reproducible demos.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
