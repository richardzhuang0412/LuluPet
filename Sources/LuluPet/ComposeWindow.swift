import AppKit
import ImageIO
import LuluCore
import SwiftUI

/// Small panel (opened by double-clicking the pet) to send a heart, text or a quick sticker, or to
/// go visit the partner ("去找TA 🏃"). v0.4: a second tab「记录」shows the message history.
final class ComposeWindow: NSPanel {
    enum Tab: Hashable { case compose, history, tools }

    var onSendText: ((String) -> Void)?
    var onSendSticker: ((String) -> Void)?
    var onSendHeart: (() -> Void)?
    var onGoVisit: (() -> Void)?
    /// v0.10: 「💧 叫 TA 喝水」/「🧍 叫 TA 起来动动」.
    var onSendRemind: ((ReminderKind) -> Void)?
    /// v0.14.3 「👀 偷看」 under the weather card: peek at TA (the panel closes first).
    var onPeek: (() -> Void)?
    /// v0.11.3 「调时长…」 on the 小工具 tab: open Settings on the 小工具 page.
    var onOpenToolsSettings: (() -> Void)?

    private var stickerPrefs: StickerPrefsModel?
    /// Open / close 「更多表情…」 (demo and snapshot flags).
    func setMoreStickers(expanded: Bool) {
        stickerPrefs?.moreExpanded = expanded
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    private var outsideClickMonitor: Any?
    private var isDismissing = false

    /// v0.13.3: the weather card at the top of the 传话 / 表情 tab. Updated while the panel is open.
    private let weatherModel = WeatherCardModel()
    /// 「设置我的城市」 link in the card.
    var onOpenSettings: (() -> Void)?

    /// The weather changed while the panel is open.
    func setWeatherCard(_ data: WeatherCardData) {
        guard weatherModel.data != data else { return }
        weatherModel.data = data
        DispatchQueue.main.async { [weak self] in self?.refit() }
    }

    struct StickerChoice: Identifiable {
        let id: String
        let label: String
        let thumbnail: NSImage?
        /// `StickerGroup` raw value (nil = 其他).
        var group: String? = nil

        /// A very wide strip (≥ 1.85 : 1, e.g. 冷战 with the pets far apart): letterboxed, not cropped to an empty middle.
        /// Ordinary 16:9 stickers (贴贴, 送你花, 晚安…) still fill their tile as before.
        var isWide: Bool { thumbnail.map { $0.size.height > 0 && $0.size.width / $0.size.height >= 1.85 } ?? false }
    }

    /// v0.15 the user's 常用 list and use times (`stickerFavorites` / `stickerRecent` of the profile), shared by the
    /// panel's grids. Without a store (tests, snapshots of a throwaway profile) it is in memory only.
    @MainActor final class StickerPrefsModel: ObservableObject {
        private let store: ConfigStore?
        @Published var pinned: [String]?
        @Published var recent: [String: Int64]
        /// A short confirmation (「已加入常用」) shown beside the 常用 title for a moment.
        @Published var toast: String?
        /// 「更多表情…」 is open. Remembered while the app runs (not saved): the next panel opens the same way.
        @Published var moreExpanded = StickerPrefsModel.expandedThisSession {
            didSet { StickerPrefsModel.expandedThisSession = moreExpanded }
        }
        nonisolated(unsafe) static var expandedThisSession = false
        private var toastGeneration = 0

        init(store: ConfigStore?) {
            self.store = store
            pinned = store?.stickerFavorites
            recent = store?.stickerRecent ?? [:]
        }

        /// A sticker was sent (or acted out in solo): it moves to the front of 常用 next time.
        func use(_ id: String) {
            recent = StickerPanel.recorded(id, at: nowMs(), in: recent)
            store?.stickerRecent = recent
        }

        /// 加入常用 / 移出常用 (nothing happens when 常用 is full).
        func toggle(_ id: String, visible: [String]) {
            let removing = StickerPanel.favorites(pinned: pinned, recent: [:], visible: visible).contains(id)
            guard removing || StickerPanel.canAdd(pinned: pinned, visible: visible) else { return }
            pinned = StickerPanel.toggled(id, pinned: pinned)
            store?.stickerFavorites = pinned
            toastGeneration += 1
            let mine = toastGeneration
            toast = removing ? "已移出常用" : "已加入常用 ★"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                if self?.toastGeneration == mine { self?.toast = nil }
            }
        }
    }

