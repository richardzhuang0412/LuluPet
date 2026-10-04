import Foundation

/// v0.12 pure rules for the weather plumbing in the app: when a refresh is needed at all, when it is due, and how
/// weather clips are mixed into the random idle fidgets.
public enum WeatherPlan {
    /// A refresh job exists only for a set city AND something that shows weather: the open compose panel, a character
    /// with weather clips (the look), or (v0.13.3) a paired TA with a city, whose weather the 想 TA bubble shows.
    /// Otherwise there is no deadline and no request.
    public static func needsRefresh(hasPlace: Bool, partnerHasPlace: Bool, composeOpen: Bool, hasClips: Bool) -> Bool {
        hasPlace && (partnerHasPlace || composeOpen || hasClips)
    }

    /// The moment the last refresh counted: the last attempt (a failed one too, so an unreachable server is not hammered)
    /// else the oldest cached result of the places in use; nil = something was never fetched.
    public static func lastRefresh(fetchedAt: [TimeInterval?], lastAttempt: TimeInterval?) -> TimeInterval? {
        if let lastAttempt { return lastAttempt }
        let known = fetchedAt.compactMap { $0 }
        return known.count == fetchedAt.count ? known.min() : nil
    }

    /// The wall-clock deadline for `HousekeepingDeadlines.weather`; nil = no job.
    public static func deadline(needed: Bool, last: TimeInterval?, now: TimeInterval) -> TimeInterval? {
        needed ? WeatherRefresh.nextDeadline(last: last, now: now) : nil
    }

    /// Roughly this share of the random fidgets is a weather clip while the look has clips (1 in `weatherOneIn`).
    public static let weatherOneIn = 3

    public enum FidgetChoice: Equatable, Sendable {
        case plain(Int)
        case weather(Int)
    }

    /// Picks the next fidget out of `plain` regular and `weather` weather clips (never the same one twice in a row when
    /// there is a choice). With weather clips about one pick in three is one of them; with no regular fidgets, always.
    /// `roll(n)` returns a random integer in `0..<n`.
    public static func pickFidget(plain: Int, weather: Int, lastPlain: Int?, lastWeather: Int?, roll: (Int) -> Int) -> FidgetChoice? {
        if weather > 0, plain == 0 || roll(weatherOneIn) == 0 {
            return IdleRules.pickFidget(count: weather, last: lastWeather, roll: roll).map(FidgetChoice.weather)
        }
        return IdleRules.pickFidget(count: plain, last: lastPlain, roll: roll).map(FidgetChoice.plain)
    }
}
