import Foundation

// v0.12 weather (docs/superpowers/specs/2026-10-06-weather-design.md). Pure model, parsing and rules;
// the network client is `WeatherClient` in LuluSync, persistence is `WeatherStore`.

/// What the sky looks like, reduced from Open-Meteo's WMO weather codes.
public enum WeatherCondition: String, Codable, Sendable, CaseIterable {
    case clear, partlyCloudy, cloudy, fog, drizzle, rain, snow, thunder

    /// WMO code (https://open-meteo.com/en/docs): 0-1 clear, 2 partly cloudy, 3 overcast, 45/48 fog,
    /// 51-57 drizzle, 61-67 and 80-82 rain / showers, 71-77 and 85-86 snow, 95-99 thunderstorm.
    /// Anything unknown is read as cloudy.
    public init(wmo: Int) {
        switch wmo {
        case 0, 1: self = .clear
        case 2: self = .partlyCloudy
        case 3: self = .cloudy
        case 45, 48: self = .fog
        case 51...57: self = .drizzle
        case 61...67, 80...82: self = .rain
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .thunder
        default: self = .cloudy
        }
    }

    public func emoji(isDay: Bool) -> String {
        switch self {
        case .clear: return isDay ? "☀️" : "🌙"
        case .partlyCloudy: return isDay ? "⛅" : "☁️"
        case .cloudy: return "☁️"
        case .fog: return "🌫"
        case .drizzle: return isDay ? "🌦" : "🌧"
        case .rain: return "🌧"
        case .snow: return "🌨"
        case .thunder: return "⛈"
        }
    }

    /// 晴 / 多云 / 阴 / 雾 / 毛毛雨 / 雨 / 雪 / 雷雨.
    public var label: String {
        switch self {
        case .clear: return "晴"
        case .partlyCloudy: return "多云"
        case .cloudy: return "阴"
        case .fog: return "雾"
        case .drizzle: return "毛毛雨"
        case .rain: return "雨"
        case .snow: return "雪"
        case .thunder: return "雷雨"
        }
    }
}

/// A city. Coordinates are kept at two decimals (about 1 km, city level) everywhere: stored, published, decoded.
public struct WeatherPlace: Codable, Equatable, Sendable {
    public var name: String
    public var admin: String?
    public var country: String?
    public var latitude: Double
    public var longitude: Double
    /// IANA time zone id ("America/Los_Angeles").
    public var timezone: String

    public init(name: String, admin: String?, country: String?, latitude: Double, longitude: Double, timezone: String) {
        self.name = name
        self.admin = admin
        self.country = country
        self.latitude = Self.round2(latitude)
        self.longitude = Self.round2(longitude)
        self.timezone = timezone
    }

    private enum CodingKeys: String, CodingKey { case name, admin, country, latitude, longitude, timezone }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  admin: try c.decodeIfPresent(String.self, forKey: .admin),
                  country: try c.decodeIfPresent(String.self, forKey: .country),
                  latitude: try c.decode(Double.self, forKey: .latitude),
                  longitude: try c.decode(Double.self, forKey: .longitude),
                  timezone: try c.decode(String.self, forKey: .timezone))
    }

    static func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    /// "加利福尼亚 · 美国" (the province / state when it differs from the city name, then the country).
    public var subtitle: String {
        [admin.flatMap { $0 == name ? nil : $0 }, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// JSON object for `presence/<seat>/place`.
    public var json: [String: Any] {
        var out: [String: Any] = ["name": name, "latitude": latitude, "longitude": longitude, "timezone": timezone]
        if let admin { out["admin"] = admin }
        if let country { out["country"] = country }
        return out
    }

    /// Tolerant read of a `place` object: needs name / latitude / longitude / timezone, else nil.
    public init?(json: Any?) {
        guard let d = json as? [String: Any], let name = d["name"] as? String, !name.isEmpty,
              let lat = (d["latitude"] as? NSNumber)?.doubleValue, let lon = (d["longitude"] as? NSNumber)?.doubleValue,
              let tz = d["timezone"] as? String, !tz.isEmpty else { return nil }
        self.init(name: name, admin: d["admin"] as? String, country: d["country"] as? String,
                  latitude: lat, longitude: lon, timezone: tz)
    }

    /// Cache key: the rounded coordinates.
    var cacheKey: String { String(format: "%.2f,%.2f", latitude, longitude) }
}

public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var condition: WeatherCondition
    /// °C.
    public var temperature: Double
    public var high: Double?
    public var low: Double?
    /// km/h.
    public var windSpeed: Double?
    public var isDay: Bool
    /// Unix seconds.
    public var fetchedAt: TimeInterval

    public init(condition: WeatherCondition, temperature: Double, high: Double?, low: Double?,
                windSpeed: Double?, isDay: Bool, fetchedAt: TimeInterval) {
        self.condition = condition
        self.temperature = temperature
        self.high = high
        self.low = low
        self.windSpeed = windSpeed
        self.isDay = isDay
        self.fetchedAt = fetchedAt
    }
}