    /// Nothing is loaded until the「记录」tab is opened.
    struct HistorySource {
        var store: HistoryStore
        var me: Role
        /// "你不在的时候" batch not looked at yet (shown at the top of the tab).
        var away: AwaySummary?
        /// v0.8: finished 勿扰 stretches (dividers in the list) and the away card's title.
        var dndSpans: [DNDSpan] = []
        var awayTitle = "🍊 你不在的时候"
        /// The batch came in during 勿扰: list it like the 诚意清单.
        var awaySincerity = false
    }

    /// Called once the「记录」tab has been shown (the "你不在的时候" batch counts as seen).
    var onHistorySeen: (() -> Void)?

    /// `statusNote` is a tiny warning under the title (e.g. when not connected yet); nil hides it.
    init(partnerName: String, stickers: StickerCatalog, partnerFocusNote: String? = nil, statusNote: String? = nil, partnerApp: String? = nil,
         history: HistorySource? = nil, tab: Tab = .compose,
         policy: ContentPolicy = .couple, solo: Bool = false, tools: ToolsPanelModel? = nil, weather: WeatherCardData = WeatherCardData(),
         stickerStore: ConfigStore? = nil) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)   // our panels are drawn light (cream / orange); keep them light in Dark Mode
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // v0.11: kiss / hug stickers are hidden when the policy (friend mode) does not allow intimate content.
        let choices = stickers.stickers.filter { policy.allowsSticker(intimate: $0.intimate) }.map { s in
            StickerChoice(id: s.id, label: s.label, thumbnail: stickers.url(for: s.id).flatMap(Self.firstFrame), group: s.group)
        }
        NSLog("[lulu] compose: %ld stickers (%@), policy %@%@", choices.count, choices.map(\.id).joined(separator: ","),
              policy.mode.rawValue, solo ? ", solo panel" : "")
        let thumbs = Dictionary(choices.compactMap { c in c.thumbnail.map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let labels = Dictionary(choices.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        let model = solo ? nil : history.map { HistoryModel(source: $0, thumbnails: thumbs, labels: labels) }
        weatherModel.data = weather
        let sprefs = StickerPrefsModel(store: stickerStore)
        stickerPrefs = sprefs
        let view = ComposeView(
            weather: weatherModel,
            partnerName: partnerName,
            solo: solo,
            statusNote: statusNote,
            focusNote: partnerFocusNote,
            partnerApp: partnerApp,
            stickers: choices,
            prefs: sprefs,
            history: model,
            tools: tools,
            initialTab: (tab == .history && model == nil) || (tab == .tools && tools == nil) ? .compose : tab,
            onTabChanged: { [weak self] tab in
                if tab == .history { self?.onHistorySeen?() }
                DispatchQueue.main.async { self?.refit() }
            },
            onSendText: { [weak self] text in self?.onSendText?(text); self?.dismiss() },
            onSendSticker: { [weak self] id in self?.onSendSticker?(id); self?.dismiss() },
            onSendHeart: { [weak self] in self?.onSendHeart?(); self?.dismiss() },
            onGoVisit: { [weak self] in self?.dismiss(); self?.onGoVisit?() },
            onPeek: { [weak self] in self?.dismiss(); self?.onPeek?() },
            onSendRemind: { [weak self] kind in self?.onSendRemind?(kind); self?.dismiss() },
            onOpenSettings: { [weak self] in self?.dismiss(); self?.onOpenSettings?() },
            onOpenToolsSettings: { [weak self] in self?.dismiss(); self?.onOpenToolsSettings?() },
            onClose: { [weak self] in self?.dismiss() }
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
        setContentSize(host.fittingSize)
        if tab == .history, model != nil { DispatchQueue.main.async { [weak self] in self?.onHistorySeen?() } }
    }

    /// After a tab switch: new size, same top edge, still on screen.
    private func refit() {
        guard let content = contentView else { return }
        let size = content.fittingSize
        guard size != frame.size else { return }
        let top = frame.maxY
        let vf = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: frame.minX, y: top - size.height)
        origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size.height - 4)
        setFrame(NSRect(origin: origin, size: size), display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc (routed through the field editor / responder chain).
    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func resignKey() {
        super.resignKey()
        dismiss()
    }

    /// Shows the panel beside `petFrame` (left if there is room, otherwise right).
    func present(beside petFrame: NSRect) {
        setContentSize(contentView?.fittingSize ?? frame.size)
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = petFrame.minY + 10
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        // Flip to the right when the left side is off screen or would cover another pet.
        let left = NSPoint(x: petFrame.minX - size.width - 4, y: y), right = NSPoint(x: petFrame.maxX + 4, y: y)
        setFrameOrigin(PetNeighbors.bestOrigin([left, right], size: size, in: vf))

        NSApp.activate()
        makeKeyAndOrderFront(nil)
        if outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    func dismiss() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        orderOut(nil)
        isDismissing = false
    }

    static func firstFrame(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

private struct ComposeView: View {
    @ObservedObject var weather: WeatherCardModel
    /// With `solo` this is the pet's own name: the panel is just a sticker grid for it to act out.
    let partnerName: String
    let solo: Bool
    let statusNote: String?
    let focusNote: String?
    /// v0.11.2: the partner's app version when known (shown tiny next to mine).
    let partnerApp: String?
    let stickers: [ComposeWindow.StickerChoice]
    @ObservedObject var prefs: ComposeWindow.StickerPrefsModel
    let history: HistoryModel?
    let tools: ToolsPanelModel?
    let initialTab: ComposeWindow.Tab
    let onTabChanged: (ComposeWindow.Tab) -> Void
    let onSendText: (String) -> Void
    let onSendSticker: (String) -> Void
    let onSendHeart: () -> Void
    let onGoVisit: () -> Void
    let onPeek: () -> Void
    let onSendRemind: (ReminderKind) -> Void
    let onOpenSettings: () -> Void
    let onOpenToolsSettings: () -> Void
    let onClose: () -> Void

    @State private var text = ""
    @State private var tab: ComposeWindow.Tab?
    @FocusState private var focused: Bool

    private var currentTab: ComposeWindow.Tab { tab ?? initialTab }

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(currentTab == .tools ? "🍅 小工具" : solo ? "让\(partnerName)演一个" : currentTab == .compose ? "给\(partnerName)传话" : "和\(partnerName)的记录")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Self.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .layoutPriority(-1)
                Spacer(minLength: 4)
                if history != nil || tools != nil { tabPicker }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭（Esc）")
            }
            .padding(.bottom, statusNote == nil || currentTab == .history ? 0 : -6)

            if currentTab == .history, let history {
                HistoryPane(model: history, partnerName: partnerName)
            } else if currentTab == .tools, let tools {
                ToolsTabView(model: tools, onOpenSettings: onOpenToolsSettings)
            } else {
                composeBody
            }

            HStack {
                Spacer()
                Text(Self.versionLabel + (partnerApp.map { " · TA v\($0)" } ?? ""))
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .help("当前版本")
            }
            .padding(.top, -6)
        }
        .padding(14)
        .frame(width: 296)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Self.cream)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Self.accent.opacity(0.2), lineWidth: 1))
        .padding(14)
        .environment(\.colorScheme, .light)
        .onAppear { if currentTab == .compose { focused = true } }
        .onExitCommand(perform: onClose)
    }

    /// "v0.11.0 (123)" from the app bundle; "开发版" when run outside a bundle (swift run).
    static let versionLabel: String = {
        let info = Bundle.main.infoDictionary
        if let fake = AppVersionSource.override { return "v\(fake)" }   // --fake-app-version (testing)
        guard let v = info?["CFBundleShortVersionString"] as? String else { return "开发版" }
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return "v\(v)\(build)"
    }()

    /// 「传话 | 记录 | 小工具」 (solo: 「表情 | 小工具」); a tab only exists when its content does.
    private var tabs: [(ComposeWindow.Tab, String)] {
        [(ComposeWindow.Tab.compose, solo ? "表情" : "传话")]
            + (history != nil ? [(ComposeWindow.Tab.history, "记录")] : [])
            + (tools != nil ? [(ComposeWindow.Tab.tools, "小工具")] : [])
    }

    /// Small tab pill switch.
    private var tabPicker: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.0) { t, title in
                Button {
                    guard currentTab != t else { return }
                    tab = t
                    onTabChanged(t)
                    if t == .compose { focused = true }
                } label: {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()   // never wrap 「记录」/「小工具」 into a vertical column when the title is long
                        .foregroundStyle(currentTab == t ? Color.white : Self.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(currentTab == t ? Self.accent : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(t == .compose ? (solo ? "表情" : "传话") : t == .history ? "聊天记录" : "番茄钟、喝水和站立提醒")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white).padding(1).background(Capsule().fill(Self.accent.opacity(0.3))))
    }

    @ViewBuilder
    private var composeBody: some View {
        weatherLine
        if solo {
            if !stickers.isEmpty { stickerGrid }
        } else {
            fullComposeBody
        }
    }

    /// v0.13.3 weather rows (TA first, then me), re-evaluated every minute while the panel is open.
    private var weatherLine: some View {
        VStack(alignment: .trailing, spacing: 4) {
            WeatherCardView(model: weather, onOpenSettings: onOpenSettings)
            if !solo { peekButton }
        }
    }

    /// v0.14.3: 「👀 偷看」: see what TA is up to right now (nothing is sent to TA).
    private var peekButton: some View {
        Button(action: onPeek) {
            Text("👀 偷看")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.accent)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Self.accent.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("马上看看 TA 这会儿在干嘛（TA 不会知道哦）")
    }

    @ViewBuilder
    private var fullComposeBody: some View {

            if let statusNote {
                Text(statusNote)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Self.accent.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let focusNote {
                Text(focusNote)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                quickButton("❤️ 发送爱心", filled: true, help: "给TA发一颗爱心", action: onSendHeart)
                quickButton("去找TA 🏃", filled: false, help: "跑去TA的桌面串门（TA不在线时会跑回来）", action: onGoVisit)
            }

            HStack(spacing: 8) {
                quickButton("💧 叫 TA 喝水", filled: false, help: "让 TA 的宠物跑过去叫 TA 喝水") { onSendRemind(.water) }
                quickButton("🧍 叫 TA 起来动动", filled: false, help: "让 TA 的宠物跑过去叫 TA 起来动动") { onSendRemind(.stand) }
            }

            HStack(spacing: 6) {
                TextField("想对TA说点什么…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .focused($focused)
                    .onSubmit(send)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Self.accent.opacity(0.35), lineWidth: 1))
                    .onChange(of: text) { _, new in
                        if new.count > Message.maxTextLength { text = String(new.prefix(Message.maxTextLength)) }
                    }
                Button(action: send) {
                    Text("发送")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(trimmed.isEmpty ? Self.accent.opacity(0.4) : Self.accent))
                }
                .buttonStyle(.plain)
                .disabled(trimmed.isEmpty)
            }

            if !stickers.isEmpty {
                stickerGrid
            }
    }

    /// v0.3: compact 4-column grid; more than `visibleRows` rows scroll inside a fixed-height area.
    private static let columns = 4
    private static let visibleRows = 3
    private static let cellHeight: CGFloat = 66
    private static let gridSpacing: CGFloat = 6

    /// v0.15: 「常用」 grid, then a「更多表情…」 row that opens the whole library by emotion (remembered while the app runs).

    private var stickerGrid: some View {
        let visibleIDs = stickers.map(\.id)
        let favIDs = StickerPanel.favorites(pinned: prefs.pinned, recent: prefs.recent, visible: visibleIDs)
        let byID = Dictionary(stickers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let favs = favIDs.compactMap { byID[$0] }
        let hasMore = stickers.count > favs.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("常用")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.accent.opacity(0.85))
                Spacer(minLength: 0)
                if let toast = prefs.toast {
                    Text(toast)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(Self.accent)
                        .transition(.opacity)
                }
            }
            if favs.isEmpty {
                Text("还没有常用表情：右键（或长按）表情，选「加入常用」")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                gridBlock(favs, visibleRows: prefs.moreExpanded && hasMore ? 2 : Self.visibleRows, favIDs: Set(favIDs))
            }
            if hasMore {
                moreToggle
                if prefs.moreExpanded { moreSection(favIDs: Set(favIDs), canAdd: favIDs.count < StickerPanel.maxFavorites) }
            }
        }
        .animation(.easeOut(duration: 0.15), value: prefs.toast)
    }

    /// 「更多表情」 sections (StickerGroup order; anything without a known group last, as 「其他」).
    private var sections: [(title: String, items: [ComposeWindow.StickerChoice])] {
        var out: [(title: String, items: [ComposeWindow.StickerChoice])] = []
        for g in StickerGroup.allCases {
            let items = stickers.filter { $0.group == g.rawValue }
            if !items.isEmpty { out.append((g.title, items)) }
        }
        let rest = stickers.filter { $0.group.flatMap(StickerGroup.init(rawValue:)) == nil }
        if !rest.isEmpty { out.append(("其他", rest)) }
        return out
    }

    private func toggleFavorite(_ id: String) {
        prefs.toggle(id, visible: stickers.map(\.id))
        DispatchQueue.main.async { onTabChanged(.compose) }   // 常用 may have gained / lost a row: refit the panel
    }

    private var moreToggle: some View {
        Button {
            prefs.moreExpanded.toggle()
            DispatchQueue.main.async { onTabChanged(.compose) }   // refit the panel to the new height
        } label: {
            HStack(spacing: 4) {
                Text(prefs.moreExpanded ? "收起更多表情" : "更多表情…")
                Image(systemName: prefs.moreExpanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 10).fill(Self.accent.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("全部表情，按心情分组")
    }

    /// The whole library by emotion inside one scroll area (a ★ marks what is already in 常用).
    private func moreSection(favIDs: Set<String>, canAdd: Bool) -> some View {
        let height = 2.4 * Self.cellHeight + 2 * Self.gridSpacing + 24   // two rows + a sliver of the next + a group title
        return ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.45))
                        gridBlock(section.items, visibleRows: nil, favIDs: favIDs, markFavorites: true)
                    }
                }
            }
            .padding(.trailing, 8)   // room for the scroller
        }
        .frame(height: height)
    }

    /// A 4-column grid of cells; `visibleRows` (nil = all) more rows scroll inside a fixed-height area.
    @ViewBuilder
    private func gridBlock(_ items: [ComposeWindow.StickerChoice], visibleRows: Int?, favIDs: Set<String>, markFavorites: Bool = false) -> some View {
        let rows = (items.count + Self.columns - 1) / Self.columns
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gridSpacing), count: Self.columns),
                             spacing: Self.gridSpacing) {
            ForEach(items) { s in cell(s, isFavorite: favIDs.contains(s.id), mark: markFavorites, canAdd: favIDs.count < StickerPanel.maxFavorites) }
        }
        if let visibleRows, rows > visibleRows {
            // When scrolling, a sliver of the next row peeks out so it's obvious there are more.
            let shown = CGFloat(visibleRows) + 0.4
            ScrollView(.vertical, showsIndicators: true) {
                grid.padding(.trailing, 8)   // room for the scroller
            }
            .frame(height: shown * Self.cellHeight + CGFloat(visibleRows) * Self.gridSpacing)
        } else {
            grid
        }
    }

    /// One sticker. Tap = send (solo: act it out); right-click or long-press = 加入 / 移出常用.
    private func cell(_ s: ComposeWindow.StickerChoice, isFavorite: Bool, mark: Bool, canAdd: Bool) -> some View {
        VStack(spacing: 2) {
            Group {
                if let img = s.thumbnail {
                    // Wide strips (e.g. 冷战, two pets far apart) are letterboxed instead of cropped to an empty middle.
                    Image(nsImage: img).resizable().aspectRatio(contentMode: s.isWide ? .fit : .fill)
                } else {
                    Color.gray.opacity(0.15)
                }
            }
            .frame(width: 50, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if mark && isFavorite {
                    Text("★").font(.system(size: 9)).foregroundStyle(Self.accent).padding(1)
                }
            }
            Text(s.label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.3))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: Self.cellHeight, maxHeight: Self.cellHeight)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.85)))
        .contentShape(Rectangle())
        .onTapGesture { prefs.use(s.id); onSendSticker(s.id) }
        .onLongPressGesture(minimumDuration: 0.6) { toggleFavorite(s.id) }
        .contextMenu {
            if isFavorite {
                Button("移出常用") { toggleFavorite(s.id) }
            } else if canAdd {
                Button("加入常用") { toggleFavorite(s.id) }
            } else {
                Button("常用已满（最多 \(StickerPanel.maxFavorites) 个）") {}.disabled(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(s.label)
        .accessibilityAddTraits(.isButton)
        .help((solo ? "让它演「\(s.label)」" : "发送「\(s.label)」") + "（右键：加入 / 移出常用）")
    }

    private func quickButton(_ title: String, filled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? Color.white : Self.accent)
                .lineLimit(1)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(filled ? Self.accent : Color.white)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.accent.opacity(filled ? 0 : 0.6), lineWidth: 1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help(help)
    }

    private func send() {
        guard !trimmed.isEmpty else { return }
        onSendText(trimmed)
        text = ""
    }
}
