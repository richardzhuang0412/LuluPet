import Foundation

/// v0.14.1 「使用我现在的位置」: when to look the location up again and when a new fix means a new city. Pure rules.
public enum LocationRules {
    /// Refresh at most this often (besides launch and wake).
    public static let interval: TimeInterval = 3 * 3600
    /// Only a move of more than this many km is reverse geocoded again.
    public static let moveKm = 3.0

    /// Never looked up, 3 hours passed, or the clock went back.
    public static func isDue(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now < last || now - last >= interval
    }

    /// The housekeeping deadline (wall clock): nil unless auto-location is on; `now` when due already.
    public static func deadline(auto: Bool, last: TimeInterval?, now: TimeInterval) -> TimeInterval? {
        guard auto else { return nil }
        guard let last, last <= now else { return now }
        return max(now, last + interval)
    }

    /// True when the new fix is far enough from the current city (or there is none) to look up its name again.
    /// The city's coordinates are rounded to 2 decimals (~1 km), well inside the 3 km threshold.
    public static func needsGeocode(current: WeatherPlace?, latitude: Double, longitude: Double) -> Bool {
        guard let current else { return true }
        return NWSSelect.distanceKm(current.latitude, current.longitude, latitude, longitude) > moveKm
    }
}
