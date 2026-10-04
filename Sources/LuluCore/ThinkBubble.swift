import Foundation

/// v0.13.3 「想 TA」: my pet "thinks of" TA (a thought cloud with TA's character, TA's weather and local time).
/// Pure rules only; the window and animation live in LuluPet (`ThinkBubbleWindow`).
public enum ThinkReason: Equatable, Sendable {
    /// Now and then on its own, as an idle fidget (about every 20–40 min of active time).
    case idle
    /// The mouse rested on the pet for ~1 s.
    case hover
    /// TA's weather turned into rain / snow / hot.
    case weather(WeatherLook)
}

/// What is going on right now (filled in by the app; every flag that is true blocks the bubble).
public struct ThinkContext: Equatable, Sendable {
    public var solo: Bool
    public var hidden: Bool          // pet hidden (manual or fullscreen auto-hide)
    public var dnd: Bool
    public var focus: Bool           // pomodoro focus round
    public var quiet: Bool           // energy-saving still frame (also dozing)
    public var visitActive: Bool
    public var bubbleShowing: Bool
    public var petBusy: Bool         // clip playing, dragged, compose open …
    public init(solo: Bool = false, hidden: Bool = false, dnd: Bool = false, focus: Bool = false, quiet: Bool = false,
                visitActive: Bool = false, bubbleShowing: Bool = false, petBusy: Bool = false) {
        self.solo = solo; self.hidden = hidden; self.dnd = dnd; self.focus = focus; self.quiet = quiet
        self.visitActive = visitActive; self.bubbleShowing = bubbleShowing; self.petBusy = petBusy
    }
    var blocked: Bool { solo || hidden || dnd || focus || quiet || visitActive || bubbleShowing || petBusy }
}

/// The little weather scene inside the cloud.
public enum ThinkFlourish: Equatable, Sendable { case rain, snow, sun, none }

public enum ThinkRules {
    /// The whole animation: pop-in, hold, fade out.
    public static let duration: TimeInterval = 6
    /// Mouse rest time before a hover shows it.
    public static let hoverDelay: TimeInterval = 1
    /// Minimum time between two bubbles (hover and idle); a weather change ignores it.
    public static let cooldown: TimeInterval = 60
    public static let idleRange: ClosedRange<TimeInterval> = (20 * 60)...(40 * 60)

    /// The next idle think, `unit` in 0…1 → 20…40 min of active time (uptime keeps still while the Mac sleeps).
    public static func idleDelay(unit: Double) -> TimeInterval {
        idleRange.lowerBound + (idleRange.upperBound - idleRange.lowerBound) * min(1, max(0, unit))
    }

    public static func shouldShow(_ reason: ThinkReason, context: ThinkContext, lastShown: TimeInterval?, now: TimeInterval) -> Bool {
        guard !context.blocked else { return false }
        if case .weather = reason { return true }
        guard let last = lastShown else { return true }
        return now < last || now - last >= cooldown   // a clock/uptime that went back never blocks forever
    }

    /// TA's look changed: the look to announce (rain / snow / hot only). `hadData` = a look was known before (the
    /// first data after launch or after TA's city changed announces nothing).
    public static func weatherTrigger(previous: WeatherLook?, hadData: Bool, current: WeatherLook?) -> WeatherLook? {
        guard hadData, let current, current != previous else { return nil }
        switch current {
        case .rain, .snow, .hot: return current
        default: return nil
        }
    }

    public static func hint(for look: WeatherLook) -> String? {
        switch look {
        case .rain: return "TA 那边下雨啦"
        case .snow: return "TA 那边下雪啦"
        case .hot: return "TA 那边好热呀"
        default: return nil
        }
    }

    public static func flourish(_ s: WeatherSnapshot?) -> ThinkFlourish {
        guard let s else { return .none }
        switch s.condition {
        case .rain, .drizzle, .thunder: return .rain
        case .snow: return .snow
        case .clear: return s.isDay ? .sun : .none
        default: return .none
        }
    }

    /// The pill under the character: 「上海 🌧 19° · 晚上 11:42」; for a weather change the hint leads instead of the
    /// city: 「TA 那边下雨啦 🌧 19° · 晚上 11:42」. nil without a city or without fresh data.
    public static func barText(reason: ThinkReason, place: WeatherPlace?, snapshot: WeatherSnapshot?, now: Date) -> String? {
        guard let place, let s = snapshot, !WeatherRefresh.isStale(fetchedAt: s.fetchedAt, now: now.timeIntervalSince1970) else { return nil }
        var lead = place.name
        if case .weather(let look) = reason, let h = hint(for: look) { lead = h }
        return "\(lead) \(s.condition.emoji(isDay: s.isDay)) \(Int(s.temperature.rounded()))° · \(LocalTime.format(timezone: place.timezone, now: now))"
    }
}
