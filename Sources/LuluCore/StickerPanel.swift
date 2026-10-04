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

    /// Stamp the use of a sticker; keeps the table small.
    public static func recorded(_ id: String, at ts: Int64, in recent: [String: Int64]) -> [String: Int64] {
        var r = recent
        r[id] = ts
        if r.count > 200 { for (k, _) in r.sorted(by: { $0.value < $1.value }).prefix(r.count - 200) { r[k] = nil } }
        return r
    }
}
