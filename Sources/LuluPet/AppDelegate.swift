import AppKit
import CoreLocation
import LuluCore
import LuluSync

/// Wires config → PairChannel → pet window, bubble, compose panel and menus.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct Options {
        var profile: String?
        var role: Role?
        var demo = false          // use a dummy config if none is saved
        var demoBubble = false    // queue a local text + sticker bubble
        var demoSticker = false   // queue only a sticker bubble
        var demoCompose = false   // open the compose panel at launch
        var demoSleep = false     // show the sleeping state
        var demoPoke = false      // simulate an incoming poke shortly before the snapshot
        var demoNotice = false    // pretend the channel is misconfigured and show the notice
        var demoOffline = false   // pretend the network is down and show the offline hint
        var demoSettings = false  // open the settings window at launch
        var forceDark = false     // --force-dark: whole app in Dark Mode (to test panels)
        var selftestReopen = false // close Welcome without finishing, then reopen via the menu's 设置… and the Dock click; log which window shows
        var selftestPaste = false // open Settings, focus a text field, send ⌘V through the main menu, log the result
        var autotest = false      // send a poke, a text and a sticker through the real channel after 5 s
        var snapshotDir: String?  // render visible windows to PNGs (no Screen Recording permission needed)
        var rotateSeconds: TimeInterval?  // shorten the outfit rotation interval (testing)
        var demoTogglePinAfter: TimeInterval?  // act as if "固定这套造型" was clicked after N s (testing)
        var demoVisit = false     // simulate the partner visiting (a text, or --demo-visit-kind K) after 1 s
        var demoVisitKind: Message.Kind?
        var demoVisitSticker: String?   // --demo-visit-sticker ID[,ID...]: the demo visit is that sticker (several: one every --demo-visit-every s)
        var demoVisitEvery: TimeInterval = 9
        var demoGoOnline: Bool?   // --demo-go-online / --demo-go-offline: pretend presence, then "去找TA" after 1 s
        var demoMerge = false     // visitor present, then simulate dragging the home pet onto it
        var demoDismissBubble: TimeInterval?  // click away every bubble after N s (lets a text visit end)
        var autovisit: [TimeInterval] = []   // "去找TA" through the real channel at these seconds after launch
        var snapshotAt: [TimeInterval] = []  // with --snapshot DIR: capture at these seconds into DIR/t<sec>/
        var fakeAppVersion: String?   // --fake-app-version X: report X as my app version (testing the upgrade nudge)
        var presenceFast = false  // 2 s heartbeat / poll, offline after 6 s (testing)
        var seatCheckInterval: TimeInterval?   // --seat-check-interval S: read my own seat every S s instead of ~3 min (testing)
        var demoSettingsCharacter: (PetCharacter, TimeInterval)?   // --demo-settings-character lulu@3: open Settings and pick that character at 3 s (testing)
        var seatConfirm: Bool?    // --seat-confirm accept|cancel: answer the 换角色 confirmation without a dialog (testing)
        var dozeSeconds: TimeInterval?    // doze after N s without interaction (default IdleRules.dozeAfter)
        var fidgetSeconds: TimeInterval?  // fidget every N s instead of a random 45–120 s
        // v0.4
        var demoHide: HideOption?         // --demo-hide-5m / --demo-hide: hide 0.8 s after launch
        var demoHideRemaining: TimeInterval?  // --demo-hide-5m-remaining N: a 5 min hide with only N s left
        var demoHiddenMessages = 0        // --demo-hidden-messages N: N partner messages arrive while hidden
        var demoUnhideAfter: TimeInterval?  // --demo-unhide-after S: show again after S s (plays "你不在的时候…")
        var demoHistory = false           // --demo-history: seed an EMPTY profile history with ~40 messages over 3 days
        var demoOpenHistory = false       // --demo-open-history: open the compose panel on the「记录」tab
        var demoOpenHistoryAt: TimeInterval?  // --demo-open-history-at S: (re)open the panel on the「记录」tab at S s (demo GIFs)
        var demoMoreStickersAt: TimeInterval?  // --demo-more-stickers S: open 「更多表情…」 in the compose panel at S s (demo GIFs, snapshots)
        var demoHotkeys: [(HotkeyCenter.Action, TimeInterval)] = []   // --demo-hotkey toggle@2,compose@4
        var demoMenu: TimeInterval?       // --demo-menu S: pop up the status menu at S s (snapshots)
        var demoPressCard: TimeInterval?  // --demo-press-card S: press the card's「看看」at S s
        var demoMenuSubmenu = false       // --demo-menu-submenu: …with the 隐藏 submenu open
        // v0.5
        var demoMenuSound = false         // --demo-menu-sound: --demo-menu pops up the 声音 submenu instead
        var demoClicks: [TimeInterval] = []   // --demo-click 2,4: a single click on the home pet at these seconds
        var demoFidgets: [TimeInterval] = []  // --demo-fidget 2: a random fidget at these seconds (demo GIFs)
        var demoSend: [TimeInterval] = []     // --demo-heart 3: 「❤️ 发送爱心」 at these seconds (demo database: nothing leaves)
        var outfit: String?               // --outfit NAME: wear this outfit at launch (not pinned; testing / snapshots)
        var forceCouple: String?          // --force-couple NAME: every meeting plays this couples.json clip (demos / tests)
        var demoVisitOutfit: String?      // --demo-visit-outfit NAME: the demo partner message carries `outfit` NAME
        var today: Date?                  // --today YYYY-MM-DD: pretend it is this day (seasonal outfits)
        // v0.6
        /// --auto-send "poke@5,sticker:hug@7,text:你好@9,visit@11": sends through the real channel (same path as the
        /// buttons) at these seconds after launch; a time > 1e12 is an absolute Unix time in ms (two instances in sync).
        var autoSend: [(kind: Message.Kind, arg: String?, at: TimeInterval)] = []
        var autoSendTs: Int64?            // --auto-send-ts MS: the first auto-send carries this ts (same-ms collision tests)
        // v0.7
        var scale: Double?                // --scale 1.4: pet size for this run (not saved; testing / snapshots)
        var demoResizeHandle = false      // --demo-resize-handle: keep the hover resize handle visible
        var demoResizeDrag: (CGVector, TimeInterval)?   // --demo-resize-drag DX,DY@T: drag the handle by (DX, DY) pt at T s
        var demoScale: [(Double, TimeInterval)] = []    // --demo-scale 1.3@3,1@6: menu 大小 → that scale at T s
        var demoMenuSize = false          // --demo-menu-size: --demo-menu pops up the 大小 submenu instead
        // v0.7.4
        var visitorMaxStay: TimeInterval?  // --visitor-max-stay 5: the visitor's time limit for this run (default 45 s)
        var demoAck: [TimeInterval] = []   // --demo-ack 3,5: press「收到 ❤️」on the current bubble at these seconds
        var demoVisitText: String?         // --demo-visit-text "…": the demo visit's text (e.g. a long one)
        // v0.8
        var quietSeconds: TimeInterval?    // --quiet-seconds N: quiet mode after N s (default IdleRules.quietAfter)
        var batteryMode = false            // --battery-mode: battery timings (heartbeat / polls / hover) as if unplugged
        var demoDND: (DNDMood, TimeInterval)?   // --demo-dnd angry@2: 勿扰 on at T s through the menu's path
        var demoDNDFor: DNDDuration = .untilOff // --demo-dnd-for thirtyMinutes|oneHour|today|untilOff
        var demoDNDOff: TimeInterval?      // --demo-dnd-off T: 关闭勿扰 at T s
        var demoMenuDND = false            // --demo-menu-dnd: --demo-menu pops up the 勿扰模式 submenu instead
        var demoRemindReply: [(comply: Bool, at: TimeInterval)] = []   // --demo-remind-reply comply@8,snooze@20: press 喝了/好的 or 等会儿 on the bubble
        var demoPartnerFocus: Double?      // --demo-partner-focus 12: pretend the partner is focusing for 12 more minutes
        var demoPartnerDND: DNDMood?       // --demo-partner-dnd busy: pretend the partner has 勿扰 on (status line / sends)
        var demoMenuOutfits = false        // --demo-menu-outfits: --demo-menu pops up the 选择造型 submenu instead
        var demoPomodoro: TimeInterval?    // --demo-pomodoro S: start a focus round of S seconds (breaks S/2) at launch
        var demoReminders: [(ReminderKind, TimeInterval)] = []   // --demo-reminder water@5,stand@9: that bubble pops at T s
        var demoMenuTools: String?         // --demo-menu-tools pomodoro|reminders: --demo-menu pops up that submenu instead
        var demoSnoozeDelay: TimeInterval?   // --demo-snooze-delay S: 等会儿 asks again after S s (test only)
        var demoOutfitSteps: [(String, TimeInterval)] = []   // --demo-outfit change@2,back@4,choose:bear@6
        // v0.11 modes (Task 2: welcome / settings / solo)
        var demoWelcome: Int?              // --demo-welcome N: open the welcome window on step N (1 mode, 2 character, 3 city, 4 pairing)
        var demoMode: PairMode?            // --mode solo|couple|friend: the mode of the --demo dummy config (and of --demo-welcome)
        var demoCharacter: PetCharacter?   // --character lulu|lumei: the character of the --demo dummy config
        var demoSeatClash: TimeInterval?   // --demo-seat-clash S: show the seat-clash notice at S s (snapshots; the real detection needs two machines)
        var demoComposeTab: String?        // --demo-compose-tab tools: --demo-compose / --demo-solo-compose open on that tab (snapshots)
        // v0.12 weather
        var fakeWeather = false            // --fake-weather: fixed FakeWeather data and city search, no network (offscreen tests)
        var demoPartnerPlace: WeatherPlace?   // --demo-partner-place 上海: pretend the partner's city is that FakeWeather place
        var demoThink: [(kind: String, at: TimeInterval)] = []   // --demo-think rain@2,snow@8,clear@14: show the 想 TA bubble (forced) with that weather
        var demoPeek: [(at: TimeInterval, state: String?)] = []   // --demo-peek S[:never|offline|online][,S2…]: a 偷看 at S s; a state fakes TA (snapshots, no network), none = the real presence fetch
        var demoMyPlace: WeatherPlace?     // --demo-my-place 洛杉矶: seed my city (temp profiles; snapshots)
        // v0.14.1 current location (testing only; none of these touch the real location permission)
        var fakeLocation: String?          // --fake-location ok|denied|fail: no CoreLocation / geocoder, a fixed answer (ok = 伯克利)
        var demoMyPlaceAuto = false        // --demo-my-place-auto: seed 「使用我现在的位置」 as on (snapshots, temp profiles)
        var demoLocationStatus: LocationStatus?   // --demo-location-status denied|failed|locating: show that status line (snapshots)
        var demoSoloCompose = false        // --demo-solo-compose: open the (simplified) panel at launch like --demo-compose
        // v0.13 更新日志 / 待设置
        var demoWhatsNew: WhatsNewModel.Page?   // --demo-whatsnew [updates|todos]: open the 更新日志 window at 0.5 s
        var demoWhatsNewSeen: String?      // --demo-whatsnew-seen X: set whatsNewSeen to X before the launch check (temp profiles)
        var demoWhatsNewHelp = false       // --demo-whatsnew-help: 待设置 page, partner pretended older, its explanation unfolded
        // v0.14 one-click updater (all hidden, for tests)
        var update = UpdateOptions()       // --update-feed URL / --update-auto-confirm / --update-allow-dir DIR
        var demoUpdateCheck: TimeInterval?  // --demo-update-check S: a manual 检查更新 at S s (card / 已经是最新版)
        var demoPingUpgrade: TimeInterval?  // --demo-ping-upgrade S: press 「📣 叫 TA 升级」 at S s (the 更新日志 button when open)
        var demoUpdateNow: TimeInterval?    // --demo-update-now S: 「一键更新」 at S s (check, confirm, install, restart)

        init(_ args: [String]) {
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--profile": profile = it.next()
                case "--role": role = it.next().flatMap(Role.init(rawValue:))
                case "--demo": demo = true
                case "--demo-bubble": demoBubble = true
                case "--demo-sticker": demoSticker = true
                case "--demo-compose": demoCompose = true
                case "--demo-sleep": demoSleep = true
                case "--demo-poke": demoPoke = true
                case "--demo-notice": demoNotice = true
                case "--demo-offline": demoOffline = true
                case "--demo-settings": demoSettings = true
                case "--selftest-paste": selftestPaste = true
                case "--selftest-reopen": selftestReopen = true
                case "--force-dark": forceDark = true
                case "--autotest": autotest = true
                case "--snapshot": snapshotDir = it.next()
                case "--rotate-seconds": rotateSeconds = it.next().flatMap(TimeInterval.init)
                case "--demo-toggle-pin": demoTogglePinAfter = it.next().flatMap(TimeInterval.init)
                case "--demo-visit": demoVisit = true
                case "--demo-visit-kind": demoVisit = true; demoVisitKind = it.next().map(Message.Kind.init(rawValue:))
                case "--demo-visit-sticker": demoVisit = true; demoVisitKind = .sticker; demoVisitSticker = it.next()
                case "--demo-visit-every": demoVisitEvery = it.next().flatMap(TimeInterval.init) ?? demoVisitEvery
                case "--demo-go-online": demoGoOnline = true
                case "--demo-go-offline": demoGoOnline = false
                case "--demo-merge": demoMerge = true
                case "--demo-dismiss-bubble": demoDismissBubble = it.next().flatMap(TimeInterval.init)
                case "--autovisit": autovisit = Self.seconds(it.next())
                case "--snapshot-at": snapshotAt = Self.seconds(it.next())
                case "--presence-fast": presenceFast = true
                case "--fake-app-version": fakeAppVersion = it.next(); AppVersionSource.override = fakeAppVersion
                case "--seat-check-interval": seatCheckInterval = it.next().flatMap(TimeInterval.init)
                case "--demo-settings-character":
                    if let spec = it.next() {
                        let p = spec.split(separator: "@")
                        if p.count == 2, let c = PetCharacter(rawValue: String(p[0])), let t = TimeInterval(p[1]) { demoSettingsCharacter = (c, t) }
                    }
                case "--seat-confirm": seatConfirm = it.next() == "accept"
                case "--doze-seconds": dozeSeconds = it.next().flatMap(TimeInterval.init)
                case "--fidget-seconds": fidgetSeconds = it.next().flatMap(TimeInterval.init)
                case "--demo-hide-5m": demoHide = .fiveMinutes
                case "--demo-hide-5m-remaining": demoHide = .fiveMinutes; demoHideRemaining = it.next().flatMap(TimeInterval.init)
                case "--demo-hide": demoHide = .untilReopened
                case "--demo-hidden-messages": demoHiddenMessages = it.next().flatMap(Int.init) ?? 3
                case "--demo-unhide-after": demoUnhideAfter = it.next().flatMap(TimeInterval.init)
                case "--demo-history": demoHistory = true
                case "--demo-open-history": demoOpenHistory = true
                case "--demo-open-history-at": demoOpenHistoryAt = it.next().flatMap(TimeInterval.init)
                case "--demo-more-stickers": demoMoreStickersAt = it.next().flatMap(TimeInterval.init)
                case "--demo-history-day": demoOpenHistory = true; HistoryModel.demoScrollToDaysAgo = it.next().flatMap(Int.init)
                case "--demo-hotkey":
                    demoHotkeys = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let t = TimeInterval(bits[1]) else { return nil }
                        return (HotkeyCenter.Action.allCases.first { $0.name == bits[0] } ?? .toggle, t)
                    }
                case "--demo-menu": demoMenu = it.next().flatMap(TimeInterval.init)
                case "--demo-menu-submenu": demoMenuSubmenu = true
                case "--demo-press-card": demoPressCard = it.next().flatMap(TimeInterval.init)
                case "--demo-menu-sound": demoMenuSound = true
                case "--demo-click": demoClicks = Self.seconds(it.next())
                case "--demo-fidget": demoFidgets = Self.seconds(it.next())
                case "--demo-heart": demoSend = Self.seconds(it.next())
                case "--outfit": outfit = it.next()
                case "--demo-visit-outfit": demoVisitOutfit = it.next()
                case "--force-couple": forceCouple = it.next()
                case "--auto-send": autoSend += Self.autoSends(it.next())
                case "--auto-send-ts": autoSendTs = it.next().flatMap(Int64.init)
                case "--scale": scale = it.next().flatMap(Double.init)
                case "--demo-resize-handle": demoResizeHandle = true
                case "--demo-resize-drag":
                    let parts = (it.next() ?? "").split(separator: "@")
                    let xy = (parts.first ?? "").split(separator: ",").compactMap { Double($0) }
                    if xy.count == 2 { demoResizeDrag = (CGVector(dx: xy[0], dy: xy[1]), parts.count > 1 ? Double(parts[1]) ?? 3 : 3) }
                case "--demo-scale":
                    demoScale = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let v = Double(bits[0]), let t = TimeInterval(bits[1]) else { return nil }
                        return (v, t)
                    }
                case "--demo-menu-size": demoMenuSize = true
                case "--visitor-max-stay": visitorMaxStay = it.next().flatMap(TimeInterval.init)
                case "--demo-ack": demoAck = Self.seconds(it.next())
                case "--demo-visit-text": demoVisit = true; demoVisitKind = .text; demoVisitText = it.next()
                case "--quiet-seconds": quietSeconds = it.next().flatMap(TimeInterval.init)
                case "--battery-mode": batteryMode = true
                case "--demo-dnd":
                    let bits = (it.next() ?? "").split(separator: "@")
                    demoDND = (bits.first.flatMap { DNDMood(rawValue: String($0)) } ?? .default, bits.count > 1 ? TimeInterval(bits[1]) ?? 0.8 : 0.8)
                case "--demo-dnd-for": demoDNDFor = it.next().flatMap(DNDDuration.init(rawValue:)) ?? .untilOff
                case "--demo-dnd-off": demoDNDOff = it.next().flatMap(TimeInterval.init)
                case "--demo-menu-dnd": demoMenuDND = true
                case "--demo-menu-outfits": demoMenuOutfits = true
                case "--demo-pomodoro": demoPomodoro = it.next().flatMap(TimeInterval.init)
                case "--demo-reminder":
                    demoReminders = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let k = ReminderKind(rawValue: String(bits[0])), let t = TimeInterval(bits[1]) else { return nil }
                        return (k, t)
                    }
                case "--demo-menu-tools": demoMenuTools = it.next()
                case "--demo-snooze-delay": demoSnoozeDelay = it.next().flatMap(TimeInterval.init)
                case "--demo-settings-tools": SettingsWindow.demoToolsPage = true
                case "--demo-settings-stickers": SettingsWindow.demoStickersPage = true
                case "--demo-solo-compose": demoSoloCompose = true
                case "--demo-compose-tab": demoComposeTab = it.next()
                case "--demo-seat-clash": demoSeatClash = it.next().flatMap(TimeInterval.init) ?? 1
                case "--fake-weather": fakeWeather = true
                case "--demo-partner-place": demoPartnerPlace = it.next().flatMap { n in FakeWeather.places.first { $0.name == n } }
                case "--demo-think":
                    demoThink = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let t = TimeInterval(bits[1]) else { return nil }
                        return (String(bits[0]), t)
                    }
                case "--demo-peek":
                    demoPeek = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: ":").map(String.init)
                        guard let t = bits.first.flatMap(TimeInterval.init) else { return nil }
                        return (t, bits.count > 1 ? bits[1] : nil)
                    }
                case "--demo-my-place": demoMyPlace = it.next().flatMap { n in FakeWeather.places.first { $0.name == n } }
                case "--demo-city-query": CityPicker.demoQuery = it.next()
                case "--fake-location": fakeLocation = it.next()
                case "--demo-my-place-auto": demoMyPlaceAuto = true
                case "--demo-location-status":
                    demoLocationStatus = ["denied": .denied, "failed": .failed, "locating": .locating][it.next() ?? ""]
                case "--demo-whatsnew":
                    let next = args.firstIndex(of: a).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
                    demoWhatsNew = next == "todos" ? .todos : .updates   // an unknown following arg is ignored by the loop
                case "--demo-whatsnew-seen": demoWhatsNewSeen = it.next()
                case "--update-feed":   // https, or http to this Mac only; anything else is ignored (the real GitHub feed is used)
                    let raw = it.next()
                    update.feed = UpdateFeed.sanitizedOverride(raw)?.absoluteString
                    if update.feed == nil { NSLog("[lulu] ignoring --update-feed %@ (only https or http://127.0.0.1 / localhost)", raw ?? "") }
                case "--update-auto-confirm": update.autoConfirm = true
                case "--update-allow-dir": update.allowDir = it.next()
                case "--demo-update-check": demoUpdateCheck = it.next().flatMap(TimeInterval.init) ?? 1.5
                case "--demo-ping-upgrade": demoPingUpgrade = it.next().flatMap(TimeInterval.init) ?? 3
                case "--demo-update-now": demoUpdateNow = it.next().flatMap(TimeInterval.init) ?? 1.5
                case "--demo-whatsnew-help": demoWhatsNewHelp = true; demoWhatsNew = .todos
                case "--demo-welcome": demoWelcome = it.next().flatMap(Int.init) ?? 1
                case "--mode": demoMode = it.next().flatMap(PairMode.init(rawValue:))
                case "--character": demoCharacter = it.next().flatMap(PetCharacter.init(rawValue:))
                case "--demo-outfit":
                    demoOutfitSteps = (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let t = TimeInterval(bits[1]) else { return nil }
                        return (String(bits[0]), t)
                    }
                case "--demo-remind-reply":
                    demoRemindReply += (it.next() ?? "").split(separator: ",").compactMap { part in
                        let bits = part.split(separator: "@")
                        guard bits.count == 2, let t = TimeInterval(bits[1]), bits[0] == "comply" || bits[0] == "snooze" else { return nil }
                        return (bits[0] == "comply", t)
                    }
                case "--demo-partner-focus": demoPartnerFocus = it.next().flatMap(Double.init)
                case "--demo-partner-dnd": demoPartnerDND = it.next().flatMap(DNDMood.init(rawValue:))
                case "--today":
                    let f = DateFormatter()
                    f.calendar = OutfitSeason.calendar
                    f.timeZone = .current
                    f.dateFormat = "yyyy-MM-dd"
                    today = it.next().flatMap(f.date(from:)).map { $0.addingTimeInterval(12 * 3600) }   // midday
                default: break
                }
            }
        }

        /// "poke@5,sticker:hug@7.5" → [(poke, nil, 5), (sticker, "hug", 7.5)]
        private static func autoSends(_ s: String?) -> [(kind: Message.Kind, arg: String?, at: TimeInterval)] {
            (s ?? "").split(separator: ",").compactMap { part in
                guard let at = part.lastIndex(of: "@"), let t = TimeInterval(part[part.index(after: at)...]) else { return nil }
                let what = part[..<at]
                let colon = what.firstIndex(of: ":")
                let kind = Message.Kind(rawValue: String(what[..<(colon ?? what.endIndex)]))
                return (kind, colon.map { String(what[what.index(after: $0)...]) }, t)
            }
        }

        /// "1,2.5,4" → [1, 2.5, 4]
        private static func seconds(_ s: String?) -> [TimeInterval] {
            (s ?? "").split(separator: ",").compactMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
        }
    }

    private let options = Options(CommandLine.arguments)
    private lazy var store = ConfigStore(profile: options.profile)
    private lazy var history = HistoryStore(directory: HistoryStore.defaultDirectory(profile: options.profile))
    /// v0.15.2 快捷栏 + send counts, shared by the compose panel and the Settings 「表情」 page (counts are built from history once).
    private lazy var stickerPrefs = StickerPrefsModel(store: store, library: stickers.stickers.map(\.id), scanHistory: { [unowned self] in
        self.role.map { StickerPanel.sendCounts(from: self.history.all(), me: $0) }   // prelaunch-C: nil until a role exists (nothing stored)
    })
    private let sprites = SpriteCatalog(root: resourcesRoot().appendingPathComponent("Sprites"))
    private let stickers = StickerCatalog(root: resourcesRoot().appendingPathComponent("Stickers"))
    private let couples = CoupleCatalog(root: resourcesRoot().appendingPathComponent("Couples"))
    private let reactions = ReactionTable(url: resourcesRoot().appendingPathComponent("reactions.json"))
    private lazy var visits = VisitController(sprites: sprites, couples: couples, bubble: bubble, notice: notice)
    /// v0.5 sounds (Resources/Sounds/sounds.json).
    private lazy var sound = SoundPlayer(root: resourcesRoot().appendingPathComponent("Sounds"),
                                         enabled: store.soundEnabled, volume: store.soundVolume, bgmEnabled: store.bgmEnabled)
    /// `--demo` without a saved config: the database is a placeholder, so nothing real is sent.
    private var usingDummyConfig = false

    private var config: AppConfig?
    private var channel: PairChannel?
    private var statusMenu: StatusMenu!
    private var pet: PetWindow?
    private var petCharacter: Role?
    private var outfit: String?
    private let bubble = BubbleWindow()
    private var compose: ComposeWindow?
    private var settings: SettingsWindow?
    private var whatsNewWindow: WhatsNewWindow?   // v0.13
    /// v0.14 one-click updater (daily check = housekeeping `.updateCheck`).
    private lazy var updater = UpdateController(env: .init(
        store: store, options: options.update,
        petRect: { [weak self] in self?.pet?.spriteScreenRect },
        bubble: bubble, notice: notice,
        bubbleFree: { [weak self] in self.map { $0.pet != nil && !$0.windowsHidden && !$0.dndOn && !$0.holdingForFocus } ?? false },
        menuLine: { [weak self] in self?.statusMenu.setUpdateLine($0) },
        needsArm: { [weak self] in self?.housekeeping.setNeedsArm() },
        terminate: { NSApp.terminate(nil) }))
    /// v0.13: the launch check decided on a card for this many new items; shown when the pet is free.
    private var pendingUpgradeCard: Int?
    private lazy var changelog: [ChangelogEntry] =
        (try? Data(contentsOf: resourcesRoot().appendingPathComponent("changelog.json"))).map(Changelog.parse) ?? []
    private var welcome: WelcomeWindow?   // v0.11
    private let notice = NoticeWindow()
    /// v0.11: the seat-clash notice is up (a "connected" must not dismiss it).
    private var seatClashShown = false
    private var connection: PairChannel.ConnectionState?
    private var partnerOnline: Bool?

    // v0.4 hide / fullscreen / "你不在的时候…"
    private var hide = HideState()
    /// Whether the pet's windows are currently taken off screen (follows `hide.isHidden`).
    private var windowsHidden = false
    /// Wall-clock time a timed hide ends (for the menu).
    private var hideUntilDate: Date?
    /// ⌃⌥L / "显示" while a fullscreen app is in front: show the pet over it until fullscreen ends.
    private var fullscreenOverride = false
    private let fullscreenWatcher = FullscreenWatcher()
    /// Partner messages that arrived while hidden (and whether they came from the channel, i.e. can be
    /// marked read), in arrival order.
    private var awayMessages: [(message: Message, fromChannel: Bool)] = []
    /// Summary of the last "你不在的时候" batch until the「记录」tab has been looked at.
    private var unseenAway: AwaySummary?
    /// v0.6: partner messages that arrived while our pet was over at theirs (shown on the
    /// "在TA那边的时候" card when it is home again), in arrival order.
    private var tripMessages: [(message: Message, fromChannel: Bool)] = []

    // v0.8 勿扰模式 / 省电
    private lazy var dnd = store.dnd
    /// The queued batch (`awayMessages`) holds messages that came in during 勿扰: the card is the 诚意清单.
    private var awayBatchIsDND = false
    // v0.10 partner: while OUR pomodoro focus runs, incoming visits are held like 勿扰 (read from the shared store;
    // PersonalToolsController owns the state).
    private lazy var toolsStore = PersonalToolsStore(defaults: store.defaults)
    private var holdingForFocus: Bool { Visits.isHoldingForFocus(state: toolsStore.pomodoro, now: wallClock) }
    private var awayBatchIsFocus = false
    /// v0.10: partner receipts (「TA 喝啦」) that arrived while our pet was out; shown when it is home again.
    private var unseenAwayTitle = "🍊 你不在的时候"
    private var dndOn: Bool { dnd.isOn(now: wallClock) }
    private let visibility = VisibilityMonitor()
    private lazy var power = PowerMonitor(forceBattery: options.batteryMode)

    private var role: Role? { config?.role }

    // MARK: v0.11 policy helpers (contentPolicy / partnerIdentity live in the v0.11 modes block)
    /// The character the partner draws, for a message `m` that just arrived (the channel has already noted its
    /// `character`); never the seat's name when something better is known.
    private func partnerCharacter(for m: Message? = nil) -> PetCharacter {
        partnerIdentity?.character ?? m?.character ?? (m?.from ?? role?.partner).map(PetCharacter.init) ?? .lumei
    }
    /// My own drawn character as the sprite catalog's key.
    private var myCharacterRole: Role? { config.flatMap { Role(rawValue: $0.myCharacter.rawValue) } }
    // MARK: end v0.11 policy

    /// v0.7 "大小" of everything on this desk (`petScale`; `--scale` overrides it for one run).
    private lazy var petScale: Double = options.scale.map(PetScale.clamp) ?? store.petScale
    /// A size chosen while the home pet is out on a trip / in a meeting: applied once it is back.
    private var pendingHostScale: Double?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Presence: sign off when the Mac sleeps, report back at once when it wakes.
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.channel?.signOffBlocking() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkDNDExpiry(reason: "wake")
                self?.channel?.resumeAfterSignOff()   // v0.17: the sleep sign-off ended the presence loop; restart it
                self?.refreshLocation(userInitiated: false, minGap: 300)   // v0.14.1: the Mac may have moved (no-op unless 「使用我现在的位置」 is on)
                self?.refreshWeather(force: false)   // v0.12: overdue after sleep → fetch now (no-op when nothing needs weather)
            }
        }
        if options.forceDark { NSApp.appearance = NSAppearance(named: .darkAqua) }
        AppMenus.install()   // Edit menu: ⌘C / ⌘V / ⌘A work in text fields
        DockPresence.shared.always = store.showInDock
        if options.selftestReopen { DispatchQueue.main.async { [weak self] in self?.runReopenSelfTest() } }
        if options.selftestPaste { DispatchQueue.main.async { [weak self] in self?.runPasteSelfTest() } }
        statusMenu = StatusMenu()
        statusMenu.onSettings = { [weak self] in self?.openSettings() }
        statusMenu.onChangeOutfit = { [weak self] in self?.changeOutfit() }
        statusMenu.onTogglePin = { [weak self] in self?.togglePin() }
        statusMenu.onOutfitBack = { [weak self] in self?.outfitBack() }
        statusMenu.onChooseOutfit = { [weak self] o in self?.chooseOutfit(o) }
        statusMenu.onGoVisit = { [weak self] in self?.goVisit() }
        statusMenu.onPeek = { [weak self] in self?.peekAtPartner() }   // v0.14.3
        statusMenu.onWhatsNew = { [weak self] in self?.openWhatsNew(page: .updates) }   // v0.13
        statusMenu.onSetupTodos = { [weak self] in self?.openWhatsNew(page: .todos) }
        statusMenu.onPingUpgrade = { [weak self] in self?.pingPartnerToUpgrade() }   // v0.15.5
        statusMenu.onCheckUpdate = { [weak self] in self?.updater.check(manual: true) }   // v0.14
        statusMenu.onUpdateTapped = { [weak self] in self?.updater.updateTapped() }
        statusMenu.onOpen = { [weak self] in
            self?.syncSetupTodoMenu()   // v0.13: recomputed each time the menu opens
            self?.checkDNDExpiry(reason: "menu")
            self?.noteActivity("menu")
        }
        statusMenu.onCompose = { [weak self] in self?.composeShortcut() }
        statusMenu.onHide = { [weak self] option in self?.hidePet(option) }
        statusMenu.onShow = { [weak self] in self?.showPetAgain(reason: "menu") }
        statusMenu.setOutfitChangeEnabled(false)
        statusMenu.setOutfitPinned(false)
        statusMenu.onSoundEnabled = { [weak self] on in self?.setSoundEnabled(on) }
        statusMenu.onSoundVolume = { [weak self] v in self?.setSoundVolume(v) }
        statusMenu.onBGM = { [weak self] on in self?.setBGM(on) }
        refreshSoundMenu()
        statusMenu.onScale = { [weak self] s in self?.setPetScale(s, source: "menu") }
        visits.setPetScale(CGFloat(petScale))
        refreshScaleMenu()
        NSLog("[lulu] pet scale: %.2f (%@)", petScale, options.scale != nil ? "--scale" : "saved or default")

        if let limit = options.visitorMaxStay { visits.visitorMaxStay = limit; NSLog("[lulu] visitor max stay: %.0f s (--visitor-max-stay)", limit) }
        bubble.onDismiss = { [weak self] item in
            if let m = item.message {
                self?.channel?.markRead(m)
                NSLog("[lulu] read: %@ ts %lld (acknowledged)", m.kind.rawValue, m.ts)
            }
            item.alsoRead.forEach { self?.channel?.markRead($0) }
            // All read: the away replay is over (before the visitor's leave sound).
            if self?.bubble.isShowingSomething == false { self?.sound.endAwayOnly() }
            self?.visits.bubbleDismissed()
            self?.somethingEnded()   // a bubble being read holds up a due quiet / doze / rotation
        }
        bubble.onShow = { [weak self] item in
            self?.petMoved()   // v0.12.1: anchor per item (my own bubbles stay on the home pet)
            if case .card = item.content { self?.sound.play(.awaySummary) } else { self?.sound.play(.bubble) }
        }
        visits.onSound = { [weak self] keys, who in
            self?.sound.playFirstAvailable(keys, visitor: who, allowIntimate: self?.contentPolicy.allowsIntimate ?? true)
        }
        // v0.11 friends: the visitor is the partner's character; intimate clips / sounds follow the policy.
        visits.identity = { [weak self] in
            guard let self else { return (nil, .couple) }
            return (self.partnerIdentity?.character, self.contentPolicy)
        }
        visits.onLayoutChanged = { [weak self] in
            self?.applyPendingHostScale()
            self?.petMoved()
            self?.somethingEnded()   // a visit may have held up a due quiet / doze / rotation
        }
        visits.onNoVisitor = { [weak self] e in self?.showOnHomePet(e) }
        // prelaunch-B15: a 喝了 / 等会儿 reply that couldn't ride the return toast (trip reset, bounce, collision)
        // shows as the usual small bubble on the home pet instead of being dropped.
        visits.onToastLost = { [weak self] line in
            guard let self else { return }
            NSLog("[lulu] remind reply: return toast lost, showing at home: %@", line)
            self.bubble.enqueueAtHome(BubbleItem(header: self.partnerCharacter().displayName, content: .text(line), autoHide: 4))
            self.petMoved()
        }
        visits.onHome = { [weak self] in
            self?.playTripCard()
        }
        visits.outfitFor = { [weak self] character in
            guard let self else { return nil }
            return self.pinnedOutfit(for: character).flatMap { self.sprites.outfits(for: character).contains($0) ? $0 : nil }
        }
        visits.configureVisitor = { [weak self] w in
            w.onClick = { [weak w] in w.map { self?.petClicked($0) } }
            w.onCompose = nil   // double-click only opens compose on your OWN pet, not on the visitor
            w.contextMenu = { self?.statusMenu.menu }
            w.onInteraction = { self?.noteActivity("visitor click") }
        }

        // v0.8 勿扰模式
        statusMenu.onDNDStart = { [weak self] d in self?.startDND(d, source: "menu") }
        statusMenu.onDNDMood = { [weak self] m in self?.setDNDMood(m) }
        statusMenu.onDNDOff = { [weak self] in self?.endDND(reason: "menu") }
        checkDNDExpiry(reason: "launch")
        if dndOn { NSLog("[lulu] dnd: still on from before (%@)", dnd.statusLine()) }
        statusMenu.setDND(dnd)
        setUpHousekeeping()   // v0.8.1: one timer for 勿扰 / hide ends, quiet, doze, fidgets, outfit rotation
        tools.onOpenSettings = { [weak self] in
            SettingsWindow.demoToolsPage = true   // the page the window opens on (reset right after)
            self?.openSettings()
            SettingsWindow.demoToolsPage = false
        }
        tools.onOpenPanel = { [weak self] in self?.openCompose(tab: .tools) }
        tools.testSnoozeDelay = options.demoSnoozeDelay
        tools.start(menu: statusMenu)   // v0.10: 🍅 / 提醒 menus, restore the pomodoro, arm the reminders
        // v0.14.4: 「喝了」 on the re-reminder a partner-remind 等会儿 caused → tell TA 「终于做到了」.
        NotificationCenter.default.addObserver(forName: PersonalToolsNotification.didCompleteLate, object: nil, queue: .main) { [weak self] n in
            guard let kind = (n.userInfo?["kind"] as? String).flatMap(ReminderKind.init(rawValue:)), let ackOf = n.userInfo?["ackOf"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self, let role = self.role else { return }
                self.transmit(RemindReply(kind: kind, answer: .now, late: true).message(from: role, ackOf: ackOf))
            }
        }
        tools.onFocusEnded = { [weak self] in DispatchQueue.main.async { self?.releaseFocusHold(reason: "focus ended"); self?.showUpgradeCardIfFree() } }   // after the controller saved the new phase
        housekeeping.setNeedsArm()
        // v0.8 省电
        visibility.onChange = { [weak self] unseen, why in self?.visibilityChanged(unseen, why: why) }
        visibility.start()
        power.onChange = { [weak self] _ in self?.applyPower() }
        power.start()

        registerHotkeys()
        fullscreenWatcher.screen = { [weak self] in
            guard let pet = self?.pet else { return NSScreen.main }
            return NSScreen.screens.first { $0.frame.contains(NSPoint(x: pet.frame.midX, y: pet.frame.minY + 1)) } ?? NSScreen.main
        }
        fullscreenWatcher.onChange = { [weak self] fs in self?.fullscreenChanged(fs) }
        setAutoHideFullscreen(store.autoHideInFullscreen)

        let migrated = store.runMigrations()
        if !migrated.isEmpty { NSLog("[lulu] migrated local data to schema %ld", store.schemaVersion) }
        NSLog("[lulu] history: %ld messages in %@", history.count, history.fileURL.path)

        if let p = options.demoMyPlace { weatherStore.myPlace = p }   // v0.12 --demo-my-place (temp profiles)
        if options.demoMyPlaceAuto { weatherStore.myPlaceAuto = true }   // v0.14.1 (temp profiles)
        // v0.13: was there a saved config before this launch? (old user vs. new user, see `Changelog.plan`)
        let hadConfig = store.load() != nil
        if let seen = options.demoWhatsNewSeen { store.whatsNewSeen = seen }
        var loaded = store.load()
        if loaded?.isComplete != true, options.demo {
            loaded = AppConfig(role: options.role ?? .lulu,
                               pairCode: "ABCDEFGHJKLMNPQRSTUVWXYZ",
                               databaseURL: "https://example-default-rtdb.firebaseio.com",
                               mode: options.demoMode, character: options.demoCharacter)
            usingDummyConfig = true
        }
        // --- v0.11 welcome: only for a config that is not complete AND has no mode (a complete config never sees it)
        if let step = options.demoWelcome {
            WelcomeWindow.demoStep = step
            WelcomeWindow.demoMode = options.demoMode ?? .couple
            openWelcome()
        } else if var cfg = loaded, cfg.isComplete {
            if let r = options.role { cfg.role = r }
            apply(cfg)
        } else if loaded?.mode == nil {
            openWelcome()
        } else {
            openSettings()
        }
        // --- end v0.11 welcome
        planUpgradeCard(hadConfig: hadConfig)
        syncSetupTodoMenu()
        if let page = options.demoWhatsNew {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openWhatsNew(page: page) }
        }
        if let t = options.demoUpdateCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.updater.check(manual: true) }
        }
        if let t = options.demoPingUpgrade {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                NSLog("[lulu] demo: pressing 叫 TA 升级 (status %@)", String(describing: self.upgradePingStatus()))
                if let w = self.whatsNewWindow, w.isVisible { w.model.sendPing() } else { self.pingPartnerToUpgrade() }
            }
        }
        if let t = options.demoUpdateNow {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.updater.updateTapped() }
        }

        if options.demoBubble || options.demoSticker { runDemoBubbles(text: options.demoBubble) }
        if options.demoSleep { pet?.setSleeping(true) }
        if options.demoNotice || options.demoOffline {
            connectionChanged(options.demoNotice ? .misconfigured("数据库地址有误 (HTTP 404)") : .offline)
            if !options.demoCompose, !options.demoSettings {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showNotConnectedNotice() }
            }
        }
        if options.demoSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings() }
        }
        if let (c, t) = options.demoSettingsCharacter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t - 1) { [weak self] in self?.openSettings() }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.settings?.demoPickCharacter(c) }
        }
        if let t = options.demoSeatClash {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.seatClashChanged(true) }
        }
        if options.demoCompose || options.demoSoloCompose {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.openCompose(tab: self?.options.demoComposeTab == "tools" ? .tools : self?.options.demoComposeTab == "history" ? .history : .compose)
            }
        }
        if options.demoPoke, let role {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.receive(.poke(from: role.partner), live: true, fromChannel: false)
            }
        }
        if options.demoVisit || options.demoMerge { runDemoVisit() }
        if let online = options.demoGoOnline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.connectionChanged(.connected)
                self.partnerOnlineChanged(online)
                self.goVisit()
            }
        }
        if let delay = options.demoDismissBubble {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                NSLog("[lulu] demo: dismissing bubbles")
                while self.bubble.isShowingSomething { self.bubble.dismissCurrent() }
            }
        }
        for s in options.autoSend {
            let delay = s.at > 1e12 ? (s.at - Date().timeIntervalSince1970 * 1000) / 1000 : s.at
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
                NSLog("[lulu] auto-send %@%@", s.kind.rawValue, s.arg.map { ":\($0)" } ?? "")
                self?.autoSendNow(s.kind, arg: s.arg)
            }
        }
        for t in options.autovisit {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                NSLog("[lulu] autovisit at %.0f s", t)
                self?.goVisit()
            }
        }
        if options.autotest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in self?.runAutotest() }
        }
        if let delay = options.demoTogglePinAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.togglePin() }
        }
        runV04Demos()
        runV05Demos()
        if let s = options.demoPomodoro { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.tools.demoPomodoro(focusSeconds: s) } }
        for (kind, t) in options.demoReminders { tools.demoReminder(kind, after: t) }
        // Background music (if turned on) once at launch, when the pet is on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.windowsHidden else { return }
            self.sound.playBGMOnce(reason: "launch")
        }
        DemoRecorder.startIfRequested()   // --record DIR (README demo GIFs)
        if let dir = options.snapshotDir {
            if options.snapshotAt.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    DebugSnapshot.capture(into: URL(fileURLWithPath: dir))
                }
            }
            for t in options.snapshotAt {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    DebugSnapshot.capture(into: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "t%05.2f", t)))
                }
            }
        }
    }

    /// Hidden self-test (`--selftest-reopen`, run with an empty profile): Welcome closed with no config must come back
    /// from the menu-bar 设置… and from a Dock click, never as the raw Settings form.
    private func runReopenSelfTest() {
        func state(_ what: String) {
            NSLog("[lulu] selftest reopen: %@ → welcome %@, settings %@, pet %@", what,
                  welcome?.isVisible == true ? "visible" : "hidden", settings?.isVisible == true ? "visible" : "hidden",
                  pet == nil ? "none" : "shown")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            state("launch")
            self.welcome?.close(); state("welcome closed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.statusMenu.onSettings?(); state("menu 设置…")
                self.welcome?.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    guard let self else { return }
                    _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false); state("Dock click")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        // Once more while Welcome is still open: it comes to the front, no second window.
                        _ = self?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true); state("Dock click again")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    /// Dock icon clicked (only visible while Settings is open or with 在程序坞中显示图标 on).
    /// Hidden self-test: ⌘V must reach a focused text field via the (invisible) Edit menu.
    private func runPasteSelfTest() {
        openSettings(force: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let win = self?.settings else { NSLog("[lulu] selftest paste: no settings window"); return }
            func fields(_ v: NSView) -> [NSTextField] {
                var out: [NSTextField] = []
                if let f = v as? NSTextField, f.isEditable { out.append(f) }
                for sub in v.subviews { out += fields(sub) }
                return out
            }
            let editable = win.contentView.map(fields) ?? []
            guard let field = editable.last else { NSLog("[lulu] selftest paste: no editable field"); return }
            field.stringValue = ""
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(field)
            let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                      windowNumber: win.windowNumber, context: nil, characters: "v",
                                      charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: ev) ?? false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let text = (win.firstResponder as? NSText)?.string ?? field.stringValue
                NSLog("[lulu] selftest paste: menu handled=%@ fields=%d pasted=\"%@\"", handled ? "yes" : "no", editable.count, text)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if config == nil { openSettings() }   // → Welcome while there is no mode yet
        else if hide.isHidden { showPetAgain(reason: "dock") }
        else { composeShortcut() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        DemoRecorder.shared?.finish()
        // Tell the partner right away that we're gone (otherwise it takes up to 75 s to notice).
        if !usingDummyConfig { channel?.signOffBlocking() }
        channel?.stop()
        PetNeighbors.unregister()
    }

    // MARK: Config → channel + pet

    private static let stalePokeMs: Int64 = 5 * 60 * 1000
    private var shownMisconfigNotice = false

    private func apply(_ cfg: AppConfig) {
        // v0.11: leaving the seat (solo, or another seat / code): tell the partner right away that this seat is empty.
        if let old = channel, !usingDummyConfig, cfg.effectiveMode == .solo || cfg.role != config?.role || cfg.pairCode != config?.pairCode {
            old.signOffBlocking()
        }
        // prelaunch-B10: what was queued / waiting belongs to the old mode / seat / pair code — never show it under the new one.
        let seatChanged = cfg.effectiveMode != config?.effectiveMode || cfg.role != config?.role || cfg.pairCode != config?.pairCode
        config = cfg
        if seatChanged {
            awayMessages = []
            tripMessages = []
            awayBatchIsDND = false
            awayBatchIsFocus = false
            unseenAway = nil
            statusMenu.setUnseen(0)
        }
        channel?.stop()
        channel = nil
        partnerOnline = nil
        shownMisconfigNotice = false
        seatClashShown = false
        statusMenu.setSeatClash(false)   // prelaunch-B9: the status line must not keep the old seat's clash
        bubble.clearAll()
        notice.dismiss()
        statusMenu.setSolo(cfg.effectiveMode == .solo)
        statusMenu.setPartnerFocus(nil, name: partnerName)
        statusMenu.setPartnerDND(nil)
        statusMenu.setVersionLine(nil)

        if cfg.effectiveMode == .solo {
            // v0.11 一个人: no channel at all; the pet lives on its own.
            connection = nil
            statusMenu.setConnection(nil)
            showPet(for: spriteRole(cfg), seat: cfg.role)
            if let pet { visits.setHost(pet, character: spriteRole(cfg)) }
            tools.syncFocus()
            refreshScaleMenu()
            applyHidden()   // the menu's 隐藏 / 显示 title carries the pet's name
            applyPower()
            applyDND()
            weatherConfigChanged()   // v0.12
            NSLog("[lulu] mode: solo, character %@ (no channel)", cfg.myCharacter.rawValue)
            return
        }

        let ch = PairChannel(config: cfg, store: store, history: history)
        // --- v0.11: heartbeats carry who I am (character / mode / device); a second machine on my seat is noticed
        ch.setIdentity(character: cfg.myCharacter, mode: cfg.effectiveMode, device: store.deviceId)
        // prelaunch-A: every callback below ignores a channel that has been replaced / stopped (`self.channel === ch`).
        ch.onSeatClash = { [weak self, weak ch] clash in
            guard let self, let ch, self.channel === ch else { return }
            self.seatClashChanged(clash)
        }
        ch.setAppVersion(AppVersionSource.current)   // v0.11.2: nil outside a bundle = not published
        ch.onPartnerPresence = { [weak self, weak ch] _ in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            self.evaluateUpgradeNudge()
            self.partnerPlaceMaybeChanged()   // v0.12
            self.refreshComposeWeatherCard()  // v0.15.1 TA's status tag
        }
        ch.onPartnerIdentity = { [weak self, weak ch] id in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            NSLog("[lulu] partner identity: %@ / %@", id.character.rawValue, id.mode.rawValue)
            self.partnerIdentityChanged()
        }
        // --- end v0.11
        if let s = options.seatCheckInterval { ch.seatCheckInterval = s }
        if options.presenceFast {
            ch.heartbeatInterval = 2
            ch.presencePollInterval = 2
            ch.presenceThresholdMs = 6_000
        }
        ch.onMessage = { [weak self, weak ch] m, live in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            self.receive(m, live: live, fromChannel: true)
        }
        ch.onPartnerOnline = { [weak self, weak ch] online in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            self.partnerOnlineChanged(online)
        }
        // prelaunch-A: a message the server refused for good (parked, still in history): tell me once.
        ch.onSendFailed = { [weak self, weak ch] _ in
            guard let self, let ch, self.channel === ch else { return }
            self.pet?.showToast("有一条消息没发出去")
        }
        // prelaunch-A: a backlog of > 50 partner messages was folded (only the newest 50 reach `receive`; the older
        // ones are already in history, marked read) — say so once, they're in 记录.
        ch.onMessagesFolded = { [weak self, weak ch] count in
            guard let self, let ch, self.channel === ch else { return }
            NSLog("[lulu] backlog folded: %ld older message(s) only in history", count)
            self.pet?.showToast("还有 \(count) 条更早的话在「记录」里")
        }
        ch.onPartnerDND = { [weak self, weak ch] d in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            NSLog("[lulu] partner dnd: %@", d.map { DND.partnerStatusLine($0) + " until \($0.untilMs)" } ?? "off")
            self.statusMenu.setPartnerDND(d)
        }
        ch.onPartnerFocus = { [weak self, weak ch] f in
            guard let self, let ch, self.channel === ch else { return }   // prelaunch-A
            NSLog("[lulu] partner focus: %@", f.map { "until \($0.until)" } ?? "off")
            self.statusMenu.setPartnerFocus(f, name: self.partnerName)
        }
        ch.dnd = dnd.status(now: wallClock)
        ch.onConnection = { [weak self, weak ch] state in
            // `--demo-notice` / `--demo-offline` pin a fake state for snapshots.
            guard let self, let ch, self.channel === ch, !self.options.demoNotice, !self.options.demoOffline else { return }
            self.connectionChanged(state)
        }
        ch.setPlace(weatherStore.myPlace)   // v0.12: heartbeats carry my city from the first one
        channel = ch
        refreshPresenceLook()   // v0.14.2: the first heartbeat already carries outfit + pose
        tools.syncFocus()   // v0.10: a focus round in progress goes out with the new channel's heartbeats
        connection = .connecting
        statusMenu.setConnection(.connecting)
        statusMenu.setPartnerOnline(nil)

        // v0.2: the desktop shows your own character; the partner's comes to visit.
        showPet(for: spriteRole(cfg), seat: cfg.role)
        if let pet { visits.setHost(pet, character: spriteRole(cfg), seat: cfg.role) }
        refreshScaleMenu()
        applyPower()
        applyDND()
        if let m = options.demoPartnerDND { statusMenu.setPartnerDND(DNDStatus(mood: m.rawValue, untilMs: 0)) }
        if let minutes = options.demoPartnerFocus {
            statusMenu.setPartnerFocus(FocusStatus(until: nowMs() + Int64(minutes * 60_000)), name: partnerName)
        }
        weatherConfigChanged()   // v0.12
        ch.start()
    }

    // MARK: v0.12 weather: city picker + compose line (Task 2)

    /// City search for the picker: Open-Meteo, or `FakeWeather.places` filtered by the query with `--fake-weather`.
    /// v0.13.1: open the Open-Meteo connection while the city picker is coming up, so the first search is quick.
    private func warmUpCitySearch() {
        guard !options.fakeWeather else { return }
        Task.detached(priority: .utility) { await WeatherClient().warmUp() }
    }

    var citySearch: CitySearch {
        if options.fakeWeather {
            return { q in
                let q = q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return FakeWeather.places.filter { p in [p.name, p.admin ?? "", p.country ?? ""].contains { $0.lowercased().contains(q) } }
            }
        }
        return { q in try await WeatherClient().search(q) }
    }

    /// I picked (or cleared) my city by hand: save it (this turns 「使用我现在的位置」 off), tell TA with the next heartbeat, fetch.
    func setMyPlace(_ place: WeatherPlace?) {
        weatherStore.myPlaceAuto = false
        cityModel.auto = false
        cityModel.status = .idle
        storeMyPlace(place)
    }

    private func storeMyPlace(_ place: WeatherPlace?) {
        weatherStore.myPlace = place
        cityModel.place = place
        channel?.setPlace(weatherStore.myPlace)   // prelaunch-C (S5): the store's copy is flagged coarse while auto-located
        NSLog("[lulu] weather: my city → %@%@", place?.name ?? "none", weatherStore.myPlaceAuto ? " (located)" : "")
        refreshWeather(force: true)
        housekeeping.setNeedsArm()
    }

    // MARK: v0.14.1 「使用我现在的位置」
    /// Shared with the Settings 我的城市 section (a located city shows up there while it is open).
    lazy var cityModel: CityModel = {
        let m = CityModel()
        m.place = weatherStore.myPlace
        m.auto = weatherStore.myPlaceAuto
        m.status = options.demoLocationStatus ?? .idle
        return m
    }()
    private lazy var locationProvider = LocationProvider()
    private var locating = false
    private var locationLastAttempt: TimeInterval?

    /// The Settings toggle. On: ask for permission (the one place the system prompt may appear) and look up the city;
    /// denied / failed → the toggle goes back off and the manual city stays. Off: just stop (the city stays as it is).
    func setAutoLocation(_ on: Bool) {
        weatherStore.myPlaceAuto = on
        cityModel.auto = on
        cityModel.status = .idle
        NSLog("[lulu] location: auto %@", on ? "on" : "off")
        if on { refreshLocation(userInitiated: true) }
        housekeeping.setNeedsArm()
    }

    /// One look-up: location → (moved > 3 km, or asked by hand) city name → my city. Never prompts unless `userInitiated`.
    /// `minGap`: skip when the last look-up was less than that many seconds ago.
    func refreshLocation(userInitiated: Bool, minGap: TimeInterval = 0) {
        guard weatherStore.myPlaceAuto, !locating else { return }
        let now = wallClock
        if let last = locationLastAttempt, now >= last, now - last < minGap { return }
        locating = true
        locationLastAttempt = now
        if userInitiated { cityModel.status = .locating }
        let fix: (Result<CLLocation, LocationFailure>) -> Void = { [weak self] result in
            guard let self else { return }
            Task { @MainActor in await self.locationArrived(result, userInitiated: userInitiated) }
        }
        switch options.fakeLocation {
        case nil: locationProvider.locate(prompt: userInitiated, completion: fix)
        case "denied": fix(.failure(.denied))
        case "fail": fix(.failure(.unavailable))
        default: fix(.success(CLLocation(latitude: 37.8716, longitude: -122.2727)))
        }
    }

    private func locationArrived(_ result: Result<CLLocation, LocationFailure>, userInitiated: Bool) async {
        defer { locating = false; housekeeping.setNeedsArm() }
        guard weatherStore.myPlaceAuto else { return }   // switched off meanwhile
        func fail(_ status: LocationStatus) {
            cityModel.status = status
            NSLog("[lulu] location: %@", status == .denied ? "denied" : "no fix")
            if userInitiated { weatherStore.myPlaceAuto = false; cityModel.auto = false }   // the toggle did not take
        }
        guard case .success(let loc) = result else {
            if case .failure(let why) = result { fail(why == .denied ? .denied : .failed) }
            return
        }
        cityModel.status = .idle
        let c = loc.coordinate
        guard userInitiated || LocationRules.needsGeocode(current: weatherStore.myPlace, latitude: c.latitude, longitude: c.longitude) else {
            NSLog("[lulu] location: still within %.0f km of %@", LocationRules.moveKm, weatherStore.myPlace?.name ?? "?")
            return
        }
        let place: WeatherPlace?
        if options.fakeLocation != nil {
            place = WeatherPlace(name: "伯克利", admin: "加利福尼亚", country: "美国", latitude: c.latitude, longitude: c.longitude, timezone: "America/Los_Angeles")
        } else {
            place = await PlaceGeocoder.place(for: loc)
        }
        guard weatherStore.myPlaceAuto else { return }
        guard let place else { fail(.failed); return }
        if place != weatherStore.myPlace { storeMyPlace(place) }
    }

    /// 系统设置 → 隐私与安全性 → 定位服务.
    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") { NSWorkspace.shared.open(url) }
    }
    // MARK: end v0.14.1 location

    /// v0.13.3 the weather card at the top of the compose panel: TA's row first (paired, once TA's city is known), then
    /// mine; solo only mine. No city of mine → the 「设置我的城市」 link.
    /// v0.15.3 the compose panel's ⚙︎ by 「快捷栏」: Settings opened on the 「表情」 page.
    private func openStickerSettings() {
        SettingsWindow.demoStickersPage = true   // the page the window opens on (reset right after)
        openSettings()
        SettingsWindow.demoStickersPage = false
    }

    private func refreshComposeWeatherCard() {
        if let compose, compose.isVisible { compose.setWeatherCard(composeWeatherCard()) }
    }

    private func composeWeatherCard() -> WeatherCardData {
        var rows: [WeatherRow] = []
        if !isSolo, let channel {
            // v0.15.1: TA's row is there even without TA's city — it carries TA's online / 勿扰 / 专注 tag.
            let theirChar = Role(rawValue: partnerCharacter().rawValue)
            let p = channel.partnerPresence
            let status = PartnerStatus(online: partnerOnline, neverSeen: channel.partnerNeverSeen, lastSeenMs: p?.lastSeen,
                                       dnd: p?.dnd, focus: channel.partnerFocus)
            rows.append(WeatherRow(id: "ta", label: "TA", avatar: theirChar.flatMap(avatar(for:)), emoji: "💛",
                                   place: weather.partnerPlace, snapshot: weather.partner, status: status))
        }
        if let place = weatherStore.myPlace {
            rows.append(WeatherRow(id: "me", label: "我", avatar: myCharacterRole.flatMap(avatar(for:)), emoji: "🍊", place: place, snapshot: weather.mine))
        }
        return WeatherCardData(rows: rows, hasMyCity: weatherStore.myPlace != nil)
    }
    // MARK: end v0.12 weather: city picker + compose line

    // MARK: v0.11 modes: who is who, welcome, seat clash

    /// The character I draw, as the `Role`-typed key the sprite / outfit catalogs use (same raw values).
    private func spriteRole(_ cfg: AppConfig) -> Role { Role(rawValue: cfg.myCharacter.rawValue) ?? cfg.role }

    var isSolo: Bool { config?.effectiveMode == .solo }
    private var myName: String { (config?.myCharacter ?? options.demoCharacter ?? .lulu).displayName }
    /// The partner's character name (presence → their last message → their seat's namesake); "TA" in solo.
    private var partnerName: String {
        guard let config, config.effectiveMode != .solo else { return "TA" }
        return (partnerIdentity?.character ?? PetCharacter(config.role.partner)).displayName
    }

    /// nil in solo (or before a config exists). One source for the content policy and the partner's name.
    var partnerIdentity: PartnerIdentity? {
        guard let config, config.effectiveMode != .solo else { return nil }
        return channel?.partnerIdentity
            ?? PartnerIdentity.resolve(partnerSeat: config.role.partner, presence: nil, lastMessageCharacter: nil)
    }

    /// What may be shown with this partner (stickers, couple clips, sounds): `ContentPolicy` from my config
    /// and the partner's identity. Before a config exists: the couple default.
    var contentPolicy: ContentPolicy {
        guard let config else { return .couple }
        return ContentPolicy(myMode: config.effectiveMode, partnerMode: partnerIdentity?.mode,
                             me: config.myCharacter, partner: partnerIdentity?.character)
    }

    // MARK: v0.13 更新日志 + 待设置

    /// The to-dos right now (pure rules in `SetupTodos`; recomputed from the live state every time).
    private func setupTodoList() -> [SetupTodo] {
        let paired = config.map { $0.effectiveMode != .solo } ?? false
        var older = options.demoWhatsNewHelp
        if paired, partnerOnline == true,
           case .partnerOlder = UpgradeNudge.evaluate(mine: AppVersionSource.current, partner: channel?.partnerPresence?.app, lastNudged: nil) {
            older = true
        }
        let ts = toolsStore.settings
        return SetupTodos.compute(hasCity: weatherStore.myPlace != nil,
                                  waterOn: ts.waterEnabled, standOn: ts.standEnabled,
                                  paired: paired || options.demoWhatsNewHelp, partnerOlder: older, dismissed: store.setupTodoDismissed)
    }

    private func syncSetupTodoMenu() { statusMenu.setSetupTodoCount(setupTodoList().count) }

    /// Launch check (`Changelog.plan`): new user → record silently; upgraded user → remember to show the card.
    private func planUpgradeCard(hadConfig: Bool) {
        guard let current = AppVersionSource.current else { return }   // swift run: no version, no card
        let plan = Changelog.plan(seen: store.whatsNewSeen, hadConfig: hadConfig, current: current, in: changelog)
        NSLog("[lulu] whatsnew: seen %@, current %@, hadConfig %@ → %@", store.whatsNewSeen ?? "nil", current, hadConfig ? "yes" : "no", String(describing: plan))
        switch plan {
        case .none: break
        case .markSeen: store.whatsNewSeen = current
        case .card(let n):
            pendingUpgradeCard = n
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.showUpgradeCardIfFree() }
        }
    }

    /// The「升级到 vX 啦」card from my own pet, once the pet is on screen and nothing (hidden / 勿扰 / focus round)
    /// holds bubbles back; retried whenever one of those ends. Dismissing it or 「看看」 records the version.
    private func showUpgradeCardIfFree() {
        defer { updater.showCardIfFree() }   // v0.14: a found update waits for the same moments
        guard let n = pendingUpgradeCard, let current = AppVersionSource.current, pet != nil,
              !windowsHidden, !dndOn, !holdingForFocus else { return }
        pendingUpgradeCard = nil
        let todos = setupTodoList().count
        NSLog("[lulu] whatsnew: upgrade card (%ld item(s), %ld to-do(s))", n, todos)
        bubble.enqueueAtHome(BubbleItem(
            header: "🆕 新版本", content: .text(Changelog.cardText(current: current, newItems: n, todos: todos)), message: nil,
            buttons: [BubbleButton(title: "看看", action: { [weak self] in self?.openWhatsNew(page: .updates) })],
            onClose: { [weak self] in self?.store.whatsNewSeen = current }))
    }

    private func openWhatsNew(page: WhatsNewModel.Page) {
        if let w = whatsNewWindow, w.isVisible { w.show(page: page); return }
        let current = AppVersionSource.current
        let curVersion = AppVersion(current)
        let model = WhatsNewModel(
            entries: changelog.filter { e in curVersion.map { v in AppVersion(e.version).map { $0 <= v } ?? false } ?? true },
            seen: store.whatsNewSeen, current: current, page: page, todos: setupTodoList(),
            reload: { [weak self] in self?.setupTodoList() ?? [] },
            perform: { [weak self] todo in self?.performSetupTodo(todo) },
            dismiss: { [weak self] id in
                guard let self else { return }
                self.store.setupTodoDismissed.insert(id)
                NSLog("[lulu] whatsnew: to-do %@ dismissed", id)
            })
        model.showUpgradeHelp = options.demoWhatsNewHelp
        model.pingStatusProvider = { [weak self] in self?.upgradePingStatus() ?? .unavailable }   // v0.15.5
        model.ping = { [weak self] in self?.pingPartnerToUpgrade() }
        model.pingStatus = model.pingStatusProvider()
        model.checkUpdate = { [weak self] report in self?.updater.check(manual: true, report: report) }   // v0.14
        model.onTodosChanged = { [weak self] todos in self?.statusMenu.setSetupTodoCount(todos.count) }
        if let current { store.whatsNewSeen = current }   // opening the log = seen (the 「新」 badges use the value from before)
        let w = WhatsNewWindow(model: model)
        whatsNewWindow = w
        w.show(page: page)
        NSLog("[lulu] whatsnew: window opened on %@ (%ld entries, %ld to-dos)", page.rawValue, model.entries.count, model.todos.count)
    }

    private func performSetupTodo(_ todo: SetupTodo) {
        NSLog("[lulu] whatsnew: to-do %@ → %@", todo.id, todo.action.rawValue)
        switch todo.action {
        case .openSettingsCity: openSettings()   // 通用 page: 我的城市
        case .openToolsTab: openCompose(tab: .tools)   // same path as「这是什么？」
        case .howToUpgradePartner: break   // unfolded inside the window
        }
    }

    // MARK: v0.11.2 upgrade nudge

    /// The partner's version I last showed in a bubble that is still waiting / showing (never queue it twice).
    private var upgradeBubbleQueued: String?

    /// Paired modes only, and only while the partner is online-ish (their presence is fresh): the menu line follows the
    /// version comparison; the bubble appears once per new partner version, when the pet is free (not hidden /
    /// fullscreen / 勿扰 / our own focus round). Re-evaluated on every partner presence read, which also retries a
    /// deferred bubble.
    private func evaluateUpgradeNudge() {
        // v0.15.5: an open 更新日志 window follows the partner's version / my ping state.
        defer { if let w = whatsNewWindow, w.isVisible { w.model.refresh() } }
        guard let config, config.effectiveMode != .solo, let channel, partnerOnline == true else {
            statusMenu.setVersionLine(nil)
            return
        }
        let mine = AppVersionSource.current
        let nudge = UpgradeNudge.evaluate(mine: mine, partner: channel.partnerPresence?.app, lastNudged: store.upgradeNudgedFor)
        switch nudge {
        case .none:
            statusMenu.setVersionLine(nil)
        case .partnerOlder(let v):
            // v0.15.5: clickable while I can still ping for this version; afterwards a plain line.
            if UpgradePing.canPing(mine: mine, partner: v, sent: store.upgradePingSent) {
                statusMenu.setVersionLine("TA 还在用 v\(v) · 📣 叫 TA 升级", pingable: true)
            } else {
                statusMenu.setVersionLine("TA 还在用 v\(v)")
            }
        case .partnerNewer(let v, let shouldBubble):
            statusMenu.setVersionLine("有新版本 v\(v)（TA 已升级）")
            guard shouldBubble, upgradeBubbleQueued != v, !hide.isHidden, !dndOn, !holdingForFocus else { return }
            upgradeBubbleQueued = v
            // Once per partner version: persisted when the bubble is actually shown (B17: not while it waits in the queue,
            // else quitting before it showed would lose the nudge for good).
            NSLog("[lulu] upgrade nudge: partner is on v%@, mine v%@ — bubble", v, mine ?? "?")
            bubble.enqueueAtHome(BubbleItem(header: partnerName, content: .text("\(partnerName)已经升级到 v\(v) 啦，你也升级一下吧～点「一键更新」就行"),
                                      message: nil,
                                      buttons: [BubbleButton(title: "一键更新", action: { [weak self] in self?.updater.updateTapped() }),   // v0.14
                                                BubbleButton(title: "知道啦", action: {})],
                                      onShown: { [weak self] in self?.store.upgradeNudgedFor = v }))
        }
    }

    // MARK: v0.15.5 叫 TA 升级

    private func upgradePingStatus() -> WhatsNewModel.PingStatus {
        guard let config, config.effectiveMode != .solo, partnerOnline == true else { return .unavailable }
        let mine = AppVersionSource.current
        let partner = channel?.partnerPresence?.app
        if UpgradePing.alreadySent(mine: mine, sent: store.upgradePingSent) {
            return AppVersion(partner).map { p in AppVersion(mine).map { p < $0 } ?? false } == true ? .sent : .unavailable
        }
        return UpgradePing.canPing(mine: mine, partner: partner, sent: store.upgradePingSent) ? .ready : .unavailable
    }

    /// Once per my version: a normal text message + `upgradeTo`, sent like any text (queues when TA is offline).
    private func pingPartnerToUpgrade() {
        guard let role, !isSolo, let mine = AppVersionSource.current,
              UpgradePing.canPing(mine: mine, partner: channel?.partnerPresence?.app, sent: store.upgradePingSent),
              let ping = UpgradePing.message(from: role, version: mine) else { return }
        store.upgradePingSent = mine
        NSLog("[lulu] upgrade ping: v%@ → partner on v%@", mine, channel?.partnerPresence?.app ?? "?")
        send(ping)
        pet?.showToast("已经叫 TA 升级啦")
        evaluateUpgradeNudge()   // the menu line stops being clickable
    }

    private func partnerIdentityChanged() {
        statusMenu.setPartnerFocus(channel?.partnerFocus, name: partnerName)
    }

    private func seatClashChanged(_ clash: Bool) {
        NSLog("[lulu] seat clash: %@", clash ? "another device is on my seat" : "resolved")
        statusMenu.setSeatClash(clash)   // stays in the menu even if the notice is clicked away
        // The channel only reports a change after two consecutive reads (`SeatClashMonitor`), so this does not flap:
        // show the notice on a clash, take it down again when it is resolved.
        if !clash {
            if seatClashShown { seatClashShown = false; notice.dismiss() }
            return
        }
        guard !seatClashShown, let pet else { return }
        seatClashShown = true
        notice.show(title: "座位冲突了", body: SeatClash.message,
                    actionTitle: "去设置", action: { [weak self] in self?.openSettings() },
                    beside: pet.spriteScreenRect)
    }

    private func openWelcome() {
        if let welcome, welcome.isVisible { welcome.show(); return }
        warmUpCitySearch()
        let w = WelcomeWindow(sprites: sprites, defaultRole: options.role ?? .lulu, citySearch: citySearch)
        w.onPlaceChosen = { [weak self] place in self?.setMyPlace(place) }   // v0.12: before apply, which reads the store
        w.onFinish = { [weak self] cfg in
            guard let self else { return }
            NSLog("[lulu] welcome: mode %@, character %@", cfg.effectiveMode.rawValue, cfg.myCharacter.rawValue)
            self.store.save(cfg)
            self.store.setupTodoDismissed.formUnion([SetupTodos.cityID, SetupTodos.remindersID])   // v0.13: the welcome flow already asked
            self.apply(cfg)
        }
        welcome = w
        w.show()
    }

    /// Couple: 我的角色 is the seat, so changing it moves me to the other seat and TA (still on the old seats) no
    /// longer reaches me until they switch too. Returns whether to go ahead.
    private func confirmSeatMove(to character: PetCharacter) -> Bool {
        if let answer = options.seatConfirm {
            NSLog("[lulu] seat move confirm → %@ (auto: %@)", character.rawValue, answer ? "accept" : "cancel")
            return answer
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "换成\(character.displayName)？"
        alert.informativeText = "情侣模式下，角色就是你的座位。换了之后，TA 也要在设置里换成\(character.other.displayName)，不然两边会对不上，收不到彼此的消息。"
        alert.addButton(withTitle: "换，我会告诉TA")
        alert.addButton(withTitle: "取消")
        alert.window.appearance = NSAppearance(named: .aqua)
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Settings: the 模式 / 角色 picker changed and the config is usable: save and re-apply.
    private func applyModeChange(_ cfg: AppConfig) {
        guard cfg != config else { return }
        NSLog("[lulu] mode change: %@ / %@ (seat %@)", cfg.effectiveMode.rawValue, cfg.myCharacter.rawValue, cfg.role.rawValue)
        store.save(cfg)
        apply(cfg)
    }

    private func connectionChanged(_ state: PairChannel.ConnectionState) {
        NSLog("[lulu] connection: %@", String(describing: state))
        connection = state
        statusMenu.setConnection(state)
        switch state {
        case .misconfigured:
            // Explain once, softly, next to the pet (never pop Settings by itself). The dummy
            // `--demo` database is always misconfigured, so stay quiet there.
            if !shownMisconfigNotice, !options.demo {
                shownMisconfigNotice = true
                showNotConnectedNotice()
            }
        case .connected:
            if !seatClashShown { notice.dismiss() }
        default:
            break
        }
    }

    /// "Can't reach the partner" notice for the current state; nil state = nothing to explain.
    private func showNotConnectedNotice() {
        guard let pet else { return }
        switch connection {
        case .misconfigured(let reason)?:
            notice.show(title: "还没和TA连上哦",
                        body: "\(reason)\n请在设置里检查 配对码 和 数据库地址（两个人要填一样的）",
                        actionTitle: "去设置", action: { [weak self] in self?.openSettings() },
                        beside: pet.spriteScreenRect)
        case .offline?, .connecting?:
            notice.show(title: nil, body: "网络不太好，消息会在连上后自动送达 ✉️",
                        autoHide: 3, beside: pet.spriteScreenRect)
        case .connected?, nil:
            break
        }
    }

    private func showPet(for character: Role, seat: Role) {
        if pet == nil {
            let w = PetWindow(defaults: store.defaults)
            w.onClick = { [weak self, weak w] in w.map { self?.petClicked($0) } }
            w.onCompose = { [weak self] in self?.openCompose() }
            w.onMoved = { [weak self] in self?.petMoved() }
            w.onDragEnded = { [weak self] origin in self?.visits.homeDragEnded(from: origin) ?? false }
            w.contextMenu = { [weak self] in self?.statusMenu.menu }
            w.onInteraction = { [weak self] in self?.noteActivity("pet click") }
            w.onScaleChosen = { [weak self] s in self?.scaleChosenByHandle(s) }
            w.forceResizeHandle = options.demoResizeHandle
            w.setPetScale(CGFloat(petScale))
            w.onHover = { [weak self] in self?.quietActivity("hover"); self?.scheduleThinkHover() }
            pet = w
            visibility.watch(w)
        }
        guard let pet else { return }
        pet.defaultSlot = seat == .lumei ? 0 : 1   // v0.11: by seat (the character may be either)
        if petCharacter != character || outfit == nil {
            let all = sprites.outfits(for: character), seasons = sprites.seasons(for: character)
            let saved = pinnedOutfit(for: character)
            let pinned = OutfitRules.resolvePin(saved, outfits: all, seasons: seasons, on: today)
            if let saved, let pinned, saved != pinned {
                // e.g. v0.4's 噜妹 "bow" (removed in v0.5): keep the pet pinned, to the preferred outfit.
                NSLog("[lulu] pinned outfit %@ no longer exists: pinned %@ instead", saved, pinned)
                setPinnedOutfit(pinned, for: character)
            }
            let forced = options.outfit.flatMap { all.contains($0) ? $0 : nil }
            guard let o = forced ?? pinned ?? OutfitRules.launchOutfit(all, seasons: seasons, on: today) else {
                NSLog("LuluPet: no sprites for %@ under %@", character.rawValue, sprites.root.path)
                return
            }
            petCharacter = character
            outfit = o
            pet.setCharacter(sprites, character: character, outfit: o)
            refreshPresenceLook()
            let why = forced != nil ? "--outfit" : pinned != nil ? "pinned"
                : OutfitRules.isInSeason(o, seasons: seasons, on: today) ? "in season" : "preferred"
            NSLog("[lulu] outfit: %@ (launch, %@; %ld outfits, %ld wearable today)", o, why, all.count,
                  OutfitRules.eligible(all, seasons: seasons, on: today).count)
            refreshOutfitMenu()
            scheduleOutfitRotation()
        }
        pet.setSleeping(false)
        if windowsHidden {
            pet.orderOut(nil)
        } else {
            pet.orderFrontRegardless()
            pet.didAppear()
        }
        petMoved()
        startIdleBehaviour()
    }

    // MARK: Idle behaviour (v0.3): random fidgets, doze after a long time without interaction

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private lazy var dozeClock = DozeClock(threshold: options.dozeSeconds ?? IdleRules.dozeAfter, now: uptime)
    /// v0.8 省电 quiet mode: after `IdleRules.quietAfter` without interaction the pet holds a still frame.
    private lazy var quietClock = DozeClock(threshold: options.quietSeconds ?? IdleRules.quietAfter, now: uptime)
    private var quietMode = false
    /// v0.10: a pomodoro focus round also holds the still `quiet` frame (and no fidgets).
    private var restQuiet: Bool { quietMode || tools.isFocusing }
    /// v0.10 personal tools: pomodoro + water / stand reminders (all timing rides on the housekeeping timer).
    private lazy var tools = PersonalToolsController(
        store: PersonalToolsStore(defaults: store.defaults),
        env: .init(pet: { [weak self] in self?.pet }, channel: { [weak self] in self?.channel },
                   character: { [weak self] in self?.role }, bubble: bubble, sound: sound,
                   blocked: { [weak self] in self.map { $0.windowsHidden || $0.dndOn } ?? true },
                   restChanged: { [weak self] in self?.applyRestPose() },
                   needsArm: { [weak self] in self?.housekeeping.setNeedsArm() }))

    // v0.8.1 省电: one housekeeping timer for every deadline below (see `HousekeepingScheduler`).
    private let housekeeping = HousekeepingScheduler()
    /// Monotonic (uptime) deadlines; nil = not armed.
    private var quietDue: TimeInterval?
    private var dozeDue: TimeInterval?
    private var fidgetDue: TimeInterval?
    private var rotationDue: TimeInterval?
    /// A rotation came due while hidden: it runs shortly after the pet is shown again (no polling meanwhile).
    private var rotationDeferred = false
    /// Due jobs that found the pet busy, and how many retries in a row (`Housekeeping.blockedRetry`).
    private var blockedTasks: Set<HousekeepingTask> = []
    private var blockedStreak = 0

    private func setUpHousekeeping() {
        housekeeping.deadlines = { [weak self] in self?.housekeepingDeadlines() ?? HousekeepingDeadlines() }
        housekeeping.run = { [weak self] task in self?.runHousekeeping(task) }
    }

    private func housekeepingDeadlines() -> HousekeepingDeadlines {
        var armed = false
        if let pet {
            let pose = RestPose.pick(dozing: pet.isDozing, quiet: restQuiet, dnd: dndOn)
            armed = Housekeeping.fidgetsArmed(pose: pose, hidden: windowsHidden, paused: SpritePlayer.paused)
        }
        fidgetDue = Housekeeping.fidgetDeadline(current: fidgetDue, armed: armed, now: uptime,
                                                delay: IdleRules.fidgetDelay(fixed: options.fidgetSeconds, unit: Double.random(in: 0...1)))
        let dndEnd = dnd.endDeadline // prelaunch-B1: not gated on dndOn (false once the end passes -> timer never fired)
        let hideEnd = hide.manual ? hide.until : nil
        var d = HousekeepingDeadlines(quiet: quietDue, doze: dozeDue, rotation: rotationDue, fidget: fidgetDue,
                                      dndEnd: dndEnd, hideEnd: hideEnd)
        tools.fill(&d)   // v0.10 pomodoro / water / stand
        d.weather = weatherDeadline()   // v0.12
        d.updateCheck = updater.deadline()   // v0.14
        d.location = LocationRules.deadline(auto: weatherStore.myPlaceAuto && !locating, last: locationLastAttempt, now: wallClock)   // v0.14.1
        return d
    }

    private func runHousekeeping(_ task: HousekeepingTask) {
        switch task {
        case .quiet: quietDue = nil; quietCheck()
        case .doze: dozeDue = nil; dozeCheck()
        case .fidget: fidgetDue = nil; fidgetNow()
        case .rotation: rotationDue = nil; rotateOutfit()
        case .dndEnd: checkDNDExpiry(reason: "timer")
        case .hideEnd: hideTimeUp()
        case .pomodoro, .water, .stand: tools.run(task)   // v0.10
        case .weather: refreshWeather(force: true)   // v0.12: the job only exists (and is only due) when weather is needed
        case .updateCheck: updater.runAuto()   // v0.14: the daily update check
        case .location: refreshLocation(userInitiated: false)   // v0.14.1: 3 h after the last look-up, only while auto-location is on
        }
    }

    /// A due job found the pet busy: try again soon (backing off while it stays busy).
    private func retryWhenFree(_ task: HousekeepingTask) -> TimeInterval {
        blockedTasks.insert(task)
        blockedStreak += 1
        return uptime + Housekeeping.blockedRetry(attempt: blockedStreak)
    }

    /// Whatever blocked a due job may be over (bubble read, visit over, interaction): retry within `IdleRules.retry`.
    private func somethingEnded() {
        releaseFocusHold(reason: "something ended")
        blockedStreak = 0
        guard !blockedTasks.isEmpty else { return }
        let soon = uptime + IdleRules.retry
        for t in blockedTasks {
            switch t {
            case .quiet: quietDue = quietDue.map { min($0, soon) }
            case .doze: dozeDue = dozeDue.map { min($0, soon) }
            case .rotation: rotationDue = rotationDue.map { min($0, soon) }
            default: break
            }
        }
        blockedTasks = []
        housekeeping.setNeedsArm()
    }

    /// Something is going on with the home pet: no doze, no fidget right now.
    private var homePetBusy: Bool {
        guard let pet else { return true }
        return pet.isBusy || pet.isDragging || pet.inputLocked || visits.isActive
            || bubble.isOnScreen || compose?.isVisible == true   // B11: a suspended bubble isn't visible
    }

    // MARK: v0.12 weather (shared)
    lazy var weatherStore = WeatherStore(defaults: store.defaults)
    var weather = WeatherState()
    /// Fetches my city's weather and (paired) TA's, at most 2 requests; `force` skips the 30-minute due check (a city
    /// changed, the housekeeping job fired). Does nothing without my city. `--fake-weather`: fixed data, no network.
    func refreshWeather(force: Bool) {
        let now = wallClock
        let mine = weatherStore.myPlace
        let theirs = currentPartnerPlace()
        var changed = false
        if mine != weatherTrackedMine {
            weatherTrackedMine = mine
            weather.mine = mine.flatMap { weatherStore.cached(for: $0) }
            weatherLastAttempt = nil
            changed = true
        }
        if theirs != weather.partnerPlace {
            weather.partnerPlace = theirs
            weather.partner = theirs.flatMap { weatherStore.cached(for: $0) }
            weatherLastAttempt = nil
            changed = true
        }
        if changed { weatherDidChange() }
        guard let mine else { return }
        if weatherFetching {
            // A city changed (or a forced refresh came) while a fetch runs: fetch again once it is done, so a
            // partner city that arrives a moment after launch isn't left without weather for 30 minutes.
            if changed || force { weatherRefetchPending = true }
            return
        }
        if !force {
            guard weatherNeeded, WeatherRefresh.isDue(last: weatherLastRefresh(), now: now) else { return }
        }
        weatherLastAttempt = now   // a failure waits the full interval too
        if options.fakeWeather {
            takeWeather(mine: FakeWeather.snapshot(for: mine, now: now), partner: theirs.map { FakeWeather.snapshot(for: $0, now: now) },
                        mineAt: mine, partnerAt: theirs)
            return
        }
        weatherFetching = true
        let client = WeatherClient()
        NSLog("[lulu] weather: fetching %@%@", mine.name, theirs.map { " + \($0.name)" } ?? "")
        let store = weatherStore
        let ua = NWSClient.userAgent(version: AppVersionSource.current)
        Task { @MainActor [weak self] in
            // v0.14.1: US places use a nearby station's observation (NWS), everything else (and any failure) Open-Meteo
            let m = try? await client.currentBest(for: mine, store: store, userAgent: ua)
            var t: (snapshot: WeatherSnapshot, source: String)?
            if let theirs { t = try? await client.currentBest(for: theirs, store: store, userAgent: ua) }
            NSLog("[lulu] weather: %@ ← %@%@", mine.name, m?.source ?? "failed", theirs.map { ", \($0.name) ← \(t?.source ?? "failed")" } ?? "")
            guard let self else { return }
            self.weatherFetching = false
            self.weatherLastAttempt = self.wallClock
            if m == nil { NSLog("[lulu] weather: no data for %@ (keeping the last result)", mine.name) }
            self.takeWeather(mine: m?.snapshot, partner: t?.snapshot, mineAt: mine, partnerAt: theirs)
            if self.weatherRefetchPending {
                self.weatherRefetchPending = false
                if self.weatherStore.myPlace != mine || self.weather.partnerPlace != theirs { self.refreshWeather(force: true) }
            }
        }
    }

    /// Stores a fetch result; one for a city that has been changed meanwhile is dropped.
    private func takeWeather(mine m: WeatherSnapshot?, partner t: WeatherSnapshot?, mineAt: WeatherPlace, partnerAt: WeatherPlace?) {
        if mineAt == weatherStore.myPlace, let m {
            weather.mine = m
            weatherStore.setCached(m, for: mineAt)
        }
        if let partnerAt, partnerAt == weather.partnerPlace, let t {
            weather.partner = t
            weatherStore.setCached(t, for: partnerAt)
        }
        weatherDidChange()
    }
    // MARK: end v0.12 weather (shared)

    // MARK: v0.12 weather looks (Task 3)
    private var weatherFetching = false
    private var weatherRefetchPending = false
    private var weatherLastAttempt: TimeInterval?
    private var weatherTrackedMine: WeatherPlace?
    private var weatherLoggedLook: WeatherLook??
    private var weatherAvatars: [String: NSImage] = [:]

    /// TA's city (their presence), or with `--fake-weather` and none published 上海, so paired snapshots have a second row.
    private func currentPartnerPlace() -> WeatherPlace? {
        guard !isSolo, config != nil else { return nil }
        return channel?.partnerPresence?.place ?? options.demoPartnerPlace ?? (options.fakeWeather ? FakeWeather.places[1] : nil)
    }

    /// Something shows weather: an open compose panel, a character with weather clips, or (paired) TA's city for the 想 TA bubble.
    private var weatherNeeded: Bool {
        WeatherPlan.needsRefresh(hasPlace: weatherStore.myPlace != nil, partnerHasPlace: weather.partnerPlace != nil || currentPartnerPlace() != nil,
                                 composeOpen: compose?.isVisible == true, hasClips: pet?.hasWeatherClips == true)
    }

    private func weatherLastRefresh() -> TimeInterval? {
        WeatherPlan.lastRefresh(fetchedAt: [weather.mine?.fetchedAt] + (weather.partnerPlace == nil ? [] : [weather.partner?.fetchedAt]),
                                lastAttempt: weatherLastAttempt)
    }

    /// `HousekeepingDeadlines.weather` (wall clock): nil unless weather is needed; then 30 min after the last refresh.
    private func weatherDeadline() -> TimeInterval? {
        WeatherPlan.deadline(needed: weatherNeeded && !weatherFetching, last: weatherLastRefresh(), now: wallClock)
    }

    /// My weather's look (rain / snow / hot / cold / windy) unless the data is stale; nil = no look.
    private var currentWeatherLook: WeatherLook? {
        guard let s = weather.mine, !WeatherRefresh.isStale(fetchedAt: s.fetchedAt, now: wallClock) else { return nil }
        return WeatherLook.of(s)
    }

    /// The in-memory weather changed: an open compose panel's weather card, the pet's look.
    private func weatherDidChange() {
        if let compose, compose.isVisible { compose.setWeatherCard(composeWeatherCard()) }
        thinkWeatherChanged()
        refreshPresenceLook()
        let look = currentWeatherLook
        if weatherLoggedLook != .some(look) {
            weatherLoggedLook = .some(look)
            let has = look.map { l in petCharacter.map { !sprites.weatherClips(for: $0, look: l).isEmpty } ?? false } ?? false
            NSLog("[lulu] weather look: %@%@", look?.rawValue ?? "none", look == nil ? "" : (has ? " (this character has clips for it)" : " (no clips for this character)"))
        }
        housekeeping.setNeedsArm()
    }

    /// The character / mode / channel changed (apply): partner row, avatars, the pet's weather clips, first fetch.
    private func weatherConfigChanged() {
        refreshWeather(force: false)
        weatherDidChange()
    }

    private func partnerPlaceMaybeChanged() {
        if weatherNeeded, currentPartnerPlace() != weather.partnerPlace { refreshWeather(force: true) }
    }

    /// A tiny portrait: the first idle frame of the character's current (pinned or worn) outfit.
    private func avatarOutfit(for character: Role) -> String {
        let o = character == petCharacter ? outfit : pinnedOutfit(for: character)
        return o ?? sprites.outfits(for: character).first ?? "classic"
    }

    private func avatar(for character: Role) -> NSImage? {
        let outfitName = avatarOutfit(for: character)
        let key = "\(character.rawValue)/\(outfitName)"
        if let img = weatherAvatars[key] { return img }
        guard let url = sprites.clip(character, outfit: outfitName, action: .idle)?.frames.first,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 96,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        weatherAvatars[key] = img
        return img
    }
    // MARK: end v0.12 weather looks (Task 3)

    // MARK: v0.13.3 想 TA thought bubble (rules in LuluCore ThinkRules; window in ThinkBubbleWindow)
    private lazy var thinkWindow = ThinkBubbleWindow()
    private var thinkLastShown: TimeInterval?
    private var thinkNextIdle: TimeInterval?
    private var thinkHoverWork: DispatchWorkItem?
    /// TA's last known weather look (for the "TA 那边下雨啦" trigger); `thinkPartnerHad` = a fresh snapshot existed.
    private var thinkPartnerLook: WeatherLook?
    private var thinkPartnerHad = false
    private var thinkPartnerPlace: WeatherPlace?

    private func thinkContext() -> ThinkContext {
        ThinkContext(solo: isSolo, hidden: windowsHidden || hide.isHidden, dnd: dndOn, focus: tools.isFocusing,
                     quiet: restQuiet || (pet?.isDozing ?? false) || (pet?.isSleeping ?? false),
                     visitActive: visits.isActive, bubbleShowing: bubble.isOnScreen,
                     petBusy: homePetBusy || thinkWindow.isShowing)
    }

    /// Shows the bubble when the rules allow (or `force`, for demos). Returns whether it was shown.
    @discardableResult
    private func tryThink(_ reason: ThinkReason, force: Bool = false, demo: WeatherSnapshot? = nil) -> Bool {
        let isPeek = reason == .peek
        guard config != nil, let pet else { return false }
        if !force {
            guard ThinkRules.shouldShow(reason, context: thinkContext(), lastShown: thinkLastShown, now: uptime) else { return false }
        }
        guard let theirs = Role(rawValue: partnerCharacter().rawValue), let scene = thinkScene(for: theirs) else { return false }
        let place = weather.partnerPlace ?? currentPartnerPlace()
        var snap = demo ?? weather.partner
        if demo == nil, let s = snap, WeatherRefresh.isStale(fetchedAt: s.fetchedAt, now: wallClock) { snap = nil }
        let now = Date()
        let shownSnap = snap.map { s in var s = s; if demo != nil { s.fetchedAt = now.timeIntervalSince1970 }; return s }
        let bar = isPeek ? ThinkRules.peekBarText(online: partnerOnlineForPeek(), place: place, snapshot: shownSnap, now: now)
                         : ThinkRules.barText(reason: reason, place: place, snapshot: shownSnap, now: now)
        thinkLastShown = uptime
        NSLog("[lulu] think: 想 TA (%@) bar \"%@\"", String(describing: reason), bar ?? "-")
        thinkWindow.show(.init(clip: scene.clip, still: scene.still, dimmed: scene.dimmed, badge: scene.badge, barText: bar,
                               flourish: ThinkRules.flourish(snap), clickToClose: isPeek), anchor: pet.spriteScreenRect,
                         now: isPeek ? ThinkRules.peekDuration : ThinkRules.duration)
        return true
    }

    /// v0.14.2: TA's character as on TA's desk: TA's published outfit (else the last message's, else the character's
    /// preferred one; only outfits we have) and pose (`PresenceLook` / `ThinkPoseLook`). Offline TA reads as idle.
    private func thinkScene(for theirs: Role) -> (clip: SpriteClip, still: Bool, dimmed: Bool, badge: ThinkBubbleWindow.Badge?)? {
        let presence = channel?.partnerPresence
        let online = presence.map { Presence.isOnline(lastSeen: $0.lastSeen, now: Int64(wallClock * 1000), thresholdMs: Presence.thresholdMs) } ?? false
        let pose: PetPose? = online ? presence?.pose : nil
        let outfitName = ThinkOutfit.pick(published: presence?.outfit, lastMessage: lastPartnerOutfit,
                                          available: sprites.outfits(for: theirs), preferred: sprites.preferredOutfit(for: theirs)) ?? "classic"
        guard let idle = sprites.clip(theirs, outfit: outfitName, action: .idle) else { return nil }
        let focusClip = sprites.namedClips(theirs, outfit: outfitName, list: .clips).first { ToolClips.pool(.focus, for: theirs).contains($0.name) }?.clip
        let kind = ThinkPoseLook.resolve(pose, hasFocusClip: focusClip != nil,
                                         hasWeatherClip: { !sprites.weatherNamedClips(for: theirs, look: $0).isEmpty })
        let quiet = sprites.clip(theirs, outfit: outfitName, action: .quiet) ?? idle
        NSLog("[lulu] think: TA draws %@ in %@, pose %@ → %@ (%@)", theirs.rawValue, outfitName, pose?.raw ?? "-", String(describing: kind),
              online ? "online" : "offline / no presence")
        switch kind {
        case .idleLoop: return (idle, false, false, nil)
        case .dozeStill:
            if let sleep = sprites.exactClip(theirs, outfit: outfitName, action: .sleep) { return (sleep, true, false, .tiny("z z")) }
            return (idle, true, true, .tiny("z z"))
        case .quietStill: return (quiet, true, false, nil)
        case .focusClip: return (focusClip ?? idle, false, false, nil)
        case .focusStill: return (quiet, true, false, .tiny("🍅"))
        case .dndStill: return (quiet, true, false, .sign(ThinkPoseLook.dndSign(presence?.dnd)))
        case .weatherClip(let look):
            let clips = sprites.weatherNamedClips(for: theirs, look: look)
            return (clips.randomElement()?.clip ?? idle, false, false, nil)
        }
    }

    /// v0.14.2: how my pet looks on my desk, published in presence (outfit + pose) for TA's 想 TA bubble.
    private func refreshPresenceLook() {
        let look = currentWeatherLook
        let hasClips = look.map { l in petCharacter.map { !sprites.weatherClips(for: $0, look: l).isEmpty } ?? false } ?? false
        let pose = PetPose.derive(hidden: windowsHidden || hide.isHidden, dnd: dndOn, focus: tools.isFocusing,
                                  dozing: pet?.isDozing ?? false, quiet: restQuiet, weather: look, hasWeatherClips: hasClips)
        channel?.setLook(PresenceLook(outfit: outfit, pose: pose))
    }
    /// The outfit on TA's most recent message (fallback for the bubble when presence has none).
    private var lastPartnerOutfit: String?

    /// Called from the fidget slot (no timer of its own): the first call draws a 20–40 min wait, later calls show the
    /// bubble once it is over (and keep trying on later fidgets while something blocks it).
    private func thinkIdleTick() -> Bool {
        guard !isSolo, config != nil else { thinkNextIdle = nil; return false }
        guard let due = thinkNextIdle else {
            thinkNextIdle = uptime + ThinkRules.idleDelay(unit: Double.random(in: 0...1)); return false
        }
        guard uptime >= due, tryThink(.idle) else { return false }
        thinkNextIdle = nil
        return true
    }

    /// Mouse resting on the pet: after ~1 s (if still there) the bubble may show (60 s cooldown in the rules).
    private func scheduleThinkHover() {
        thinkHoverWork?.cancel()
        guard !isSolo, config != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pet?.isPointerOver == true else { return }
            self.tryThink(.hover)
        }
        thinkHoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + ThinkRules.hoverDelay, execute: work)
    }

    /// TA's weather changed: rain / snow / hot starting now announces itself (not at the first data).
    private func thinkWeatherChanged() {
        guard !isSolo else { thinkPartnerHad = false; thinkPartnerLook = nil; return }
        let place = weather.partnerPlace
        if place != thinkPartnerPlace { thinkPartnerPlace = place; thinkPartnerHad = false; thinkPartnerLook = nil }
        let fresh = weather.partner.flatMap { WeatherRefresh.isStale(fetchedAt: $0.fetchedAt, now: wallClock) ? nil : $0 }
        let look = fresh.flatMap { WeatherLook.of($0) }
        let trigger = ThinkRules.weatherTrigger(previous: thinkPartnerLook, hadData: thinkPartnerHad, current: look)
        thinkPartnerHad = fresh != nil
        thinkPartnerLook = look
        if let trigger { tryThink(.weather(trigger)) }
    }

    /// `--demo-think rain@2`: the bubble with a fixed weather for TA (snapshots).
    private func demoThink(_ kind: String) {
        let place = weather.partnerPlace ?? currentPartnerPlace() ?? FakeWeather.places[1]
        let now = wallClock
        let s: WeatherSnapshot
        switch kind {
        case "snow": s = WeatherSnapshot(condition: .snow, temperature: -2, high: 1, low: -5, windSpeed: 8, isDay: true, fetchedAt: now)
        case "clear": s = WeatherSnapshot(condition: .clear, temperature: 24, high: 27, low: 16, windSpeed: 10, isDay: true, fetchedAt: now)
        default: s = WeatherSnapshot(condition: .rain, temperature: 19, high: 21, low: 17, windSpeed: 18, isDay: true, fetchedAt: now)
        }
        if weather.partnerPlace == nil { weather.partnerPlace = place }
        NSLog("[lulu] demo: 想 TA (%@)", kind)
        tryThink(.idle, force: true, demo: s)
    }
    // MARK: end v0.13.3 想 TA

    // MARK: v0.14.3 偷看 (peek at TA on demand; private: nothing is sent)
    private var peekInFlight = false
    private var peekWaiting = false   // prelaunch-A: a peek is waiting for the speech bubble to go (a 2nd press must not start a 2nd wait)

    /// --demo-peek: a faked TA state for this peek (nil = real).
    private var peekDemoState: String?
    /// TA online as the last presence read says (a demo state overrides it for snapshots).
    private func partnerOnlineForPeek() -> Bool {
        if let d = peekDemoState { return d == "online" }
        guard let p = channel?.partnerPresence else { return false }
        return Presence.isOnline(lastSeen: p.lastSeen, now: Int64(wallClock * 1000), thresholdMs: Presence.thresholdMs)
    }
    private func partnerEverSeenForPeek() -> Bool {
        if let d = peekDemoState { return d != "never" }
        return channel?.partnerPresence?.lastSeen != nil || lastPartnerOutfit != nil
    }

    /// 「👀 偷看」 / 「偷看 TA 👀」: one fresh GET of TA's presence, then the 想 TA bubble with that outfit / pose / weather.
    /// Ignores the 60 s cooldown and dnd / focus / quiet / doze (the user asked); a visit in progress or TA never seen
    /// gives a toast; a speech bubble on screen makes the peek wait until it is gone (the cleaner of the two options:
    /// nothing overlaps and the message being read stays readable).
    func peekAtPartner() {
        guard config != nil, !isSolo, pet != nil, !peekInFlight, !peekWaiting else { return }   // prelaunch-A: peekWaiting
        NSLog("[lulu] peek: asked")
        // Checks that need no fetch: hidden / visit (a waiting speech bubble is handled after the fetch).
        let pre = ThinkRules.peekVerdict(context: thinkContext(), partnerEverSeen: true)
        if pre != .show && pre != .wait { applyPeekVerdict(pre); return }
        if peekDemoState != nil || usingDummyConfig || channel == nil || connection != .connected {
            finishPeek(waitedSince: nil)
            return
        }
        peekInFlight = true
        let started = uptime
        channel?.refreshPartnerPresenceNow { [weak self] online in
            guard let self else { return }
            self.peekInFlight = false
            NSLog("[lulu] peek: fresh presence in %.2f s → %@", self.uptime - started, online.map { $0 ? "online" : "offline" } ?? "check failed (last known)")
            self.finishPeek(waitedSince: nil)
        }
    }

    private func finishPeek(waitedSince: TimeInterval?) {
        guard !isSolo else { peekWaiting = false; return }   // prelaunch-A
        let v = ThinkRules.peekVerdict(context: thinkContext(), partnerEverSeen: partnerEverSeenForPeek())
        switch v {
        case .show:
            peekWaiting = false   // prelaunch-A
            tryThink(.peek, force: true)
        case .wait:
            // A speech bubble is on screen: look again every 0.5 s (only while a peek is waiting), give up after 30 s.
            let since = waitedSince ?? uptime
            guard uptime - since < 30 else { peekWaiting = false; return }   // prelaunch-A
            if waitedSince == nil { peekWaiting = true; NSLog("[lulu] peek: waiting for the speech bubble") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.finishPeek(waitedSince: since) }
        default:
            peekWaiting = false   // prelaunch-A
            applyPeekVerdict(v)
        }
    }

    private func applyPeekVerdict(_ v: ThinkRules.PeekVerdict) {
        switch v {
        case .toast(let text):
            NSLog("[lulu] peek: toast \"%@\"", text)
            pet?.showToast(text)
        case .ignore:
            NSLog("[lulu] peek: ignored (solo / hidden)")
        default: break
        }
    }
    // MARK: end v0.14.3 偷看

    private func startIdleBehaviour() {
        noteActivity("pet shown")
        fidgetDue = nil   // a fresh random wait
        housekeeping.setNeedsArm()
    }

    /// Click / drag / double click / menu / compose / sending / incoming message: restarts the doze
    /// countdown and wakes a dozing pet (happy once, then idle).
    private func noteActivity(_ reason: String) {
        quietActivity(reason)
        if dozeClock.activity(now: uptime), let pet {
            NSLog("[lulu] idle: woke up (%@)", reason)
            pet.setDozing(false)
            refreshPresenceLook()
            if !pet.isBusy { pet.playOnce(.happy) }
        }
        dozeDue = uptime + dozeClock.threshold
        blockedTasks.remove(.doze)
        somethingEnded()
        housekeeping.setNeedsArm()
    }

    /// v0.8: interaction / hover / incoming visit: leave quiet mode at once and restart its countdown.
    private func quietActivity(_ reason: String) {
        quietClock.activity(now: uptime)
        if quietMode {
            quietMode = false
            NSLog("[lulu] quiet: animating again (%@)", reason)
            applyRestPose()
        }
        quietDue = uptime + quietClock.threshold
        blockedTasks.remove(.quiet)
        housekeeping.setNeedsArm()
    }

    private func quietCheck() {
        let now = uptime
        if !quietMode, quietClock.isDue(now: now), homePetBusy {
            quietDue = retryWhenFree(.quiet)
            return
        }
        switch quietClock.check(now: now, blocked: false) {
        case .wait(let t): quietDue = now + t
        case .doze:
            quietMode = true
            blockedTasks.remove(.quiet)
            NSLog("[lulu] quiet: no interaction for %.0f s, holding the still frame (no fidgets)", quietClock.threshold)
            applyRestPose()
        case .none: break
        }
    }

    /// Quiet mode or 勿扰 → the still `quiet` frame; otherwise the idle loop (dozing keeps its own pose).
    private func applyRestPose() {
        housekeeping.setNeedsArm()   // fidgets are armed only in the idle pose
        guard let pet else { return }
        let pose = RestPose.pick(dozing: pet.isDozing, quiet: restQuiet, dnd: dndOn)
        pet.setQuiet(restQuiet || dndOn)
        refreshPresenceLook()
        DispatchQueue.main.async { [weak pet] in
            guard let pet else { return }
            NSLog("[lulu] rest pose: %@ (%@)", pose.rawValue, pet.isStill ? "still, nothing animating" : "animating")
        }
    }

    private func dozeCheck() {
        let now = uptime
        if !dozeClock.dozing, dozeClock.isDue(now: now), homePetBusy {
            dozeDue = retryWhenFree(.doze)
            return
        }
        switch dozeClock.check(now: now, blocked: false) {
        case .wait(let t): dozeDue = now + t
        case .doze:
            blockedTasks.remove(.doze)
            guard let pet else { return }
            pet.setDozing(true)
            refreshPresenceLook()
            housekeeping.setNeedsArm()   // no fidgets while dozing
            NSLog("[lulu] idle: dozing after %.0f s without interaction (%@, %@)", dozeClock.threshold,
                  pet.hasClip(.sleep) ? "still eyes-closed frame + Zzz" : "frozen idle + Zzz", pet.isStill ? "nothing animating" : "animating")
            sound.play(.doze)
        case .none: break
        }
    }

    private func fidgetNow() {
        if thinkIdleTick() { return }   // v0.13.3: now and then the fidget is a 想 TA bubble instead
        // Once a doze is due, no new fidget starts (it would keep postponing the doze).
        // v0.8: no fidgets in quiet mode / 勿扰, nor while nothing can be seen (v0.8.1: not even scheduled then).
        let pose = RestPose.pick(dozing: pet?.isDozing ?? false, quiet: restQuiet, dnd: dndOn)
        if let pet, pose.allowsFidgets, !SpritePlayer.paused, !homePetBusy, !dozeClock.isDue(now: uptime), !pet.isSleeping, let name = pet.playFidget(weather: currentWeatherLook) {
            NSLog("[lulu] idle: fidget %@%@", name, pet.lastFidgetWasWeather ? " (weather look: \(currentWeatherLook?.rawValue ?? "?"))" : "")
        }
        // The next fidget deadline is drawn when the scheduler re-arms.
    }

    // MARK: Outfits

    /// How often the outfit changes by itself (unless pinned). `--rotate-seconds N` overrides it.
    private static let outfitRotationInterval: TimeInterval = 30 * 60
    /// UserDefaults key: [character rawValue: outfit name] of pinned outfits.
    private static let pinnedOutfitKey = "pinnedOutfit"

    private var rotationInterval: TimeInterval { options.rotateSeconds ?? Self.outfitRotationInterval }

    /// Today for the seasonal outfits (`--today` overrides it).
    private var today: Date { options.today ?? Date() }
    private var outfitRNG = SystemRandomNumberGenerator()

    private func pinnedOutfit(for character: Role) -> String? {
        (store.defaults.dictionary(forKey: Self.pinnedOutfitKey) as? [String: String])?[character.rawValue]
    }

    private func setPinnedOutfit(_ outfit: String?, for character: Role) {
        var all = (store.defaults.dictionary(forKey: Self.pinnedOutfitKey) as? [String: String]) ?? [:]
        all[character.rawValue] = outfit
        store.defaults.set(all, forKey: Self.pinnedOutfitKey)
    }

    private var isOutfitPinned: Bool { petCharacter.flatMap(pinnedOutfit(for:)) != nil }

    private func refreshOutfitMenu() {
        let count = petCharacter.map { sprites.outfits(for: $0).count } ?? 0
        statusMenu.setOutfitChangeEnabled(count > 1)
        statusMenu.setOutfitPinned(isOutfitPinned)
        guard let character = petCharacter else { return }
        let all = sprites.outfits(for: character)
        statusMenu.setOutfitChoices(OutfitChoice.list(outfits: all, labels: sprites.labels(for: character), seasons: sprites.seasons(for: character),
                                                      current: outfit, pinned: pinnedOutfit(for: character), on: today),
                                    canGoBack: store.outfitHistory(for: character).canGoBack(valid: all, current: outfit))
    }

    /// v0.8 "换回上一个": back to the previous outfit (the pin moves along, like 换个造型).
    private func outfitBack() {
        guard let character = petCharacter else { return }
        var h = store.outfitHistory(for: character)
        guard let o = h.pop(valid: sprites.outfits(for: character), current: outfit) else { return }
        store.setOutfitHistory(h, for: character)
        wearOutfit(o, reason: "back", remember: false)
    }

    /// v0.8 选择造型.
    private func chooseOutfit(_ o: String) {
        guard o != outfit else { return }
        wearOutfit(o, reason: "chosen", remember: true)
    }

    /// Switches to `o` (pushing the outfit being left when `remember`), moves a pin, restarts the rotation.
    private func wearOutfit(_ o: String, reason: String, remember: Bool) {
        guard let pet, let character = petCharacter, sprites.outfits(for: character).contains(o) else { return }
        if remember, let old = outfit { rememberOutfit(old, for: character) }
        outfit = o
        NSLog("[lulu] outfit: %@ (%@)", o, reason)
        refreshPresenceLook()
        pet.transitionOutfit(sprites, character: character, outfit: o) { [weak self] in self?.petMoved() }
        if isOutfitPinned { setPinnedOutfit(o, for: character) }
        scheduleOutfitRotation()
        refreshOutfitMenu()
        NSLog("[lulu] outfit menu: %@", statusMenu.outfitMenuDescription)
    }

    private func rememberOutfit(_ o: String, for character: Role) {
        var h = store.outfitHistory(for: character)
        h.push(o)
        store.setOutfitHistory(h, for: character)
    }

    /// (Re)starts the rotation countdown; no-op when pinned or there is nothing to rotate to.
    private func scheduleOutfitRotation() {
        rotationDeferred = false
        blockedTasks.remove(.rotation)
        rotationDue = nil
        defer { housekeeping.setNeedsArm() }
        guard let character = petCharacter, !isOutfitPinned, sprites.outfits(for: character).count > 1 else { return }
        rotationDue = uptime + rotationInterval
    }

    private func rotateOutfit() {
        guard let pet, !isOutfitPinned else { return }
        // Hidden: nothing polls; the change happens shortly after the pet is shown again (applyHidden).
        if windowsHidden {
            rotationDeferred = true
            NSLog("[lulu] outfit: rotation due while hidden, after showing again")
            return
        }
        // Never cut into a react / happy clip or a message being read: wait until idle.
        if pet.isBusy || bubble.isShowingSomething || visits.isActive {
            rotationDue = retryWhenFree(.rotation)
            return
        }
        switchToOtherOutfit(reason: "rotate")
        scheduleOutfitRotation()
    }

    /// "换个造型": also allowed when pinned, in which case the pin moves to the new outfit.
    private func changeOutfit() {
        guard let character = petCharacter, switchToOtherOutfit(reason: "manual") != nil else { return }
        if isOutfitPinned, let outfit { setPinnedOutfit(outfit, for: character) }
        scheduleOutfitRotation()   // next automatic change is a full interval from now
    }

    @discardableResult
    private func switchToOtherOutfit(reason: String) -> String? {
        guard let pet, let character = petCharacter else { return nil }
        guard let o = OutfitRules.next(after: outfit, outfits: sprites.outfits(for: character),
                                       seasons: sprites.seasons(for: character), on: today, using: &outfitRNG) else { return nil }
        if let old = outfit { rememberOutfit(old, for: character) }   // v0.8 换回上一个
        outfit = o
        defer { refreshOutfitMenu() }
        refreshPresenceLook()
        NSLog("[lulu] outfit: %@ (%@)", o, reason)
        pet.transitionOutfit(sprites, character: character, outfit: o) { [weak self] in self?.petMoved() }
        return o
    }

    private func togglePin() {
        guard let character = petCharacter, let outfit else { return }
        let pin = !isOutfitPinned
        setPinnedOutfit(pin ? outfit : nil, for: character)
        refreshOutfitMenu()
        scheduleOutfitRotation()   // pinned: stops; unpinned: resumes a full interval from now
        NSLog("[lulu] outfit %@: %@; menu: %@", pin ? "pinned" : "unpinned", outfit, statusMenu.pinItemDescription)
    }

    /// Partner bubbles point at the visitor while it is here, else at the home pet; my own (`atHome`) at the home pet.
    private func petMoved() {
        guard let pet else { return }
        let home = bubble.currentItem?.atHome == true
        bubble.follow(home ? pet.spriteScreenRect : (visits.bubbleAnchor ?? pet.spriteScreenRect))
        thinkWindow.follow(pet.spriteScreenRect)
    }

    // MARK: Incoming

    /// S8: logs never carry what the two of them wrote — a text is logged as its length only.
    private static func logBody(_ m: Message) -> String {
        m.text.map { "\($0.count) chars" } ?? m.stickerId ?? m.remindRaw ?? ""
    }

    /// A partner message: the partner's character comes to visit and says it (VisitController).
    private func receive(_ m: Message, live: Bool, fromChannel: Bool) {
        if fromChannel {
            NSLog("[lulu] received %@: %@ (id %@, ts %lld, trip %@, %@)", m.kind.rawValue, Self.logBody(m), m.id, m.ts,
                  m.trip ?? "-", live ? "live" : "backlog")
        }
        if fromChannel, let o = m.outfit { lastPartnerOutfit = o }
        guard pet != nil else { return }
        thinkWindow.dismiss()   // v0.13.3: a real message beats the thought bubble
        checkDNDExpiry(reason: "incoming")
        releaseFocusHold(reason: "incoming")
        if hide.isHidden || dndOn || holdingForFocus {
            // v0.8 勿扰: no visitor, no bubble, no sound — queued like the hidden queue (🍊N), shown as the
            // 诚意清单 when 勿扰 ends. v0.10: our own pomodoro focus holds visitors the same way.
            awayMessages.append((m, fromChannel))
            if dndOn { awayBatchIsDND = true } else if !hide.isHidden { awayBatchIsFocus = true }
            statusMenu.setUnseen(awayMessages.count)
            NSLog("[lulu] %@: queued %@ (%ld waiting), menu bar \"%@\"", dndOn ? "dnd" : hide.isHidden ? "hidden" : "focus", m.kind.rawValue, awayMessages.count, statusMenu.statusTitle)
            return
        }
        if live { noteActivity("partner \(m.kind.rawValue)") }
        // A poke is only meaningful live; backlog pokes replayed after a restart are skipped.
        if m.kind == .poke, nowMs() - m.ts >= Self.stalePokeMs {
            if fromChannel { channel?.markRead(m) }
            return
        }
        // v0.10: the partner's receipt (「TA 喝啦」) is a small bubble on the home pet — no visitor runs over.
        // v0.14.4: it may be 马上 / 等会儿 / 终于做到了 (`RemindReply`). Our pet still out at TA's desk: it carries the
        // answer home as the return toast instead of 「送到啦」.
        if Visits.isRemindAck(m), let reply = RemindReply.decode(m) {
            if !live, nowMs() - m.ts >= Self.stalePokeMs {   // a replayed old reply (after a restart) isn't news
                if fromChannel { channel?.markRead(m) }
                return
            }
            if visits.homeState != .home {
                visits.homeToastOverride = reply.line
                if fromChannel { channel?.markRead(m) }
                NSLog("[lulu] remind reply: carried home on the return toast: %@", reply.line)
                return
            }
            showRemindAck(m, reply: reply, fromChannel: fromChannel, live: live)
            return
        }
        // v0.6: our pet may be out delivering (no host to visit) — or both set off at once.
        let action = visits.incomingAction(for: m)
        switch action {
        case .queueForCard:
            tripMessages.append((m, fromChannel))
            NSLog("[lulu] trip: queued %@ for the \"在TA那边的时候\" card (%ld waiting)", m.kind.rawValue, tripMessages.count)
            return
        case .collision, .showVisitor, .holdUntilHome:
            break
        }
        if m.kind == .poke, fromChannel { channel?.markRead(m) }
        let (item, label) = bubbleItem(for: m, fromChannel: fromChannel)
        let event = visitEvent(for: m, bubble: item, label: label, live: live)
        if action == .collision {
            visits.collide(with: m, event: event)   // both pets set off at once: the collision dance
        } else {
            visits.partner(event)
        }
    }

    // MARK: v0.10 remind water / stand

    /// 「喝了 ✓ / 好的 ✓」 (comply) or 「等会儿」: the answer goes back as a receipt (`ackOf`, no trip), and the
    /// tools controller hears about it (it owns the local reminder state).
    private func answerRemind(_ m: Message, kind: ReminderKind, comply: Bool) {
        NSLog("[lulu] remind %@: %@", kind.rawValue, comply ? "complied" : "snoozed (等会儿)")
        // v0.14.4: both answers go back (`RemindReply`): 马上 = the v0.10 receipt + `answer`, 等会儿 = "water.later".
        if let role { transmit(RemindReply(kind: kind, answer: comply ? .now : .later).message(from: role, ackOf: m.id)) }
        if comply {
            NotificationCenter.default.post(name: PersonalToolsNotification.didComply, object: nil, userInfo: ["kind": kind.rawValue])
        } else {
            NotificationCenter.default.post(name: PersonalToolsNotification.didSnooze, object: nil, userInfo: ["kind": kind.rawValue, "ackOf": m.id])
        }
    }

    /// The partner's receipt: a small bubble on the home pet (「TA 喝啦 💧」), nothing runs, bubble sound.
    private func showRemindAck(_ m: Message, reply: RemindReply, fromChannel: Bool, live: Bool) {
        if live { noteActivity("partner remind reply") }
        NSLog("[lulu] remind reply: %@", reply.line)
        bubble.enqueueAtHome(BubbleItem(header: partnerCharacter(for: m).displayName, content: .text(reply.line),
                                  message: fromChannel ? m : nil, autoHide: 4))
        petMoved()
    }

    /// Our focus round is over (or no longer holds): show what the partner left meanwhile. Called when something
    /// happens that could follow the end of a round (a message arrives, a bubble is read, the pet is clicked,
    /// the pomodoro's end) — no timer of its own.
    func releaseFocusHold(reason: String) {
        // prelaunch-B3: any queued batch (also hidden / 勿扰 ones that ended mid-focus) is released once the focus hold ends.
        guard !awayMessages.isEmpty, !holdingForFocus, !hide.isHidden, !dndOn else { return }
        NSLog("[lulu] focus hold released (%@): %ld message(s) waiting", reason, awayMessages.count)
        DispatchQueue.main.async { [weak self] in self?.playAwayMoment() }
    }

    /// The bubble a partner message shows (nil for a poke), and the sticker's label.
    private func bubbleItem(for m: Message, fromChannel: Bool) -> (BubbleItem?, String?) {
        let header = "\(partnerCharacter(for: m).displayName)说："
        let source = fromChannel ? m : nil
        switch m.kind {
        case .poke:
            return (nil, nil)
        case .text:
            // v0.15.5: a 叫 TA 升级 ping from a newer version of TA gets 「一键更新」 (nothing otherwise).
            if fromChannel, UpgradePing.shouldShowUpdateButton(message: m, mine: AppVersionSource.current) {
                NSLog("[lulu] upgrade ping received: partner on v%@, mine v%@ — 一键更新 button", m.upgradeTo ?? "?", AppVersionSource.current ?? "?")
                return (BubbleItem(header: header, content: .text(m.text ?? ""), message: source,
                                   buttons: [BubbleButton(title: "一键更新", action: { [weak self] in self?.updater.updateTapped() }),
                                             BubbleButton(title: "知道啦", action: {})]), nil)
            }
            return (BubbleItem(header: header, content: .text(m.text ?? ""), message: source), nil)
        case .sticker:
            let label = m.stickerId.flatMap(stickers.label(for:))
            let content: BubbleItem.Content
            if let id = m.stickerId, let url = stickers.url(for: id), FileManager.default.fileExists(atPath: url.path) {
                content = .sticker(url, caption: label.map { $0.hasSuffix("～") || $0.hasSuffix("!") || $0.hasSuffix("！") ? $0 : $0 + "～" })
            } else {
                content = .text("［表情：\(label ?? m.stickerFallbackLabel ?? m.stickerId ?? "?")］")
            }
            return (BubbleItem(header: header, content: content, message: source), label)
        case .visit:
            return (BubbleItem(header: header, content: .text(Visits.visitGreeting), message: source, autoHide: Visits.dwell(for: .visit)), nil)
        case .remind:
            // v0.10: 「叫你喝水 / 起来动动」 with 喝了 ✓ / 等会儿. (An unknown `remind` value or a local preview falls through.)
            guard let kind = m.remind, m.ackOf == nil else {
                if !fromChannel || m.ackOf != nil { return (nil, nil) }
                return (BubbleItem(header: header, content: .text(Message.unknownKindPlaceholder), message: source), nil)
            }
            guard fromChannel else { return (nil, nil) }
            let rb = Visits.remindBubble(kind: kind, sender: partnerCharacter(for: m).displayName)
            return (BubbleItem(header: rb.header, content: .text(rb.line), message: source,
                               buttons: [BubbleButton(title: rb.comply, action: { [weak self] in self?.answerRemind(m, kind: kind, comply: true) }),
                                         BubbleButton(title: rb.snooze, action: { [weak self] in self?.answerRemind(m, kind: kind, comply: false) })]), nil)
        case .unknown:
            // Sent by a newer version: kept in history, shown as a hint to upgrade.
            return (BubbleItem(header: header, content: .text(Message.unknownKindPlaceholder), message: source), nil)
        }
    }

    /// The meeting for message `m` (reactions.json pools, keyword pools, sounds, the sender's outfit).
    private func visitEvent(for m: Message, bubble item: BubbleItem?, label: String?, live: Bool, local: Bool = false) -> VisitController.Event {
        var reaction = reactions.reaction(kind: m.kind, stickerId: m.kind == .remind ? m.remind.map(Visits.remindReactionKey) : m.stickerId)
        if m.kind == .text, let pool = Visits.keywordCouples(text: m.text) {
            reaction = Reaction(couples: pool, visitors: reaction?.visitor ?? [:], sounds: reaction?.sounds ?? [])
        }
        if let forced = options.forceCouple {
            reaction = Reaction(couples: [forced], visitors: reaction?.visitor ?? [:], sounds: reaction?.sounds ?? [])
        }
        // Meeting sound (VisitController, `SoundEvent.meetingKeys`): reactions.json "sound", else the couple
        // clip's own bound sound (couples.json "sound"), else the built-in sticker sound (angry / cry / happy),
        // else the clip's category sound.
        let stickerSound = [SoundEvent.forSticker(m.stickerId)?.rawValue].compactMap { $0 }
        return .init(kind: m.kind, bubble: item, move: Visits.coupleMove(for: m.kind, text: m.text, label: label), live: live,
                     reaction: reaction, sounds: reaction?.sounds ?? [], fallbackSounds: stickerSound,
                     outfit: local ? nil : (m.outfit ?? channel?.partnerPresence?.outfit), local: local)   // v0.14.2: no outfit on the message → what TA wears now
    }

    /// No visitor sprites: the v0.1 behaviour, on the home pet.
    private func showOnHomePet(_ e: VisitController.Event) {
        guard let pet else { return }
        pet.playOnce(e.kind == .sticker || e.kind == .visit ? .happy : .react)
        if e.kind == .poke || e.kind == .visit { pet.showHearts() }
        sound.playFirstAvailable(e.kind == .poke ? [SoundEvent.poke.rawValue] : e.sounds + e.fallbackSounds + [SoundEvent.happy.rawValue],
                                 allowIntimate: contentPolicy.allowsIntimate)
        if let b = e.bubble { bubble.enqueue(b) }
        petMoved()
    }

    private func partnerOnlineChanged(_ online: Bool) {
        NSLog("[lulu] partner %@", online ? "online" : "offline")
        let previous = partnerOnline
        partnerOnline = online
        statusMenu.setPartnerNeverSeen(channel?.partnerNeverSeen ?? false)
        statusMenu.setPartnerOnline(online)
        evaluateUpgradeNudge()
        refreshComposeWeatherCard()   // v0.15.1
        guard previous != online else { return }
        // v0.3: the home pet stays awake whatever the partner's presence (status menu only).
        if online, let pet, !pet.isDozing, !pet.isBusy { pet.playOnce(.happy) }
    }

    // MARK: Outgoing

    /// Queues `message` (the channel retries until delivered); returns the timestamp it went out with.
    @discardableResult
    private func transmit(_ message: Message) -> Message? {
        var message = message
        message.character = message.character ?? config?.myCharacter   // v0.11: which character I draw (partner's visitor)
        message.outfit = message.outfit ?? outfit   // v0.5: the partner's visitor wears what our pet wears
        guard let m = channel?.send(message) else { return nil }
        NSLog("[lulu] sent %@: %@ (ts %lld, trip %@, outfit %@)", m.kind.rawValue, m.text.map { "\($0.count) chars" } ?? m.stickerId ?? m.remindRaw.map { "\($0)\(m.ackOf == nil ? "" : " (receipt)")" } ?? "", m.ts, m.trip ?? "-", m.outfit ?? "-")
        return m
    }

    /// v0.6: every send (❤️ / text / sticker / 去找TA) is a delivery visit — the home pet runs off with it, or
    /// bounces off the edge (partner offline), or meets the partner's pet right here (it is visiting us), or,
    /// already out, just stays longer (VisitController / LuluCore `PetLocation`).
    private func send(_ message: Message) {
        guard pet != nil, !isSolo else { return }   // v0.11: solo has nobody to send to
        noteActivity("send")
        if message.kind == .poke, let pet {
            pet.showHearts()
            sound.play(.poke)
        }
        if hide.isHidden {
            // No pet on screen to run: just send it.
            var m = message
            m.trip = Message.tripLocal
            transmit(m)
            return
        }
        let connected = options.demoGoOnline != nil || connection == .connected
        // Check presence fresh right before the trip, so a partner who just quit is seen as away.
        if connected, options.demoGoOnline == nil, !usingDummyConfig, let channel {
            Task { @MainActor [weak self] in
                let fresh = await channel.refreshPartnerPresence()
                guard self?.channel === channel else { return }   // prelaunch-A: the channel was replaced meanwhile
                self?.dispatchSend(message, connected: connected, reachable: fresh ?? (self?.partnerOnline == true))
            }
            return
        }
        dispatchSend(message, connected: connected, reachable: connected && partnerOnline == true)
    }

    private func dispatchSend(_ message: Message, connected: Bool, reachable: Bool) {
        // v0.8: a partner in 勿扰 still gets everything (stored for them); our pet runs out and comes back.
        var partnerDND: DNDStatus?
        if let m = options.demoPartnerDND {
            partnerDND = DNDStatus(mood: m.rawValue, untilMs: 0)
        } else if connected, options.demoGoOnline == nil, !usingDummyConfig, case .dnd(let d)? = channel?.partnerReach(connected: true) {
            partnerDND = d
        }
        // v0.10: a partner who is in a pomodoro focus round is held like 勿扰 — everything is sent and waits for them.
        var partnerFocusing: Bool
        if let minutes = options.demoPartnerFocus {
            partnerFocusing = minutes > 0
        } else {
            partnerFocusing = connected && !usingDummyConfig
                && Visits.partnerFocusHolds(channel?.partnerFocus, partnerOnline: partnerOnline == true, nowMs: nowMs())
        }
        partnerFocusing = partnerFocusing && partnerDND == nil
        let reachable = reachable && partnerDND == nil && !partnerFocusing
        visits.partnerDND = partnerDND
        visits.partnerFocusHold = partnerFocusing
        visits.partnerNotPaired = channel?.partnerNeverSeen ?? false
        statusMenu.setPartnerNeverSeen(channel?.partnerNeverSeen ?? false)
        let (_, label) = bubbleItem(for: message, fromChannel: false)
        let local = visitEvent(for: message, bubble: nil, label: label, live: true, local: true)
        var sent: Message?
        let action = visits.dispatchSend(kind: message.kind, reachable: reachable, partnerDND: partnerDND != nil || partnerFocusing, local: local) { [weak self] trip in
            guard let self else { return nil }
            var m = message
            m.trip = trip
            if self.usingDummyConfig, m.kind == .visit {
                NSLog("[lulu] visit: (demo database) visit message not sent")
                return nil
            }
            sent = self.transmit(m)
            return sent
        }
        switch action {
        case .localMeeting:
            if connected { pet?.showToast("已发送 ✓") } else { showNotConnectedNotice() }
        case .deliver, .extendAway, .bounce, .coolingDown, .sendOnly:
            // The trip itself tells how it went ("送到啦 ❤️" / "TA 不在…" when the pet is back).
            if sent != nil, !connected, !usingDummyConfig { showNotConnectedNotice() }
        }
    }

    /// Single click on a pet: a cute local reaction only. Nothing is sent (too easy to trigger by accident);
    /// hearts go out via the compose panel's「❤️ 发送爱心」.
    private var lastClickClip: String?
    private var clickRNG = SystemRandomNumberGenerator()

    private func petClicked(_ w: PetWindow) {
        guard !w.isBusy else { return }
        // v0.9: now and then a funny extra clip (reactions.json "click" pool) instead of the plain react clip.
        let who: Role? = w === pet ? petCharacter : Role(rawValue: visits.visitorCharacter.rawValue)   // v0.11: characters, not seats
        let funny = who.map { reactions.clickClips(for: $0).filter(w.hasNamed) } ?? []
        if Double.random(in: 0..<1) < ReactionTable.clickChance,
           let name = PoolPick.pick(funny, last: lastClickClip, using: &clickRNG), w.playNamed(name) {
            lastClickClip = name
            NSLog("[lulu] click: local reaction (nothing sent), funny clip %@", name)
        } else {
            NSLog("[lulu] click: local reaction (nothing sent)")
            w.playOnce(.react)
        }
        w.showHearts()
        sound.play(.click)
    }

    /// 「❤️ 发送爱心」: sends a poke (wire kind "poke", unchanged).
    private func sendHeart() {
        guard let role, !isSolo else { return }
        send(.poke(from: role))
    }

    /// "去找TA 🏃" (compose panel / menu): a `visit` message, delivered like everything else (10 s cooldown).
    private func goVisit() {
        guard let role, !isSolo else { return }
        if hide.isHidden {
            showPetAgain(reason: "go visit")
            return   // the pet first has to be back on screen; "去找TA" again from there
        }
        compose?.dismiss()
        send(.visit(from: role))
    }

    private lazy var pendingAutoSendTs = options.autoSendTs

    /// `--auto-send`: the same path as the buttons.
    private func autoSendNow(_ kind: Message.Kind, arg: String?) {
        guard let role else { return }
        var m: Message
        switch kind {
        case .text: m = .text(arg ?? "自动测试 你好", from: role)
        case .sticker: m = .sticker(arg ?? "hug", from: role)
        case .remind: m = .remind(arg.flatMap(ReminderKind.init(rawValue:)) ?? .water, from: role)
        default: m = Message(from: role, kind: kind, ts: nowMs())
        }
        if let ts = pendingAutoSendTs {
            m.ts = ts
            pendingAutoSendTs = nil
        }
        if kind == .visit { goVisit() } else { send(m) }
    }

    /// v0.11 一个人: double-click opens just the sticker grid; tapping one makes the own pet act it out (nothing is sent).
    private func openSoloCompose(tab: ComposeWindow.Tab = .compose) {
        guard let role, let pet else { return }
        noteActivity("compose")
        compose?.dismiss()
        notice.dismiss()
        DispatchQueue.main.async { [weak self] in self?.refreshWeather(force: false) }   // v0.12: after the panel is up (it is a reason to refresh)
        let c = ComposeWindow(partnerName: myName, stickers: stickers, tab: tab, policy: contentPolicy, solo: true, tools: tools.panel,
                              weather: composeWeatherCard(), stickerPrefs: stickerPrefs)
        c.onOpenSettings = { [weak self] in self?.openSettings() }
        c.onOpenToolsSettings = { [weak self] in self?.tools.onOpenSettings?() }
        c.onOpenStickerSettings = { [weak self] in self?.openStickerSettings() }
        c.onSendSticker = { [weak self] id in self?.playSoloSticker(id, seat: role) }
        compose = c
        c.present(beside: pet.spriteScreenRect)
    }

    /// The sticker plays on the own pet through the same reaction path as a received one (pet clip, sound, the
    /// sticker bubble), but nothing is transmitted, recorded or marked read.
    private func playSoloSticker(_ id: String, seat: Role) {
        guard !hide.isHidden else { return }
        let m = Message.sticker(id, from: seat)
        let label = stickers.label(for: id)
        let (item, _) = bubbleItem(for: m, fromChannel: false)
        var shown = item
        shown?.header = myName
        shown?.autoHide = 4
        let e = visitEvent(for: m, bubble: shown, label: label, live: true, local: true)
        NSLog("[lulu] solo sticker: %@ on the own pet (nothing sent)", id)
        showOnHomePet(e)
    }

    private func openCompose(tab: ComposeWindow.Tab = .compose) {
        if isSolo { openSoloCompose(tab: tab); return }
        guard let role, let pet else { return }
        noteActivity("compose")
        compose?.dismiss()
        notice.dismiss()
        DispatchQueue.main.async { [weak self] in self?.refreshWeather(force: false) }   // v0.12: after the panel is up (it is a reason to refresh); cached shown at once
        var partnerFocusNote: String?
        if let f = channel?.partnerFocus, Visits.partnerFocusHolds(f, partnerOnline: partnerOnline == true, nowMs: nowMs()) {
            partnerFocusNote = Visits.partnerFocusLine(name: partnerName, focus: f, nowMs: nowMs())
        } else if let minutes = options.demoPartnerFocus, minutes > 0 {
            partnerFocusNote = Visits.partnerFocusLine(name: partnerName, focus: FocusStatus(until: nowMs() + Int64(minutes * 60_000)), nowMs: nowMs())
        }
        let c = ComposeWindow(partnerName: partnerName, stickers: stickers, partnerFocusNote: partnerFocusNote,
                              statusNote: connection == .connected ? nil : "⚠︎ 还没连上，发出的消息会先存着",
                              partnerApp: partnerOnline == true ? channel?.partnerPresence?.app.flatMap { AppVersion($0)?.description } : nil,
                              history: .init(store: history, me: role, away: unseenAway, dndSpans: store.dndLog, awayTitle: unseenAwayTitle,
                                             awaySincerity: unseenAwayTitle.hasPrefix("🔕")), tab: tab,
                              policy: contentPolicy, tools: tools.panel, weather: composeWeatherCard(), stickerPrefs: stickerPrefs)
        c.onOpenSettings = { [weak self] in self?.openSettings() }
        c.onOpenToolsSettings = { [weak self] in self?.tools.onOpenSettings?() }
        c.onOpenStickerSettings = { [weak self] in self?.openStickerSettings() }
        c.onHistorySeen = { [weak self] in
            if self?.unseenAway != nil { NSLog("[lulu] history tab: \"你不在的时候\" batch seen") }
            self?.unseenAway = nil
        }
        c.onSendText = { [weak self] text in self?.send(.text(text, from: role)) }
        c.onSendSticker = { [weak self] id in self?.send(.sticker(id, from: role, label: self?.stickers.label(for: id))) }
        c.onGoVisit = { [weak self] in self?.goVisit() }
        c.onPeek = { [weak self] in self?.peekAtPartner() }   // v0.14.3
        c.onSendHeart = { [weak self] in self?.sendHeart() }
        c.onSendRemind = { [weak self] kind in
            guard let self, let role = self.role else { return }
            self.send(.remind(kind, from: role))
        }
        compose = c
        // Keep clear of an open bubble so the message being answered stays readable.
        var anchor = pet.spriteScreenRect
        if bubble.isVisible { anchor = anchor.union(NSRect(x: bubble.frame.minX, y: anchor.minY, width: bubble.frame.width, height: 1)) }
        c.present(beside: anchor)
    }

    // MARK: Settings

    /// `force`: skip the welcome redirect (hidden self-tests).
    private func openSettings(force: Bool = false) {
        warmUpCitySearch()   // v0.13.1
        // Welcome closed without finishing (no mode, no usable config): 设置 would be a raw form, so the way back is
        // Welcome again (menu-bar 🍊 / Dock icon / 去设置).
        if !force, config == nil, store.load()?.mode == nil { openWelcome(); return }
        if let settings, settings.isVisible {
            settings.show()
            return
        }
        var warning: String?
        if case .misconfigured(let reason)? = connection { warning = reason }
        let prefs = SettingsWindow.Prefs(
            shortcuts: storedShortcuts, autoHideFullscreen: store.autoHideInFullscreen,
            setShortcut: { [weak self] action, shortcut in self?.setShortcut(shortcut, for: action) },
            recording: { [weak self] on in
                if on { HotkeyCenter.shared.suspend(); NSLog("[lulu] hotkey: recording, hotkeys released") } else { self?.registerHotkeys() }
            },
            setAutoHide: { [weak self] on in
                self?.store.autoHideInFullscreen = on
                self?.setAutoHideFullscreen(on)
            },
            showInDock: store.showInDock,
            setShowInDock: { [weak self] on in
                self?.store.showInDock = on
                DockPresence.shared.always = on
            },
            soundEnabled: sound.enabled, soundVolume: sound.volume, bgmEnabled: sound.bgmEnabled,
            setSoundEnabled: { [weak self] on in self?.setSoundEnabled(on) },
            setSoundVolume: { [weak self] v in self?.setSoundVolume(v) },
            setBGM: { [weak self] on in self?.setBGM(on) },
            previewSound: { [weak self] in self?.sound.preview() },
            tools: tools.settingsAccess,
            applyMode: { [weak self] cfg in self?.applyModeChange(cfg) },   // v0.11
            confirmSeatMove: { [weak self] character in self?.confirmSeatMove(to: character) ?? true },
            city: CityAccess(model: cityModel, set: { [weak self] in self?.setMyPlace($0) }, search: citySearch, partnerPlace: weather.partnerPlace,
                             setAuto: { [weak self] in self?.setAutoLocation($0) },
                             openLocationSettings: { [weak self] in self?.openLocationSettings() }),   // v0.12 / v0.14.1
            stickers: StickerSettingsAccess(model: stickerPrefs, choices: ComposeWindow.choices(stickers, policy: contentPolicy)))   // v0.15.2
        let w = SettingsWindow(initial: config ?? store.load(), defaultRole: options.role ?? .lulu, warning: warning, prefs: prefs)
        w.onSave = { [weak self] cfg in
            guard let self else { return }
            self.store.save(cfg)
            self.apply(cfg)
        }
        settings = w
        w.show()
    }

    // MARK: v0.7 size (menu 大小 / resize handle)

    /// Menu 大小 (or `--demo-scale`): saves it and resizes the home pet (now, or once it is back home)
    /// and the visitor.
    private func setPetScale(_ s: Double, source: String) {
        let v = PetScale.normalized(s)
        petScale = v
        store.petScale = v
        if let pet, visits.hostCanResize {
            pendingHostScale = nil
            pet.setPetScale(CGFloat(v))
            pet.avoidNeighbors(reason: "resize", yieldToOlder: false)
        } else {
            pendingHostScale = v
            NSLog("[lulu] pet scale: home pet busy (%@), resized when it is back", visits.homeState.rawValue)
        }
        visits.setPetScale(CGFloat(v))
        refreshScaleMenu()
        petMoved()
        NSLog("[lulu] pet scale → %.2f (%@); menu: %@", v, source, statusMenu.sizeMenuDescription)
        if let pet { NSLog("[lulu] pet scale %.2f: pet frame %@, sprite %@", v, NSStringFromRect(pet.frame), NSStringFromRect(pet.visibleSpriteScreenRect)) }
    }

    /// The handle was released: the home pet is already at `s`.
    private func scaleChosenByHandle(_ s: Double) {
        petScale = s
        store.petScale = s
        pendingHostScale = nil
        visits.setPetScale(CGFloat(s))
        refreshScaleMenu()
        petMoved()
        NSLog("[lulu] pet scale → %.2f (handle); menu: %@", s, statusMenu.sizeMenuDescription)
    }

    private func applyPendingHostScale() {
        guard let s = pendingHostScale, let pet, visits.hostCanResize else { return }
        pendingHostScale = nil
        pet.setPetScale(CGFloat(s))
        NSLog("[lulu] pet scale: applied %.2f now that the pet is home; frame %@", s, NSStringFromRect(pet.frame))
    }

    private func refreshScaleMenu() {
        statusMenu.setScale(petScale, petName: config == nil ? (options.role ?? .lulu).displayName : myName)
    }

    // MARK: v0.5 sound settings (menu 声音 / Settings)

    private func setSoundEnabled(_ on: Bool) {
        store.soundEnabled = on
        sound.setEnabled(on)
        refreshSoundMenu()
    }

    private func setSoundVolume(_ v: Float) {
        store.soundVolume = v
        sound.setVolume(v)
        refreshSoundMenu()
    }

    private func setBGM(_ on: Bool) {
        store.bgmEnabled = on
        sound.setBGMEnabled(on)
        refreshSoundMenu()
    }

    private func refreshSoundMenu() {
        statusMenu.setSound(enabled: sound.enabled, volume: sound.volume, bgm: sound.bgmEnabled)
        settings?.refreshSound(enabled: sound.enabled, volume: sound.volume, bgm: sound.bgmEnabled)
    }

    // MARK: v0.4 shortcuts

    /// v0.7: toggle / compose / quit as saved (`hotkeyToggle` / `hotkeyCompose` / `hotkeyQuit`).
    private var storedShortcuts: ShortcutSet {
        ShortcutSet(toggle: store.toggleShortcut, compose: store.composeShortcut, quit: store.quitShortcut)
    }

    private func storeShortcut(_ s: Shortcut, for action: HotkeyCenter.Action) {
        switch action {
        case .toggle: store.toggleShortcut = s
        case .compose: store.composeShortcut = s
        case .quit: store.quitShortcut = s
        }
    }

    private func registerHotkeys() {
        let all = storedShortcuts
        for action in HotkeyCenter.Action.allCases {
            HotkeyCenter.shared.register(action, all[action]) { [weak self] in self?.hotkeyPressed(action) }
        }
        statusMenu.setShortcuts(all)
    }

    /// From Settings: registers `shortcut` (old one stays if it fails) and saves it. Returns an error text.
    private func setShortcut(_ shortcut: Shortcut, for action: HotkeyCenter.Action) -> String? {
        let old = storedShortcuts[action]
        if let error = HotkeyCenter.shared.register(action, shortcut, handler: { [weak self] in self?.hotkeyPressed(action) }) {
            HotkeyCenter.shared.register(action, old) { [weak self] in self?.hotkeyPressed(action) }
            return error
        }
        storeShortcut(shortcut, for: action)
        statusMenu.setShortcuts(storedShortcuts)
        return nil
    }

    private func hotkeyPressed(_ action: HotkeyCenter.Action) {
        switch action {
        case .toggle:
            if hide.isHidden { showPetAgain(reason: "hotkey") } else { hidePet(.untilReopened) }
        case .compose:
            composeShortcut()
        case .quit:
            // Same path as 🍊 → 退出: applicationWillTerminate signs presence off.
            NSLog("[lulu] quit (hotkey)")
            NSApp.terminate(nil)
        }
    }

    /// ⌃⌥M / menu「传话…」: un-hides the pet first (the panel opens beside it).
    private func composeShortcut() {
        if hide.isHidden { showPetAgain(reason: "compose") }
        openCompose()
    }

    // MARK: v0.4 hide / show

    private var wallClock: TimeInterval { Date().timeIntervalSince1970 }

    /// `startedAgo` (testing only): pretend the hide began that many seconds ago.
    private func hidePet(_ option: HideOption, startedAgo: TimeInterval = 0) {
        hide.hide(option, now: wallClock - startedAgo)
        hideUntilDate = option.duration.map { Date().addingTimeInterval($0 - startedAgo) }
        NSLog("[lulu] hide: %@", option.title)
        // v0.8.1: the end is a wall-clock deadline of the housekeeping timer (re-armed after wake / clock
        // change, so a Mac that slept through the time still brings the pet back) — no 2 s poller.
        applyHidden()
    }

    /// Housekeeping: a timed hide's end came.
    private func hideTimeUp() {
        guard hide.expire(now: wallClock) else { return }
        NSLog("[lulu] hide: time is up")
        hideUntilDate = nil
        applyHidden()
    }

    /// Menu「显示」/ ⌃⌥L / ⌃⌥M: ends a manual hide; in a fullscreen space it shows the pet over it.
    private func showPetAgain(reason: String) {
        NSLog("[lulu] show (%@)", reason)
        hide.showManually()
        hideUntilDate = nil
        if hide.fullscreen {
            fullscreenOverride = true
            hide.fullscreen = false
            NSLog("[lulu] fullscreen: shown on request until fullscreen ends")
        }
        applyHidden()
    }

    private func setAutoHideFullscreen(_ on: Bool) {
        NSLog("[lulu] fullscreen auto-hide: %@", on ? "on" : "off")
        if on {
            fullscreenWatcher.start()
        } else {
            fullscreenWatcher.stop()
            hide.fullscreen = false
            applyHidden()
        }
    }

    private func fullscreenChanged(_ fs: Bool) {
        if !fs { fullscreenOverride = false }
        hide.fullscreen = fs && !fullscreenOverride
        applyHidden()
    }

    /// Takes the pet (and its bubble / notice / visitor) off screen or brings it back.
    private func applyHidden() {
        let hidden = hide.isHidden
        statusMenu.setHidden(hidden, petName: config == nil ? Role.lulu.displayName : myName, until: hide.manual ? hideUntilDate : nil)
        housekeeping.setNeedsArm()   // hide end, fidgets (none while hidden)
        guard hidden != windowsHidden else { return }
        windowsHidden = hidden
        refreshPresenceLook()
        if hidden { thinkWindow.dismiss() }
        notice.suppressed = hidden
        sound.setHidden(hidden)
        if hidden {
            compose?.dismiss()
            let waiting = visits.resetKeepingBubbles()
            moveTripMessagesToAwayBatch()
            waiting.forEach(bubble.enqueue)
            bubble.suspend()
            notice.dismiss()
            pet?.orderOut(nil)
            NSLog("[lulu] hidden (%@)%@", hide.manual ? "manual" : "fullscreen",
                  waiting.isEmpty ? "" : ", kept \(waiting.count) waiting bubble(s)")
        } else {
            guard let pet else { return }
            pet.orderFrontRegardless()
            pet.didAppear()
            petMoved()
            if !dndOn { bubble.resume() }
            if rotationDeferred {
                rotationDeferred = false
                rotationDue = uptime + IdleRules.retry
            }
            NSLog("[lulu] shown again (%ld message(s) arrived meanwhile)", awayMessages.count)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.playAwayMoment() }
            tools.unblocked()   // v0.10: postponed pomodoro bubbles / due reminders
            showUpgradeCardIfFree()   // v0.13
        }
    }

    /// "你不在的时候…": the visitor runs in with a summary card, the queued bubbles follow (at most 3;
    /// more collapse into the card, whose「看看」opens the history).
    private func playAwayMoment() {
        guard !hide.isHidden, !dndOn, !holdingForFocus, let role, !awayMessages.isEmpty else { return }
        let batch = awayMessages
        awayMessages = []
        let sincerity = awayBatchIsDND   // v0.8: 勿扰 ended → 诚意清单
        awayBatchIsDND = false
        let focusBatch = awayBatchIsFocus && !sincerity   // v0.10: our focus round ended
        awayBatchIsFocus = false
        statusMenu.setUnseen(0)
        guard let summary = AwaySummary.build(batch.map(\.message), me: role, stickerLabel: stickers.label(for:)) else { return }
        unseenAway = summary
        unseenAwayTitle = sincerity ? "🔕 你勿扰的时候" : focusBatch ? "🍅 你专注的时候" : "🍊 你不在的时候"
        let followers = batch.filter { $0.message.kind == .text || $0.message.kind == .sticker }
        let collapse = followers.count > 3
        let absorbed = batch.filter { collapse || !($0.message.kind == .text || $0.message.kind == .sticker) }
        let card = BubbleItem(header: sincerity ? DND.cardTitle(count: batch.count) : focusBatch ? Visits.focusCardTitle : AwaySummary.title,
                              content: .card(lines: sincerity ? summary.sincerityLines : summary.lines,
                                             preview: collapse ? summary.latestText : nil, button: "看看"),
                              message: nil,
                              alsoRead: absorbed.filter(\.fromChannel).map(\.message),
                              action: { [weak self] in self?.openCompose(tab: .history) })
        NSLog("[lulu] away moment%@: %ld message(s): %@; %@", sincerity ? " (诚意清单)" : "", batch.count,
              (sincerity ? summary.sincerityLines : summary.lines).joined(separator: " / "),
              collapse ? "\(followers.count) bubbles collapsed into the card" : "\(followers.count) bubble(s) follow")
        noteActivity("away moment")
        sound.beginAwayOnly()   // only the card's sound, not one per replayed message
        visits.partner(.init(kind: .visit, bubble: card, move: Visits.coupleMove(for: .visit, text: nil, label: nil), live: true,
                             reaction: reactions.reaction(kind: .visit, stickerId: nil)))
        if !collapse {
            for f in followers { receive(f.message, live: false, fromChannel: f.fromChannel) }
        }
    }

    /// v0.6 "在TA那边的时候，TA说：": what the partner sent while our pet was at theirs, shown on the home pet
    /// once it is back (the card, then at most 3 text / sticker bubbles; more collapse into the card).
    private func playTripCard() {
        guard !hide.isHidden, !dndOn, let role, !tripMessages.isEmpty else { return }
        let batch = tripMessages
        tripMessages = []
        guard let summary = AwaySummary.build(batch.map(\.message), me: role, stickerLabel: stickers.label(for:)) else { return }
        let followers = batch.filter { $0.message.kind == .text || $0.message.kind == .sticker }
        let collapse = followers.count > 3
        let absorbed = batch.filter { collapse || !($0.message.kind == .text || $0.message.kind == .sticker) }
        let card = BubbleItem(header: Visits.tripCardTitle,
                              content: .card(lines: summary.lines, preview: collapse ? summary.latestText : nil, button: "看看"),
                              message: nil,
                              alsoRead: absorbed.filter(\.fromChannel).map(\.message),
                              action: { [weak self] in self?.openCompose(tab: .history) })
        NSLog("[lulu] trip card: %ld message(s): %@; %@", batch.count, summary.lines.joined(separator: " / "),
              collapse ? "\(followers.count) bubbles collapsed into the card" : "\(followers.count) bubble(s) follow")
        noteActivity("trip card")
        sound.beginAwayOnly()   // only the card's sound, not one per replayed message
        bubble.enqueue(card)
        if !collapse {
            for f in followers { if let item = bubbleItem(for: f.message, fromChannel: f.fromChannel).0 { bubble.enqueue(item) } }
        }
        petMoved()
    }

    // MARK: v0.8 勿扰模式

    /// 开启 (or a new end time while on).
    private func startDND(_ d: DNDDuration, source: String) {
        let wasOn = dndOn
        dnd.turnOn(d, now: wallClock)
        store.dnd = dnd
        NSLog("[lulu] dnd: on (%@, %@) — %@", d.title, source, dnd.statusLine())
        if !wasOn {
            // Whatever the partner's pet is doing here is put away like when hiding; its bubbles wait.
            if visits.visitorState != .absent, visits.homeState == .home {
                visits.resetKeepingBubbles().forEach(bubble.enqueue)
            }
            moveTripMessagesToAwayBatch()
            if !awayMessages.isEmpty { awayBatchIsDND = true }
            bubble.suspend()
        }
        applyDND()
    }

    private func setDNDMood(_ m: DNDMood) {
        dnd.mood = m
        store.dnd = dnd
        NSLog("[lulu] dnd: mood %@", m.title)
        applyDND()
    }

    /// 关闭勿扰 (menu) or its time is up: back to normal, then the 诚意清单 (if anything came in).
    private func endDND(reason: String) {
        guard dnd.until != nil else { return }
        let span = dnd.turnOff(now: wallClock)   // a timed one ends at its end time
        store.dnd = dnd
        if let span { store.dndLog = DNDSpan.appending(span, to: store.dndLog) }
        NSLog("[lulu] dnd: off (%@)%@, %ld message(s) waiting", reason, span.map { ", logged \"\($0.label())\"" } ?? "", awayMessages.count)
        applyDND()
        noteActivity("dnd off")
        if !hide.isHidden {
            bubble.resume()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.playAwayMoment() }
        }
    }

    /// Ends a timed 勿扰 that is over (timer, wake from sleep, launch, menu, incoming message).
    private func checkDNDExpiry(reason: String) {
        guard let until = dnd.until, until > 0, wallClock >= until else { return }
        if pet == nil {
            // At launch: just record it (nothing to show yet).
            if let span = dnd.expire(now: wallClock) { store.dndLog = DNDSpan.appending(span, to: store.dndLog) }
            store.dnd = dnd
            NSLog("[lulu] dnd: expired while away (%@)", reason)
            return
        }
        endDND(reason: "time up")
    }

    /// Menu, status line, mood sign, quiet pose, badge and the presence field follow `dnd`.
    private func applyDND() {
        housekeeping.setNeedsArm()   // 勿扰 end; fidgets (none in the quiet pose)
        let on = dndOn
        statusMenu.setDND(dnd)
        channel?.dnd = dnd.status(now: wallClock)
        pet?.setMoodSign(on ? dnd.mood.sign : nil)
        applyRestPose()
        statusMenu.setUnseen(awayMessages.count)
        if !on { tools.unblocked(); showUpgradeCardIfFree() }   // v0.10: postponed pomodoro bubbles / due reminders; v0.13 upgrade card
    }

    /// Our pet was out: what the partner said meanwhile joins the queued batch instead of the trip card.
    private func moveTripMessagesToAwayBatch() {
        guard !tripMessages.isEmpty else { return }
        awayMessages = tripMessages + awayMessages
        tripMessages = []
        statusMenu.setUnseen(awayMessages.count)
    }

    // MARK: v0.8 省电

    private func visibilityChanged(_ unseen: Bool, why: String) {
        SpritePlayer.setPaused(unseen)
        housekeeping.setNeedsArm()   // no fidgets while nothing can be seen
        pet?.hoverPaused = unseen
        NSLog("[lulu] energy: %@ → %@", why, unseen ? "animations paused" : "animations resumed")
    }

    /// Battery-aware timings (`PowerProfile`); `--presence-fast` keeps its test timings.
    private func applyPower() {
        let p = PowerProfile.current(onBattery: power.onBattery)
        if let channel, !options.presenceFast {
            channel.heartbeatInterval = p.heartbeat
            channel.presencePollInterval = p.presencePoll
        }
        pet?.hoverInterval = p.hoverInterval
        fullscreenWatcher.pollInterval = p.fullscreenPoll
        NSLog("[lulu] energy: %@ → heartbeat %.0f s, presence poll %.0f s (one shared wake-up); hover & full screen event-driven",
              power.onBattery ? (options.batteryMode ? "battery (--battery-mode)" : "on battery / low power") : "on AC",
              p.heartbeat, p.presencePoll)
    }

    // MARK: Demo

    private func runV04Demos() {
        if options.demoHistory { seedDemoHistory() }
        if let option = options.demoHide {
            let ago = options.demoHideRemaining.map { (option.duration ?? 0) - $0 } ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.hidePet(option, startedAgo: ago) }
        }
        if options.demoHiddenMessages > 0, let role {
            let from = role.partner
            let samples: [Message] = [
                .poke(from: from), .sticker("hug", from: from), .text("下班了吗？今天好想你呀～", from: from),
                .poke(from: from), .visit(from: from), .sticker("kiss", from: from), .text("晚上一起吃火锅吧 🍲", from: from),
                .sticker("hug", from: from), .text("到家了给我说一声哦", from: from),
            ]
            for i in 0..<options.demoHiddenMessages {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 0.15) { [weak self] in
                    var m = samples[i % samples.count]
                    m.id = UUID().uuidString
                    m.ts = nowMs()
                    self?.receive(m, live: true, fromChannel: false)
                }
            }
        }
        if let t = options.demoUnhideAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.showPetAgain(reason: "demo") }
        }
        if options.demoOpenHistory {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.openCompose(tab: .history) }
        }
        if let t = options.demoMoreStickersAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.compose?.setMoreStickers(expanded: true) }
        }
        if let t = options.demoOpenHistoryAt {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.openCompose(tab: .history) }
        }
        for (action, t) in options.demoHotkeys {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSLog("[lulu] demo: simulated hotkey %@", action.name)
                HotkeyCenter.shared.fire(action)
            }
        }
        for t in options.demoAck {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                NSLog("[lulu] demo: pressing 收到 (%@)", self?.bubble.debugDescription_ ?? "")
                self?.bubble.pressAck()
            }
        }
        for (comply, t) in options.demoRemindReply {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                NSLog("[lulu] demo: pressing %@ on the remind bubble (%@)", comply ? "comply" : "snooze", self?.bubble.debugDescription_ ?? "")
                self?.bubble.pressToolButton(comply ? 0 : 1)
            }
        }
        if let t = options.demoPressCard {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                NSLog("[lulu] demo: pressing the card button (%@)", self?.bubble.debugDescription_ ?? "")
                self?.bubble.pressButton()
            }
        }
        if let t = options.demoMenu {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.popUpMenuForSnapshot() }
        }
        if let (mood, t) = options.demoDND {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                self.setDNDMood(mood)
                self.startDND(self.options.demoDNDFor, source: "demo")
            }
        }
        for (step, t) in options.demoOutfitSteps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self else { return }
                NSLog("[lulu] demo: outfit %@", step)
                if step == "change" { self.changeOutfit() } else if step == "back" { self.outfitBack() } else if step == "pin" { self.togglePin() }
                else if step.hasPrefix("choose:") { self.chooseOutfit(String(step.dropFirst(7))) }
                NSLog("[lulu] outfit menu: %@ (pinned %@)", self.statusMenu.outfitMenuDescription, self.petCharacter.flatMap(self.pinnedOutfit(for:)) ?? "-")
            }
        }
        if let t = options.demoDNDOff {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.endDND(reason: "demo") }
        }
    }

    private func runV05Demos() {
        for t in options.demoClicks {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, let pet = self.pet else { return }
                NSLog("[lulu] demo: click on the home pet")
                self.petClicked(pet)
            }
        }
        for d in options.demoPeek {
            DispatchQueue.main.asyncAfter(deadline: .now() + d.at) { [weak self] in
                self?.peekDemoState = d.state
                self?.peekAtPartner()
            }
        }
        for (kind, t) in options.demoThink {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.demoThink(kind) }
        }
        for t in options.demoFidgets {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.fidgetNow() }
        }
        if let (delta, t) = options.demoResizeDrag {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                guard let self, let pet = self.pet else { return }
                NSLog("[lulu] demo: dragging the resize handle by (%.0f, %.0f) from scale %.2f, frame %@, handle %@",
                      delta.dx, delta.dy, Double(pet.petScale), NSStringFromRect(pet.frame), NSStringFromRect(pet.handleScreenRect))
                pet.simulateResizeDrag(to: delta) {
                    NSLog("[lulu] demo: resize done: scale %.2f (saved %.2f), frame %@", Double(pet.petScale), self.store.petScale, NSStringFromRect(pet.frame))
                }
            }
        }
        for (v, t) in options.demoScale {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.setPetScale(v, source: "demo menu") }
        }
        for t in options.demoSend {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                NSLog("[lulu] demo: 发送爱心")
                self?.sendHeart()
            }
        }
    }

    /// `--demo-menu`: opens the status menu (and maybe the 隐藏 submenu) next to the pet; the snapshot
    /// timers keep running while the menu tracks (common run loop modes).
    private func popUpMenuForSnapshot() {
        guard let pet else { return }
        // The 隐藏 submenu can't be opened programmatically while tracking: `--demo-menu-submenu` pops
        // it up on its own instead (the snapshot tool places it beside the main menu).
        let menu = options.demoMenuTools == "pomodoro" ? statusMenu.pomodoroItem.submenu ?? statusMenu.menu
            : options.demoMenuTools == "reminders" ? statusMenu.remindItem.submenu ?? statusMenu.menu
            : options.demoMenuOutfits ? statusMenu.chooseOutfitItem.submenu ?? statusMenu.menu
            : options.demoMenuDND ? statusMenu.dndItem.submenu ?? statusMenu.menu
            : options.demoMenuSize ? statusMenu.sizeItem.submenu ?? statusMenu.menu
            : options.demoMenuSound ? statusMenu.soundItem.submenu ?? statusMenu.menu
            : options.demoMenuSubmenu ? statusMenu.menu.items.first { $0.submenu != nil && !$0.isHidden }?.submenu ?? statusMenu.menu
                                      : statusMenu.menu
        if let dir = options.snapshotDir {
            // Menus aren't NSApp windows and the main thread is busy tracking: capture our own menu
            // windows from the window server on a background queue (no Screen Recording permission is
            // needed for a process's own windows).
            let url = URL(fileURLWithPath: dir).appendingPathComponent("menu")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { DebugSnapshot.captureOwnMenus(into: url) }
        }
        let r = pet.spriteScreenRect
        NSLog("[lulu] demo: status line \"%@\"; 勿扰模式: %@", statusMenu.statusLineTitle, statusMenu.dndMenuDescription)
        NSLog("[lulu] demo: 小工具: %@", statusMenu.toolsMenuDescription)
        NSLog("[lulu] demo: menu items: %@", statusMenu.menu.items.filter { !$0.isHidden && !$0.isSeparatorItem }.map(\.title).joined(separator: " | "))
        NSLog("[lulu] demo: popping up the %@", menu === statusMenu.menu ? "status menu" : options.demoMenuDND ? "勿扰模式 submenu" : options.demoMenuSize ? "大小 submenu" : options.demoMenuSound ? "声音 submenu" : "隐藏 submenu")
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX - 260, y: r.maxY + 320), in: nil)
    }

    /// `--demo-history`: ~40 varied messages over the last 3 days, only into an empty history (a test profile).
    private func seedDemoHistory() {
        guard let role else { return }
        guard history.count == 0 else {
            NSLog("[lulu] demo history: profile already has %ld messages, not seeding", history.count)
            return
        }
        let me = role, ta = role.partner
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func at(_ dayOffset: Int, _ h: Int, _ m: Int) -> Int64 {
            let d = cal.date(byAdding: .day, value: -dayOffset, to: today)!.addingTimeInterval(TimeInterval(h * 3600 + m * 60))
            return Int64(min(d.timeIntervalSince1970, Date().timeIntervalSince1970 - 60) * 1000)
        }
        typealias S = (Int, Int, Int, Role, Message.Kind, String?)
        let script: [S] = [
            (2, 8, 5, ta, .sticker, "morning"), (2, 8, 7, me, .text, "早呀～今天也要元气满满"), (2, 8, 8, me, .poke, nil),
            (2, 12, 30, ta, .text, "中午吃什么呀"), (2, 12, 31, me, .sticker, "eat"), (2, 12, 33, ta, .text, "我要喝奶茶！"),
            (2, 12, 34, ta, .sticker, "milktea"), (2, 18, 2, me, .visit, nil), (2, 18, 3, ta, .sticker, "hug"),
            (2, 21, 40, ta, .text, "今天有点累，但是看到你就开心啦"), (2, 21, 41, me, .sticker, "nuzzle"), (2, 23, 10, ta, .sticker, "night"),
            (2, 23, 11, me, .text, "晚安，做个好梦 🌙"),
            (1, 7, 50, me, .sticker, "morning"), (1, 9, 15, ta, .poke, nil), (1, 9, 16, ta, .text, "开会好无聊…"),
            (1, 9, 17, me, .sticker, "goodgirl"), (1, 11, 0, ta, .visit, nil), (1, 11, 1, me, .text, "被你抓到了 hhh"),
            (1, 13, 20, ta, .unknown("voice"), nil), (1, 15, 45, me, .text, "下午茶要不要一起？我请客"), (1, 15, 46, ta, .sticker, "celebrate"),
            (1, 19, 30, ta, .text, "到家了吗"), (1, 19, 32, me, .text, "刚到～今天地铁好挤"), (1, 19, 33, ta, .sticker, "hug"),
            (1, 22, 5, me, .poke, nil), (1, 22, 6, ta, .poke, nil), (1, 23, 0, ta, .sticker, "sleeptogether"),
            (0, 8, 20, ta, .sticker, "hi"), (0, 8, 21, me, .text, "早安宝贝"), (0, 9, 0, ta, .text, "今天降温了，记得多穿点哦"),
            (0, 9, 2, me, .sticker, "heart"), (0, 10, 30, me, .visit, nil), (0, 10, 31, ta, .sticker, "shy"),
            (0, 11, 45, ta, .text, "周末去看电影好不好？"), (0, 11, 46, me, .text, "好呀好呀！你挑片子"), (0, 11, 47, ta, .sticker, "dance"),
            (0, 12, 10, ta, .poke, nil), (0, 12, 11, me, .sticker, "kiss"), (0, 12, 15, ta, .text, "想你啦"),
        ]
        let msgs = script.enumerated().map { i, e -> Message in
            Message(id: String(format: "-demo%03d", i), from: e.3, kind: e.4,
                    text: e.4 == .text ? e.5 : nil, stickerId: e.4 == .sticker ? e.5 : nil, ts: at(e.0, e.1, e.2) + Int64(i))
        }
        NSLog("[lulu] demo history: seeded %ld messages", history.merge(msgs))
    }

    private func runAutotest() {
        guard let role else { return }
        sendHeart()
        send(.text("自动测试 你好", from: role))
        send(.sticker("hug", from: role))
    }

    /// `--demo-visit` / `--demo-merge`: the partner visits locally (no network).
    private func runDemoVisit() {
        guard let role else { return }
        let from = role.partner
        let kind = options.demoVisitKind ?? (options.demoMerge ? .visit : .text)
        let ids = (options.demoVisitSticker ?? "").split(separator: ",").map(String.init)
        for (i, id) in (ids.isEmpty ? [""] : ids).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 + Double(i) * options.demoVisitEvery) { [weak self] in
                self?.demoPartnerMessage(kind: kind, from: from, stickerId: id.isEmpty ? nil : id)
            }
        }
    }

    private func demoPartnerMessage(kind: Message.Kind, from: Role, stickerId: String?) {
        var m: Message
        switch kind {
        case .sticker: m = Message(from: from, kind: .sticker, stickerId: stickerId ?? stickers.stickers.first?.id ?? "hug", ts: nowMs())
        case .text: m = Message(from: from, kind: .text, text: options.demoVisitText ?? "我来串门啦～今天也好想你呀 🍊", ts: nowMs())
        default: m = Message(from: from, kind: kind, ts: nowMs())
        }
        m.outfit = options.demoVisitOutfit
        NSLog("[lulu] demo: partner %@ %@ (%@)", kind.rawValue, m.stickerId ?? "", from.rawValue)
        receive(m, live: true, fromChannel: false)
        if options.demoMerge { demoMergeWhenStaying() }
    }

    /// Waits for the visitor to settle, then drags the home pet onto it (as a user would).
    private func demoMergeWhenStaying(attempt: Int = 0) {
        guard attempt < 100 else { return }
        guard visits.visitorState == .staying, let pet, let visitor = visits.visitorWindow else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.demoMergeWhenStaying(attempt: attempt + 1) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let origin = pet.frame.origin
            pet.setFrameOrigin(NSPoint(x: visitor.frame.midX - pet.frame.width / 2 + 20, y: origin.y))
            self.petMoved()
            NSLog("[lulu] demo: dropped home pet at %@ (from %@)", NSStringFromPoint(pet.frame.origin), NSStringFromPoint(origin))
            if !self.visits.homeDragEnded(from: origin) { pet.setFrameOrigin(origin) }
        }
    }

    private func runDemoBubbles(text: Bool) {
        guard let role else { return }
        let from = role.partner
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            if text {
                self?.receive(Message(from: from, kind: .text, text: "今天也好想你呀～下班早点回家，一起吃火锅好不好？🍲", ts: nowMs()), live: true, fromChannel: false)
            }
            if let id = self?.stickers.stickers.first?.id {
                self?.receive(Message(from: from, kind: .sticker, stickerId: id, ts: nowMs()), live: true, fromChannel: false)
            }
        }
    }
}
