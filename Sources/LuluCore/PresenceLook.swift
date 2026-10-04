import Foundation

/// v0.14.2: what my pet looks like on my desk, published in presence (`outfit` + `pose`) so TA's 「想 TA」 bubble can
/// show me "exactly as on my desk". State-level, not frame-level: the outfit name and one pose word.
/// Pure rules only; the app derives the inputs (AppDelegate) and the bubble draws it (ThinkBubbleWindow).
public enum PetPose: Equatable, Sendable {
    case idle, doze, quiet, focus, dnd, hidden
    case weather(WeatherLook)

    private static let weatherPrefix = "weather:"

    /// The published word: `idle` / `doze` / `quiet` / `focus` / `dnd` / `hidden` / `weather:<look>`.
    public var raw: String {
        switch self {
        case .idle: return "idle"
        case .doze: return "doze"
        case .quiet: return "quiet"
        case .focus: return "focus"
        case .dnd: return "dnd"
        case .hidden: return "hidden"
        case .weather(let look): return Self.weatherPrefix + look.rawValue
        }
    }

    /// Tolerant: an unknown word (a newer client's pose, a weather look we don't know) reads as `.idle`.
    public init(raw: String) {
        switch raw {
        case "doze": self = .doze
        case "quiet": self = .quiet
        case "focus": self = .focus
        case "dnd": self = .dnd
        case "hidden": self = .hidden
        default:
            if raw.hasPrefix(Self.weatherPrefix), let look = WeatherLook(rawValue: String(raw.dropFirst(Self.weatherPrefix.count))) {
                self = .weather(look)
            } else {
                self = .idle
            }
        }
    }

    /// My pose from the existing state. Priority: hidden → 勿扰 → pomodoro focus → dozing → energy-saving still →
    /// a current weather look this character has clips for → idle.
    public static func derive(hidden: Bool, dnd: Bool, focus: Bool, dozing: Bool, quiet: Bool,
                              weather: WeatherLook?, hasWeatherClips: Bool) -> PetPose {
        if hidden { return .hidden }
        if dnd { return .dnd }
        if focus { return .focus }
        if dozing { return .doze }
        if quiet { return .quiet }
        if let weather, hasWeatherClips { return .weather(weather) }
        return .idle
    }
}

/// The two optional presence fields (`presence/<seat>/outfit`, `presence/<seat>/pose`).
public struct PresenceLook: Equatable, Sendable {
    public var outfit: String?
    public var pose: PetPose?
    public init(outfit: String? = nil, pose: PetPose? = nil) {
        self.outfit = outfit
        self.pose = pose
    }

    /// Outfit names are short identifiers; anything empty / absurdly long / path-like is ignored.
    public static func cleanOutfit(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.count <= 64, !s.contains("/"), !s.contains("..") else { return nil }
        return s
    }
}

/// What the 想 TA bubble draws for a pose (the character's own clips decide what is possible).
public enum ThinkPoseLook: Equatable, Sendable {
    case idleLoop
    case dozeStill
    case quietStill
    /// The character's focus clip (噜噜 tool_F01), looping.
    case focusClip
    /// No focus clip for this character: the quiet still frame plus a tiny 🍅.
    case focusStill
    /// Quiet still frame plus TA's 勿扰 mood sign.
    case dndStill
    case weatherClip(WeatherLook)

    public static func resolve(_ pose: PetPose?, hasFocusClip: Bool, hasWeatherClip: (WeatherLook) -> Bool) -> ThinkPoseLook {
        switch pose ?? .idle {
        case .idle, .hidden: return .idleLoop
        case .doze: return .dozeStill
        case .quiet: return .quietStill
        case .focus: return hasFocusClip ? .focusClip : .focusStill
        case .dnd: return .dndStill
        case .weather(let look): return hasWeatherClip(look) ? .weatherClip(look) : .idleLoop
        }
    }

    /// TA's 勿扰 sign in the bubble: the reason, or "🔕 勿扰中" (also when only the pose said `dnd`).
    public static func dndSign(_ status: DNDStatus?) -> String {
        (status?.knownMood ?? .unsaid).sign
    }
}

public enum ThinkOutfit {
    /// The outfit the bubble draws: TA's published outfit, else the one on TA's last message, else the character's
    /// preferred outfit; only names in `available` (our catalog, for that character) count.
    public static func pick(published: String?, lastMessage: String?, available: [String], preferred: String?) -> String? {
        for c in [published, lastMessage, preferred] {
            if let c, available.contains(c) { return c }
        }
        return available.first
    }
}
