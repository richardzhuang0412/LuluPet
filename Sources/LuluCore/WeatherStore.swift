import CoreGraphics
import Foundation

/// v0.12 persistence, in the same defaults domain as `ConfigStore` (docs/upgrade-compat.md): `myPlace`,
/// `weatherWidget`, `weatherCache`. All JSON; bad / missing data = defaults.
public final class WeatherStore: @unchecked Sendable {
    private let defaults: UserDefaults
    /// The cache keeps the most recent results of this many places (mine, TA's, and a few old ones).
    static let cacheLimit = 8

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private struct WidgetState: Codable {
        var enabled: Bool = false
        var x: Double?
        var y: Double?
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    /// My city; nil = none set.
    public var myPlace: WeatherPlace? {
        get { load("myPlace") }
        set { save(newValue, "myPlace") }
    }

    private var widget: WidgetState {
        get { load("weatherWidget") ?? WidgetState() }
        set { save(newValue, "weatherWidget") }
    }

    /// 天气小组件 on / off (default off).
    public var widgetEnabled: Bool {
        get { widget.enabled }
        set { var w = widget; w.enabled = newValue; widget = w }
    }

    /// Where the widget was dragged to (screen coordinates); nil = never moved.
    public var widgetOrigin: CGPoint? {
        get { let w = widget; return w.x.flatMap { x in w.y.map { CGPoint(x: x, y: $0) } } }
        set { var w = widget; w.x = newValue.map { Double($0.x) }; w.y = newValue.map { Double($0.y) }; widget = w }
    }

    private func cache() -> [String: WeatherSnapshot] { load("weatherCache") ?? [:] }

    /// The last successful result for this place.
    public func cached(for place: WeatherPlace) -> WeatherSnapshot? { cache()[place.cacheKey] }

    public func setCached(_ s: WeatherSnapshot, for place: WeatherPlace) {
        var c = cache()
        c[place.cacheKey] = s
        if c.count > Self.cacheLimit {
            for (k, _) in c.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt }).prefix(c.count - Self.cacheLimit) where k != place.cacheKey { c[k] = nil }
        }
        save(c, "weatherCache")
    }
}
