import AppKit
import LuluCore
import SwiftUI

// v0.11 (docs/superpowers/specs/2026-10-05-modes-design.md): first-launch welcome (mode → character → pairing)
// and the pairing pieces Settings shares with it.

/// What the person is editing: mode, character, seat, pair code, database. Used by the Welcome window and the
/// Settings 通用 page, so the seat rule lives in one place:
/// - couple: seat = character (噜噜 sits in seat A, 噜妹 in B);
/// - friend: 生成配对码 → seat lulu (A), 粘贴 → seat lumei (B), whatever character is drawn;
/// - solo: the seat is irrelevant; an existing one is kept (and the pair code / URL are kept for switching back).
final class PairingDraft: ObservableObject {
    @Published var mode: PairMode
    @Published var character: PetCharacter
    @Published var pairCode: String
    @Published var databaseURL: String
    @Published var copied = false
    /// The friend-mode seat (set by 生成 / 粘贴); couple derives the seat from the character instead.
    @Published private(set) var friendSeat: Role
    private let initial: AppConfig?
    private var lastGenerated: String?

    init(initial: AppConfig?, defaultRole: Role) {
        self.initial = initial
        mode = initial?.effectiveMode ?? .couple
        character = initial?.myCharacter ?? PetCharacter(defaultRole)
        pairCode = initial?.pairCode ?? ""
        databaseURL = initial?.databaseURL ?? ""
        friendSeat = initial?.role ?? defaultRole
    }

    var normalizedCode: String { PairCode.normalize(pairCode) }

    /// The seat the config is saved with.
    var seat: Role {
        switch mode {
        case .couple: return Role(rawValue: character.rawValue) ?? .lulu
        case .friend: return friendSeat
        case .solo: return initial?.role ?? Role(rawValue: character.rawValue) ?? .lulu
        }
    }

    var config: AppConfig {
        // An old config (no mode / character) stays exactly as it was while nothing about them changed.
        let storedMode: PairMode? = (initial != nil && mode == .couple && initial?.mode == nil) ? nil : mode
        let storedCharacter: PetCharacter? = (initial != nil && initial?.character == nil && character == PetCharacter(seat)) ? nil : character
        return AppConfig(role: seat, pairCode: normalizedCode,
                         databaseURL: databaseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                         mode: storedMode, character: storedCharacter)
    }

    func generate() {
        pairCode = PairCode.generate()
        lastGenerated = normalizedCode
        copied = false
        friendSeat = .lulu
    }

    func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        pairCode = s.trimmingCharacters(in: .whitespacesAndNewlines)
        lastGenerated = nil
        copied = false
        friendSeat = .lumei
    }

    func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(normalizedCode, forType: .string)
        copied = true
    }

    /// The code field was edited by hand: a code someone else made is pasted, so friend mode takes seat B.
    func codeEditedByHand() {
        if normalizedCode == lastGenerated { return }
        friendSeat = .lumei
    }

    static func modeTitle(_ m: PairMode) -> String {
        switch m {
        case .solo: return "一个人"
        case .couple: return "情侣"
        case .friend: return "朋友"
        }
    }

    static func modeBlurb(_ m: PairMode) -> String {
        switch m {
        case .solo: return "桌面上有一只自己的宠物，不用配对"
        case .couple: return "和对象配对，会串门、亲亲、抱抱"
        case .friend: return "和朋友配对，串门、传话、互动，没有亲密动作"
        }
    }

    static func modeEmoji(_ m: PairMode) -> String {
        switch m {
        case .solo: return "🧸"
        case .couple: return "💕"
        case .friend: return "🤝"
        }
    }
}

