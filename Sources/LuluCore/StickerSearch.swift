import Foundation

/// 「搜表情」: find a sticker by its name, its pinyin (full spelling or initials: 「bb」/「baobao」 → 抱抱), its group
/// title or extra keywords. Pure; the JS twin is `searchStickers` in web/js/core/stickers.js (shared vectors
/// `stickerSearch` in web/tests/vectors/wire.json). The web reads `pinyin` / `initials` precomputed into
/// web/assets/manifest.json by tools/build_web_assets.py, with the same transform and cleanup as `pinyin(of:)`.
public enum StickerSearch {
    /// What a sticker is matched against.
    public struct Entry: Sendable, Equatable {
        public var id: String
        public var label: String
        /// `StickerGroup` raw value (nil / unknown = 其他).
        public var group: String?
        /// Space-separated syllables, ASCII lowercase: "bao bao".
        public var pinyin: String
        /// First letter of each syllable: "bb".
        public var initials: String
        public var keywords: [String]

        public init(id: String, label: String, group: String? = nil, pinyin: String, initials: String? = nil, keywords: [String] = []) {
            self.id = id
            self.label = label
            self.group = group
            self.pinyin = pinyin
            self.initials = initials ?? StickerSearch.initials(ofPinyin: pinyin)
            self.keywords = keywords
        }
    }

    /// 「想你了」 → "xiang ni le": the system Han → Latin transform, tone marks stripped, each syllable kept to [a-z0-9]
    /// (so 「啊？」 → "a"). tools/build_web_assets.py runs the same CFStringTransform steps for the web manifest.
    public static func pinyin(of label: String) -> String {
        let latin = label.applyingTransform(.toLatin, reverse: false) ?? label
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain.lowercased().split(whereSeparator: \.isWhitespace)
            .map { String($0.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map(Character.init)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "xiang ni le" → "xnl".
    public static func initials(ofPinyin pinyin: String) -> String {
        String(pinyin.split(separator: " ").compactMap(\.first))
    }

    /// The entry for a catalog sticker: its `pinyin` override when stickers.json has one (a polyphone the transform
    /// reads wrong), else `pinyin(of:)`.
    public static func entry(for s: Sticker) -> Entry {
        Entry(id: s.id, label: s.label, group: s.group, pinyin: s.pinyin ?? pinyin(of: s.label), keywords: s.keywords)
    }

    /// Width / case folded (NFKC, lowercase), only letters and digits kept: 「 Bao～抱！」 → "bao抱".
    public static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            switch u.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                out.append(u)
            default: break
            }
        }
        return String(out)
    }

    /// The title a group is searched by (`StickerGroup.title`; unknown = 「其他」).
    static func groupTitle(_ group: String?) -> String { group.flatMap(StickerGroup.init(rawValue:))?.title ?? "其他" }

    // Code-unit comparisons (like JS startsWith / includes), not Character equivalence.
    private static func starts(_ s: String, _ q: String) -> Bool { s.range(of: q, options: [.literal, .anchored]) != nil }
    private static func has(_ s: String, _ q: String) -> Bool { s.range(of: q, options: .literal) != nil }

    /// How well an already-normalized, non-empty `q` matches (lower = better), nil = no match:
    /// 0 exact name · 1 name prefix · 2 name contains · 3 initials prefix · 4 full pinyin prefix ·
    /// 5 pinyin / initials from a later syllable (「kuaile」/「kl」 → 圣诞快乐) · 6 group title or keyword.
    static func tier(_ q: String, _ e: Entry) -> Int? {
        let label = normalize(e.label)
        if label == q { return 0 }
        if starts(label, q) { return 1 }
        if has(label, q) { return 2 }
        let syllables = e.pinyin.split(separator: " ").map(String.init)
        let initials = e.initials
        if starts(initials, q) { return 3 }
        if starts(syllables.joined(), q) { return 4 }
        if syllables.count > 1 {
            for i in 1..<syllables.count where starts(syllables[i...].joined(), q) || starts(String(initials.dropFirst(i)), q) { return 5 }
        }
        if has(normalize(groupTitle(e.group)), q) || e.keywords.contains(where: { has(normalize($0), q) }) { return 6 }
        return nil
    }

    /// True when `query` finds `sticker` (an empty query finds everything).
    public static func matches(query: String, sticker: Entry) -> Bool {
        let q = normalize(query)
        return q.isEmpty || tier(q, sticker) != nil
    }

    /// The ids of `stickers` that `query` finds, best match first; equal matches keep the input order (pass the
    /// stickers already in usage order: `StickerPanel.ranked`, which falls back to catalog order). Pass only what
    /// the current mode shows (friend mode: no intimate stickers). Empty query (or only spaces / punctuation) =
    /// every id, unchanged.
    public static func filter(query: String, stickers: [Entry]) -> [String] {
        let q = normalize(query)
        guard !q.isEmpty else { return stickers.map(\.id) }
        return stickers.enumerated()
            .compactMap { i, e in tier(q, e).map { (t: $0, i: i, id: e.id) } }
            .sorted { $0.t != $1.t ? $0.t < $1.t : $0.i < $1.i }
            .map(\.id)
    }
}