/// Which special look my pet takes on in this weather. Priority: rain / snow > cold / hot > windy > cloudy.
public enum WeatherLook: String, Codable, Sendable, CaseIterable {
    case rain, snow, hot, cold, windy
    /// Lowest priority: an overcast / foggy sky and nothing else special (mild, calm).
    case cloudy

    public static let hotAt = 30.0      // °C, >=
    public static let coldAt = 5.0      // °C, <=
    public static let windyAt = 30.0    // km/h, >=

    public static func of(_ s: WeatherSnapshot) -> WeatherLook? {
        switch s.condition {
        case .rain, .drizzle, .thunder: return .rain
        case .snow: return .snow
        default: break
        }
        if s.temperature >= hotAt { return .hot }
        if s.temperature <= coldAt { return .cold }
        if let w = s.windSpeed, w >= windyAt { return .windy }
        if s.condition == .cloudy || s.condition == .fog { return .cloudy }
        return nil
    }

    /// Whose clips to use for this look, in order: snow falls back to the cold clips when a character has no snow
    /// clips of its own; every other look only uses its own.
    public var clipLooks: [WeatherLook] { self == .snow ? [.snow, .cold] : [self] }
}

/// When to fetch, and how old is too old. Wall clock (Unix seconds) so sleep counts.
public enum WeatherRefresh {
    public static let interval: TimeInterval = 1800
    public static let staleAfter: TimeInterval = 3 * 3600
    /// Data younger than this shows no age.
    public static let ageShownFrom: TimeInterval = 45 * 60

    /// Never fetched, 30 minutes passed (also after sleep), or the clock went back.
    public static func isDue(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now < last || now - last >= interval
    }

    /// The wall-clock time of the next refresh; `now` when it is due already.
    public static func nextDeadline(last: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let last, last <= now else { return now }
        return max(now, last + interval)
    }

    /// nil below 45 minutes, else "50 分钟前" / "2 小时前".
    public static func ageLabel(fetchedAt: TimeInterval, now: TimeInterval) -> String? {
        let age = now - fetchedAt
        guard age >= ageShownFrom else { return nil }
        return age < 3600 ? "\(Int(age / 60)) 分钟前" : "\(Int(age / 3600)) 小时前"
    }

    /// More than 3 hours old: shown as 暂时拿不到天气.
    public static func isStale(fetchedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - fetchedAt > staleAfter
    }
}

/// "下午 3:20" in a time zone.
public enum LocalTime {
    public static func format(timezone: String, now: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timezone) ?? .current
        let c = cal.dateComponents([.hour, .minute], from: now)
        let h = c.hour ?? 0, m = c.minute ?? 0
        let period: String
        switch h {
        case 0..<6: period = "凌晨"
        case 6..<12: period = "上午"
        case 12..<18: period = "下午"
        default: period = "晚上"
        }
        return "\(period) \(h % 12 == 0 ? 12 : h % 12):\(String(format: "%02d", m))"
    }
}

public enum WeatherText {
    public static let unavailable = "暂时拿不到天气"

    /// "下午 3:20".
    public static func localTime(timezone: String, now: Date) -> String { LocalTime.format(timezone: timezone, now: now) }

    /// The line at the top of the compose panel: "噜妹那边：洛杉矶 ☀️ 24° · 下午 3:20" (`name` = the partner's
    /// display name). Data of 45+ minutes gets its age appended; over 3 hours, or none, reads 暂时拿不到天气.
    public static func line(name: String, place: WeatherPlace, snapshot: WeatherSnapshot?, now: Date) -> String {
        let t = now.timeIntervalSince1970
        let time = localTime(timezone: place.timezone, now: now)
        guard let s = snapshot, !WeatherRefresh.isStale(fetchedAt: s.fetchedAt, now: t) else {
            return "\(name)那边：\(place.name) \(unavailable) · \(time)"
        }
        var out = "\(name)那边：\(place.name) \(s.condition.emoji(isDay: s.isDay)) \(Int(s.temperature.rounded()))° · \(time)"
        if let age = WeatherRefresh.ageLabel(fetchedAt: s.fetchedAt, now: t) { out += " · \(age)" }
        return out
    }
}

public enum WeatherParseError: Error, Equatable { case malformed }

/// Open-Meteo JSON → model. Tolerant of extra fields; a forecast without a temperature is an error.
public enum WeatherParse {
    public static func snapshot(_ data: Data, now: TimeInterval) throws -> WeatherSnapshot {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cur = root["current"] as? [String: Any],
              let temp = (cur["temperature_2m"] as? NSNumber)?.doubleValue else { throw WeatherParseError.malformed }
        let daily = root["daily"] as? [String: Any]
        func first(_ key: String) -> Double? { ((daily?[key] as? [Any])?.first as? NSNumber)?.doubleValue }
        return WeatherSnapshot(condition: WeatherCondition(wmo: (cur["weather_code"] as? NSNumber)?.intValue ?? -1),
                               temperature: temp, high: first("temperature_2m_max"), low: first("temperature_2m_min"),
                               windSpeed: (cur["wind_speed_10m"] as? NSNumber)?.doubleValue,
                               isDay: ((cur["is_day"] as? NSNumber)?.intValue ?? 1) != 0, fetchedAt: now)
    }

