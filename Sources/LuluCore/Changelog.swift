import Foundation

/// v0.13: one release in `assets/changelog.json` (copied to `Resources/changelog.json`):
/// `[{"version": "0.12.2", "date": "2026-10-07", "items": ["..."]}, ...]`, read-only for the app.
public struct ChangelogEntry: Codable, Equatable, Sendable {
    public var version: String
    public var date: String
    public var items: [String]

    public init(version: String, date: String, items: [String]) {
        self.version = version; self.date = date; self.items = items
    }
}

/// What to do at launch about the "升级到 vX 啦" card.
public enum UpgradeCardPlan: Equatable, Sendable {
    /// Nothing to say, and nothing to record.
    case none
    /// No card, but record the current version as seen (new user, or an upgrade with no log entries).
    case markSeen
    /// Show the card summarizing `newItems` new items.
    case card(newItems: Int)
}

public enum Changelog {
    /// Bad data (not JSON, wrong shape) → []. Entries whose version does not parse are dropped; the rest are sorted
    /// by semantic version, newest first (so "0.10.0" is newer than "0.9.1").
    public static func parse(_ data: Data) -> [ChangelogEntry] {
        guard let all = try? JSONDecoder().decode([ChangelogEntry].self, from: data) else { return [] }
        return all.compactMap { e -> (AppVersion, ChangelogEntry)? in
            AppVersion(e.version).map { ($0, e) }
        }
        .sorted { $0.0 > $1.0 }
        .map { $0.1 }
    }

    /// The entries newer than `seen` (nil = never seen anything: all of them) and not newer than `current`,
    /// newest first. An unparseable `seen` counts as nil; an unparseable `current` yields [].
    public static func newer(than seen: String?, upTo current: String, in all: [ChangelogEntry]) -> [ChangelogEntry] {
        guard let cur = AppVersion(current) else { return [] }
        let floor = AppVersion(seen)
        return all.filter { e in
            guard let v = AppVersion(e.version) else { return false }
            return v <= cur && (floor.map { v > $0 } ?? true)
        }
        .sorted { (AppVersion($0.version) ?? AppVersion(0, 0, 0)) > (AppVersion($1.version) ?? AppVersion(0, 0, 0)) }
    }

    /// The card's text: 「升级到 v0.12.2 啦 · 3 条新功能」, plus 「还有 2 件事待设置」 on a second line when `todos` > 0.
    public static func cardText(current: String, newItems: Int, todos: Int) -> String {
        var line = "升级到 v\(current) 啦"
        if newItems > 0 { line += " · \(newItems) 条新功能" }
        if todos > 0 { line += "\n还有 \(todos) 件事待设置" }
        return line
    }

    /// Old / new user rules. `seen` = `whatsNewSeen`; `hadConfig` = a saved config existed before this launch.
    /// - no `seen`, no config (new user): record silently;
    /// - no `seen`, config exists (upgraded from ≤ 0.12.2): card for the newest entry only;
    /// - `seen` older than `current`: card for everything in between (or just record when the log has none);
    /// - otherwise nothing. `current` nil (swift run, no bundle) → nothing.
    public static func plan(seen: String?, hadConfig: Bool, current: String?, in all: [ChangelogEntry]) -> UpgradeCardPlan {
        guard let current, let cur = AppVersion(current) else { return .none }
        if let s = AppVersion(seen), s >= cur { return .none }
        if AppVersion(seen) == nil {
            guard hadConfig else { return .markSeen }
            guard let newest = newer(than: nil, upTo: current, in: all).first else { return .markSeen }
            return .card(newItems: newest.items.count)
        }
        let entries = newer(than: seen, upTo: current, in: all)
        return entries.isEmpty ? .markSeen : .card(newItems: entries.reduce(0) { $0 + $1.items.count })
    }
}

public enum SetupTodoAction: String, Sendable { case openSettingsCity, openToolsTab, howToUpgradePartner }

public struct SetupTodo: Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var button: String
    public var action: SetupTodoAction

    public init(id: String, title: String, detail: String, button: String, action: SetupTodoAction) {
        self.id = id; self.title = title; self.detail = detail; self.button = button; self.action = action
    }
}

public enum SetupTodos {
    public static let cityID = "city"
    public static let remindersID = "reminders"
    public static let partnerUpgradeID = "partnerUpgrade"

    /// Pure rules (recomputed from the current state every time; nothing about "done" is stored). Order: city,
    /// reminders, partnerUpgrade. `paired` = couple / friend mode (solo never has partnerUpgrade);
    /// `partnerOlder` = the partner's version is known and older than mine (unknown → false).
    public static func compute(hasCity: Bool, waterOn: Bool, standOn: Bool, paired: Bool,
                               partnerOlder: Bool, dismissed: Set<String>) -> [SetupTodo] {
        var out: [SetupTodo] = []
        if !hasCity {
            out.append(SetupTodo(id: cityID, title: "设置我的城市", detail: "设了城市，宠物就能告诉你天气，TA 也能看到你那边的天气",
                                 button: "去设置", action: .openSettingsCity))
        }
        if !waterOn && !standOn {
            out.append(SetupTodo(id: remindersID, title: "开启喝水 / 站立提醒", detail: "宠物会按时提醒你喝水、站起来动一动",
                                 button: "去设置", action: .openToolsTab))
        }
        if paired && partnerOlder {
            out.append(SetupTodo(id: partnerUpgradeID, title: "TA 的版本比你旧", detail: "让 TA 也升级，就能一起用上新功能",
                                 button: "怎么升级", action: .howToUpgradePartner))
        }
        return out.filter { !dismissed.contains($0.id) }
    }
}
