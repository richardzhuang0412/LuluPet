import Foundation
import LuluCore

/// v0.14.1: US National Weather Service station observations (api.weather.gov; no key, public domain, needs an
/// identifiable User-Agent). `/points` → stations are looked up once per place and cached for a week in the
/// `WeatherStore`; a refresh is then one `/stations/{id}/observations` call (up to 3 when the nearest stations
/// have no usable reading). Every failure answers nil so the caller falls back to Open-Meteo.
public struct NWSClient: Sendable {
    /// Fetches a URL's body; throws `WeatherClientError.http(code)` for a non-2xx answer. Injectable for tests.
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let fetch: Fetch

    public static func userAgent(version: String?) -> String {
        "LuluPet/\(version ?? "dev") (github.com/richardzhuang0412/LuluPet)"
    }

    public init(userAgent: String, session: URLSession = WeatherClient.sharedSession) {
        self.fetch = { url in
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("application/geo+json", forHTTPHeaderField: "Accept")
            let (data, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw WeatherClientError.http(http.statusCode) }
            return data
        }
    }

    public init(fetch: @escaping Fetch) { self.fetch = fetch }

    /// The cached or freshly looked up stations of a place; nil = not a US place (cached for a week) or no answer now.
    func lookup(for place: WeatherPlace, store: WeatherStore?, now: TimeInterval) async -> NWSLookup? {
        if let hit = store?.nwsLookup(for: place), hit.isFresh(now: now) { return hit }
        guard NWSSelect.mayBeUS(place) else { return nil }
        let points = URL(string: String(format: "https://api.weather.gov/points/%.2f,%.2f", place.latitude, place.longitude))!
        let found: NWSLookup
        do {
            let data = try await fetch(points)
            guard let stationsURL = NWSParse.stationsURL(points: data) else { return nil }
            let stations = NWSParse.stations(try await fetch(stationsURL))
            guard !stations.isEmpty else { return nil }
            found = NWSLookup(isUS: true, stations: stations, checkedAt: now)
        } catch WeatherClientError.http(404) {
            found = NWSLookup(isUS: false, stations: [], checkedAt: now)   // outside NWS coverage: don't ask again for a week
        } catch {
            return nil
        }
        store?.setNWSLookup(found, for: place)
        return found
    }

    /// The latest usable station reading near `place` (temperature present, under 90 minutes old, station within 25 km).
    public func observation(for place: WeatherPlace, store: WeatherStore?, now: TimeInterval = Date().timeIntervalSince1970) async -> NWSObservation? {
        guard let look = await lookup(for: place, store: store, now: now), look.isUS else { return nil }
        var asked = Set<String>()
        var found: NWSObservation?
        for station in NWSSelect.candidates(look.stations, near: place) {
            asked.insert(station.id)
            if let obs = await reading(station.id, now: now) { found = obs; break }
        }
        guard var best = found else { return nil }
        // The temperature station may report no sky (many mesonet stations, even KSFO at times): borrow the sky from
        // the nearest airport station with one extra call; only when that has none either does Open-Meteo's sky stay.
        if best.condition == nil, let sky = NWSSelect.skyStation(look.stations, near: place, excluding: asked),
           let c = await reading(sky.id, now: now)?.condition {
            best.condition = c
            best.skyStationId = sky.id
        }
        return best
    }

    private func reading(_ stationId: String, now: TimeInterval) async -> NWSObservation? {
        guard let url = URL(string: "https://api.weather.gov/stations/\(stationId)/observations?limit=3"),
              let data = try? await fetch(url) else { return nil }
        return NWSSelect.usable(NWSParse.observations(data, stationId: stationId), now: now)
    }
}
