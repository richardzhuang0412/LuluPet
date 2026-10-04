import Foundation

// v0.10 对方相关：专注排队 + 叫 TA 喝水 / 起来动动 (pure rules, tested in LuluCoreTests).

extension Visits {
    /// 接收方自己在专注：新来的访客先攒着（和勿扰一样），专注结束再演。暂停中不算。
    public static func isHoldingForFocus(state: PomodoroState, now: TimeInterval) -> Bool {
        guard state.phase == .focus, !state.isPaused, let until = state.until else { return false }
        return now < until
    }

    /// 发送方：对方在线并且正在专注 → 东西先放在 TA 那儿（同勿扰：宠物跑出去再回来，消息照发）。
    /// 对方的专注状态在断线后会残留（markOffline 不清它），所以必须同时在线。
    public static func partnerFocusHolds(_ focus: FocusStatus?, partnerOnline: Bool, nowMs: Int64) -> Bool {
        partnerOnline && (focus?.isActive(nowMs: nowMs) ?? false)
    }

    /// 宠物跑回来后的提示。
    public static let focusBounceLine = "TA 在专注，先放在 TA 那儿啦"

    /// 专注结束后的汇总卡片标题。
    public static let focusCardTitle = "你专注的时候，TA来过～"

    /// 状态栏的对方状态行：「噜妹正在专注 🍅 还剩 12 分钟」。
    public static func partnerFocusLine(name: String, focus: FocusStatus, nowMs: Int64) -> String {
        "\(name)正在专注 🍅 还剩 \(focus.minutesLeft(nowMs: nowMs)) 分钟"
    }

    /// 收到「叫你喝水 / 起来动动」时气泡的文案和按钮。
    public struct RemindBubble: Equatable, Sendable {
        public var header: String
        public var line: String
        public var comply: String
        public var snooze: String
    }

    public static func remindBubble(kind: ReminderKind, sender: String) -> RemindBubble {
        switch kind {
        case .water: return RemindBubble(header: "\(sender)说：", line: "\(sender)叫你喝水啦 💧", comply: "喝了 ✓", snooze: "等会儿")
        case .stand: return RemindBubble(header: "\(sender)说：", line: "\(sender)叫你起来动动 🧍", comply: "好的 ✓", snooze: "等会儿")
        }
    }

    /// 对方回执后，自家宠物冒的小气泡。
    public static func remindAckLine(_ kind: ReminderKind) -> String {
        switch kind {
        case .water: return "TA 喝啦 💧"
        case .stand: return "TA 站起来啦"
        }
    }

    /// 回执（`ackOf` 不为空）不串门，只在自家宠物上冒小气泡。
    public static func isRemindAck(_ m: Message) -> Bool { m.kind == .remind && m.ackOf != nil }

    /// 记录里的一行：`fromMe` = 我发的。nil = 不认识的 remind 值（沿用「新版本消息」）。
    public static func remindHistoryLine(_ m: Message, fromMe: Bool) -> String? {
        guard m.kind == .remind, let kind = m.remind else { return nil }
        let icon = kind == .water ? "💧" : "🧍"
        if m.ackOf != nil {
            switch kind {
            case .water: return "\(icon) " + (fromMe ? "你喝啦" : "TA 喝啦")
            case .stand: return "\(icon) " + (fromMe ? "你站起来啦" : "TA 站起来啦")
            }
        }
        switch kind {
        case .water: return "\(icon) " + (fromMe ? "叫 TA 喝水" : "TA 叫你喝水")
        case .stand: return "\(icon) " + (fromMe ? "叫 TA 起来动动" : "TA 叫你起来动动")
        }
    }

    /// reactions.json 里喝水 / 起来动动的访客片段，用这两个键（`reaction(kind:stickerId:)` 的 stickerId 位）。
    public static func remindReactionKey(_ kind: ReminderKind) -> String { "remind_\(kind.rawValue)" }
}
