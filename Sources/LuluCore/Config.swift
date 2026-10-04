import Foundation

public struct AppConfig: Codable, Equatable, Sendable {
    public var role: Role
    public var pairCode: String
    public var databaseURL: String
    /// v0.11: nil = couple (configs written before v0.11 have no `mode`).
    public var mode: PairMode?
    /// v0.11: which character I draw; nil = the one named like my seat (`role`).
    public var character: PetCharacter?

    public init(role: Role, pairCode: String, databaseURL: String, mode: PairMode? = nil, character: PetCharacter? = nil) {
        self.role = role
        self.pairCode = pairCode
        self.databaseURL = databaseURL
        self.mode = mode
        self.character = character
    }

    public var effectiveMode: PairMode { mode ?? .couple }
    public var myCharacter: PetCharacter { character ?? PetCharacter(role) }

    // Tolerant decoding: a `mode` / `character` this version doesn't know (written by a newer one) reads as
    // nil instead of making the whole config unreadable. nil values are not written.
    private enum CodingKeys: String, CodingKey { case role, pairCode, databaseURL, mode, character }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        pairCode = try c.decode(String.self, forKey: .pairCode)
        databaseURL = try c.decode(String.self, forKey: .databaseURL)
        mode = (try? c.decodeIfPresent(PairMode.self, forKey: .mode)) ?? nil
        character = (try? c.decodeIfPresent(PetCharacter.self, forKey: .character)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(pairCode, forKey: .pairCode)
        try c.encode(databaseURL, forKey: .databaseURL)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(character, forKey: .character)
    }

    public var normalizedDatabaseURL: String {
        var s = databaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public var isComplete: Bool {
        if effectiveMode == .solo { return true }   // v0.11: solo needs no code / URL (they are kept for switching back)
        guard PairCode.isValid(pairCode) else { return false }
        let url = normalizedDatabaseURL
        if url.hasPrefix("https://") { return true }
        // Plain http only for a local test server (tools/fake_firebase.py).
        guard url.hasPrefix("http://"), let host = URL(string: url)?.host else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }
}

/// Per-profile persistence. A profile lets two instances run side by side on one Mac for testing.
public struct ConfigStore: @unchecked Sendable {
    public let defaults: UserDefaults
    private let suite: String?

    public init(profile: String?) {
        suite = profile.map { "lulupet.\($0)" }
        defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func load() -> AppConfig? {
        defaults.data(forKey: "config").flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
    }

    public func save(_ config: AppConfig) {
        defaults.set(try? JSONEncoder().encode(config), forKey: "config")
    }

    /// Timestamp of the newest partner message already shown.
    public var lastReadTs: Int64 {
        get { (defaults.object(forKey: "lastReadTs") as? NSNumber)?.int64Value ?? 0 }
        nonmutating set { defaults.set(NSNumber(value: newValue), forKey: "lastReadTs") }
    }

    /// v0.11: one random id per machine / profile, generated on first read (`deviceId`, UUID string). Published
    /// in presence so two machines on the same seat can be told apart (`SeatClash`).
    public var deviceId: String {
        if let id = defaults.string(forKey: "deviceId"), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "deviceId")
        return id
    }

