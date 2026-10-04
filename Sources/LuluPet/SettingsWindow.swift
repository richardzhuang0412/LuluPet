import AppKit
import LuluCore
import SwiftUI

/// Onboarding / settings: who am I, shared pair code, Firebase database URL.
/// v0.4: global shortcuts and "全屏时自动隐藏" (these apply immediately, without「保存」).
/// v0.5: 声音 on / off, volume,「试听」and 背景音乐 (also immediate).
final class SettingsWindow: NSWindow {
    var onSave: ((AppConfig) -> Void)?
    private var prefsModel: ShortcutPrefsModel?
    private var draft: PairingDraft?

    /// v0.4 preferences and how to apply them.
    struct Prefs {
        /// v0.7: toggle / compose / quit.
        var shortcuts: ShortcutSet
        var autoHideFullscreen: Bool
        /// Registers the shortcut; returns an error to show (e.g. taken by another app) or nil.
        var setShortcut: (HotkeyCenter.Action, Shortcut) -> String?
        /// Recording started (true: release the global hotkeys) / ended (false: register them again).
        var recording: (Bool) -> Void
        var setAutoHide: (Bool) -> Void
        // v0.6.3: keep the Dock icon
        var showInDock: Bool = false
        var setShowInDock: (Bool) -> Void = { _ in }
        // v0.5 sound
        var soundEnabled: Bool
        var soundVolume: Float
        var bgmEnabled: Bool
        var setSoundEnabled: (Bool) -> Void
        var setSoundVolume: (Float) -> Void
        var setBGM: (Bool) -> Void
        var previewSound: () -> Void
        /// v0.10 小工具 page (applies immediately); nil hides the page.
        var tools: PersonalToolsController.SettingsAccess? = nil
        /// v0.11: the 模式 / 角色 picker changed: re-apply at once (only called with a complete config).
        var applyMode: (AppConfig) -> Void = { _ in }
        /// v0.11 couple: 我的角色 moves the seat; ask before doing it (false = keep the old character).
        var confirmSeatMove: (PetCharacter) -> Bool = { _ in true }
        /// v0.12 「我的城市」 (applies immediately); nil hides the row.
        var city: CityAccess? = nil
    }

    /// Hidden `--demo-settings-tools`: open on the 小工具 page (snapshots).
    nonisolated(unsafe) static var demoToolsPage = false

    /// `warning` (e.g. why the connection failed) is shown as a soft banner at the top.
    init(initial: AppConfig?, defaultRole: Role, warning: String? = nil, prefs: Prefs) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)   // our panels are drawn light (cream / orange); keep them light in Dark Mode
        title = "噜噜桌宠 · 设置"
        let model = ShortcutPrefsModel(prefs)
        prefsModel = model
        isReleasedWhenClosed = false
        setLuluLevel(.normal)   // --offscreen: below the desktop picture, no mouse
        let draft = PairingDraft(initial: initial, defaultRole: defaultRole)
        self.draft = draft
        let view = SettingsView(
            draft: draft,
            warning: warning,
            firstLaunch: initial?.isComplete != true,
            prefs: model,
            tools: prefs.tools.map { ToolsPrefsModel($0) },
            applyMode: prefs.applyMode,
            confirmSeatMove: prefs.confirmSeatMove,
            city: prefs.city,
            onPageChange: { [weak self] in self?.fitToContent() },
            onSave: { [weak self] config in
                self?.onSave?(config)
                self?.close()
            }
        )
        let host = NSHostingView(rootView: view)
        contentView = host
        setContentSize(host.fittingSize)
        center()
    }

    /// v0.10: after switching 通用 / 小工具 resize to the new page, keeping the top-left corner where it is.
    private func fitToContent() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.contentView else { return }
            let top = self.frame.maxY, left = self.frame.minX
            self.setContentSize(host.fittingSize)
            self.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        }
    }

    /// Hidden `--demo-settings-character`: pick 我的角色 as a click on the segmented control would.
    func demoPickCharacter(_ c: PetCharacter) { draft?.character = c }

    /// The 声音 menu changed a setting while this window is open.
    func refreshSound(enabled: Bool, volume: Float, bgm: Bool) {
        prefsModel?.refreshSound(enabled: enabled, volume: volume, bgm: bgm)
    }

    override func close() {
        prefsModel?.cancelRecording()
        super.close()
        DockPresence.shared.release("settings")
    }

    func show() {
        if Offscreen.enabled { orderFront(nil); return }   // test instance: no Dock icon, no focus grab
        DockPresence.shared.acquire("settings")   // Dock icon while Settings is open (also brings us to front)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }
}

