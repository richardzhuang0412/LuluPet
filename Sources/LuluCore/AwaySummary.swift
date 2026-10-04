import Foundation

/// v0.4 "你不在的时候…": what the partner sent while the pet was hidden (by hand or by a fullscreen
/// app), summarised for the card the visitor brings when the pet is shown again.
public struct AwaySummary: Equatable, Sendable {
    public struct StickerCount: Equatable, Sendable {
        public var id: String
        public var label: String
        public var count: Int
    }

    public static let title = "你不在的时候，TA来过～"
    /// At most this many sticker lines; the rest collapse into one "还有 N 个表情" line.
    public static let maxStickerLines = 3

    public var pokes = 0
    public var texts = 0
    public var visits = 0
    public var unknown = 0
    /// v0.10: 「叫你喝水 / 起来动动」 and the partner's receipts.
    public var waterCalls = 0
    public var standCalls = 0
    public var acks = 0
    /// Grouped by sticker id, in order of first appearance.
    public var stickers: [StickerCount] = []
    /// The newest text message (for a one-line preview).
    public var latestText: String?

    public var total: Int { pokes + texts + visits + unknown + waterCalls + standCalls + acks + stickers.reduce(0) { $0 + $1.count } }

    /// nil when nothing arrived. `messages` should be the partner's messages in arrival order;
    /// messages from `me` (if given) are ignored.
    public static func build(_ messages: [Message], me: Role? = nil, stickerLabel: (String) -> String?) -> AwaySummary? {
        var s = AwaySummary()
        for m in messages where m.from != me {
            switch m.kind {
            case .poke: s.pokes += 1
            case .text:
                s.texts += 1
                if let t = m.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { s.latestText = t }
            case .visit: s.visits += 1
            case .remind:
                if m.remind == nil { s.unknown += 1 }
                else if m.ackOf != nil { s.acks += 1 }
                else if m.remind == .water { s.waterCalls += 1 }
                else { s.standCalls += 1 }
            case .unknown: s.unknown += 1
            case .sticker:
                let id = m.stickerId ?? "?"
                if let i = s.stickers.firstIndex(where: { $0.id == id }) {
                    s.stickers[i].count += 1
                } else {
                    s.stickers.append(StickerCount(id: id, label: stickerLabel(id) ?? "表情", count: 1))
                }
            }
        }
        return s.total == 0 ? nil : s
    }

    /// Card lines, in a fixed order: hearts, stickers, texts, visits, newer-version messages.
    /// e.g. ["❤️ 爱心 ×2", "🤗 抱抱", "💬 2 条消息", "🏃 来找过你 1 次"].
    public var lines: [String] {
        var out: [String] = []
        if pokes > 0 { out.append("❤️ 爱心" + Self.times(pokes)) }
        for s in stickers.prefix(Self.maxStickerLines) {
            out.append("\(Self.emoji(forSticker: s.id)) \(s.label)" + Self.times(s.count))
        }
        let rest = stickers.dropFirst(Self.maxStickerLines).reduce(0) { $0 + $1.count }
        if rest > 0 { out.append("🧸 还有 \(rest) 个表情") }
        if texts > 0 { out.append("💬 \(texts) 条消息") }
        if visits > 0 { out.append("🏃 来找过你 \(visits) 次") }
        out += remindLines
        if unknown > 0 { out.append("✨ \(unknown) 条新版本消息") }
        return out
    }

    /// v0.10 lines for the reminders: "💧 叫你喝水 ×2", "🧍 叫你起来动动", "✅ TA 回应了提醒".
    private var remindLines: [String] {
        var out: [String] = []
        if waterCalls > 0 { out.append("💧 叫你喝水" + Self.times(waterCalls)) }
        if standCalls > 0 { out.append("🧍 叫你起来动动" + Self.times(standCalls)) }
        if acks > 0 { out.append("✅ TA 回应了提醒" + Self.times(acks)) }
        return out
    }

    /// v0.8 诚意清单 (勿扰 ended): every count spelled out, pokes and visits first because they count
    /// as 诚意 too. e.g. ["❤️ 爱心 ×3", "🏃 来找你 ×2", "💬 4 条消息", "🤗 抱抱 ×1"].
    public var sincerityLines: [String] {
        var out: [String] = []
        if pokes > 0 { out.append("❤️ 爱心 ×\(pokes)") }
        if visits > 0 { out.append("🏃 来找你 ×\(visits)") }
        if texts > 0 { out.append("💬 \(texts) 条消息") }
        for s in stickers.prefix(Self.maxStickerLines) { out.append("\(Self.emoji(forSticker: s.id)) \(s.label) ×\(s.count)") }
        let rest = stickers.dropFirst(Self.maxStickerLines).reduce(0) { $0 + $1.count }
        if rest > 0 { out.append("🧸 还有 \(rest) 个表情") }
        out += remindLines
        if unknown > 0 { out.append("✨ \(unknown) 条新版本消息") }
        return out
    }