/// 配对码 + 数据库地址 (shared by Welcome and Settings). In friend mode there is also 粘贴 and the seat hint.
struct PairingFields: View {
    @ObservedObject var draft: PairingDraft
    static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                title("配对码")
                HStack(spacing: 6) {
                    TextField(draft.mode == .friend ? "一个人生成，另一个人粘贴" : "两个人填同一个配对码", text: $draft.pairCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: draft.pairCode) { _, _ in draft.codeEditedByHand() }
                    Button("生成") { draft.generate() }
                    if draft.mode == .friend { Button("粘贴") { draft.pasteFromClipboard() } }
                    Button(draft.copied ? "已复制" : "复制") { draft.copyCode() }
                        .disabled(draft.normalizedCode.isEmpty)
                }
                hint(codeHint, ok: PairCode.isValid(draft.normalizedCode))
            }
            VStack(alignment: .leading, spacing: 6) {
                title("Firebase 数据库地址")
                TextField("https://xxx-default-rtdb.firebaseio.com", text: $draft.databaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if !draft.databaseURL.isEmpty && !draft.config.normalizedDatabaseURL.hasPrefix("https://") {
                    hint("地址需要以 https:// 开头", ok: false)
                }
            }
        }
    }

    private var codeHint: String {
        let code = draft.normalizedCode
        if code.isEmpty {
            return draft.mode == .friend ? "两个人里，一个点「生成」再把配对码发给对方；另一个点「粘贴」"
                                         : "一个人点「生成」，再把配对码发给另一个人填进来"
        }
        if PairCode.isValid(code) { return "配对码没问题 ✓" }
        return "配对码应为 24 位字母或数字（不含 0、O、1、I），现在是 \(code.count) 位"
    }

    private func title(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
    }

    private func hint(_ text: String, ok: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded))
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 「还没有数据库？」 with a clickable link to the illustrated setup guide (Welcome step 4 and Settings 通用).
struct FirebaseGuideNote: View {
    static let guideURL = "https://github.com/richardzhuang0412/LuluPet/blob/main/docs/firebase-setup.md"

    var body: some View {
        Text("还没有数据库？按照[图文步骤](https://github.com/richardzhuang0412/LuluPet/blob/main/docs/firebase-setup.md)创建一个，大约 10 分钟。")
            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// First launch (no usable config, no mode yet): 一个人 / 情侣 / 朋友 → which character → (paired modes) the
/// pairing fields. Calls `onFinish` with the finished config; closing the window without finishing leaves the
/// app without a pet (the menu 设置… still works).
final class WelcomeWindow: NSWindow {
    var onFinish: ((AppConfig) -> Void)?
    /// v0.12: the city picked on the extra step (called just before `onFinish`; not called when skipped).
    var onPlaceChosen: ((WeatherPlace) -> Void)?

    /// Hidden `--demo-welcome N`: open on step N (1 mode, 2 character, 3 city, 4 pairing) with the mode `demoMode`.
    nonisolated(unsafe) static var demoStep: Int?
    nonisolated(unsafe) static var demoMode: PairMode = .couple

    init(sprites: SpriteCatalog, defaultRole: Role, citySearch: @escaping CitySearch = { _ in [] }) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)
        title = "欢迎来到噜噜桌宠"
        isReleasedWhenClosed = false
        setLuluLevel(.normal)   // --offscreen: below the desktop picture, no mouse
        let draft = PairingDraft(initial: nil, defaultRole: defaultRole)
        let portraits = Dictionary(uniqueKeysWithValues: PetCharacter.allCases.map { c in
            (c, Self.portrait(sprites, c))
        })
        let view = WelcomeView(draft: draft, portraits: portraits, citySearch: citySearch, onFinish: { [weak self] cfg, place, launchAtLogin in
            if let place { self?.onPlaceChosen?(place) }
            if launchAtLogin { LoginItem.set(true) }   // v0.16: the final step's 开机自动打开 checkbox (no-op in test instances)
            self?.onFinish?(cfg)
            self?.close()
        })
        let host = NSHostingView(rootView: view)
        contentView = host
        setContentSize(host.fittingSize)
        center()
    }

    /// The idle clip's first frame of the character's preferred outfit.
    private static func portrait(_ sprites: SpriteCatalog, _ c: PetCharacter) -> NSImage? {
        let role = Role(rawValue: c.rawValue) ?? .lulu
        guard let outfit = sprites.preferredOutfit(for: role),
              let url = sprites.clip(role, outfit: outfit, action: .idle)?.frames.first else { return nil }
        return ComposeWindow.firstFrame(url)
    }

    func show() {
        if Offscreen.enabled { orderFront(nil); return }   // test instance: no Dock icon, no focus grab
        DockPresence.shared.acquire("welcome")
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        super.close()
        DockPresence.shared.release("welcome")
    }
}

private struct WelcomeView: View {
    @ObservedObject var draft: PairingDraft
    let portraits: [PetCharacter: NSImage?]
    let citySearch: CitySearch
    let onFinish: (AppConfig, WeatherPlace?, Bool) -> Void

