import Foundation

// v0.14.1 weather accuracy (docs/research/weather-accuracy.md): inside the US the current temperature and sky come
// from real NWS station observations (api.weather.gov) instead of a forecast model. Pure parsing / mapping /
// selection lives here (tested with fixture JSON); the network is `NWSClient` in LuluSync.

/// One observation station near a place (`/gridpoints/.../stations`).
public struct NWSStation: Codable, Equatable, Sendable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public init(id: String, latitude: Double, longitude: Double) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// One reading of a station, reduced to what we use.
public struct NWSObservation: Equatable, Sendable {
    public var stationId: String
    /// °C (a reading without a temperature is dropped by the parser).
    public var temperature: Double
    /// The sky, from the text description or (when that is empty) the cloud layers; nil = unknown.
    public var condition: WeatherCondition?
    /// Unix seconds.
    public var observedAt: TimeInterval
    /// Set when `condition` was taken from another (nearby) station because this one reports no sky.
    public var skyStationId: String?
    public init(stationId: String, temperature: Double, condition: WeatherCondition?, observedAt: TimeInterval, skyStationId: String? = nil) {
        self.skyStationId = skyStationId
        self.stationId = stationId
        self.temperature = temperature
        self.condition = condition
        self.observedAt = observedAt
    }
}

/// What a place's `/points` lookup found, cached for days: a US place with its nearby stations, or "not US".
public struct NWSLookup: Codable, Equatable, Sendable {
    public var isUS: Bool
    public var stations: [NWSStation]
    /// Unix seconds.
    public var checkedAt: TimeInterval
    public init(isUS: Bool, stations: [NWSStation], checkedAt: TimeInterval) {
        self.isUS = isUS
        self.stations = stations
        self.checkedAt = checkedAt
    }
    public static let ttl: TimeInterval = 7 * 86400
    public func isFresh(now: TimeInterval) -> Bool { now >= checkedAt && now - checkedAt < Self.ttl }
}

extension WeatherCondition {
    /// NWS `textDescription` ("Mostly Cloudy", "Light Rain Fog/Mist", ...), by keyword, first match wins:
    /// thunder, snow / sleet / ice / flurries, drizzle, rain / showers, fog / mist / haze / smoke / dust,
    /// overcast / mostly cloudy, partly / scattered / mostly sunny, cloudy, clear / sunny / fair / few clouds.
    /// nil for an empty or unrecognised text.
    public init?(nwsText text: String) {
        let t = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }
        if has("thunder") { self = .thunder }
        else if has("snow", "sleet", "ice", "flurr") { self = .snow }
        else if has("drizzle") { self = .drizzle }
        else if has("rain", "shower") { self = .rain }
        else if has("fog", "mist", "haze", "smoke", "dust") { self = .fog }
        else if has("overcast", "mostly cloudy") { self = .cloudy }
        else if has("partly", "scattered", "mostly sunny") { self = .partlyCloudy }   // before "cloudy": "Partly Cloudy"
        else if has("cloudy") { self = .cloudy }
        else if has("clear", "sunny", "fair", "few clouds") { self = .clear }
        else { return nil }
    }

    /// METAR cloud layer amounts (the most covered layer wins): CLR / SKC / FEW = clear, SCT / BKN = partly cloudy,
    /// OVC / VV = cloudy. nil when there is no known amount.
    public init?(nwsCloudAmounts amounts: [String]) {
        func rank(_ a: String) -> Int? {
            switch a.uppercased() {
            case "CLR", "SKC", "FEW": return 0
            case "SCT", "BKN": return 1
            case "OVC", "VV": return 2
            default: return nil
            }
        }
        guard let top = amounts.compactMap(rank).max() else { return nil }
        self = [WeatherCondition.clear, .partlyCloudy, .cloudy][top]
    }
}

