import LuluCore
import SwiftUI

// v0.12 weather: 「我的城市」 search box + result list, shared by Settings (通用 page) and the Welcome window.

/// How a city is searched (Open-Meteo geocoding, or `FakeWeather.places` with `--fake-weather`).
typealias CitySearch = @Sendable (String) async throws -> [WeatherPlace]

/// v0.14.1 how 「使用我现在的位置」 is going (shown under the toggle).
enum LocationStatus: Equatable {
    case idle, locating
    /// No location permission: the hint with the 打开系统设置 button.
    case denied
    /// Permitted, but no fix / city name right now.
    case failed
}

/// What the 我的城市 section shows; AppDelegate updates it while Settings is open (a located city arrives later).
@MainActor
final class CityModel: ObservableObject {
    @Published var place: WeatherPlace?
    /// 「使用我现在的位置」 is on (`WeatherStore.myPlaceAuto`).
    @Published var auto = false
    @Published var status: LocationStatus = .idle
}

/// 「我的城市」 for Settings: the current place, how to change it (applies at once), how to search.
struct CityAccess {
    var model: CityModel
    var set: (WeatherPlace?) -> Void
    var search: CitySearch
    /// TA's city (their presence), read-only; nil = unknown. Shown in paired modes only.
    var partnerPlace: WeatherPlace? = nil
    /// v0.14.1 the 「使用我现在的位置」 toggle (applies at once).
    var setAuto: (Bool) -> Void = { _ in }
    /// Opens 系统设置 → 隐私与安全性 → 定位服务.
    var openLocationSettings: () -> Void = {}
}

/// The whole 我的城市 section body: picker, the location toggle with its status line, TA's city, the privacy note.
struct CitySection: View {
    let access: CityAccess
    let paired: Bool
    @ObservedObject var model: CityModel

    init(access: CityAccess, paired: Bool) {
        self.access = access
        self.paired = paired
        self.model = access.model
    }

