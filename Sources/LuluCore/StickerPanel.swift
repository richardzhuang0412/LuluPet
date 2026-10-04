import Foundation

/// v0.15 the compose panel's sticker sections (`stickers.json` `group`): shown in this order in「更多表情」.
public enum StickerGroup: String, CaseIterable, Sendable {
    case love, happy, sad, wow, daily, reply, season

    public var title: String {
        switch self {
        case .love: return "爱意 · 撒娇"
        case .happy: return "开心 · 得意 · 加油"
        case .sad: return "委屈 · 生气 · 难过"
        case .wow: return "无语 · 惊讶 · 疑问"
        case .daily: return "作息 · 日常"
        case .reply: return "回应 · 招呼"
        case .season: return "天气 · 节日"
        }
    }
}

/// v0.15 「常用」 + 「更多表情」: which stickers the panel's first grid shows and in what order, and the grouped
/// full library. Pure rules (the app stores the two inputs as `stickerFavorites` / `stickerRecent`).
public enum StickerPanel {
    /// 「常用」 holds at most this many.
    public static let maxFavorites = 24

    /// Until the user pins anything, 常用 is the 24 stickers that existed before v0.15, in their old order.
    public static let defaultFavorites = [
        "missyou", "hug", "kiss", "nuzzle", "flower", "night", "morning", "run", "heart", "shy", "angry", "cry",
        "happy", "dance", "eat", "milktea", "holdhands", "sleeptogether", "whatsup", "goodgirl", "celebrate", "bleh",
        "hi", "wink",
    ]

    /// The 常用 grid: `pinned` (the user's ordered `stickerFavorites`; nil = never edited → `defaultFavorites`),
    /// restricted to `visible` ids (a sticker the policy hides, or one this build lacks, is skipped, duplicates
    /// dropped, at most `maxFavorites`), ordered by recent use: stickers used before come first, newest `recent`
    /// timestamp first; the rest keep their pinned order.
    public static func favorites(pinned: [String]?, recent: [String: Int64], visible: [String]) -> [String] {
        let ok = Set(visible)
        var seen = Set<String>()
        let base = Array((pinned ?? defaultFavorites).filter { ok.contains($0) && seen.insert($0).inserted }.prefix(maxFavorites))
        let order = Dictionary(uniqueKeysWithValues: base.enumerated().map { ($1, $0) })
        return base.sorted { a, b in
            switch (recent[a], recent[b]) {
            case let (x?, y?): return x != y ? x > y : order[a]! < order[b]!
            case (.some, nil): return true
            case (nil, .some): return false
            default: return order[a]! < order[b]!
            }
        }
    }

    /// The list to store after 加入 / 移出常用. The first edit starts from `defaultFavorites`. Ids hidden by the
    /// policy that are already stored stay (friend mode must not drop the couple's pins). Adding to a full list
    /// does nothing (`canAdd` is false).
    public static func toggled(_ id: String, pinned: [String]?) -> [String] {
        var list = pinned ?? defaultFavorites
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else if list.count < maxFavorites { list.append(id) }
        return list
    }

    /// False when 常用 is full (the context menu then explains instead of adding).
    public static func canAdd(pinned: [String]?, visible: [String]) -> Bool {
        favorites(pinned: pinned, recent: [:], visible: visible).count < maxFavorites
    }

    /// 「更多表情」: the whole library by group (`StickerGroup.allCases` order, library order inside a group);
    /// a sticker with a missing / unknown group (a newer catalog) goes in a last group `nil` (shown 「其他」).
    public static func grouped(_ stickers: [Sticker]) -> [(group: StickerGroup?, stickers: [Sticker])] {
        var out: [(group: StickerGroup?, stickers: [Sticker])] = []
        for g in StickerGroup.allCases {
            let list = stickers.filter { $0.group == g.rawValue }
            if !list.isEmpty { out.append((g, list)) }
        }
        let rest = stickers.filter { $0.group.flatMap(StickerGroup.init(rawValue:)) == nil }
        if !rest.isEmpty { out.append((nil, rest)) }
        return out
    }

    // MARK: v0.15.1 快捷栏 + 自动「常用」

    /// 快捷栏 holds at most this many (one row).
    public static let maxQuickBar = 8
    /// The automatic 常用 grid shows at most this many (four rows of four).
    public static let maxFrequent = 16

