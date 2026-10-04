import Foundation

/// v0.5 sounds (docs/superpowers/specs/2026-09-28-visits-design.md, "v0.5 声音"): which sound file an
/// event plays, per-event throttling and mute / hidden gating. Pure rules; LuluPet's `SoundPlayer`
/// does the playing.
///
/// `Resources/Sounds/sounds.json` (built from `assets/sounds.json` by tools/build_sounds.py):
///
///     { "<event>": "file.m4a" | ["file1.m4a", "file2.m4a"], ..., "bgm": [...] }
///
/// Events are the `SoundEvent` names; any other key is a custom event a reactions.json `"sound"` /
/// couples.json `"sound"` (clip-bound) can name. A missing event (or one whose files are all missing)
/// is silently skipped.
///
/// v0.9 character-specific voice lines: a list entry may be an object `{"file": "v4/S01.m4a",
/// "visitor": "lulu"}` instead of a plain name. A plain name is neutral (plays whoever it is about);
/// a file with `"visitor"` only plays when the pet the event is about (arrive: the visiting pet;
/// goVisit / goBack: our own pet) is that character. Old manifests (plain names only) parse unchanged,
/// and a manifest with filters still parses in older builds' eyes as "no such file" for those entries
/// only (they skip non-string entries), so the rest keeps working.
public enum SoundEvent: String, Sendable, CaseIterable {
    case arrive, leave, poke, hug, kiss, nuzzle, bubble, angry, cry, happy, doze
    case awaySummary, goVisit, goBack, notHome, click

    /// Manifest key of the optional background music pool (not an event: see `SoundGate.allowsBGM`).
    public static let bgmKey = "bgm"

    /// The meeting sound for a couple clip name (couples.json key): kiss* → kiss, nuzzle* → nuzzle,
    /// hug* → hug, angry* → angry, anything else (dance, wink, flowers, …, or no clip) → happy.
    /// v0.9 keys: cuddle* / lean / sniff → nuzzle, comfort → hug, coldwar / shout → angry,
    /// bite → poke, sleep → doze.
    public static func forCouple(_ name: String?) -> SoundEvent {
        guard let name else { return .happy }
        for (prefix, event) in coupleSoundPrefixes where name.hasPrefix(prefix) { return event }
        return .happy
    }

    private static let coupleSoundPrefixes: [(String, SoundEvent)] = [
        ("kiss", .kiss), ("nuzzle", .nuzzle), ("hug", .hug), ("angry", .angry),
        ("cuddle", .nuzzle), ("lean", .nuzzle), ("sniff", .nuzzle), ("comfort", .hug),
        ("coldwar", .angry), ("shout", .angry), ("bite", .poke), ("sleep", .doze),
    ]

    /// v0.9: the sounds.json keys to try, in order, for a meeting (the first one with a sound plays):
    /// the message reaction's own `"sound"` pool, then the couple clip's bound sound (couples.json
    /// `"sound"`), then the built-in sticker sound, and finally the clip's category sound (`forCouple`).
    public static func meetingKeys(reaction: [String], clipSound: String?, fallback: [String], couple: String?) -> [String] {
        reaction + [clipSound].compactMap { $0 } + fallback + [forCouple(couple).rawValue]
    }

    /// Built-in sound for a sticker's reaction when reactions.json gives none: angry / cry / happy.
    public static func forSticker(_ id: String?) -> SoundEvent? {
        switch id {
        // v0.15 stickers follow the reaction pool they are mapped to (assets/reactions.json).
        case "angry"?, "heng"?, "heng2"?, "lengzhan"?, "xiongni"?: return .angry
        case "cry"?, "anwei"?, "weiqu"?, "xinsui"?, "xiasi"?, "leitan"?, "aqi"?: return .cry
        case "happy"?, "celebrate"?, "haha"?, "haha2"?, "xiaosi"?, "heihei"?, "heihei2"?, "wow"?, "haode"?,
             "biye"?, "ye"?, "jiayou"?, "facai"?, "shengdan"?: return .happy
        default: return nil
        }
    }
}

