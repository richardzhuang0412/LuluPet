import Foundation
import LuluCore

public enum WeatherClientError: Error, Equatable {
    case http(Int)
    case badURL
}

extension URLSession {
    /// Ephemeral (no cookies / disk cache), 10 s timeouts.
    public static var ephemeralTimeout10: URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }
}

/// Open-Meteo: city search (geocoding, `language=zh`) and current weather. No key, no account.
public struct WeatherClient: Sendable {
    private let session: URLSession

    /// v0.13.1: one long-lived session, so the TLS connection to Open-Meteo is reused (a fresh one costs ~0.5 s
    /// per search — the city picker felt slow).
    public static let sharedSession: URLSession = .ephemeralTimeout10

    public init(session: URLSession = WeatherClient.sharedSession) { self.session = session }

    /// Opens the connection ahead of the first search (the picker appearing); errors ignored.
    public func warmUp() async { _ = try? await search("上海") }

    /// Up to 8 matches for a city name (Chinese or English); a blank query makes no request.
    public func search(_ query: String) async throws -> [WeatherPlace] {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return [] }
        let url = try Self.url("https://geocoding-api.open-meteo.com/v1/search",
                               ["name": name, "count": "8", "language": "zh", "format": "json"])
        return WeatherParse.places(try await fetch(url))
    }

    /// Current conditions plus today's high / low; `fetchedAt` is now. Open-Meteo only.
    public func current(for place: WeatherPlace) async throws -> WeatherSnapshot {
        let url = try Self.url("https://api.open-meteo.com/v1/forecast", [
            "latitude": String(format: "%.2f", place.latitude), "longitude": String(format: "%.2f", place.longitude),
            "current": "temperature_2m,weather_code,cloud_cover,wind_speed_10m,is_day",
            "daily": "temperature_2m_max,temperature_2m_min", "timezone": "auto", "forecast_days": "1"])
        return try WeatherParse.snapshot(try await fetch(url), now: Date().timeIntervalSince1970)
    }

    /// v0.14.1: the weather the app shows. High / low (and wind, day / night) always come from Open-Meteo; inside the US
    /// the temperature and sky are replaced by a real station observation (`NWSClient`) when a usable one exists.
    /// `source` says which: "NWS KSFO" or "Open-Meteo". Open-Meteo failing is an error (no high / low to show).
    public func currentBest(for place: WeatherPlace, store: WeatherStore?, userAgent: String) async throws -> (snapshot: WeatherSnapshot, source: String) {
        async let nws = NWSClient(userAgent: userAgent, session: session).observation(for: place, store: store)
        let base = try await current(for: place)
        let obs = await nws
        return (WeatherMerge.apply(base, nws: obs), obs.map { "NWS \($0.stationId)" + ($0.skyStationId.map { " (sky \($0))" } ?? "") } ?? "Open-Meteo")
    }

    static func url(_ base: String, _ query: [String: String]) throws -> URL {
        guard var c = URLComponents(string: base) else { throw WeatherClientError.badURL }
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw WeatherClientError.badURL }
        return url
    }

    private func fetch(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw WeatherClientError.http(http.statusCode) }
        return data
    }
}