    /// The sticker ids I sent, counted from a history (my seat's `.sticker` messages only).
    public static func sendCounts(from messages: [Message], me: Role) -> [String: Int] {
        var counts: [String: Int] = [:]
        for m in messages where m.from == me && m.kind == .sticker {
            if let id = m.stickerId, !id.isEmpty { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Order for stickers nobody sent: the original 24 first (old order), then library order.
    private static func baseOrder(_ library: [String]) -> [String: Int] {
        var order: [String: Int] = [:]
        for id in defaultFavorites + library where order[id] == nil { order[id] = order.count }
        return order
    }

    /// All `visible` ids ranked: more sends first, ties by newest `recent`, then the default order.
    public static func ranked(counts: [String: Int], recent: [String: Int64], visible: [String]) -> [String] {
        let order = baseOrder(visible)
        var seen = Set<String>()
        let ids = visible.filter { seen.insert($0).inserted }
        return ids.sorted { a, b in
            let ca = counts[a] ?? 0, cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            let ra = recent[a] ?? 0, rb = recent[b] ?? 0
            if ra != rb { return ra > rb }
            return order[a]! < order[b]!
        }
    }

    /// The 快捷栏 to show: the stored ids (full list, hidden ones included) limited to `visible`, deduped, at most 8.
    public static func quickBar(stored: [String], visible: [String]) -> [String] {
        let ok = Set(visible)
        var seen = Set<String>()
        return Array(stored.filter { ok.contains($0) && seen.insert($0).inserted }.prefix(maxQuickBar))
    }

    /// The automatic 常用: `ranked`, minus the quick bar, at most 16. Nobody sent anything → the default order.
    public static func frequent(quickBar: [String], counts: [String: Int], recent: [String: Int64], visible: [String]) -> [String] {
        let bar = Set(quickBar)
        return Array(ranked(counts: counts, recent: recent, visible: visible).filter { !bar.contains($0) }.prefix(maxFrequent))
    }

    /// First run of v0.15.1: a customized `stickerFavorites` (differs from the default 24) seeds the bar with its
    /// first entries; the rest of the slots go to the most-sent stickers, then to the default order. `library` is
    /// every id of the catalog (not the policy-filtered ones: the stored bar keeps intimate stickers in friend mode).
    public static func seedQuickBar(favorites: [String]?, counts: [String: Int], recent: [String: Int64], library: [String]) -> [String] {
        let ok = Set(library)
        var bar: [String] = []
        func add(_ id: String) { if bar.count < maxQuickBar, ok.contains(id), !bar.contains(id) { bar.append(id) } }
        if let favorites, favorites != defaultFavorites { favorites.forEach(add) }
        for id in ranked(counts: counts, recent: recent, visible: library) where (counts[id] ?? 0) > 0 { add(id) }
        for id in defaultFavorites + library { add(id) }
        return bar
    }

    /// 装上 `id`. Already on the bar → unchanged. Full → the last slot shown (`visible`) is replaced;
    /// `replaced` names the sticker that made room.
    public static func equipped(_ id: String, in stored: [String], visible: [String]) -> (list: [String], replaced: String?) {
        if stored.contains(id) { return (stored, nil) }
        if stored.count < maxQuickBar { return (stored + [id], nil) }
        let ok = Set(visible)
        guard let i = stored.lastIndex(where: { ok.contains($0) }) else { return (stored, nil) }
        var out = stored
        let old = out[i]
        out[i] = id
        return (out, old)
    }

    /// 拿下 `id` (other slots shift left).
    public static func removed(_ id: String, from stored: [String]) -> [String] { stored.filter { $0 != id } }

    /// Moves `id` one place left (`delta` -1) or right (+1) among the slots shown; ids hidden by the policy keep their place.
    public static func moved(_ id: String, by delta: Int, in stored: [String], visible: [String]) -> [String] {
        let ok = Set(visible)
        let positions = stored.indices.filter { ok.contains(stored[$0]) }
        guard let k = positions.firstIndex(where: { stored[$0] == id }), positions.indices.contains(k + delta) else { return stored }
        var out = stored
        out.swapAt(positions[k], positions[k + delta])
        return out
    }

    /// 「按常用推荐」: the 8 most-sent stickers; ids hidden by the policy that were on the bar stay (taking their slots).
    public static func recommended(stored: [String], counts: [String: Int], recent: [String: Int64], visible: [String]) -> [String] {
        let ok = Set(visible)
        let kept = stored.filter { !ok.contains($0) }
        return Array(ranked(counts: counts, recent: recent, visible: visible).prefix(max(0, maxQuickBar - kept.count))) + kept
    }

    /// Stamp the use of a sticker; keeps the table small.
    public static func recorded(_ id: String, at ts: Int64, in recent: [String: Int64]) -> [String: Int64] {
        var r = recent
        r[id] = ts
        if r.count > 200 { for (k, _) in r.sorted(by: { $0.value < $1.value }).prefix(r.count - 200) { r[k] = nil } }
        return r
    }
}