/// Settings defaults and volume presets.
public enum SoundDefaults {
    /// Flip this one constant to ship with sound off.
    public static let enabled = true
    /// 小 / 中 / 大 in the status menu.
    public static let presets: [(title: String, volume: Float)] = [("小", 0.25), ("中", 0.5), ("大", 0.8)]
    /// Default master volume (小).
    public static let volume: Float = 0.25
    /// Background music: off unless turned on in Settings / the menu.
    public static let bgmEnabled = false
    /// BGM plays at this fraction of the master volume.
    public static let bgmFactor: Float = 0.5
    /// The same event doesn't start again within this many seconds.
    public static let throttle: TimeInterval = 0.3

    /// Index of the preset nearest to `volume` (for the menu checkmark).
    public static func presetIndex(for volume: Float) -> Int {
        presets.indices.min { abs(presets[$0].volume - volume) < abs(presets[$1].volume - volume) } ?? 0
    }
}

public struct SoundManifest: Equatable, Sendable {
    /// Event (or `bgm`, or a custom key) → file names relative to the Sounds folder (every file,
    /// whoever it is restricted to).
    public let entries: [String: [String]]
    /// v0.9: event → file → character (`Role.rawValue`) for the files that only play for that character.
    public let only: [String: [String: String]]
    /// v0.11: event → files flagged `"intimate": true` (skipped when `ContentPolicy` doesn't allow intimate content).
    /// An event whose files are all intimate is thereby skipped as a whole.
    public let intimate: [String: Set<String>]

    public init(entries: [String: [String]] = [:], only: [String: [String: String]] = [:], intimate: [String: Set<String>] = [:]) {
        self.entries = entries
        self.only = only
        self.intimate = intimate
    }

    /// Missing or unreadable file = no sounds.
    public init(url: URL) {
        let parsed = (try? Data(contentsOf: url)).map(Self.parseFull) ?? (entries: [:], only: [:], intimate: [:])
        self.init(entries: parsed.entries, only: parsed.only, intimate: parsed.intimate)
    }

    /// Tolerant: each value is a file name, an object `{"file", "visitor"}` or a list of those;
    /// non-strings, empty names and duplicates are dropped, and keys left without files are omitted.
    public static func parse(_ data: Data) -> [String: [String]] { parseFull(data).entries }

    /// Like `parse`, plus the per-file character filters (`"visitor": "lulu" | "lumei"`; any other value
    /// is ignored = neutral). The first mention of a file within an event decides its filter.
    public static func parseFull(_ data: Data) -> (entries: [String: [String]], only: [String: [String: String]], intimate: [String: Set<String>]) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([:], [:], [:]) }
        var out: [String: [String]] = [:]
        var only: [String: [String: String]] = [:]
        var intimate: [String: Set<String>] = [:]
        for (key, value) in obj {
            var raw: [Any] = []
            if let a = value as? [Any] { raw = a } else { raw = [value] }
            var list: [String] = []
            var filters: [String: String] = [:]
            var intimateFiles: Set<String> = []
            for item in raw {
                var file: String?
                var who: String?
                var isIntimate = false
                if let s = item as? String { file = s } else if let d = item as? [String: Any] {
                    file = d["file"] as? String
                    who = (d["visitor"] as? String).flatMap { Role(rawValue: $0) }?.rawValue
                    isIntimate = (d["intimate"] as? Bool) == true
                }
                guard let f = file, !f.isEmpty, !list.contains(f) else { continue }
                list.append(f)
                if let who { filters[f] = who }
                if isIntimate { intimateFiles.insert(f) }
            }
            if !list.isEmpty {
                out[key] = list
                if !filters.isEmpty { only[key] = filters }
                if !intimateFiles.isEmpty { intimate[key] = intimateFiles }
            }
        }
        return (out, only, intimate)
    }

    /// Every file of `key`, whoever it is restricted to.
    public func files(for key: String) -> [String] { entries[key] ?? [] }

    /// The files of `key` that may play for `visitor` (the character the event is about; nil = unknown,
    /// which only gets the neutral files).
    /// `allowIntimate` false (friend / solo, see `ContentPolicy.allowsIntimate`) also drops the files flagged intimate.
    public func files(for key: String, visitor: Role?, allowIntimate: Bool = true) -> [String] {
        let filters = only[key] ?? [:]
        let blocked = allowIntimate ? [] : (intimate[key] ?? [])
        return files(for: key).filter { f in !blocked.contains(f) && (filters[f].map { $0 == visitor?.rawValue } ?? true) }
    }

    /// Only the files for which `exists` is true; `missing` lists the dropped ones as "event: file".
    public func resolved(exists: (String) -> Bool) -> (manifest: SoundManifest, missing: [String]) {
        var kept: [String: [String]] = [:]
        var keptOnly: [String: [String: String]] = [:]
        var keptIntimate: [String: Set<String>] = [:]
        var missing: [String] = []
        for key in entries.keys.sorted() {
            let files = entries[key] ?? []
            let ok = files.filter(exists)
            missing += files.filter { !ok.contains($0) }.map { "\(key): \($0)" }
            if !ok.isEmpty {
                kept[key] = ok
                if let f = only[key]?.filter({ ok.contains($0.key) }), !f.isEmpty { keptOnly[key] = f }
                if let i = intimate[key]?.filter({ ok.contains($0) }), !i.isEmpty { keptIntimate[key] = i }
            }
        }
        return (SoundManifest(entries: kept, only: keptOnly, intimate: keptIntimate), missing)
    }
}