    /// v0.11.2: the partner version I was already bubbled about (`upgradeNudgedFor`, String like "0.12.0"; absent = none).
    public var upgradeNudgedFor: String? {
        get { defaults.string(forKey: "upgradeNudgedFor") }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "upgradeNudgedFor") } else { defaults.removeObject(forKey: "upgradeNudgedFor") }
        }
    }

    /// v0.13: the app version whose update log I last saw (`whatsNewSeen`, String like "0.13.0"; absent = never / upgraded
    /// from ≤ 0.12.2).
    public var whatsNewSeen: String? {
        get { defaults.string(forKey: "whatsNewSeen") }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "whatsNewSeen") } else { defaults.removeObject(forKey: "whatsNewSeen") }
        }
    }

    /// v0.14: when the daily update check last ran (`updateLastCheck`, Unix seconds as Double; absent = never).
    public var updateLastCheck: TimeInterval? {
        get { defaults.object(forKey: "updateLastCheck") as? Double }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "updateLastCheck") } else { defaults.removeObject(forKey: "updateLastCheck") }
        }
    }

    /// v0.14: the release version I tapped 以后再说 on (`updateSkipped`, String like "0.14.0"; absent = none). Only the
    /// automatic check stays quiet about it; a newer release is announced again.
    public var updateSkipped: String? {
        get { defaults.string(forKey: "updateSkipped") }
        nonmutating set {
            if let newValue { defaults.set(newValue, forKey: "updateSkipped") } else { defaults.removeObject(forKey: "updateSkipped") }
        }
    }

    /// v0.13: ids of the 待设置 items I tapped 不用了 on (`setupTodoDismissed`, array of strings; absent = none).
    public var setupTodoDismissed: Set<String> {
        get { Set(defaults.stringArray(forKey: "setupTodoDismissed") ?? []) }
        nonmutating set { defaults.set(newValue.sorted(), forKey: "setupTodoDismissed") }
    }

    // MARK: v0.4 preferences (new keys, see docs/upgrade-compat.md)

    /// Global shortcut: show / hide the pet (`hotkeyToggle`, JSON of `Shortcut`; absent = ⌃⌥L).
    public var toggleShortcut: Shortcut {
        get { shortcut(forKey: "hotkeyToggle") ?? .defaultToggle }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkeyToggle") }
    }

    /// Global shortcut: open the compose panel (`hotkeyCompose`; absent = ⌃⌥M).
    public var composeShortcut: Shortcut {
        get { shortcut(forKey: "hotkeyCompose") ?? .defaultCompose }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkeyCompose") }
    }

    /// v0.7 global shortcut: quit the app (`hotkeyQuit`; absent = ⌃⌥Q).
    public var quitShortcut: Shortcut {
        get { shortcut(forKey: "hotkeyQuit") ?? .defaultQuit }
        nonmutating set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "hotkeyQuit") }
    }

    private func shortcut(forKey key: String) -> Shortcut? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }

    /// Hide the pet while a fullscreen app is in front on its screen (`autoHideFullscreen`; absent = on).
    public var autoHideInFullscreen: Bool {
        get { (defaults.object(forKey: "autoHideFullscreen") as? NSNumber)?.boolValue ?? true }
        nonmutating set { defaults.set(newValue, forKey: "autoHideFullscreen") }
    }

    /// v0.6.3: keep the Dock icon visible (default off: menu-bar only). New key `showInDock`.
    public var showInDock: Bool {
        get { (defaults.object(forKey: "showInDock") as? NSNumber)?.boolValue ?? false }
        nonmutating set { defaults.set(newValue, forKey: "showInDock") }
    }

    /// v0.7 pet size (`petScale`, Double; absent = 1.0). Read and written clamped to
    /// [`PetScale.min`, `PetScale.max`], so a hand-edited or future out-of-range value is harmless.
    public var petScale: Double {
        get { (defaults.object(forKey: "petScale") as? NSNumber).map { PetScale.clamp($0.doubleValue) } ?? PetScale.standard }
        nonmutating set { defaults.set(PetScale.normalized(newValue), forKey: "petScale") }
    }

    // MARK: v0.8 勿扰模式 (new keys, see docs/upgrade-compat.md)

    /// `dndUntil` (Double, Unix s; 0 = until turned off; absent = off), `dndMood` (String, a `DNDMood`
    /// raw value; absent / unknown = 不说原因; kept while off = the menu's choice), `dndSince` (Double,
    /// Unix s, when it was turned on). An expired `dndUntil` is ended by the app at launch.
    public var dnd: DNDState {
        get {
            DNDState(until: (defaults.object(forKey: "dndUntil") as? NSNumber)?.doubleValue,
                     mood: defaults.string(forKey: "dndMood").flatMap(DNDMood.init(rawValue:)) ?? .default,
                     since: (defaults.object(forKey: "dndSince") as? NSNumber)?.doubleValue)
        }
        nonmutating set {
            defaults.set(newValue.mood.rawValue, forKey: "dndMood")
            if let u = newValue.until { defaults.set(u, forKey: "dndUntil") } else { defaults.removeObject(forKey: "dndUntil") }
            if let s = newValue.since { defaults.set(s, forKey: "dndSince") } else { defaults.removeObject(forKey: "dndSince") }
        }
    }

    /// Finished 勿扰 stretches for the「记录」tab (`dndLog`, JSON `[{"start": ms, "end": ms, "mood": ...}]`,
    /// newest last, at most `DNDSpan.maxLog`). Bad data reads as empty.
    public var dndLog: [DNDSpan] {
        get { defaults.data(forKey: "dndLog").flatMap { try? JSONDecoder().decode([DNDSpan].self, from: $0) } ?? [] }
        nonmutating set { defaults.set(try? JSONEncoder().encode(Array(newValue.suffix(DNDSpan.maxLog))), forKey: "dndLog") }
    }

    /// v0.8 "换回上一个" stack per character (`outfitHistory`, dictionary `{role rawValue: [outfit]}`, most
    /// recent first, ≤ 10). Absent = empty; unknown outfit names are skipped when popped.
    public func outfitHistory(for role: Role) -> OutfitHistory {
        OutfitHistory(((defaults.dictionary(forKey: "outfitHistory") as? [String: [String]]) ?? [:])[role.rawValue] ?? [])
    }

    public func setOutfitHistory(_ h: OutfitHistory, for role: Role) {
        var all = (defaults.dictionary(forKey: "outfitHistory") as? [String: [String]]) ?? [:]
        all[role.rawValue] = h.stack
        defaults.set(all, forKey: "outfitHistory")
    }

    /// v0.15 「常用」 stickers: the ordered ids the user pinned (`stickerFavorites`, array of strings); nil = never
    /// edited → `StickerPanel.defaultFavorites`. Unknown ids are skipped on read, never deleted.
    public var stickerFavorites: [String]? {
        get { defaults.stringArray(forKey: "stickerFavorites") }
        nonmutating set { defaults.set(newValue, forKey: "stickerFavorites") }
    }

    /// v0.15 when each sticker was last sent / played (`stickerRecent`, `{id: Unix ms}`); orders 常用.
    public var stickerRecent: [String: Int64] {
        get { ((defaults.dictionary(forKey: "stickerRecent") as? [String: Any]) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value } }
        nonmutating set { defaults.set(newValue, forKey: "stickerRecent") }
    }

    // MARK: v0.5 sound (new keys, see docs/upgrade-compat.md)

    /// Sound on / off (`soundEnabled`; absent = `SoundDefaults.enabled`).
    public var soundEnabled: Bool {
        get { (defaults.object(forKey: "soundEnabled") as? NSNumber)?.boolValue ?? SoundDefaults.enabled }
        nonmutating set { defaults.set(newValue, forKey: "soundEnabled") }
    }

    /// Master volume 0…1 (`soundVolume`, Double; absent = `SoundDefaults.volume`).
    public var soundVolume: Float {
        get { (defaults.object(forKey: "soundVolume") as? NSNumber).map { min(1, max(0, $0.floatValue)) } ?? SoundDefaults.volume }
        nonmutating set { defaults.set(Double(min(1, max(0, newValue))), forKey: "soundVolume") }
    }

    /// Background music once at launch / when shown again (`bgmEnabled`; absent = off).
    public var bgmEnabled: Bool {
        get { (defaults.object(forKey: "bgmEnabled") as? NSNumber)?.boolValue ?? SoundDefaults.bgmEnabled }
        nonmutating set { defaults.set(newValue, forKey: "bgmEnabled") }
    }

    // MARK: Schema migrations

    /// A one-way local upgrade step that brings stored data to `version`. Migrations must only add or
    /// convert local data — never delete history or remote data (docs/upgrade-compat.md).
    public struct Migration: Sendable {
        public let version: Int
        public let run: @Sendable (ConfigStore) -> Void
        public init(version: Int, run: @escaping @Sendable (ConfigStore) -> Void) {
            self.version = version
            self.run = run
        }
    }

    /// Ordered list of migrations shipped with the app. Append new ones with increasing versions.
    public static let migrations: [Migration] = []

    /// Version of the locally stored data; absent means 1 (every install before migrations existed).
    public var schemaVersion: Int {
        get { (defaults.object(forKey: "schemaVersion") as? NSNumber)?.intValue ?? 1 }
        nonmutating set { defaults.set(newValue, forKey: "schemaVersion") }
    }

    /// Runs, in order, every migration newer than `schemaVersion`, recording progress after each step
    /// so an interrupted launch resumes where it stopped. Returns the versions that ran.
    @discardableResult
    public func runMigrations(_ migrations: [Migration] = ConfigStore.migrations) -> [Int] {
        var ran: [Int] = []
        for m in migrations.sorted(by: { $0.version < $1.version }) where m.version > schemaVersion {
            m.run(self)
            schemaVersion = m.version
            ran.append(m.version)
        }
        return ran
    }

    /// Removes everything stored for this profile (used by tests).
    public func wipe() {
        if let suite { defaults.removePersistentDomain(forName: suite) }
    }
}

/// Where Sprites/ and Stickers/ live: `$LULU_RESOURCES`, the app bundle, or `./Resources`.
public func resourcesRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["LULU_RESOURCES"] {
        return URL(fileURLWithPath: env)
    }
    if let r = Bundle.main.resourceURL, FileManager.default.fileExists(atPath: r.appendingPathComponent("Sprites").path) {
        return r
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")
}
