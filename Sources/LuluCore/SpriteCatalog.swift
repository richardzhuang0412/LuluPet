import CoreGraphics
import Foundation

/// `idle` / `react` / `happy` exist for every outfit. `run` (side view, facing right) and `wave` are
/// optional (v0.2 visits); callers fall back to idle + bob and to happy when they are missing.
/// `sleep` is optional (v0.3 idle doze, looped); without it the pet freezes on idle frame 0 with Zzz.
public enum Action: String, Sendable, CaseIterable {
    case idle, react, happy, run, wave, sleep
    /// v0.8 省电: one still frame (calm, eyes open, facing front) held in quiet mode / 勿扰 (optional;
    /// without it idle frame 0 is held).
    case quiet

    /// Actions every outfit is expected to have (missing ones fall back to idle).
    public static let base: [Action] = [.idle, .react, .happy]
}

public struct SpriteClip: Sendable {
    public var frames: [URL]
    public var delays: [Double]
    public var size: CGSize
}

/// Reads `Sprites/<character>/<outfit>/<action>/meta.json`, whose `"clip"` id names the frames in
/// the shared clip store (`Clips/<id>/`, next to `Sprites/`; see `loadClip`).
public struct SpriteCatalog: Sendable {
    public let root: URL
    /// Content-addressed frame store; default `<root>/../Clips`.
    public let clipStore: URL

    public init(root: URL, clipStore: URL? = nil) {
        self.root = root
        self.clipStore = clipStore ?? root.deletingLastPathComponent().appendingPathComponent("Clips")
    }

    /// Outfits that have an idle clip, in preference order: the order listed in
    /// `<character>/order.json` (written by tools/build_sprites.py from assets/sprites.json),
    /// then any others sorted by name.
    public func outfits(for character: Role) -> [String] {
        let dir = root.appendingPathComponent(character.rawValue)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let available = names.filter { name in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent("idle/meta.json").path)
        }.sorted()
        let order = (try? Data(contentsOf: dir.appendingPathComponent("order.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var seen = Set<String>()
        let ordered = order.filter { available.contains($0) && seen.insert($0).inserted }
        return ordered + available.filter { !seen.contains($0) }
    }

    /// The character's favourite outfit: first in `order.json` that exists, else first by name.
    public func preferredOutfit(for character: Role) -> String? { outfits(for: character).first }

    public func randomOutfit(for character: Role) -> String? { outfits(for: character).randomElement() }

    /// v0.5 `<character>/outfits.json` (`{"<outfit>": {"season": ..., "label": ...}}`): outfit → season
    /// raw value (see `OutfitSeason`), for the seasonal outfits only. Missing / bad file = none.
    public func seasons(for character: Role) -> [String: String] {
        OutfitIndex.seasons(outfitIndexData(character))
    }

    /// v0.5 display names (`label`) from `<character>/outfits.json`; outfits without one are absent.
    public func labels(for character: Role) -> [String: String] {
        OutfitIndex.labels(outfitIndexData(character))
    }

    private func outfitIndexData(_ character: Role) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(character.rawValue).appendingPathComponent("outfits.json"))
    }

    /// Missing actions fall back to `idle`.
    public func clip(_ character: Role, outfit: String, action: Action) -> SpriteClip? {
        load(character, outfit, action) ?? (action == .idle ? nil : load(character, outfit, .idle))
    }

    /// The action's own clip, without falling back to idle (nil when the outfit doesn't have it).
    public func exactClip(_ character: Role, outfit: String, action: Action) -> SpriteClip? {
        load(character, outfit, action)
    }

    private func load(_ character: Role, _ outfit: String, _ action: Action) -> SpriteClip? {
        loadClip(outfitDir(character, outfit).appendingPathComponent(action.rawValue), store: clipStore)
    }

    private func outfitDir(_ character: Role, _ outfit: String) -> URL {
        root.appendingPathComponent(character.rawValue).appendingPathComponent(outfit)
    }

    /// v0.3 optional clip lists of an outfit, in manifest order: random idle `fidgets`
    /// (`<outfit>/fidgets.json` → `fidget_<i>/`), the visitor's `stay` poses (`stay.json` → `stay_<i>/`)
    /// and extra `clips` only played by reactions.json (`clips.json` → `clip_<i>/`).
    /// Entries whose clip is missing are skipped; no index = no clips.
    public func namedClips(_ character: Role, outfit: String, list: ClipList) -> [NamedClip] {
        let dir = outfitDir(character, outfit)
        let entries = (try? Data(contentsOf: dir.appendingPathComponent(list.indexFile))).map(ClipIndex.parse) ?? []
        return entries.compactMap { e in loadClip(dir.appendingPathComponent(e.dir), store: clipStore).map { NamedClip(name: e.name, clip: $0, sound: e.sound) } }
    }
}

/// Parses `<character>/outfits.json` (v0.5, written by tools/build_sprites.py). Tolerant: bad JSON,
/// non-object entries and non-string values are ignored.
public enum OutfitIndex {
    public static func seasons(_ data: Data?) -> [String: String] { field("season", data) }
    public static func labels(_ data: Data?) -> [String: String] { field("label", data) }

    private static func field(_ key: String, _ data: Data?) -> [String: String] {
        guard let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (outfit, v) in obj {
            if let s = (v as? [String: Any])?[key] as? String, !s.isEmpty { out[outfit] = s }
        }
        return out
    }
}

/// Optional per-outfit clip lists (v0.3).
public enum ClipList: String, Sendable, CaseIterable {
    case fidgets, stay, clips

    /// Index file inside the outfit directory, written by tools/build_sprites.py.
    public var indexFile: String { "\(rawValue).json" }
}

