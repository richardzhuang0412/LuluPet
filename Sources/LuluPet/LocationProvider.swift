import AppKit
import CoreLocation
import LuluCore
import MapKit

// v0.14.1 「使用我现在的位置」 (opt-in, default off). One-shot, kilometre-accuracy fixes only; the coordinates stay on
// this Mac, the city (rounded to two decimals, like a hand-picked one) is all that is ever shared.

enum LocationFailure: Error, Equatable {
    /// No permission (denied, restricted, or location services off).
    case denied
    /// No fix right now (no Wi-Fi position, timed out, ...).
    case unavailable
}

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: [(Result<CLLocation, LocationFailure>) -> Void] = []
    private var inFlight = false
    private var generation = 0

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// One fix. `prompt` allows the system permission prompt (only when the user just asked for it: the app is
    /// activated first, since a menu-bar app's prompt can hide behind other windows); without it an undecided
    /// permission counts as denied.
    func locate(prompt: Bool, completion: @escaping (Result<CLLocation, LocationFailure>) -> Void) {
        waiting.append(completion)
        guard !inFlight else { return }
        inFlight = true
        generation += 1
        switch manager.authorizationStatus {
        case .notDetermined:
            if prompt {
                NSApp.activate()
                manager.requestWhenInUseAuthorization()   // answered in locationManagerDidChangeAuthorization
            } else {
                finish(.failure(.denied))
            }
        case .denied, .restricted:
            finish(.failure(.denied))
        default:   // authorizedAlways (what macOS reports once allowed) / authorizedWhenInUse
            requestFix()
        }
    }

    private func requestFix() {
        manager.requestLocation()
        let g = generation
        Task { @MainActor [weak self] in   // watchdog: a request that never answers must not block the next one
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if let self, self.inFlight, self.generation == g { self.finish(.failure(.unavailable)) }
        }
    }

    private func finish(_ result: Result<CLLocation, LocationFailure>) {
        guard inFlight else { return }
        inFlight = false
        let done = waiting
        waiting = []
        done.forEach { $0(result) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.inFlight else { return }
            switch self.manager.authorizationStatus {
            case .notDetermined: break
            case .denied, .restricted: self.finish(.failure(.denied))
            default: self.requestFix()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor [weak self] in self?.finish(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor [weak self] in self?.finish(.failure(denied ? .denied : .unavailable)) }
    }
}

/// Coordinates → a `WeatherPlace` with a Chinese city name ("伯克利", "上海市").
enum PlaceGeocoder {
    static let locale = Locale(identifier: "zh_CN")

    static func place(for location: CLLocation) async -> WeatherPlace? {
        let c = location.coordinate
        if #available(macOS 26, *), let p = await mapKitPlace(location) { return p }
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(location, preferredLocale: locale).first else { return nil }
        guard let name = [mark.locality, mark.subAdministrativeArea, mark.administrativeArea, mark.name].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        return WeatherPlace(name: name, admin: mark.administrativeArea, country: mark.country, latitude: c.latitude, longitude: c.longitude,
                            timezone: (mark.timeZone ?? .current).identifier)
    }

    /// macOS 26: `CLGeocoder` is deprecated there; MapKit's reverse geocoding request replaces it.
    @available(macOS 26, *)
    private static func mapKitPlace(_ location: CLLocation) async -> WeatherPlace? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        request.preferredLocale = locale
        guard let item = try? await request.mapItems.first,
              let name = item.addressRepresentations?.cityName, !name.isEmpty else { return nil }
        let c = location.coordinate
        return WeatherPlace(name: name, admin: nil, country: item.addressRepresentations?.regionName, latitude: c.latitude, longitude: c.longitude,
                            timezone: (item.timeZone ?? .current).identifier)
    }
}