    var body: some View {
        CityPicker(place: model.place, syncedPlace: model.place, search: access.search, onChange: access.set)
        Toggle(isOn: Binding(get: { model.auto }, set: { access.setAuto($0) })) {
            Text("使用我现在的位置").font(.system(size: 12, design: .rounded))
        }
        .toggleStyle(.checkbox)
        if let line = statusLine {
            Text(line).font(.system(size: 11, design: .rounded))
                .foregroundStyle(model.status == .denied ? Color.red.opacity(0.8) : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if model.status == .denied {
            Button("打开系统设置", action: access.openLocationSettings).controlSize(.small)
        }
        if paired {
            Text(access.partnerPlace.map { "TA 的城市：📍 " + $0.pickerTitle } ?? "TA 还没设置城市")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(access.partnerPlace == nil ? Color.secondary : Color(white: 0.2))
                .lineLimit(1)
        }
        Text("用来显示天气：TA 能看到你那边的天气和当地时间，只分享城市，不分享精确位置")
            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLine: String? {
        switch model.status {
        case .locating: return "正在定位…"
        case .denied: return "定位没打开：系统设置 → 隐私与安全性 → 定位服务 里允许噜噜桌宠"
        case .failed: return "暂时定位不到，先用现在的城市"
        case .idle: return model.auto ? "城市会跟着你所在的位置自动更新（手动选城市会关掉它）" : nil
        }
    }
}

extension WeatherPlace {
    /// "洛杉矶 · 加利福尼亚 · 美国" (just the name when there is nothing more to say).
    var pickerTitle: String { subtitle.isEmpty ? name : "\(name) · \(subtitle)" }
}

/// With a city chosen: just the row 「📍 name · subtitle」 with 更改 / 清除. 更改 (or no city yet) shows the search field
/// (250 ms debounce, cached repeats, no timers: a cancelled `.task(id:)`) and result rows "name · subtitle"; picking a row,
/// 取消 or Esc folds it back. Picking calls `onChange(place)`; 清除 calls `onChange(nil)`.
struct CityPicker: View {
    let search: CitySearch
    let onChange: (WeatherPlace?) -> Void
    /// v0.14.1: the city as the app has it; follows changes made elsewhere (a located city arriving). nil in the Welcome window.
    var syncedPlace: WeatherPlace?

    @State private var place: WeatherPlace?
    @State private var query: String
    @State private var results: [WeatherPlace] = []
    @State private var status: String?
    /// The search field is showing (always when no city is chosen).
    @State private var changing: Bool
    @FocusState private var searchFocused: Bool

    /// Hidden `--demo-city-query X`: start with X typed in (snapshots).
    nonisolated(unsafe) static var demoQuery: String?
    static let debounce: UInt64 = 250_000_000
    /// Results already seen this run (query → places): repeat queries answer at once.
    @MainActor private static var cache: [String: [WeatherPlace]] = [:]

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    init(place: WeatherPlace?, syncedPlace: WeatherPlace? = nil, search: @escaping CitySearch, onChange: @escaping (WeatherPlace?) -> Void) {
        self.syncedPlace = syncedPlace
        self.search = search
        self.onChange = onChange
        _place = State(initialValue: place)
        _query = State(initialValue: Self.demoQuery ?? "")
        _changing = State(initialValue: place == nil || Self.demoQuery != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(place.map { "📍 " + $0.pickerTitle } ?? "还没设置城市")
                    .font(.system(size: 12, weight: place == nil ? .regular : .semibold, design: .rounded))
                    .foregroundStyle(place == nil ? Color.secondary : Color(white: 0.2))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if place != nil {
                    if !changing {
                        Button("更改") { changing = true; searchFocused = true }
                            .controlSize(.small)
                    }
                    Button("清除") {
                        place = nil
                        changing = true
                        onChange(nil)
                    }
                    .controlSize(.small)
                }
            }
            if changing {
                HStack(spacing: 6) {
                    TextField("搜索城市（中文或英文）", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .onExitCommand(perform: cancel)
                    if place != nil {
                        Button("取消", action: cancel).controlSize(.small)
                    }
                }
            }
            if changing, !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(Self.rows(results).enumerated()), id: \.offset) { i, row in
                        let p = row.place
                        if i > 0 { Divider() }
                        Button { choose(p) } label: {
                            Text(row.label)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color(white: 0.2))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.accent.opacity(0.35), lineWidth: 1))
            } else if changing, let status {
                Text(status).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .task(id: query) { await runSearch() }
        .onChange(of: syncedPlace) { _, new in
            guard new != place else { return }
            place = new
            if new != nil { changing = false; query = ""; results = []; status = nil } else { changing = true }
        }
    }

    /// Result rows with identical labels ("Springfield · Illinois · 美国" twice) are told apart: a near-duplicate (same label,
    /// within ~0.1° of an earlier row) is dropped; a genuinely different place with the same label gets its coordinates appended.
    static func rows(_ places: [WeatherPlace]) -> [(place: WeatherPlace, label: String)] {
        var kept: [WeatherPlace] = []
        for p in places where !kept.contains(where: { $0.pickerTitle == p.pickerTitle && abs($0.latitude - p.latitude) < 0.1 && abs($0.longitude - p.longitude) < 0.1 }) {
            kept.append(p)
        }
        let counts = Dictionary(kept.map { ($0.pickerTitle, 1) }, uniquingKeysWith: +)
        return kept.map { p in
            guard (counts[p.pickerTitle] ?? 0) > 1 else { return (p, p.pickerTitle) }
            let lat = String(format: "%.1f°%@", abs(p.latitude), p.latitude >= 0 ? "N" : "S")
            let lon = String(format: "%.1f°%@", abs(p.longitude), p.longitude >= 0 ? "E" : "W")
            return (p, "\(p.pickerTitle)（\(lat) \(lon)）")
        }
    }

    private func choose(_ p: WeatherPlace) {
        place = p
        results = []
        status = nil
        query = ""
        changing = false
        onChange(p)
    }

    /// Fold the search field back (only meaningful with a city chosen).
    private func cancel() {
        guard place != nil else { return }
        changing = false
        query = ""
        results = []
        status = nil
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; status = nil; return }
        if let hit = Self.cache[q] {
            results = hit
            status = hit.isEmpty ? "没有找到「\(q)」" : nil
            return
        }
        // Debounce: a newer keystroke cancels this task during the sleep.
        do { try await Task.sleep(nanoseconds: Self.debounce) } catch { return }
        if results.isEmpty { status = "搜索中…" }
        do {
            let found = try await search(q)
            guard !Task.isCancelled else { return }
            Self.cache[q] = found
            results = found
            status = found.isEmpty ? "没有找到「\(q)」" : nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            status = "暂时搜不到城市，稍后再试"
        }
    }
}