public struct NamedClip: Sendable {
    /// Manifest name (the spec's `name`, else its GIF name); `reactions.json` refers to clips by it.
    public var name: String
    public var clip: SpriteClip
    /// v0.9 clip-bound sound (sounds.json key) played when this clip is played as a reaction; nil = none.
    public var sound: String? = nil
}

/// `fidgets.json` / `stay.json`: `[{"name": "lumei_more_07", "dir": "fidget_0"}, ...]`.
/// A bare string entry is a directory name that doubles as the clip name. Bad JSON = empty list.
public enum ClipIndex {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var dir: String
        /// v0.9: optional sounds.json key bound to this clip.
        public var sound: String?
        public init(name: String, dir: String, sound: String? = nil) { self.name = name; self.dir = dir; self.sound = sound }
    }

    public static func parse(_ data: Data) -> [Entry] {
        guard let items = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return items.compactMap { item in
            if let dir = item as? String, isSafe(dir) { return Entry(name: dir, dir: dir) }
            guard let d = item as? [String: Any], let dir = d["dir"] as? String, isSafe(dir) else { return nil }
            return Entry(name: (d["name"] as? String) ?? dir, dir: dir, sound: (d["sound"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// A single path component (the index never points outside the outfit directory).
    static func isSafe(_ dir: String) -> Bool {
        !dir.isEmpty && !dir.contains("/") && dir != "." && dir != ".."
    }
}

/// Reads a clip use: `<dir>/meta.json` = `{"clip": <id>, "delays": [...], ...}` with the frames in
/// `<store>/<id>/{000.webp…, meta.json}` (store meta: `frames` / `width` / `height` / `ext`), written
/// by tools/build_sprites.py so identical frames are stored once. Without `"clip"` the frames are
/// `<dir>/000.png…` and `meta.json` carries `frames` / `width` / `height` itself (older layout).
func loadClip(_ dir: URL, store: URL) -> SpriteClip? {
    struct Use: Decodable { let clip: String?; let frames: Int?; let delays: [Double]; let width: Double?; let height: Double? }
    struct Stored: Decodable { let frames: Int; let width: Double; let height: Double; let ext: String? }
    guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
          let use = try? JSONDecoder().decode(Use.self, from: data) else { return nil }
    let frameDir: URL, count: Int, size: CGSize, ext: String
    if let id = use.clip {
        guard ClipIndex.isSafe(id) else { return nil }
        frameDir = store.appendingPathComponent(id)
        guard let sdata = try? Data(contentsOf: frameDir.appendingPathComponent("meta.json")),
              let stored = try? JSONDecoder().decode(Stored.self, from: sdata) else { return nil }
        count = stored.frames
        size = CGSize(width: stored.width, height: stored.height)
        ext = stored.ext.flatMap { ClipIndex.isSafe($0) ? $0 : nil } ?? "png"
    } else {
        guard let frames = use.frames, let w = use.width, let h = use.height else { return nil }
        frameDir = dir
        count = frames
        size = CGSize(width: w, height: h)
        ext = "png"
    }
    guard count > 0 else { return nil }
    let frames = (0..<count).map { frameDir.appendingPathComponent(String(format: "%03d.", $0) + ext) }
    let delays = (0..<count).map { $0 < use.delays.count ? use.delays[$0] : 0.1 }
    return SpriteClip(frames: frames, delays: delays, size: size)
}

/// A two-character clip (hug / kiss / nuzzle) played when the visitor meets the home pet.
public struct CoupleClip: Sendable {
    public var clip: SpriteClip
    /// True when 噜噜 is on the left in the source frames (`"facing": "lulu-left"`, the default).
    public var luluOnLeft: Bool
    /// v0.9 clip-bound sound (couples.json `"sound"`, a sounds.json key): played with this clip instead of
    /// the category sound (`SoundEvent.forCouple`). Nil = none.
    public var sound: String? = nil
    /// v0.9 couples.json `"heightFactor"`: drawn at this fraction of the pet's height (half-body clips); default 1.
    public var heightFactor: Double = 1
    /// v0.11 couples.json `"intimate": true`: a kiss / hug / cuddle, filtered out in friend mode (`ContentPolicy`).
    public var intimate: Bool = false

    /// Whether to mirror the clip so each character lands on its actual side.
    public func mirrored(luluIsLeft: Bool) -> Bool { luluIsLeft != luluOnLeft }
}

/// Reads `Couples/<name>/meta.json` (a clip use, see `loadClip`; meta also carries `facing`), written
/// by tools/build_sprites.py from assets/couples.json.
public struct CoupleCatalog: Sendable {
    public let root: URL
    /// Content-addressed frame store; default `<root>/../Clips`.
    public let clipStore: URL

    public init(root: URL, clipStore: URL? = nil) {
        self.root = root
        self.clipStore = clipStore ?? root.deletingLastPathComponent().appendingPathComponent("Clips")
    }

    public var names: Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(names.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("meta.json").path) })
    }

    public func clip(named name: String) -> CoupleClip? {
        let dir = root.appendingPathComponent(name)
        guard let clip = loadClip(dir, store: clipStore) else { return nil }
        struct Extra: Decodable { let facing: String?; let sound: String?; let heightFactor: Double?; let intimate: Bool? }
        let extra = (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(Extra.self, from: $0) }
        return CoupleClip(clip: clip, luluOnLeft: extra?.facing != "lulu-right", sound: extra?.sound.flatMap { $0.isEmpty ? nil : $0 },
                          heightFactor: min(1.5, max(0.3, extra?.heightFactor ?? 1)),
                          intimate: extra?.intimate ?? false)
    }
}
