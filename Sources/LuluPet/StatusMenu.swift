import AppKit
import LuluCore
import LuluSync

/// Menu-bar "🍊" item. The same menu is shown when right-clicking the pet.
final class StatusMenu: NSObject, NSMenuDelegate {
    /// The menu was opened (menu bar or right click on a pet): user activity.
    var onOpen: (() -> Void)?
    var onChangeOutfit: (() -> Void)?
    /// v0.8 换回上一个 / 选择造型.
    var onOutfitBack: (() -> Void)?
    var onChooseOutfit: ((String) -> Void)?
    var onSettings: (() -> Void)?
    /// v0.13: 「更新日志…」 / 「待设置（N）」.
    var onWhatsNew: (() -> Void)?
    var onSetupTodos: (() -> Void)?
    var onCheckUpdate: (() -> Void)?   // v0.14 检查更新…
    var onUpdateTapped: (() -> Void)?  // v0.14 「有新版本 vX」
    var onPingUpgrade: (() -> Void)?   // v0.15.5 「TA 还在用 vX」 line → 叫 TA 升级
    /// v0.12: 「天气小组件」 toggled (the new state).
    var onTogglePin: (() -> Void)?
    var onGoVisit: (() -> Void)?
    /// v0.14.3 「偷看 TA 👀」.
    var onPeek: (() -> Void)?
    /// v0.4
    var onCompose: (() -> Void)?
    var onHide: ((HideOption) -> Void)?
    var onShow: (() -> Void)?
    /// v0.5 声音 submenu.
    var onSoundEnabled: ((Bool) -> Void)?
    var onSoundVolume: ((Float) -> Void)?
    var onBGM: ((Bool) -> Void)?
    /// v0.7 大小 submenu: a preset or 恢复默认大小 (1.0).
    var onScale: ((Double) -> Void)?
    /// v0.8 勿扰模式 submenu.
    var onDNDMood: ((DNDMood) -> Void)?
    var onDNDStart: ((DNDDuration) -> Void)?
    var onDNDOff: (() -> Void)?
    /// v0.10 小工具: 🍅 番茄钟 / 提醒 submenus.
    enum PomodoroAction { case start, pauseResume, skipBreak, stop }
    var onPomodoro: ((PomodoroAction) -> Void)?
    var onReminder: ((ReminderKind, Bool) -> Void)?
    /// The menu is about to open: refresh the tools rows (remaining time, today's cups).
    var onToolsOpen: (() -> Void)?
    /// 「这是什么？」 in the 番茄钟 / 提醒 submenus: opens the compose panel's 小工具 tab.
    var onToolsHelp: (() -> Void)?

