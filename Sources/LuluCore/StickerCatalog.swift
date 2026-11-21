import Foundation

public struct Sticker: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var file: String
    /// v0.11: a kiss / hug / cuddle sticker, hidden in friend mode (`ContentPolicy.allowsSticker`). Absent = false.
    public var intimate: Bool
    /// v0.15: the「更多表情」 section (`StickerGroup` raw value); absent / unknown = 「其他」.
    public var group: String?
    /// 「搜表情」: the label's pinyin ("bao bao") when the automatic reading is wrong (a polyphone); absent = automatic.
    public var pinyin: String?
    /// 「搜表情」: extra words that also find this sticker. Absent = none.
    public var keywords: [String]

    public init(id: String, label: String, file: String, intimate: Bool = false, group: String? = nil,
                pinyin: String? = nil, keywords: [String] = []) {
        self.id = id
        self.label = label
        self.file = file
        self.intimate = intimate
        self.group = group
        self.pinyin = pinyin
        self.keywords = keywords
    }

    private enum CodingKeys: String, CodingKey { case id, label, file, intimate, group, pinyin, keywords }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        file = try c.decode(String.self, forKey: .file)
        intimate = (try? c.decodeIfPresent(Bool.self, forKey: .intimate)) ?? false
        group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? nil
        pinyin = (try? c.decodeIfPresent(String.self, forKey: .pinyin)) ?? nil
        keywords = (try? c.decodeIfPresent([String].self, forKey: .keywords)) ?? []
    }
}

/// Reads `Stickers/stickers.json`.
public struct StickerCatalog: Sendable {
    public let root: URL
    public let stickers: [Sticker]

    public init(root: URL) {
        self.root = root
        let data = try? Data(contentsOf: root.appendingPathComponent("stickers.json"))
        stickers = data.flatMap { try? JSONDecoder().decode([Sticker].self, from: $0) } ?? []
    }

    public func url(for id: String) -> URL? {
        stickers.first { $0.id == id }.map { root.appendingPathComponent($0.file) }
    }

    public func label(for id: String) -> String? { stickers.first { $0.id == id }?.label }
}