public enum NWSParse {
    /// `/points/{lat},{lon}` → the stations list URL (`properties.observationStations`); nil when absent.
    public static func stationsURL(points data: Data) -> URL? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let props = root["properties"] as? [String: Any],
              let s = props["observationStations"] as? String, let url = URL(string: s), url.scheme == "https",
              url.host == "api.weather.gov" else { return nil }
        return url
    }

    /// `.../stations` GeoJSON → stations with coordinates (features without an id or coordinates are skipped).
    public static func stations(_ data: Data) -> [NWSStation] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let props = f["properties"] as? [String: Any], let id = props["stationIdentifier"] as? String, !id.isEmpty,
                  let coords = (f["geometry"] as? [String: Any])?["coordinates"] as? [Any], coords.count >= 2,
                  let lon = (coords[0] as? NSNumber)?.doubleValue, let lat = (coords[1] as? NSNumber)?.doubleValue else { return nil }
            return NWSStation(id: id, latitude: lat, longitude: lon)
        }
    }

    /// `/stations/{id}/observations` → readings that have a temperature and a timestamp, in the order served (newest first).
    public static func observations(_ data: Data, stationId: String) -> [NWSObservation] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { f in
            guard let p = f["properties"] as? [String: Any],
                  let temp = ((p["temperature"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue,
                  let stamp = p["timestamp"] as? String, let at = date(stamp) else { return nil }
            let layers = (p["cloudLayers"] as? [[String: Any]])?.compactMap { $0["amount"] as? String } ?? []
            let text = (p["textDescription"] as? String) ?? ""
            let cond = WeatherCondition(nwsText: text) ?? WeatherCondition(nwsCloudAmounts: layers)
            return NWSObservation(stationId: stationId, temperature: temp, condition: cond, observedAt: at.timeIntervalSince1970)
        }
    }

    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }
}

public enum NWSSelect {
    public static let maxDistanceKm = 25.0
    public static let maxAge: TimeInterval = 90 * 60
    /// "among the nearest few" for the ICAO preference.
    public static let nearestFew = 5
    /// The most stations asked in one refresh (usually the first one answers).
    public static let maxTries = 3

    /// Great-circle distance in km.
    public static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * rad) * cos(lat2 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }

    /// The stations to ask, in order: those within 25 km, nearest first, but K-prefixed airport (ICAO) stations
    /// among the nearest five go first (they report a sky and cloud layers; the small mesonet stations often do not).
    public static func candidates(_ stations: [NWSStation], near place: WeatherPlace) -> [NWSStation] {
        let near = stations
            .map { ($0, distanceKm(place.latitude, place.longitude, $0.latitude, $0.longitude)) }
            .filter { $0.1 <= maxDistanceKm }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
        let few = Array(near.prefix(nearestFew))
        return Array((few.filter { $0.id.hasPrefix("K") } + few.filter { !$0.id.hasPrefix("K") }).prefix(maxTries))
    }

    /// Where to look for a sky when the temperature station has none (one extra call): the nearest K-prefixed airport
    /// station within 25 km that has not been asked yet.
    public static func skyStation(_ stations: [NWSStation], near place: WeatherPlace, excluding asked: Set<String>) -> NWSStation? {
        stations
            .filter { $0.id.hasPrefix("K") && !asked.contains($0.id) }
            .map { ($0, distanceKm(place.latitude, place.longitude, $0.latitude, $0.longitude)) }
            .filter { $0.1 <= maxDistanceKm }
            .min { $0.1 < $1.1 }?.0
    }

    /// The first reading with a temperature that is at most 90 minutes old (and not from the future).
    public static func usable(_ readings: [NWSObservation], now: TimeInterval) -> NWSObservation? {
        readings.first { now - $0.observedAt <= maxAge && $0.observedAt - now < 600 }
    }

    /// Plausibly US territory (incl. Alaska / Hawaii / Puerto Rico); anywhere else never asks NWS.
    public static func mayBeUS(_ p: WeatherPlace) -> Bool {
        ((17...72).contains(p.latitude) && ((-180)...(-64)).contains(p.longitude)) || (p.latitude >= 50 && p.longitude >= 172)
    }
}

/// Open-Meteo base snapshot + an NWS reading → what the app shows.
public enum WeatherMerge {
    /// Temperature and sky from the station (the sky stays Open-Meteo's when the station has none); high / low,
    /// wind and day / night stay Open-Meteo's, widened so the temperature is never outside today's range.
    public static func apply(_ base: WeatherSnapshot, nws: NWSObservation?) -> WeatherSnapshot {
        guard let nws else { return base }
        var s = base
        s.temperature = nws.temperature
        if let c = nws.condition { s.condition = c }
        if let h = s.high { s.high = max(h, nws.temperature) }
        if let l = s.low { s.low = min(l, nws.temperature) }
        return s
    }
}