/// Random file per play, never the previous file of that event again when there is a choice.
public struct SoundPicker: Sendable {
    public private(set) var last: [String: String] = [:]
    public init() {}

    public mutating func pick<G: RandomNumberGenerator>(_ key: String, from files: [String], using rng: inout G) -> String? {
        guard let f = PoolPick.pick(files, last: last[key], using: &rng) else { return nil }
        last[key] = f
        return f
    }
}

/// Whether a sound may start now.
public enum SoundDecision: Equatable, Sendable {
    case play
    /// Sound is turned off.
    case muted
    /// The pet is hidden (by hand or a fullscreen app).
    case hidden
    /// The same event started less than `SoundDefaults.throttle` seconds ago.
    case throttled
    /// Right after the pet is shown again: only the "你不在的时候" card's sound plays.
    case awayOnly
}

/// Mute / hidden / throttle gate. `now` is any monotonic clock in seconds.
public struct SoundGate: Sendable {
    public var enabled: Bool
    public var hidden = false
    public let throttle: TimeInterval
    /// While set (and not past), only `awaySummary` plays: the replayed away messages stay quiet.
    public private(set) var awayOnlyUntil: TimeInterval?
    private var lastStart: [String: TimeInterval] = [:]

    public init(enabled: Bool = SoundDefaults.enabled, throttle: TimeInterval = SoundDefaults.throttle) {
        self.enabled = enabled
        self.throttle = throttle
    }

    /// Decides for `event` (a SoundEvent raw value or a custom key); a `.play` records the start.
    public mutating func decide(_ event: String, now: TimeInterval) -> SoundDecision {
        if !enabled { return .muted }
        if hidden { return .hidden }
        if let until = awayOnlyUntil {
            if now >= until { awayOnlyUntil = nil } else if event != SoundEvent.awaySummary.rawValue { return .awayOnly }
        }
        if let last = lastStart[event], now - last < throttle { return .throttled }
        lastStart[event] = now
        return .play
    }

    /// Background music may start (once) now.
    public var allowsBGM: Bool { enabled && !hidden }

    /// The away batch is being replayed: only the card's sound for at most `duration` seconds
    /// (or until `endAwayOnly()`).
    public mutating func beginAwayOnly(now: TimeInterval, duration: TimeInterval) { awayOnlyUntil = now + duration }
    public mutating func endAwayOnly() { awayOnlyUntil = nil }
}