    @State private var launchAtLogin = true   // v0.16: offered (checked) on the final step
    @State private var step: Int = WelcomeWindow.demoStep ?? 1   // 1 mode, 2 character, 3 city (v0.12), 4 pairing
    @State private var place: WeatherPlace?

    private static let accent = PairingFields.accent
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)

    init(draft: PairingDraft, portraits: [PetCharacter: NSImage?], citySearch: @escaping CitySearch,
         onFinish: @escaping (AppConfig, WeatherPlace?, Bool) -> Void) {
        self.draft = draft
        self.portraits = portraits
        self.citySearch = citySearch
        self.onFinish = onFinish
        if WelcomeWindow.demoStep != nil { draft.mode = WelcomeWindow.demoMode }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("🍊").font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎来到噜噜桌宠").font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(subtitle).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(step) / \(draft.mode.isPaired || step == 1 ? 4 : 3)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.secondary).monospacedDigit()
            }
            switch step {
            case 1: modeStep
            case 2: characterStep
            case 3: cityStep
            default: pairStep
            }
        }
        .padding(22)
        .frame(width: 440)
        .tint(Self.accent)
    }

    private var subtitle: String {
        switch step {
        case 1: return "你想怎么用？之后可以在设置里随时改"
        case 2: return draft.mode == .solo ? "选一只陪着你的宠物" : "选你桌面上住的角色"
        case 3: return "用来显示天气，宠物也会跟着天气换样子；可以跳过"
        default: return draft.mode == .friend ? "和朋友连上：一个人生成配对码，另一个人粘贴" : "和对象连上：填上一样的配对码和数据库地址"
        }
    }

    // MARK: 1 mode

    private var modeStep: some View {
        HStack(spacing: 10) {
            ForEach(PairMode.allCases, id: \.self) { m in
                Button {
                    draft.mode = m
                    step = 2
                } label: {
                    VStack(spacing: 8) {
                        Text(PairingDraft.modeEmoji(m)).font(.system(size: 38))
                        Text(PairingDraft.modeTitle(m)).font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(white: 0.2))
                        Text(PairingDraft.modeBlurb(m))
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 16).padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 178, alignment: .top)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Self.cream))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Self.accent.opacity(draft.mode == m ? 0.9 : 0.25), lineWidth: draft.mode == m ? 2 : 1))
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 2 character

    private var characterStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ForEach(PetCharacter.allCases, id: \.self) { c in
                    Button { draft.character = c } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let img = portraits[c] ?? nil {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    Text(c.displayName).font(.system(size: 30))
                                }
                            }
                            .frame(height: 150)
                            Text(c.displayName).font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(white: 0.2))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Self.cream))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Self.accent.opacity(draft.character == c ? 0.9 : 0.25), lineWidth: draft.character == c ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            if draft.mode == .couple {
                Text("情侣模式里，你们两个要选不同的角色（你是\(draft.character.displayName)，TA 就是\(draft.character.other.displayName)）")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("返回") { step = 1 }
                Spacer()
                Button("下一步") { step = 3 }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 3 city (v0.12, skippable)

    private var cityStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("你在哪个城市？").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color(white: 0.2))
            CityPicker(place: place, search: citySearch, onChange: { place = $0 })
            Text(draft.mode.isPaired ? "TA 能看到你那边的天气和当地时间，只分享城市，不分享精确位置。之后可以在设置里改。"
                                     : "之后可以在设置里改。")
                .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !draft.mode.isPaired { launchToggle }
            HStack {
                Button("返回") { step = 2 }
                Spacer()
                // Solo: this is the last step, so it is always 开始 (not 跳过, which reads as "skip the whole setup").
                Button(draft.mode.isPaired ? (place == nil ? "跳过" : "下一步") : "开始") {
                    if draft.mode.isPaired { step = 4 } else { onFinish(draft.config, place, launchAtLogin) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// v0.16: the final step offers 开机自动打开 (checked); `LoginItem.set` runs when 开始 is pressed.
    private var launchToggle: some View {
        Toggle(isOn: $launchAtLogin) {
            Text("开机自动打开（推荐）").font(.system(size: 12, design: .rounded))
        }
        .toggleStyle(.checkbox)
    }

    // MARK: 4 pairing (couple / friend)

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            PairingFields(draft: draft)
            FirebaseGuideNote()
            launchToggle
            HStack {
                Button("返回") { step = 3 }
                Spacer()
                Button("开始") { onFinish(draft.config, place, launchAtLogin) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.config.isComplete)
            }
        }
    }
}
