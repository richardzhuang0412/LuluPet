import LuluCore
import SwiftUI

// v0.12 weather: 「我的城市」 search box + result list, shared by Settings (通用 page) and the Welcome window.

/// How a city is searched (Open-Meteo geocoding, or `FakeWeather.places` with `--fake-weather`).
typealias CitySearch = @Sendable (String) async throws -> [WeatherPlace]

/// 「我的城市」 for Settings: the current place, how to change it (applies at once), how to search.
struct CityAccess {
    var place: WeatherPlace?
    var set: (WeatherPlace?) -> Void
    var search: CitySearch
    /// TA's city (their presence), read-only; nil = unknown. Shown in paired modes only.
    var partnerPlace: WeatherPlace? = nil
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

    init(place: WeatherPlace?, search: @escaping CitySearch, onChange: @escaping (WeatherPlace?) -> Void) {
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
                    ForEach(Array(results.enumerated()), id: \.offset) { i, p in
                        if i > 0 { Divider() }
                        Button { choose(p) } label: {
                            Text(p.pickerTitle)
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