    private static func times(_ n: Int) -> String { n > 1 ? " ×\(n)" : "" }

    /// A little emoji in front of each sticker's label.
    public static func emoji(forSticker id: String) -> String {
        stickerEmoji[id] ?? "🧸"
    }

    private static let stickerEmoji: [String: String] = [
        "missyou": "🥺", "hug": "🤗", "kiss": "😘", "nuzzle": "🥰", "flower": "💐", "night": "🌙",
        "morning": "☀️", "run": "💨", "heart": "🫶", "shy": "😳", "angry": "😤", "cry": "😭",
        "happy": "😄", "dance": "💃", "eat": "🍚", "milktea": "🧋", "holdhands": "🤝",
        "sleeptogether": "😴", "whatsup": "👀", "goodgirl": "🥹", "celebrate": "🎉", "bleh": "😛",
        "hi": "👋", "wink": "😉",
    ]
}

/// v0.4 history tab: pagination and day separators (pure, tested).
public enum HistoryTimeline {
    public enum Row: Equatable, Sendable, Identifiable {
        case day(String, key: String)
        case message(Message)
        /// v0.8: a 勿扰 stretch ("😤 勿扰中 14:05–15:10"), placed where it began.
        case dnd(String, key: String)

        public var id: String {
            switch self {
            case .day(_, let key): return "day-\(key)"
            case .message(let m): return m.id
            case .dnd(_, let key): return "dnd-\(key)"
            }
        }
    }

    /// Rows with 勿扰 dividers: each span of `spans` that starts within the loaded page (at or after its
    /// first message; any time when `complete`, i.e. no older page) is placed before the first message
    /// at or after its start, with a day separator in front if it starts a new day.
    public static func rows(_ messages: [Message], dndSpans spans: [DNDSpan], complete: Bool,
                            now: Date = Date(), calendar: Calendar = .current) -> [Row] {
        let from = complete ? Int64.min : (messages.first?.ts ?? Int64.max)
        var pending = spans.filter { $0.startMs >= from }.sorted { $0.startMs < $1.startMs }
        var rows: [Row] = []
        var lastDay: DateComponents?
        func dayRow(_ ts: Int64) {
            let date = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                rows.append(.day(dayLabel(date, now: now, calendar: calendar), key: "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"))
                lastDay = day
            }
        }
        func flush(before ts: Int64?) {
            while let s = pending.first, ts.map({ s.startMs <= $0 }) ?? true {
                pending.removeFirst()
                dayRow(s.startMs)
                rows.append(.dnd(s.label(calendar: calendar), key: "\(s.startMs)"))
            }
        }
        for m in messages {
            flush(before: m.ts)
            dayRow(m.ts)
            rows.append(.message(m))
        }
        flush(before: nil)
        return rows
    }

    /// The newest `limit` messages older than `before` (all when nil), oldest first, and whether
    /// even older ones exist. `sorted` is the whole history, oldest first (`HistoryStore.all()`).
    public static func page(_ sorted: [Message], limit: Int, before: Message? = nil) -> (messages: [Message], hasMore: Bool) {
        var end = sorted.count
        if let before {
            // First index at or after `before` (ties on ts broken by id, like HistoryStore's order).
            end = sorted.firstIndex { ($0.ts, $0.id) >= (before.ts, before.id) } ?? sorted.count
        }
        let start = max(0, end - max(0, limit))
        return (Array(sorted[start..<end]), start > 0)
    }

    /// Messages with a day separator before the first message of each calendar day.
    public static func rows(_ messages: [Message], now: Date = Date(), calendar: Calendar = .current) -> [Row] {
        var rows: [Row] = []
        var lastDay: DateComponents?
        for m in messages {
            let date = Date(timeIntervalSince1970: TimeInterval(m.ts) / 1000)
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            if day != lastDay {
                rows.append(.day(dayLabel(date, now: now, calendar: calendar),
                                 key: "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"))
                lastDay = day
            }
            rows.append(.message(m))
        }
        return rows
    }

    /// 今天 / 昨天 / 9月26日 / 2025年9月26日.
    public static func dayLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "今天" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "昨天" }
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let md = "\(c.month ?? 0)月\(c.day ?? 0)日"
        return c.year == calendar.component(.year, from: now) ? md : "\(c.year ?? 0)年\(md)"
    }

    /// "14:05".
    public static func timeLabel(_ ts: Int64, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts) / 1000))
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
