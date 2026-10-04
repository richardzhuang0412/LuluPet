import Foundation

public struct Sticker: Codable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var file: String
    /// v0.11: a kiss / hug / cuddle sticker, hidden in friend mode (`ContentPolicy.allowsSticker`). Absent = false.
    public var intimate: Bool

    public init(id: String, label: String, file: String, intimate: Bool = false) {
        self.id = id
        self.label = label
        self.file = file
        self.intimate = intimate
    }

    private enum CodingKeys: String, CodingKey { case id, label, file, intimate }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        file = try c.decode(String.self, forKey: .file)
        intimate = (try? c.decodeIfPresent(Bool.self, forKey: .intimate)) ?? false
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
