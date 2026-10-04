import Foundation

/// v0.15.1 the little status tag after 「TA」 in the compose panel's weather card: online / offline since … /
/// the 勿扰 mood / focusing. Pure; the view recomputes it once a minute while the panel is open.
public enum PartnerBadge {
    public struct Badge: Equatable, Sendable {
        public var dot: String
        public var text: String
        public init(dot: String, text: String) { self.dot = dot; self.text = text }
    }

    public static func make(online: Bool?, neverSeen: Bool, lastSeenMs: Int64?, dnd: DNDStatus?, focus: FocusStatus?,
                            nowMs: Int64, calendar: Calendar = .current) -> Badge {
        if neverSeen { return Badge(dot: "⚪️", text: "还没上线过") }
        if online == true {
            if let dnd, dnd.untilMs == 0 || nowMs < dnd.untilMs {
                let mood = DNDMood(rawValue: dnd.mood) ?? .unsaid
                return mood == .unsaid ? Badge(dot: "🔕", text: "勿扰中") : Badge(dot: mood.emoji, text: String(mood.title.dropFirst(2)))
            }
            if let focus, focus.isActive(nowMs: nowMs) {
                return Badge(dot: "🍅", text: "专注中 · 还剩 \(focus.minutesLeft(nowMs: nowMs)) 分钟")
            }
            return Badge(dot: "🟢", text: "在线")
        }
        guard let seen = lastSeenMs, seen > 0, seen <= nowMs else { return Badge(dot: "⚪️", text: "离线") }
        return Badge(dot: "⚪️", text: "离线 · " + ago(fromMs: seen, nowMs: nowMs, calendar: calendar))
    }

    /// "刚刚" / "12 分钟前" / "3 小时前" / "昨天" / "10月2日".
    static func ago(fromMs: Int64, nowMs: Int64, calendar: Calendar) -> String {
        let secs = Double(nowMs - fromMs) / 1000
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前" }
        let then = Date(timeIntervalSince1970: Double(fromMs) / 1000), now = Date(timeIntervalSince1970: Double(nowMs) / 1000)
        if calendar.isDate(then, inSameDayAs: now) || secs < 6 * 3600 { return "\(Int(secs / 3600)) 小时前" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(then, inSameDayAs: y) { return "昨天" }
        let c = calendar.dateComponents([.month, .day], from: then)
        return "\(c.month ?? 0)月\(c.day ?? 0)日"
    }
}