    /// Geocoding results; entries without a name / coordinates / time zone, and repeats of the same city
    /// (same name and rounded coordinates), are dropped. Bad JSON or no `results` = [].
    public static func places(_ data: Data) -> [WeatherPlace] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        var seen = Set<String>(), out: [WeatherPlace] = []
        for r in results {
            guard let name = r["name"] as? String, !name.isEmpty,
                  let lat = (r["latitude"] as? NSNumber)?.doubleValue, let lon = (r["longitude"] as? NSNumber)?.doubleValue,
                  let tz = r["timezone"] as? String, !tz.isEmpty else { continue }
            let p = WeatherPlace(name: name, admin: r["admin1"] as? String, country: r["country"] as? String,
                                 latitude: lat, longitude: lon, timezone: tz)
            if seen.insert(p.name + "|" + p.cacheKey).inserted { out.append(p) }
        }
        return out
    }
}

/// `Sprites/<character>/weather.json`: `{"rain": [{"name", "dir", "sound"?}], "hot": [...], ...}` (written by
/// tools/build_sprites.py from the optional `"weather"` block of assets/sprites.json). The clip frames of
/// entry `dir` live in `Sprites/<character>/_weather/<dir>/`. Bad JSON / unknown looks / unsafe dirs are ignored.
public enum WeatherManifest {
    public static func parse(_ data: Data) -> [WeatherLook: [ClipIndex.Entry]] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [WeatherLook: [ClipIndex.Entry]] = [:]
        for look in WeatherLook.allCases {
            guard let items = obj[look.rawValue] as? [Any] else { continue }
            let entries = ClipIndex.parse((try? JSONSerialization.data(withJSONObject: items)) ?? Data())
            if !entries.isEmpty { out[look] = entries }
        }
        return out
    }
}

extension SpriteCatalog {
    private func weatherEntries(_ character: Role, _ look: WeatherLook) -> [ClipIndex.Entry] {
        let data = try? Data(contentsOf: root.appendingPathComponent(character.rawValue).appendingPathComponent("weather.json"))
        guard let manifest = data.map(WeatherManifest.parse) else { return [] }
        // snow without clips of its own uses the cold ones (`WeatherLook.clipLooks`)
        return look.clipLooks.lazy.compactMap { manifest[$0] }.first ?? []
    }

    /// Names of the clips that go with this look for this character (mixed into the random fidgets); [] = none.
    public func weatherClips(for character: Role, look: WeatherLook) -> [String] {
        weatherEntries(character, look).map(\.name)
    }

    /// The same clips, loaded (entries whose frames are missing are skipped).
    public func weatherNamedClips(for character: Role, look: WeatherLook) -> [NamedClip] {
        let dir = root.appendingPathComponent(character.rawValue).appendingPathComponent("_weather")
        return weatherEntries(character, look).compactMap { e in
            loadClip(dir.appendingPathComponent(e.dir), store: clipStore).map { NamedClip(name: e.name, clip: $0, sound: e.sound) }
        }
    }
}

/// Fixed data for `--fake-weather` and offscreen screenshots (no network).
public enum FakeWeather {
    public static let places: [WeatherPlace] = [
        WeatherPlace(name: "洛杉矶", admin: "加利福尼亚", country: "美国", latitude: 34.05, longitude: -118.24, timezone: "America/Los_Angeles"),
        WeatherPlace(name: "上海", admin: "上海", country: "中国", latitude: 31.23, longitude: 121.47, timezone: "Asia/Shanghai"),
    ]

    /// 洛杉矶 ☀️ 24° (27 / 16), 上海 🌧 19° (21 / 17); any other place ⛅ 20°.
    public static func snapshot(for place: WeatherPlace, now: TimeInterval) -> WeatherSnapshot {
        switch place.name {
        case "洛杉矶": return WeatherSnapshot(condition: .clear, temperature: 24, high: 27, low: 16, windSpeed: 12, isDay: true, fetchedAt: now)
        case "上海": return WeatherSnapshot(condition: .rain, temperature: 19, high: 21, low: 17, windSpeed: 18, isDay: true, fetchedAt: now)
        default: return WeatherSnapshot(condition: .partlyCloudy, temperature: 20, high: 23, low: 15, windSpeed: 10, isDay: true, fetchedAt: now)
        }
    }
}

/// In-memory weather of the running app, shared by the compose panel and the desktop widget.
public struct WeatherState: Equatable, Sendable {
    public var mine: WeatherSnapshot?
    public var partner: WeatherSnapshot?
    public var partnerPlace: WeatherPlace?
    public init() {}
}