    let menu = NSMenu()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "未设置", action: nil, keyEquivalent: "")
    private let outfitItem = NSMenuItem(title: "换个造型", action: #selector(changeOutfit), keyEquivalent: "")
    private let pinItem = NSMenuItem(title: "固定这套造型", action: #selector(togglePin), keyEquivalent: "")
    private let outfitBackItem = NSMenuItem(title: "换回上一个", action: #selector(outfitBack), keyEquivalent: "")
    let chooseOutfitItem = NSMenuItem(title: "选择造型", action: nil, keyEquivalent: "")
    private let goVisitItem = NSMenuItem(title: "去找TA 🏃", action: #selector(goVisit), keyEquivalent: "")
    private let peekItem = NSMenuItem(title: "偷看 TA 👀", action: #selector(peek), keyEquivalent: "")
    private let composeItem = NSMenuItem(title: "传话…", action: #selector(compose), keyEquivalent: "")
    private let hideItem = NSMenuItem(title: "隐藏", action: nil, keyEquivalent: "")
    private let showItem = NSMenuItem(title: "显示", action: #selector(show), keyEquivalent: "")
    private var hideOptionItems: [HideOption: NSMenuItem] = [:]
    let soundItem = NSMenuItem(title: "声音", action: nil, keyEquivalent: "")
    private let soundOnItem = NSMenuItem(title: "开", action: #selector(soundOn), keyEquivalent: "")
    private let soundOffItem = NSMenuItem(title: "关", action: #selector(soundOff), keyEquivalent: "")
    private var volumeItems: [NSMenuItem] = []
    private let bgmItem = NSMenuItem(title: "背景音乐", action: #selector(toggleBGM), keyEquivalent: "")
    let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
    private var sizeItems: [NSMenuItem] = []
    private let sizeResetItem = NSMenuItem(title: "恢复默认大小", action: #selector(resetScale), keyEquivalent: "")
    private var unseen = 0
    // v0.8 勿扰模式
    let dndItem = NSMenuItem(title: "勿扰模式", action: nil, keyEquivalent: "")
    private let dndLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    /// v0.11.2: "有新版本 v0.12.0（TA 已升级）" / "TA 还在用 v0.11.1" under the status line; hidden when nothing to say.
    private let versionLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let dndOffItem = NSMenuItem(title: "关闭勿扰", action: #selector(dndOff), keyEquivalent: "")
    private let dndOffSeparator = NSMenuItem.separator()
    private var dndMoodItems: [DNDMood: NSMenuItem] = [:]
    private var dndDurationItems: [NSMenuItem] = []
    private var dndOn = false
    private var partnerDND: DNDStatus?
    /// v0.10: the partner's pomodoro focus (status line "噜妹正在专注 🍅 还剩 N 分钟", only while they are online).
    private var partnerFocus: FocusStatus?
    private var partnerFocusName = "TA"
    // v0.10 小工具
    let pomodoroItem = NSMenuItem(title: "番茄钟", action: nil, keyEquivalent: "")
    private let pomodoroLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pomodoroStartItem = NSMenuItem(title: "开始专注", action: #selector(pomodoroStart), keyEquivalent: "")
    private let pomodoroPauseItem = NSMenuItem(title: "暂停", action: #selector(pomodoroPause), keyEquivalent: "")
    private let pomodoroSkipItem = NSMenuItem(title: "跳过休息", action: #selector(pomodoroSkip), keyEquivalent: "")
    private let pomodoroStopItem = NSMenuItem(title: "结束", action: #selector(pomodoroStop), keyEquivalent: "")
    let remindItem = NSMenuItem(title: "提醒", action: nil, keyEquivalent: "")
    private let waterItem = NSMenuItem(title: "喝水提醒 💧", action: #selector(toggleWater), keyEquivalent: "")
    private let standItem = NSMenuItem(title: "站立提醒 🧍", action: #selector(toggleStand), keyEquivalent: "")
    private let pomodoroHintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let remindHintLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pomodoroHelpItem = NSMenuItem(title: "这是什么？", action: #selector(toolsHelp), keyEquivalent: "")
    private let remindHelpItem = NSMenuItem(title: "这是什么？", action: #selector(toolsHelp), keyEquivalent: "")
    private let cupsItem = NSMenuItem(title: "今天喝了 0 杯", action: nil, keyEquivalent: "")
    /// Its key equivalent only shows the global ⌃⌥Q (v0.6.5: no ⌘Q).
    // v0.13 更新日志… + 待设置（N） (only while N > 0)
    private let setupTodosItem = NSMenuItem(title: "待设置", action: #selector(openSetupTodos), keyEquivalent: "")
    private let checkUpdateItem = NSMenuItem(title: "检查更新…", action: #selector(checkUpdate), keyEquivalent: "")
    private let updateLine = NSMenuItem(title: "", action: #selector(updateTapped), keyEquivalent: "")
    private let whatsNewItem = NSMenuItem(title: "更新日志…", action: #selector(openWhatsNew), keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")

    private var connection: PairChannel.ConnectionState?
    private var partnerOnline: Bool?
    /// v0.11 一个人: no connection / partner status line, no 去找TA, 传话 becomes 表情.
    private var solo = false
    private let topSeparator = NSMenuItem.separator()

    override init() {
        super.init()
        if Offscreen.enabled { statusItem.isVisible = false }   // test instance: no 🍊 in the menu bar
        statusItem.button?.title = "🍊"
        statusItem.button?.toolTip = "噜噜桌宠"
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        dndLine.isEnabled = false
        dndLine.isHidden = true
        menu.addItem(dndLine)
        versionLine.isEnabled = false
        versionLine.isHidden = true
        menu.addItem(versionLine)
        menu.addItem(topSeparator)
        showItem.target = self
        showItem.isHidden = true
        menu.addItem(showItem)
        composeItem.target = self
        menu.addItem(composeItem)
        goVisitItem.target = self
        goVisitItem.isEnabled = false
        menu.addItem(goVisitItem)
        peekItem.target = self
        peekItem.isEnabled = false
        menu.addItem(peekItem)
        menu.addItem(.separator())
        let hideMenu = NSMenu()
        hideMenu.autoenablesItems = false
        for option in HideOption.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(hide(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.image = NSImage(systemSymbolName: option == .untilReopened ? "moon.zzz" : "timer", accessibilityDescription: nil)
            hideMenu.addItem(item)
            hideOptionItems[option] = item
        }
        hideItem.submenu = hideMenu
        hideItem.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil)
        showItem.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        menu.addItem(hideItem)
        buildDNDMenu()
        menu.addItem(dndItem)
        buildToolsMenus()
        menu.addItem(pomodoroItem)
        menu.addItem(remindItem)
        let soundMenu = NSMenu()
        soundMenu.autoenablesItems = false
        for item in [soundOnItem, soundOffItem] {
            item.target = self
            soundMenu.addItem(item)
        }
        soundMenu.addItem(.separator())
        let volumeHeader = NSMenuItem(title: "音量", action: nil, keyEquivalent: "")
        volumeHeader.isEnabled = false
        soundMenu.addItem(volumeHeader)
        for (i, preset) in SoundDefaults.presets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(volume(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.indentationLevel = 1
            soundMenu.addItem(item)
            volumeItems.append(item)
        }
        soundMenu.addItem(.separator())
        bgmItem.target = self
        soundMenu.addItem(bgmItem)
        soundItem.submenu = soundMenu
        soundItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        menu.addItem(soundItem)
        let sizeMenu = NSMenu()
        sizeMenu.autoenablesItems = false
        for (i, preset) in PetScale.presets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(scalePreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            sizeMenu.addItem(item)
            sizeItems.append(item)
        }
        sizeMenu.addItem(.separator())
        sizeResetItem.target = self
        sizeMenu.addItem(sizeResetItem)
        let hint = NSMenuItem(title: "也可以拖桌宠右下角的小圆点", action: nil, keyEquivalent: "")   // the name is filled in by `setScale`
        hint.isEnabled = false
        sizeMenu.addItem(hint)
        sizeItem.submenu = sizeMenu
        sizeItem.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        menu.addItem(sizeItem)
        outfitItem.target = self
        menu.addItem(outfitItem)
        outfitBackItem.target = self
        outfitBackItem.isEnabled = false
        menu.addItem(outfitBackItem)
        chooseOutfitItem.submenu = NSMenu()
        chooseOutfitItem.submenu?.autoenablesItems = false
        chooseOutfitItem.image = NSImage(systemSymbolName: "tshirt", accessibilityDescription: nil)
        menu.addItem(chooseOutfitItem)
        pinItem.target = self
        menu.addItem(pinItem)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        setupTodosItem.target = self
        setupTodosItem.isHidden = true
        menu.addItem(setupTodosItem)
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)
        updateLine.target = self
        updateLine.isHidden = true
        updateLine.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        menu.addItem(updateLine)
        checkUpdateItem.target = self
        menu.addItem(checkUpdateItem)
        menu.addItem(.separator())
        quitItem.target = NSApp
        menu.addItem(quitItem)
        statusItem.menu = menu
        render()
    }

    private func buildToolsMenus() {
        let p = NSMenu()
        p.autoenablesItems = false
        pomodoroLine.isEnabled = false
        p.addItem(pomodoroLine)
        p.addItem(.separator())
        for item in [pomodoroStartItem, pomodoroPauseItem, pomodoroSkipItem, pomodoroStopItem] {
            item.target = self
            p.addItem(item)
        }
        p.addItem(.separator())
        pomodoroHintLine.attributedTitle = Self.smallNote(ToolsCopy.pomodoroHint)
        pomodoroHintLine.isEnabled = false
        p.addItem(pomodoroHintLine)
        pomodoroHelpItem.target = self
        p.addItem(pomodoroHelpItem)
        pomodoroItem.submenu = p
        pomodoroItem.toolTip = ToolsCopy.pomodoroHint
        pomodoroItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let r = NSMenu()
        r.autoenablesItems = false
        for item in [waterItem, standItem] {
            item.target = self
            r.addItem(item)
        }
        r.addItem(.separator())
        cupsItem.isEnabled = false
        r.addItem(cupsItem)
        r.addItem(.separator())
        remindHintLine.attributedTitle = Self.smallNote("开着后，你累计用电脑满间隔，宠物就来提醒；离开 5 分钟以上重新计时")
        remindHintLine.isEnabled = false
        r.addItem(remindHintLine)
        remindHelpItem.target = self
        r.addItem(remindHelpItem)
        remindItem.submenu = r
        remindItem.toolTip = "喝水 / 站立提醒：只算你在用电脑的时间"
        setReminders(water: false, stand: false, cups: 0, waterInterval: 3600, standInterval: 2700)
        remindItem.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: nil)
        setPomodoro(.idle, now: Date().timeIntervalSince1970)
    }

    /// v0.10: the 🍅 番茄钟 rows for `state` (status line, which actions make sense).
    func setPomodoro(_ state: PomodoroState, now: TimeInterval) {
        let left = state.remaining(now: now).map { max(1, Int(($0 / 60).rounded(.up))) }
        let phase: String
        switch state.phase {
        case .idle: phase = "没有在计时"
        case .focus: phase = "专注中"
        case .shortBreak, .longBreak: phase = "休息中"
        }
        pomodoroLine.title = state.phase == .idle ? phase
            : "\(phase)\(state.isPaused ? "（已暂停）" : "")，还剩 \(left ?? 0) 分钟 · 第 \(state.completedFocus + (state.phase == .focus ? 1 : 0)) 个"
        pomodoroStartItem.title = state.phase == .focus ? "重新开始专注" : "开始专注"
        pomodoroPauseItem.title = state.isPaused ? "继续" : "暂停"
        pomodoroPauseItem.isEnabled = state.phase != .idle
        pomodoroSkipItem.isEnabled = state.phase == .shortBreak || state.phase == .longBreak
        pomodoroStopItem.isEnabled = state.phase != .idle
        pomodoroItem.title = state.phase == .idle ? "番茄钟" : "番茄钟（\(phase)）"
    }

    /// v0.10: 提醒 submenu: the two switches and today's cups.
    func setReminders(water: Bool, stand: Bool, cups: Int, waterInterval: TimeInterval, standInterval: TimeInterval) {
        waterItem.state = water ? .on : .off
        standItem.state = stand ? .on : .off
        waterItem.title = ToolsCopy.menuTitle(.water, interval: waterInterval)
        standItem.title = ToolsCopy.menuTitle(.stand, interval: standInterval)
        waterItem.toolTip = ToolsCopy.explanation(.water, interval: waterInterval)
        standItem.toolTip = ToolsCopy.explanation(.stand, interval: standInterval)
        cupsItem.title = "今天喝了 \(cups) 杯"
    }

    /// Small grey explanation line (disabled menu row).
    private static func smallNote(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }

    /// For logs / snapshots: both 小工具 submenus.
    var toolsMenuDescription: String {
        func lines(_ m: NSMenu?) -> String {
            (m?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title + ($0.state == .on ? " ✓" : "") + ($0.isEnabled ? "" : " (off)") }.joined(separator: " | ")
        }
        return "\(pomodoroItem.title): \(lines(pomodoroItem.submenu)); \(remindItem.title): \(lines(remindItem.submenu))"
    }

    private func buildDNDMenu() {
        let m = NSMenu()
        m.autoenablesItems = false
        dndOffItem.target = self
        dndOffItem.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        m.addItem(dndOffItem)
        m.addItem(dndOffSeparator)
        let moodHeader = NSMenuItem(title: "心情", action: nil, keyEquivalent: "")
        moodHeader.isEnabled = false
        m.addItem(moodHeader)
        for mood in DNDMood.allCases {
            let item = NSMenuItem(title: mood.title, action: #selector(dndMood(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mood.rawValue
            item.indentationLevel = 1
            m.addItem(item)
            dndMoodItems[mood] = item
        }
        m.addItem(.separator())
        let startHeader = NSMenuItem(title: "开启", action: nil, keyEquivalent: "")
        startHeader.isEnabled = false
        m.addItem(startHeader)
        for d in DNDDuration.allCases {
            let item = NSMenuItem(title: d.title, action: #selector(dndStart(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.rawValue
            item.indentationLevel = 1
            m.addItem(item)
            dndDurationItems.append(item)
        }
        dndItem.submenu = m
        setDND(DNDState())
    }

    /// v0.8: my 勿扰 (menu + status line). While on: top item "关闭勿扰（HH:mm 结束 / 手动关闭）".
    func setDND(_ state: DNDState, now: Double = Date().timeIntervalSince1970) {
        dndOn = state.isOn(now: now)
        for (mood, item) in dndMoodItems { item.state = mood == state.mood ? .on : .off }
        dndOffItem.isHidden = !dndOn
        dndOffSeparator.isHidden = !dndOn
        dndOffItem.title = state.offTitle()
        dndLine.isHidden = !dndOn
        dndLine.title = state.statusLine()
        dndItem.state = dndOn ? .on : .off
        dndItem.title = dndOn ? "勿扰模式（开）" : "勿扰模式"
        dndItem.image = NSImage(systemSymbolName: dndOn ? "moon.fill" : "moon", accessibilityDescription: nil)
        render()
    }

    /// v0.8: the partner's 勿扰 (status line "TA 勿扰中（😤 生气中）"), nil = off.
    func setPartnerDND(_ d: DNDStatus?) {
        partnerDND = d
        render()
    }

    /// v0.11.2: the upgrade line (nil / empty = hidden).
    /// `pingable` (v0.15.5): the 「TA 还在用 vX」 line is clickable and sends 「叫 TA 升级」.
    func setVersionLine(_ text: String?, pingable: Bool = false) {
        versionLine.title = text ?? ""
        versionLine.isHidden = text == nil
        versionLine.isEnabled = pingable
        versionLine.target = pingable ? self : nil
        versionLine.action = pingable ? #selector(pingUpgrade) : nil
    }

    var versionLineTitle: String? { versionLine.isHidden ? nil : versionLine.title }

    /// v0.10: the partner's pomodoro focus, nil = none.
    /// v0.12.1: a seat clash stays visible in the status line until it is resolved (the notice can be clicked away).
    private var seatClash = false
    func setSeatClash(_ on: Bool) {
        seatClash = on
        render()
    }

    func setPartnerFocus(_ f: FocusStatus?, name: String) {
        partnerFocus = f
        partnerFocusName = name
        render()
    }

    /// For logs / snapshots: every line of the 勿扰模式 submenu.
    var dndMenuDescription: String {
        (dndItem.submenu?.items ?? []).filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title + ($0.state == .on ? " ✓" : "") }.joined(separator: " | ")
    }

    var statusLineTitle: String { statusLine.title + (dndLine.isHidden ? "" : " / " + dndLine.title) + (versionLine.isHidden ? "" : " / " + versionLine.title) }

    func setConnection(_ state: PairChannel.ConnectionState?) {
        connection = state
        // Offline / misconfigured still runs to the edge and back (nothing is sent); only a missing
        // config disables it.
        goVisitItem.isEnabled = state != nil
        peekItem.isEnabled = state != nil
        render()
    }

    /// v0.11: 一个人 hides everything about the partner (connection / partner status, 去找TA) and calls the
    /// compose entry 表情….
    func setSolo(_ on: Bool) {
        solo = on
        statusLine.isHidden = on
        topSeparator.isHidden = on   // (the 勿扰 line, when on, sits at the very top)
        goVisitItem.isHidden = on
        peekItem.isHidden = on
        composeItem.title = on ? "表情…" : "传话…"
        render()
    }

    /// For logs / snapshots: the visible top-level rows.
    var visibleItemTitles: [String] { menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title) }

    private var partnerNeverSeen = false
    func setPartnerNeverSeen(_ never: Bool) {
        guard never != partnerNeverSeen else { return }
        partnerNeverSeen = never
        render()
    }

    func setPartnerOnline(_ online: Bool?) {
        partnerOnline = online
        render()
    }

    /// Shows the shortcuts at the right edge of the menu items (display only: the global hotkeys do the work).
    func setShortcuts(_ s: ShortcutSet) {
        for item in [showItem, hideOptionItems[.untilReopened]!] { Self.apply(s.toggle, to: item) }
        Self.apply(s.compose, to: composeItem)
        Self.apply(s.quit, to: quitItem)   // v0.7 ⌃⌥Q (display only, like the others)
    }

    private static func apply(_ s: Shortcut, to item: NSMenuItem) {
        if let key = s.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = HotkeyCenter.flags(s.modifiers)
        } else {
            item.keyEquivalent = ""
        }
        item.toolTip = "快捷键 \(s.display)"
    }

    /// Hidden: "显示噜噜" replaces the 隐藏 submenu; `until` = when a timed hide ends.
    func setHidden(_ hidden: Bool, petName: String, until: Date?) {
        hideItem.isHidden = hidden
        showItem.isHidden = !hidden
        var title = "显示\(petName)"
        if let until {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            title += "（\(f.string(from: until)) 自动出现）"
        }
        showItem.title = title
    }

    /// v0.5: checkmarks of the 声音 submenu.
    func setSound(enabled: Bool, volume: Float, bgm: Bool) {
        soundOnItem.state = enabled ? .on : .off
        soundOffItem.state = enabled ? .off : .on
        let selected = SoundDefaults.presetIndex(for: volume)
        for (i, item) in volumeItems.enumerated() {
            item.state = i == selected ? .on : .off
            item.isEnabled = enabled
        }
        bgmItem.state = bgm ? .on : .off
        bgmItem.isEnabled = enabled
        soundItem.image = NSImage(systemSymbolName: enabled ? "speaker.wave.2" : "speaker.slash", accessibilityDescription: nil)
    }

    /// v0.7: checkmark on the preset `scale` is exactly (none after a free drag to another size);
    /// 恢复默认大小 is disabled at 1.0. `petName` fills the drag hint.
    func setScale(_ scale: Double, petName: String) {
        let selected = PetScale.presetIndex(for: scale)
        for (i, item) in sizeItems.enumerated() { item.state = i == selected ? .on : .off }
        sizeResetItem.isEnabled = abs(scale - PetScale.standard) > 0.001
        sizeItem.submenu?.items.last?.title = "也可以拖\(petName)右下角的小圆点"
        sizeItem.title = selected == nil ? String(format: "大小（%.0f%%）", scale * 100) : "大小"
    }

    /// For logs: "大小 [小 ✓, 标准, 大] reset enabled".
    var sizeMenuDescription: String {
        "\(sizeItem.title) [" + sizeItems.map { $0.title + ($0.state == .on ? " ✓" : "") }.joined(separator: ", ")
            + "] 恢复默认大小 \(sizeResetItem.isEnabled ? "enabled" : "disabled")"
    }

    /// Partner messages that arrived while hidden: "🍊3" in the menu bar.
    func setUnseen(_ n: Int) {
        unseen = n
        render()
    }

    /// For logs / snapshots.
    var statusTitle: String { statusItem.button?.title ?? "" }

    func setOutfitChangeEnabled(_ enabled: Bool) {
        outfitItem.isEnabled = enabled
        pinItem.isEnabled = enabled
    }

    /// v0.8: 换回上一个 enabled or not, and the 选择造型 rows (current one checked).
    func setOutfitChoices(_ choices: [OutfitChoice], canGoBack: Bool) {
        outfitBackItem.isEnabled = canGoBack
        let m = chooseOutfitItem.submenu ?? NSMenu()
        m.removeAllItems()
        for c in choices {
            let item = NSMenuItem(title: c.title, action: #selector(chooseOutfit(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = c.name
            item.state = c.current ? .on : .off
            item.isEnabled = c.enabled
            m.addItem(item)
        }
        chooseOutfitItem.isEnabled = !choices.isEmpty
    }

    /// For logs: "换回上一个 [enabled]; 选择造型: 经典 ✓, 小熊, …".
    var outfitMenuDescription: String {
        "换回上一个 [\(outfitBackItem.isEnabled ? "enabled" : "disabled")]; 选择造型: "
            + (chooseOutfitItem.submenu?.items ?? []).map { $0.title + ($0.state == .on ? " ✓" : "") + ($0.isEnabled ? "" : " (disabled)") }.joined(separator: ", ")
    }

    func setOutfitPinned(_ pinned: Bool) {
        pinItem.state = pinned ? .on : .off
    }

    /// For logs: "固定这套造型 [on]".
    var pinItemDescription: String { "\(pinItem.title) [\(pinItem.state == .on ? "on" : "off")\(pinItem.isEnabled ? "" : ", disabled")]" }

    private func render() {
        let text: String
        switch solo ? nil : connection {
        case nil: text = "未设置"
        case .connecting?: text = "连接中…"
        case .offline?: text = "未连接：网络断开，正在重试"
        case .misconfigured(let reason)?: text = "未连接：\(reason)"
        case .connected? where seatClash:
            text = "⚠️ 配对冲突：两边占了同一边，请一方改成粘贴配对码"
        case .connected?:
            if let d = partnerDND {
                text = DND.partnerStatusLine(d)
                break
            }
            switch partnerOnline {
            case true? where partnerFocus?.isActive(nowMs: nowMs()) == true:
                text = Visits.partnerFocusLine(name: partnerFocusName, focus: partnerFocus!, nowMs: nowMs())
            case true?: text = "对方在线"
            case false?: text = partnerNeverSeen ? "等 TA 配对中…" : "对方离线"
            case nil: text = "已连接"
            }
        }
        statusLine.title = text
        let bad: Bool
        switch connection {
        case .misconfigured?, .offline?: bad = true
        default: bad = false
        }
        statusItem.button?.title = unseen > 0 ? "🍊\(unseen)" : (bad ? "🍊!" : "🍊")
        statusItem.button?.toolTip = unseen > 0 ? (dndOn ? "噜噜桌宠 · 你勿扰的时候TA来找过你 \(unseen) 次" : "噜噜桌宠 · 你不在的时候TA来过 \(unseen) 次") : "噜噜桌宠"
    }

    func menuWillOpen(_ menu: NSMenu) {
        if partnerFocus != nil { render() }   // the minutes left move on while the menu is closed
        if menu === self.menu { onToolsOpen?() }
        onOpen?()
    }

    @objc private func toolsHelp() { onToolsHelp?() }
    @objc private func pomodoroStart() { onPomodoro?(.start) }
    @objc private func pomodoroPause() { onPomodoro?(.pauseResume) }
    @objc private func pomodoroSkip() { onPomodoro?(.skipBreak) }
    @objc private func pomodoroStop() { onPomodoro?(.stop) }
    @objc private func toggleWater() { onReminder?(.water, waterItem.state != .on) }
    @objc private func toggleStand() { onReminder?(.stand, standItem.state != .on) }

    @objc private func changeOutfit() { onChangeOutfit?() }
    @objc private func togglePin() { onTogglePin?() }
    @objc private func outfitBack() { onOutfitBack?() }
    @objc private func chooseOutfit(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { onChooseOutfit?(name) }
    }
    @objc private func goVisit() { onGoVisit?() }
    @objc private func peek() { onPeek?() }
    @objc private func pingUpgrade() { onPingUpgrade?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func openWhatsNew() { onWhatsNew?() }
    @objc private func checkUpdate() { onCheckUpdate?() }
    @objc private func updateTapped() { onUpdateTapped?() }

    /// v0.14: 「有新版本 vX」 (clicking it starts the update); nil = hidden.
    func setUpdateLine(_ text: String?) {
        updateLine.title = text ?? ""
        updateLine.isHidden = text == nil
    }

    var updateLineTitle: String? { updateLine.isHidden ? nil : updateLine.title }
    @objc private func openSetupTodos() { onSetupTodos?() }

    /// v0.13: 「待设置（N）」 is shown only while N > 0 (recomputed whenever the menu opens).
    func setSetupTodoCount(_ n: Int) {
        setupTodosItem.title = "待设置（\(n)）"
        setupTodosItem.isHidden = n <= 0
    }
    var setupTodosDescription: String { setupTodosItem.isHidden ? "(hidden)" : setupTodosItem.title }
    @objc private func compose() { onCompose?() }
    @objc private func show() { onShow?() }
    @objc private func soundOn() { onSoundEnabled?(true) }
    @objc private func soundOff() { onSoundEnabled?(false) }
    @objc private func volume(_ sender: NSMenuItem) {
        if SoundDefaults.presets.indices.contains(sender.tag) { onSoundVolume?(SoundDefaults.presets[sender.tag].volume) }
    }
    @objc private func toggleBGM() { onBGM?(bgmItem.state != .on) }
    @objc private func scalePreset(_ sender: NSMenuItem) {
        if PetScale.presets.indices.contains(sender.tag) { onScale?(PetScale.presets[sender.tag].scale) }
    }
    @objc private func resetScale() { onScale?(PetScale.standard) }
    @objc private func dndOff() { onDNDOff?() }
    @objc private func dndMood(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = DNDMood(rawValue: raw) { onDNDMood?(m) }
    }
    @objc private func dndStart(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let d = DNDDuration(rawValue: raw) { onDNDStart?(d) }
    }
    @objc private func hide(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let option = HideOption(rawValue: raw) { onHide?(option) }
    }
}
