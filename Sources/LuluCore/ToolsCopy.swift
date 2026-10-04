import Foundation

/// v0.11.3: one wording for the 小工具 explanations, shared by the compose panel's 小工具 tab, the 🍊 menu
/// (titles, tooltips, description lines) and the Settings 小工具 page, so they cannot drift apart.
public enum ToolsCopy {
    /// Whole minutes of a seconds value ("60").
    public static func minutes(_ seconds: TimeInterval) -> Int { Int((seconds / 60).rounded()) }

    public static func name(_ kind: ReminderKind) -> String { kind == .water ? "喝水提醒" : "站立提醒" }
    public static func emoji(_ kind: ReminderKind) -> String { kind == .water ? "💧" : "🧍" }

    /// 「喝水提醒 💧（每用电脑 60 分钟）」
    public static func menuTitle(_ kind: ReminderKind, interval: TimeInterval) -> String {
        "\(name(kind)) \(emoji(kind))（每用电脑 \(minutes(interval)) 分钟）"
    }

    /// The full explanation (panel, tooltip, Settings).
    public static func explanation(_ kind: ReminderKind, interval: TimeInterval) -> String {
        let n = minutes(interval)
        let act = kind == .water ? "喝水" : "起来动一动"
        let tail = kind == .water ? "点「喝了」记一杯；" : "点「好的」收到；"
        return "开着的话，你用电脑累计满 \(n) 分钟，宠物会跑出来提醒你\(act)。\(tail)「等会儿」10 分钟后再提醒。"
            + "离开电脑 5 分钟以上会重新计时；全屏、勿扰、专注时先不打扰。"
    }

    /// Short description line for the menu.
    public static func menuHint(_ kind: ReminderKind) -> String {
        kind == .water ? "累计用电脑满间隔，宠物来提醒你喝水" : "累计用电脑满间隔，宠物来提醒你起来动动"
    }

    public static let pomodoroHint = "专注一段时间，到点宠物提醒你休息；专注中宠物安静，其他提醒先不打扰"

    /// 「25 分钟专注 / 5 分钟休息」
    public static func pomodoroDurations(_ c: PomodoroConfig) -> String {
        "\(minutes(c.focus)) 分钟专注 / \(minutes(c.shortBreak)) 分钟休息"
    }

    /// Panel state line: 没在专注 / 专注中 还剩 N 分钟 / 已暂停 / 休息中 还剩 N 分钟.
    public static func pomodoroState(_ s: PomodoroState, now: TimeInterval) -> String {
        let left = s.remaining(now: now).map { max(1, Int(($0 / 60).rounded(.up))) } ?? 0
        switch s.phase {
        case .idle: return "没在专注"
        case .focus: return s.isPaused ? "已暂停（专注还剩 \(left) 分钟）" : "专注中 还剩 \(left) 分钟"
        case .shortBreak, .longBreak: return s.isPaused ? "已暂停（休息还剩 \(left) 分钟）" : "休息中 还剩 \(left) 分钟"
        }
    }

    /// v0.13.1 the 小工具 tab's live line under a reminder: how much of this cycle is left.
    public static func cycleLine(_ kind: ReminderKind, _ status: ActiveTimeReminder.Status) -> String {
        let what = kind == .water ? "喝水" : "起来动动"
        func mins(_ t: TimeInterval) -> Int { max(1, Int((t / 60).rounded(.up))) }
        switch status {
        case .showing: return "正在提醒你\(what) ⏰"
        case .snoozed(let left): return "「等会儿」：\(mins(left)) 分钟后再提醒"
        case .away: return "你离开电脑了，回来后重新计时"
        case .waiting: return "到点啦，等你退出全屏 / 勿扰 / 专注就提醒"
        case .counting(let left): return left <= 0 ? "马上提醒你\(what)" : "还差约 \(mins(left)) 分钟提醒你\(what)（只算用电脑的时间）"
        }
    }
}
