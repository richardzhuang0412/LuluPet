import Foundation
import LuluCore

/// v0.15.1 the user's 快捷栏 (`stickerQuickBar`), send counts (`stickerSendCounts`) and use times (`stickerRecent`),
/// shared by the compose panel and the Settings 「表情」 page so a change shows up in an open panel at once.
/// Without a store (tests) everything lives in memory only.
@MainActor final class StickerPrefsModel: ObservableObject {
    private let store: ConfigStore?
    /// The stored 快捷栏 (at most 8 ids; ids the current mode hides stay in it).
    @Published private(set) var quickBar: [String]
    @Published private(set) var counts: [String: Int]
    @Published private(set) var recent: [String: Int64]
    /// A short confirmation shown beside the 快捷栏 title for a moment.
    @Published var toast: String?
    /// 「更多表情…」 is open. Remembered while the app runs (not saved): the next panel opens the same way.
    @Published var moreExpanded = StickerPrefsModel.expandedThisSession {
        didSet { StickerPrefsModel.expandedThisSession = moreExpanded }
    }
    nonisolated(unsafe) static var expandedThisSession = false
    private var toastGeneration = 0

    /// `library`: every sticker id of the catalog (not the policy-filtered ones). `scanHistory` counts my sent stickers
    /// in history.jsonl; it runs once, the first time (no `stickerSendCounts` stored yet).
    init(store: ConfigStore?, library: [String], scanHistory: (() -> [String: Int])? = nil) {
        self.store = store
        let recent = store?.stickerRecent ?? [:]
        self.recent = recent
        let counts: [String: Int]
        if let stored = store?.stickerSendCounts {
            counts = stored
        } else {
            counts = scanHistory?() ?? [:]
            store?.stickerSendCounts = counts
            NSLog("[lulu] stickers: send counts built from history (%ld stickers, %ld sends)", counts.count, counts.values.reduce(0, +))
        }
        self.counts = counts
        if let stored = store?.stickerQuickBar {
            quickBar = Array(stored.prefix(StickerPanel.maxQuickBar))
        } else {
            let seeded = StickerPanel.seedQuickBar(favorites: store?.stickerFavorites, counts: counts, recent: recent, library: library)
            store?.stickerQuickBar = seeded
            quickBar = seeded
            NSLog("[lulu] stickers: quick bar seeded: %@", seeded.joined(separator: ","))
        }
    }

    /// A sticker was sent (or acted out in solo): it counts towards 常用 and is the newest use.
    func use(_ id: String) {
        counts[id, default: 0] += 1
        recent = StickerPanel.recorded(id, at: nowMs(), in: recent)
        store?.stickerSendCounts = counts
        store?.stickerRecent = recent
    }

    func isOnBar(_ id: String) -> Bool { quickBar.contains(id) }
    var barIsFull: Bool { quickBar.count >= StickerPanel.maxQuickBar }

    private func setBar(_ list: [String]) {
        quickBar = list
        store?.stickerQuickBar = list
    }

    /// The panel's right-click: 放进快捷栏 / 从快捷栏拿下 (a full bar is not changed; the menu says so).
    func toggleQuickBar(_ id: String) {
        if isOnBar(id) {
            setBar(StickerPanel.removed(id, from: quickBar))
            say("已从快捷栏拿下")
        } else if !barIsFull {
            setBar(quickBar + [id])
            say("已放进快捷栏 ★")
        }
    }

    /// Settings: click a sticker below the bar. A full bar swaps out the last slot shown. Returns the message.
    @discardableResult
    func equip(_ id: String, visible: [String], label: (String) -> String) -> String {
        if isOnBar(id) { return "「\(label(id))」已经在快捷栏里了" }
        let r = StickerPanel.equipped(id, in: quickBar, visible: visible)
        setBar(r.list)
        if let old = r.replaced { return "快捷栏满了，已换掉最后一格「\(label(old))」" }
        return "已装上「\(label(id))」"
    }

    func unequip(_ id: String) { setBar(StickerPanel.removed(id, from: quickBar)) }
    /// v0.15.3 drag & drop onto a quick-bar slot. Returns the message for the page.
    func drop(_ id: String, onto slot: Int, visible: [String], label: (String) -> String) -> String {
        let wasOn = isOnBar(id)
        let r = StickerPanel.dropped(id, onto: slot, in: quickBar, visible: visible)
        setBar(r.list)
        if wasOn { return "已把「\(label(id))」挪到第 \(min(slot, r.list.count - 1) + 1) 格" }
        if let old = r.replaced { return "「\(label(id))」换下了「\(label(old))」" }
        return "已装上「\(label(id))」"
    }
    func move(_ id: String, by delta: Int, visible: [String]) { setBar(StickerPanel.moved(id, by: delta, in: quickBar, visible: visible)) }
    func recommend(visible: [String]) {
        setBar(StickerPanel.recommended(stored: quickBar, counts: counts, recent: recent, visible: visible))
    }

    private func say(_ text: String) {
        toastGeneration += 1
        let mine = toastGeneration
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toastGeneration == mine { self?.toast = nil }
        }
    }
}
