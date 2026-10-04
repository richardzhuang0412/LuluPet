import Foundation

/// v0.5 seasonal outfits. An outfit with a `"season"` in assets/sprites.json (copied into
/// `Resources/Sprites/<character>/outfits.json`) is only worn while that season is on, and during it
/// gets priority: it is the launch outfit and is picked more often by the rotation.
public enum OutfitSeason: String, Sendable, CaseIterable {
    /// 春节: from 15 days before to 15 days after Chinese New Year's day (inclusive).
    case springFestival
    /// 圣诞: December 1–31.
    case christmas

    /// Days before / after Chinese New Year's day that still count as the season.
    public static let springFestivalWindow = 15

    /// Chinese New Year's day (正月初一) per Gregorian year. Years missing here have no 春节 season, so
    /// extend the table before 2036.
    public static let chineseNewYear: [Int: (month: Int, day: Int)] = [
        2026: (2, 17), 2027: (2, 6), 2028: (1, 26), 2029: (2, 13), 2030: (2, 3),
        2031: (1, 23), 2032: (2, 11), 2033: (1, 31), 2034: (2, 19), 2035: (2, 8),
    ]

    /// Gregorian calendar in the local time zone (whatever calendar the user's Mac displays).
    public static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }

    /// Whether `date` (a calendar day in `calendar`'s time zone) is in this season.
    public func contains(_ date: Date, calendar: Calendar = OutfitSeason.calendar) -> Bool {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month else { return false }
        switch self {
        case .christmas:
            return month == 12
        case .springFestival:
            // The window never crosses a year boundary (earliest 春节 Jan 21 − 15 days = Jan 6).
            guard let ny = Self.chineseNewYear[year],
                  let newYear = calendar.date(from: DateComponents(year: year, month: ny.month, day: ny.day)),
                  let days = calendar.dateComponents([.day], from: newYear, to: calendar.startOfDay(for: date)).day
            else { return false }
            return abs(days) <= Self.springFestivalWindow
        }
    }
}

/// Which outfit to wear: pure rules, date and randomness injected (AppDelegate does the switching).
public enum OutfitRules {
    /// Relative rotation weight of an in-season seasonal outfit (a normal outfit weighs 1).
    public static let seasonalWeight = 4

    /// Whether `outfit` may be worn on `date`: no season, or its season is on. An unknown season name
    /// (not an `OutfitSeason`) is never in season.
    public static func isEligible(_ outfit: String, seasons: [String: String], on date: Date, calendar: Calendar = OutfitSeason.calendar) -> Bool {
        guard let raw = seasons[outfit] else { return true }
        return OutfitSeason(rawValue: raw)?.contains(date, calendar: calendar) ?? false
    }

    /// Whether `outfit` is seasonal and in season on `date`.
    public static func isInSeason(_ outfit: String, seasons: [String: String], on date: Date, calendar: Calendar = OutfitSeason.calendar) -> Bool {
        seasons[outfit] != nil && isEligible(outfit, seasons: seasons, on: date, calendar: calendar)
    }

    /// `outfits` (preference order) that may be worn on `date`.
    public static func eligible(_ outfits: [String], seasons: [String: String], on date: Date, calendar: Calendar = OutfitSeason.calendar) -> [String] {
        outfits.filter { isEligible($0, seasons: seasons, on: date, calendar: calendar) }
    }

    /// The pin to honour at launch. A pinned outfit that exists is kept even out of season (the user's
    /// choice); a pin whose outfit no longer exists (e.g. v0.4's 噜妹 "bow") falls back to the
    /// preferred outfit (first eligible one), which stays pinned. nil = not pinned.
    public static func resolvePin(_ pinned: String?, outfits: [String], seasons: [String: String], on date: Date,
                                  calendar: Calendar = OutfitSeason.calendar) -> String? {
        guard let pinned else { return nil }
        if outfits.contains(pinned) { return pinned }
        return eligible(outfits, seasons: seasons, on: date, calendar: calendar).first ?? outfits.first
    }