private struct SettingsView: View {
    @StateObject var draft: PairingDraft
    let warning: String?
    let firstLaunch: Bool
    @ObservedObject var prefs: ShortcutPrefsModel
    /// v0.10 小工具 page; nil = no such page.
    let tools: ToolsPrefsModel?
    /// v0.11: mode / character picker changed.
    let applyMode: (AppConfig) -> Void
    /// v0.11 couple: changing 我的角色 moves the seat; false = cancelled.
    let confirmSeatMove: (PetCharacter) -> Bool
    /// v0.12 「我的城市」; nil = no such row.
    let city: CityAccess?
    /// The page changed: the window fits itself to the new page.
    var onPageChange: () -> Void = {}
    let onSave: (AppConfig) -> Void

    @State private var revertingCharacter = false
    @State private var page: Page = SettingsWindow.demoToolsPage ? .tools : .general

    private enum Page { case general, tools }

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    private var config: AppConfig { draft.config }
    /// The name of the character on this desk (shortcut labels).
    private var petName: String { draft.character.displayName }

    var body: some View {
        if let tools {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $page) {
                    Text("通用").tag(Page.general)
                    Text("小工具").tag(Page.tools)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 22)
                .padding(.top, 16)
                if page == .tools {
                    ToolsPage(model: tools)
                } else {
                    generalScrolling
                }
            }
            .frame(width: 420)
            .tint(Self.accent)
            .onChange(of: page) { _, _ in onPageChange() }
        } else {
            generalScrolling
        }
    }

    /// v0.13.1: the 通用 page scrolls inside a window no taller than the screen, with「保存」pinned below it —
    /// mode + character + city + pairing + shortcuts no longer push the button off screen.
    @State private var generalHeight: CGFloat = 0
    private static var maxGeneralHeight: CGFloat { max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 190) }

    private var generalScrolling: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                generalPage
                    .background(GeometryReader { g in
                        Color.clear.preference(key: GeneralHeightKey.self, value: g.size.height)
                    })
            }
            .frame(height: generalHeight > 0 ? min(generalHeight, Self.maxGeneralHeight) : Self.maxGeneralHeight)
            .onPreferenceChange(GeneralHeightKey.self) { h in
                guard abs(h - generalHeight) > 0.5 else { return }
                generalHeight = h
                onPageChange()   // the window follows (shorter content → shorter window)
            }
            Divider()
            HStack {
                Spacer()
                Button("保存") { onSave(config) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!config.isComplete)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
    }

    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("🍊").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("噜噜桌宠").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(draft.mode == .solo ? "桌面上住着你自己的角色" : "桌面上住着你自己的角色，TA 发消息时会跑来串门")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
            }

            if let warning {
                banner("⚠︎", "连接失败：\(warning)\n请检查配对码和数据库地址，两个人要填得一模一样哦",
                       tint: Self.accent)
            } else if firstLaunch {
                banner("👋", "第一次使用：选你是谁，填上和TA一样的配对码和数据库地址就能连上啦（设置方法见 docs/firebase-setup.md）",
                       tint: Color(red: 0.36, green: 0.62, blue: 0.38))
            }

            section("模式") {
                Picker("", selection: $draft.mode) {
                    ForEach(PairMode.allCases, id: \.self) { Text(PairingDraft.modeTitle($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(PairingDraft.modeBlurb(draft.mode) + "；改了马上生效")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            }

            section("我的角色") {
                Picker("", selection: $draft.character) {
                    ForEach(PetCharacter.allCases, id: \.self) { Text("我是" + $0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(characterHint)
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let city {
                section("我的城市") {
                    CitySection(access: city, paired: draft.mode.isPaired)
                }
            }

            if draft.mode.isPaired {
                PairingFields(draft: draft)
            }

            Divider().padding(.vertical, -4)

            section("快捷键和显示") {
                shortcutRow("显示 / 隐藏\(petName)", .toggle)
                shortcutRow("打开传话", .compose)
                shortcutRow("退出噜噜桌宠", .quit)
                if let error = prefs.error {
                    hint("⚠︎ " + error, ok: false).foregroundStyle(Color.red.opacity(0.8))
                } else {
                    hint(prefs.recording == nil ? "点一下框框再按新的组合键（要带 ⌃、⌥ 或 ⌘），Esc 取消；改了马上生效"
                                                : "请按下新的组合键…（Esc 取消）", ok: false)
                }
                Toggle(isOn: Binding(get: { prefs.autoHide }, set: { prefs.setAutoHide($0) })) {
                    Text("全屏时自动隐藏（看视频、开会演示时不打扰）")
                        .font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
                .padding(.top, 2)
                Toggle(isOn: Binding(get: { prefs.showInDock }, set: { prefs.setShowInDock($0) })) {
                    Text("在程序坞中显示图标（平时只在右上角菜单栏显示 🍊）")
                        .font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
            }

            Divider().padding(.vertical, -4)

            section("声音") {
                Toggle(isOn: Binding(get: { prefs.soundEnabled }, set: { prefs.setSoundEnabled($0) })) {
                    Text("声音（串门、爱心、气泡……会有小小的音效）")
                        .font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
                HStack(spacing: 8) {
                    Text("音量").font(.system(size: 12, design: .rounded))
                    Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(prefs.soundVolume) }, set: { prefs.soundVolume = Float($0) }),
                           in: 0...1) { editing in if !editing { prefs.commitVolume() } }
                        .frame(width: 170)
                    Image(systemName: "speaker.wave.3.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("试听") { prefs.commitVolume(); prefs.preview() }
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
                .disabled(!prefs.soundEnabled)
                Toggle(isOn: Binding(get: { prefs.bgm }, set: { prefs.setBGM($0) })) {
                    Text("背景音乐（只在启动时放一首，不循环）")
                        .font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
                .disabled(!prefs.soundEnabled)
            }

            if draft.mode.isPaired {
                Text("还没有数据库？按照 docs/firebase-setup.md 里的步骤创建一个（大约 5 分钟）。")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .padding(22)
        .frame(width: 420)
        .tint(Self.accent)
        .onChange(of: draft.mode) { _, _ in modeOrCharacterChanged() }
        .onChange(of: draft.character) { old, new in
            if revertingCharacter { revertingCharacter = false; return }
            // Couple with a running pairing: the character IS the seat, so confirm first (cancel = back to the old one).
            if draft.mode == .couple, !firstLaunch, config.isComplete, !confirmSeatMove(new) {
                revertingCharacter = true
                draft.character = old
                return
            }
            modeOrCharacterChanged()
        }
    }

    /// 模式 / 角色 apply at once when the result is a usable config (solo always is); otherwise 保存 does it.
    private func modeOrCharacterChanged() {
        if config.isComplete { applyMode(config) }
    }

    private func shortcutRow(_ title: String, _ action: HotkeyCenter.Action) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, design: .rounded))
                .frame(width: 110, alignment: .leading)
            Button { prefs.startRecording(action) } label: {
                Text(prefs.recording == action ? "请按键…" : prefs.shortcut(action).display)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(prefs.recording == action ? Self.accent : Color(white: 0.2))
                    .frame(width: 96)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(prefs.recording == action ? Self.accent : Color.gray.opacity(0.35), lineWidth: prefs.recording == action ? 2 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点一下，然后按下新的组合键")
            if prefs.shortcut(action) != prefs.defaultShortcut(action) {
                Button("恢复默认") { prefs.resetToDefault(action) }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    private var characterHint: String {
        switch draft.mode {
        case .solo: return "你的桌面上住着\(petName)"
        case .couple: return "你的桌面上住着\(petName)，\(draft.character.other.displayName)是TA；两个人要选不同的角色"
        case .friend: return "你的桌面上住着\(petName)；朋友可以和你选同一个，也可以选另一个"
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
            content()
        }
    }

    private func banner(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(icon).font(.system(size: 13)).foregroundStyle(tint)
            Text(text)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(white: 0.25))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.35), lineWidth: 1))
    }

    private func hint(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// v0.10 小工具 settings: edits apply (and are saved) at once.
final class ToolsPrefsModel: ObservableObject {
    @Published var settings: ToolsSettings { didSet { if settings != oldValue { access.set(settings) } } }
    private let access: PersonalToolsController.SettingsAccess

    init(_ access: PersonalToolsController.SettingsAccess) {
        self.access = access
        settings = access.get()
    }
}

private struct ToolsPage: View {
    @ObservedObject var model: ToolsPrefsModel
    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    /// A whole-minutes stepper over a seconds value.
    private func minutes(_ title: String, _ seconds: Binding<TimeInterval>, _ range: ClosedRange<Int>, step: Int = 1) -> some View {
        let m = Binding<Int>(get: { Int((seconds.wrappedValue / 60).rounded()) }, set: { seconds.wrappedValue = TimeInterval($0 * 60) })
        return Stepper(value: m, in: range, step: step) {
            HStack {
                Text(title).font(.system(size: 12, design: .rounded))
                Spacer(minLength: 0)
                Text("\(m.wrappedValue) 分钟").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("🍅").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("小工具").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("番茄钟、喝水和站立提醒；改了马上生效")
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            section("🍅 番茄钟") {
                minutes("专注", $model.settings.pomodoro.focus, 1...120)
                minutes("短休息", $model.settings.pomodoro.shortBreak, 1...60)
                minutes("长休息", $model.settings.pomodoro.longBreak, 1...120)
                Stepper(value: $model.settings.pomodoro.roundsPerLong, in: 1...12) {
                    HStack {
                        Text("几轮一次长休息").font(.system(size: 12, design: .rounded))
                        Spacer(minLength: 0)
                        Text("\(model.settings.pomodoro.roundsPerLong) 轮").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    }
                }
                hint(ToolsCopy.pomodoroHint + "。新的时长从下一个阶段开始算；在菜单 🍊 → 番茄钟 或双击面板的「小工具」里开始")
            }
            Divider().padding(.vertical, -4)
            section("💧 喝水提醒") {
                Toggle(isOn: $model.settings.waterEnabled) {
                    Text("开启").font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
                minutes("间隔", $model.settings.waterInterval, 5...180, step: 5)
                    .disabled(!model.settings.waterEnabled)
                hint(ToolsCopy.explanation(.water, interval: model.settings.waterInterval))
            }
            section("🧍 站立提醒") {
                Toggle(isOn: $model.settings.standEnabled) {
                    Text("开启").font(.system(size: 12, design: .rounded))
                }
                .toggleStyle(.checkbox)
                minutes("间隔", $model.settings.standInterval, 5...180, step: 5)
                    .disabled(!model.settings.standEnabled)
                hint(ToolsCopy.explanation(.stand, interval: model.settings.standInterval))
            }
        }
        .padding(22)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// State behind the shortcut recorder fields: captures the next key press with a local key monitor
/// (the global hotkeys are released meanwhile, so ⌃⌥L etc. reach us).
final class ShortcutPrefsModel: ObservableObject {
    @Published private(set) var shortcuts: ShortcutSet
    @Published private(set) var autoHide: Bool
    @Published private(set) var showInDock: Bool
    @Published private(set) var recording: HotkeyCenter.Action?
    @Published private(set) var error: String?
    @Published private(set) var soundEnabled: Bool
    /// Follows the slider; saved (and applied) by `commitVolume()` when dragging ends.
    @Published var soundVolume: Float
    @Published private(set) var bgm: Bool
    private var committedVolume: Float
    private let prefs: SettingsWindow.Prefs
    private var monitor: Any?

    init(_ prefs: SettingsWindow.Prefs) {
        self.prefs = prefs
        shortcuts = prefs.shortcuts
        autoHide = prefs.autoHideFullscreen
        showInDock = prefs.showInDock
        soundEnabled = prefs.soundEnabled
        soundVolume = prefs.soundVolume
        committedVolume = prefs.soundVolume
        bgm = prefs.bgmEnabled
    }

    func setSoundEnabled(_ on: Bool) {
        soundEnabled = on
        prefs.setSoundEnabled(on)
    }

    func commitVolume() {
        guard soundVolume != committedVolume else { return }
        committedVolume = soundVolume
        prefs.setSoundVolume(soundVolume)
    }

    func setBGM(_ on: Bool) {
        bgm = on
        prefs.setBGM(on)
    }

    func preview() { prefs.previewSound() }

    func refreshSound(enabled: Bool, volume: Float, bgm: Bool) {
        soundEnabled = enabled
        soundVolume = volume
        committedVolume = volume
        self.bgm = bgm
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func shortcut(_ a: HotkeyCenter.Action) -> Shortcut { shortcuts[a] }
    func defaultShortcut(_ a: HotkeyCenter.Action) -> Shortcut { a.defaultShortcut }

    func setAutoHide(_ on: Bool) {
        autoHide = on
        prefs.setAutoHide(on)
    }

    func setShowInDock(_ on: Bool) {
        showInDock = on
        prefs.setShowInDock(on)
    }

    func startRecording(_ a: HotkeyCenter.Action) {
        if recording != nil { stopRecording() }
        recording = a
        error = nil
        prefs.recording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.recording != nil else { return e }
            MainActor.assumeIsolated { self.handle(e) }
            return nil
        }
    }

    func resetToDefault(_ a: HotkeyCenter.Action) {
        if recording != nil { stopRecording() }
        if let problem = shortcuts.problem(defaultShortcut(a), for: a) {   // another action took the default
            error = "\(defaultShortcut(a).display)：\(problem)"
            return
        }
        apply(defaultShortcut(a), to: a)
    }

    @MainActor
    private func handle(_ e: NSEvent) {
        guard let a = recording else { return }
        if e.keyCode == 53, HotkeyCenter.modifiers(e.modifierFlags).isEmpty {   // Esc: cancel
            stopRecording()
            return
        }
        let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: HotkeyCenter.modifiers(e.modifierFlags),
                         key: Shortcut.keyName(keyCode: UInt32(e.keyCode), characters: e.charactersIgnoringModifiers))
        if let problem = shortcuts.problem(s, for: a) {
            error = "\(s.display)：\(problem)"
            NSSound.beep()
            return   // keep listening
        }
        stopRecording()
        apply(s, to: a)
    }

    private func apply(_ s: Shortcut, to a: HotkeyCenter.Action) {
        if let failure = prefs.setShortcut(a, s) {
            error = failure
            return
        }
        error = nil
        shortcuts[a] = s
    }

    func cancelRecording() {
        if recording != nil { stopRecording() }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        prefs.recording(false)
    }
}

/// Height of the 通用 page's content (for the scroll area around it).
private struct GeneralHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
