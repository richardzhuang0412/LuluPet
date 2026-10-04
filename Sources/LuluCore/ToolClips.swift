import Foundation

/// v0.12 clip pools of the personal tools (user-picked 2026-10-04, design/review/2026-10-04-tools-weather): which
/// named clip the pet plays for a water / stand reminder, the pomodoro's focus loop and its break / done cheer.
/// The names are clip names of the outfit (assets/reactions.json `remind_water` / `remind_stand` / `focus` build
/// the extra ones; the break clips are the default outfits' own celebrate / clap / eat clips). An outfit that lacks
/// a clip simply skips it (the caller filters by what the pet has).
public enum ToolClips {
    public enum Kind: String, Sendable, CaseIterable { case water, stand, focus, breakTime }

    public static func pool(_ kind: Kind, for character: Role) -> [String] {
        switch (kind, character) {
        case (.water, .lulu): return ["lulu_drink_02", "sohu_107", "baidu_019", "tool_W05", "tool_W07"]
        case (.water, .lumei): return ["tool_W04", "tool_W06", "tool_W09"]
        case (.stand, .lulu): return ["baidu_069", "lulu_walk_03", "lulu_walk_02", "tool_S07", "tool_S08"]
        case (.stand, .lumei): return ["lumei_stretch_01"]
        case (.focus, .lulu): return ["tool_F01"]
        case (.focus, .lumei): return []   // 噜妹 keeps the quiet still frame
        case (.breakTime, .lulu): return ["lulu_celebrate_01", "lulu_clap_01"]
        case (.breakTime, .lumei): return ["lumei_celebrate_01", "lumei_clap_01", "lumei_eat_01"]
        }
    }

    /// A random clip of the pool that `has` accepts, never `last` again when there is a choice; nil = none usable.
    public static func pick<G: RandomNumberGenerator>(_ kind: Kind, for character: Role, last: String?,
                                                       has: (String) -> Bool, using rng: inout G) -> String? {
        PoolPick.pick(pool(kind, for: character).filter(has), last: last, using: &rng)
    }
}