    /// Launch outfit when not pinned: the first in-season seasonal outfit, else the first eligible one
    /// (the manifest's preferred outfit), else the first at all.
    public static func launchOutfit(_ outfits: [String], seasons: [String: String], on date: Date, calendar: Calendar = OutfitSeason.calendar) -> String? {
        outfits.first { isInSeason($0, seasons: seasons, on: date, calendar: calendar) }
            ?? eligible(outfits, seasons: seasons, on: date, calendar: calendar).first
            ?? outfits.first
    }

    /// Next outfit for the rotation / "换个造型": a weighted random eligible outfit other than `current`
    /// (in-season seasonal ones weigh `seasonalWeight`). nil when there is nothing else to wear.
    public static func next<G: RandomNumberGenerator>(after current: String?, outfits: [String], seasons: [String: String],
                                                      on date: Date, calendar: Calendar = OutfitSeason.calendar, using rng: inout G) -> String? {
        let candidates = eligible(outfits, seasons: seasons, on: date, calendar: calendar).filter { $0 != current }
        let weights = candidates.map { isInSeason($0, seasons: seasons, on: date, calendar: calendar) ? seasonalWeight : 1 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return nil }
        var roll = Int.random(in: 0..<total, using: &rng)
        for (outfit, w) in zip(candidates, weights) {
            if roll < w { return outfit }
            roll -= w
        }
        return candidates.last
    }

    /// The outfit a visitor wears: the one the partner's message names if this app has it, else the
    /// character's preferred outfit (`fallback`).
    public static func visitorOutfit(requested: String?, available: [String], fallback: String?) -> String? {
        if let requested, available.contains(requested) { return requested }
        return fallback
    }
}

/// v0.8 "换回上一个": outfits worn before, most recent first (at most `maxCount`). 换个造型, the timed
/// rotation and 选择造型 push the outfit being left; 换回上一个 pops. Persisted per character as
/// `outfitHistory` (see docs/upgrade-compat.md).
public struct OutfitHistory: Equatable, Sendable {
    public static let maxCount = 10
    public private(set) var stack: [String]

    public init(_ stack: [String] = []) { self.stack = Array(stack.prefix(Self.maxCount)) }

    /// Leaving `outfit`: it goes on top (an older copy of it is dropped, so no outfit is listed twice).
    public mutating func push(_ outfit: String) {
        stack.removeAll { $0 == outfit }
        stack.insert(outfit, at: 0)
        if stack.count > Self.maxCount { stack.removeLast(stack.count - Self.maxCount) }
    }

    /// The outfit to go back to: the most recent one that still exists (`valid`) and isn't `current`;
    /// entries skipped on the way (removed outfits) are dropped too. nil = nothing to go back to.
    public mutating func pop(valid: [String], current: String?) -> String? {
        while !stack.isEmpty {
            let o = stack.removeFirst()
            if o != current, valid.contains(o) { return o }
        }
        return nil
    }

    /// Whether 换回上一个 would do anything.
    public func canGoBack(valid: [String], current: String?) -> Bool {
        stack.contains { $0 != current && valid.contains($0) }
    }
}

/// v0.8 选择造型 submenu rows: every outfit of the character in preference order, by label.
public struct OutfitChoice: Equatable, Sendable {
    public var name: String
    /// "蕾丝帽", "醒狮新年（节日限定）".
    public var title: String
    public var current: Bool
    public var enabled: Bool

    /// Seasonal outfits are marked 节日限定 and can only be chosen in season (or when it is the pinned one).
    public static func list(outfits: [String], labels: [String: String], seasons: [String: String], current: String?,
                            pinned: String?, on date: Date, calendar: Calendar = OutfitSeason.calendar) -> [OutfitChoice] {
        outfits.map { o in
            let seasonal = seasons[o] != nil
            let label = labels[o] ?? o
            let ok = !seasonal || o == pinned || OutfitRules.isInSeason(o, seasons: seasons, on: date, calendar: calendar)
            return OutfitChoice(name: o, title: seasonal ? label + "（节日限定）" : label, current: o == current, enabled: ok)
        }
    }
}
