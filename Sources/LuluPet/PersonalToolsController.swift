import AppKit
import LuluCore
import LuluSync

/// v0.10 personal tools (docs/superpowers/specs/2026-10-04-personal-tools-design.md): the pomodoro timer and
/// the water / stand reminders. The rules live in LuluCore (`PomodoroState`, `ActiveTimeReminder`,
/// `WaterLog`); this class runs them. Energy: NO timer of its own — every wake-up is a `HousekeepingTask`
/// deadline (`.pomodoro` wall clock, `.water` / `.stand` monotonic) handed to the app's single housekeeping
/// timer through `fill(_:)`. With both reminders off and no pomodoro running it arms nothing.
@MainActor
final class PersonalToolsController {
    /// What the controller needs from the app (closures, so it stays free of AppDelegate's private state).
    struct Environment {
        var pet: () -> PetWindow?
        var channel: () -> PairChannel?
        var character: () -> Role?
        var bubble: BubbleWindow
        var sound: SoundPlayer
        /// The pet is off screen (hidden / full screen) or 勿扰 is on: bubbles wait, reminders stay pending.
        var blocked: () -> Bool
        /// Focusing started or ended: the pet's rest pose has to be re-evaluated.
        var restChanged: () -> Void
        /// A deadline changed: re-arm the housekeeping timer.
        var needsArm: () -> Void
    }

    /// Bridge for the settings window.
    struct SettingsAccess {
        var get: () -> ToolsSettings
        var set: (ToolsSettings) -> Void
    }

    /// The compose panel's 小工具 tab reads and edits through this (refreshed with the menu).
    let panel = ToolsPanelModel()
    /// 「调时长…」 / the menu's 这是什么？: set by the app.
    var onOpenSettings: (() -> Void)?
    var onOpenPanel: (() -> Void)?

    private let store: PersonalToolsStore
    private let env: Environment
    private weak var menu: StatusMenu?

    private var settings: ToolsSettings
    private var pomodoro: PomodoroState
    private var waterLog: WaterLog
    private var reminders: [ReminderKind: ActiveTimeReminder] = [:]
    /// `--demo-pomodoro`: short phases for this run (not saved).
    private var demoPomodoroConfig: PomodoroConfig?
    private var observers: [NSObjectProtocol] = []

    // Deadlines (see `fill`).
    private var pomodoroDue: TimeInterval?
    private var reminderDue: [ReminderKind: TimeInterval] = [:]
    /// Pomodoro bubbles that came due while blocked; shown by `unblocked()`.
    private var pendingBubbles: [(BubbleItem, Role?)] = []

    private var wall: TimeInterval { Date().timeIntervalSince1970 }
    /// `--demo-snooze-delay S`: 「等会儿」 asks again after S seconds instead of 10 minutes (test only).
    var testSnoozeDelay: TimeInterval?
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var pomodoroConfig: PomodoroConfig { demoPomodoroConfig ?? settings.pomodoro }

    /// A focus round is running (not paused): quiet pet, reminders wait.
    var isFocusing: Bool { pomodoro.phase == .focus && !pomodoro.isPaused }

    var settingsAccess: SettingsAccess {
        SettingsAccess(get: { [weak self] in self?.settings ?? ToolsSettings() },
                       set: { [weak self] in self?.apply(settings: $0) })
    }

    init(store: PersonalToolsStore, env: Environment) {
        self.store = store
        self.env = env
        settings = store.settings
        pomodoro = store.pomodoro
        waterLog = store.waterLog
        panel.apply = { [weak self] in self?.apply(settings: $0) }
        panel.act = { [weak self] in self?.menuAction($0) }
        panel.openSettings = { [weak self] in self?.onOpenSettings?() }
        panel.cycleLine = { [weak self] kind in self?.cycleLine(kind) }
        panel.update(settings: settings, pomodoro: pomodoro, cups: waterLog.cups(on: Date()))
    }

    // MARK: Launch

    /// Wires the 🍅 / 提醒 menus, restores the saved pomodoro (one `advance` for whatever ended while the app was
    /// off) and arms the reminders that are switched on.
    func start(menu: StatusMenu) {
        self.menu = menu
        menu.onPomodoro = { [weak self] a in self?.menuAction(a) }
        menu.onReminder = { [weak self] kind, on in self?.setReminder(kind, enabled: on) }
        menu.onToolsOpen = { [weak self] in self?.refreshMenu() }
        menu.onToolsHelp = { [weak self] in self?.onOpenPanel?() }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: PersonalToolsNotification.didComply, object: nil, queue: .main) { [weak self] n in
            let kind = (n.userInfo?["kind"] as? String).flatMap(ReminderKind.init(rawValue:))
            MainActor.assumeIsolated { if let kind { self?.partnerReminderAccepted(kind) } }
        })
        observers.append(nc.addObserver(forName: PersonalToolsNotification.didSnooze, object: nil, queue: .main) { [weak self] n in
            let kind = (n.userInfo?["kind"] as? String).flatMap(ReminderKind.init(rawValue:))
            let ackOf = n.userInfo?["ackOf"] as? String
            MainActor.assumeIsolated { if let kind { self?.partnerReminderSnoozed(kind, ackOf: ackOf) } }
        })

        for kind in ReminderKind.allCases { loadReminder(kind) }
        if pomodoro.phase != .idle { NSLog("[lulu] tools: pomodoro restored: %@", describe(pomodoro)) }
        pomodoroStep(reason: "launch")
        refreshMenu()
        // The pet window may not exist yet (it is created while the config is applied): show the label / rest pose then.
        DispatchQueue.main.async { [weak self] in self?.refreshPet() }
    }

    /// The channel was (re)created: publish the current focus round on it.
    func syncFocus() {
        env.channel()?.setFocus(pomodoro.focusStatus)
    }

    // MARK: Housekeeping

    /// Adds this controller's deadlines to the app's housekeeping deadlines.
    func fill(_ d: inout HousekeepingDeadlines) {
        d.pomodoro = pomodoroDue
        d.water = reminderDue[.water]
        d.stand = reminderDue[.stand]
    }

    func run(_ task: HousekeepingTask) {
        switch task {
        case .pomodoro: pomodoroStep(reason: "timer")
        case .water: reminderStep(.water)
        case .stand: reminderStep(.stand)
        default: break
        }
    }

    /// Full screen / hide / 勿扰 ended: the postponed pomodoro bubbles pop now, and the reminders (still due)
    /// are looked at right away.
    func unblocked() {
        guard !env.blocked() else { return }
        let pending = pendingBubbles
        pendingBubbles = []
        for (item, who) in pending { present(item, character: who) }
        // Only a reminder that is already due (waiting for this) is looked at now; the others keep their schedule.
        for kind in ReminderKind.allCases {
            guard let r = reminders[kind], !r.showing, r.activeSeconds >= r.interval || r.snoozeUntil != nil else { continue }
            reminderDue[kind] = uptime
        }
        env.needsArm()
    }

    // MARK: Pomodoro

    private func menuAction(_ a: StatusMenu.PomodoroAction) {
        let now = wall
        switch a {
        case .start: pomodoro.start(now: now, config: pomodoroConfig)
        case .pauseResume: pomodoro.isPaused ? pomodoro.resume(now: now) : pomodoro.pause(now: now)
        case .skipBreak: pomodoro.skipBreak()
        case .stop: pomodoro.stop()
        }
        NSLog("[lulu] tools: pomodoro %@ → %@", String(describing: a), describe(pomodoro))
        commitPomodoro()
    }

    /// `--demo-pomodoro S`: a round with S-second focus and S/2-second breaks.
    func demoPomodoro(focusSeconds s: TimeInterval) {
        var c = PomodoroConfig()
        c.focus = s
        c.shortBreak = max(2, s / 2)
        c.longBreak = c.shortBreak
        demoPomodoroConfig = c
        menuAction(.start)
    }

    /// `--demo-reminder KIND@S`: the reminder bubble pops S seconds from now (demo only: no idle detection).
    func demoReminder(_ kind: ReminderKind, after s: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self else { return }
            var r = self.reminders[kind] ?? ActiveTimeReminder(interval: kind == .water ? self.settings.waterInterval : self.settings.standInterval)
            r.showing = true
            self.reminders[kind] = r
            self.showReminder(kind)
        }
    }

    /// Advances the saved pomodoro (a phase may have ended, also while the Mac slept), then re-arms.
    private func pomodoroStep(reason: String) {
        let event = pomodoro.advance(now: wall, config: pomodoroConfig)
        if let event {
            NSLog("[lulu] tools: pomodoro %@ (%@) → %@", String(describing: event), reason, describe(pomodoro))
            phaseEnded(event)
        }
        commitPomodoro()
    }

    /// Saves, publishes the focus status, refreshes label / menu / rest pose and schedules the next wake-up.
    private func commitPomodoro() {
        store.pomodoro = pomodoro
        syncFocus()
        pomodoroDue = nextPomodoroWake(now: wall)
        refreshPet()   // label + (when focusing started / ended) the rest pose
        refreshMenu()
        env.needsArm()
    }

    /// The pet's rest pose has been told about this focus state.
    private var focusingApplied = false

    /// A focus phase ended or was stopped / restarted away (focus → break, idle; not a pause): lets the app release
    /// what it held back during the focus round (the partner's messages).
    var onFocusEnded: (() -> Void)?
    private var focusPhaseApplied = false

    private func refreshPet() {
        let inFocus = pomodoro.phase == .focus
        if focusPhaseApplied, !inFocus {
            focusPhaseApplied = false
            onFocusEnded?()
        } else if inFocus {
            focusPhaseApplied = true
        }
        env.pet()?.setCountdown(countdownText(now: wall))
        if focusingApplied != isFocusing {
            focusingApplied = isFocusing
            env.restChanged()
        }
        playFocusClip()
    }

    /// 噜噜's book-reading clip while a focus round runs (`ToolClips.focus`): once at the start and then once per
    /// minute tick (the countdown refresh), holding the still frame in between — not a 25-minute nonstop loop
    /// (省电). 噜妹 has no focus clip and keeps the quiet still frame; nothing plays while 勿扰 / full screen blocks.
    private func playFocusClip() {
        guard isFocusing, !env.blocked() else { return }
        _ = playToolClip(.focus)
    }

    /// "🍅 12" (minutes, rounded up) while more than a minute is left, "🍅 45s" in the last minute; paused: "⏸ 🍅 12".
    /// Only during focus; breaks show nothing.
    private func countdownText(now: TimeInterval) -> String? {
        guard pomodoro.phase == .focus, let rem = pomodoro.remaining(now: now) else { return nil }
        let body = rem > 60 ? "🍅 \(Int((rem / 60).rounded(.up)))" : "🍅 \(max(1, Int(rem.rounded(.up))))s"
        return pomodoro.isPaused ? "⏸ " + body : body
    }

    /// The next time housekeeping has to look at the pomodoro: the phase end, and during focus also the next
    /// label change (every minute; every second in the last minute). nil when idle / paused.
    func nextPomodoroWake(now: TimeInterval) -> TimeInterval? {
        guard pomodoro.phase != .idle, let until = pomodoro.until else { return nil }
        guard pomodoro.phase == .focus else { return until }
        let rem = until - now
        let refresh = rem > 60 ? until - 60 * (rem / 60).rounded(.up) + 60 : now + 1
        return min(until, max(refresh, now + 0.25))
    }

    private func phaseEnded(_ event: PomodoroEvent) {
        let who = env.character()
        switch event {
        case .focusDone(let next):
            let minutes = Int(((next == .longBreak ? pomodoroConfig.longBreak : pomodoroConfig.shortBreak) / 60).rounded())
            let text = minutes >= 1 ? "专注完成！休息 \(minutes) 分钟吧" : "专注完成！休息一下吧"
            deliver(BubbleItem(header: "🍅 番茄钟", content: .text(text), message: nil, autoHide: 8), character: who, happy: true)
        case .breakDone:
            let item = BubbleItem(header: "🍅 番茄钟", content: .text("休息好啦，开始下一个番茄？"), message: nil,
                                  buttons: [BubbleButton(title: "开始", action: { [weak self] in self?.menuAction(.start) }),
                                            BubbleButton(title: "先不了", action: {})])
            deliver(item, character: who, happy: false)
        }
    }

    /// Shows a pomodoro bubble now, or after full screen / 勿扰 ends.
    private func deliver(_ item: BubbleItem, character: Role?, happy: Bool) {
        if env.blocked() {
            pendingBubbles.append((item, happy ? character : nil))
            return
        }
        present(item, character: happy ? character : nil)
    }

    private func present(_ item: BubbleItem, character: Role?) {
        if character != nil {   // focus done: a happy clip and the happy sound
            if let pet = env.pet(), !pet.isBusy, !playToolClip(.breakTime) { pet.playOnce(.happy) }
            env.sound.play(.happy)
        }
        env.bubble.enqueueAtHome(item)
    }

    // MARK: Reminders

    private func interval(_ kind: ReminderKind) -> TimeInterval {
        kind == .water ? settings.waterInterval : settings.standInterval
    }

    private func isEnabled(_ kind: ReminderKind) -> Bool {
        kind == .water ? settings.waterEnabled : settings.standEnabled
    }

    /// Loads (or creates) the saved reminder of an enabled kind; a bubble that was open at quit is gone.
    private func loadReminder(_ kind: ReminderKind) {
        guard isEnabled(kind) else {
            reminders[kind] = nil
            reminderDue[kind] = nil
            return
        }
        var r = store.reminder(kind) ?? ActiveTimeReminder(interval: interval(kind))
        r.interval = interval(kind)
        r.showing = false
        reminders[kind] = r
        store.setReminder(r, for: kind)
        scheduleReminder(kind)
    }

    private func scheduleReminder(_ kind: ReminderKind) {
        guard let r = reminders[kind] else { reminderDue[kind] = nil; return }
        // At most 5 minutes between looks (= the away threshold), so an away stretch is noticed.
        reminderDue[kind] = uptime + min(r.secondsUntilNextCheck(), testSnoozeDelay != nil ? 2 : ActiveTimeReminder.awayThreshold)   // test flag: look every 2 s
    }

    /// Housekeeping woke up for a reminder: count the active time and pop the bubble when it is due.
    private func reminderStep(_ kind: ReminderKind) {
        guard var r = reminders[kind] else { reminderDue[kind] = nil; return }
        let fire = r.tick(now: wall, idleSeconds: Self.idleSeconds(), blocked: env.blocked() || isFocusing)
        reminders[kind] = r
        store.setReminder(r, for: kind)
        if fire { showReminder(kind) }
        scheduleReminder(kind)
        env.needsArm()
    }

    /// Seconds since the last keyboard / mouse input (any event type), read only when housekeeping wakes.
    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    /// The last clip played per slot, so the same one does not come twice in a row.
    private var lastClip: [ToolClips.Kind: String] = [:]

    /// Plays a random clip of the slot's pool for the current character (what the outfit has, not the previous one
    /// again); false when none is usable. Not while the pet is busy.
    @discardableResult
    private func playToolClip(_ slot: ToolClips.Kind, completion: (() -> Void)? = nil) -> Bool {
        guard let pet = env.pet(), !pet.isBusy, let who = env.character() else { return false }
        var rng = SystemRandomNumberGenerator()
        guard let name = ToolClips.pick(slot, for: who, last: lastClip[slot], has: pet.hasNamed, using: &rng),
              pet.playNamed(name, completion: completion) else { return false }
        lastClip[slot] = name
        NSLog("[lulu] tools: %@ clip %@", slot.rawValue, name)
        return true
    }

    private func showReminder(_ kind: ReminderKind) {
        let water = kind == .water
        if let pet = env.pet(), !pet.isBusy, !playToolClip(water ? .water : .stand) {
            pet.playOnce(.happy)
        }
        let item = BubbleItem(
            header: water ? "💧 喝水" : "🧍 站立",
            content: .text(water ? "该喝水啦 💧" : "站起来动一动～"),
            message: nil,
            buttons: [BubbleButton(title: water ? "喝了 ✓" : "好的 ✓", action: { [weak self] in self?.complied(kind) }),
                      BubbleButton(title: "等会儿", action: { [weak self] in self?.snoozed(kind) })],
            onClose: { [weak self] in self?.dismissed(kind) })   // clicked away: start over, no cup
        env.bubble.enqueueAtHome(item)
        NSLog("[lulu] tools: %@ reminder shown", kind.rawValue)
    }

    /// 「喝了 ✓ / 好的 ✓」.
    private func complied(_ kind: ReminderKind) {
        if kind == .water { addCup() }
        completeSnoozeOrigin(kind)
        resetReminder(kind)
    }

    private func snoozed(_ kind: ReminderKind) {
        guard var r = reminders[kind] else { return }
        r.snooze(now: wall)
        if let d = testSnoozeDelay { r.snoozeUntil = wall + d }   // --demo-snooze-delay (test only)
        reminders[kind] = r
        store.setReminder(r, for: kind)
        scheduleReminder(kind)
        env.needsArm()
    }

    /// The bubble was clicked away without a button: the timer starts over.
    private func dismissed(_ kind: ReminderKind) {
        store.setRemindSnooze(nil, for: kind)
        resetReminder(kind)
    }

    private func resetReminder(_ kind: ReminderKind) {
        guard var r = reminders[kind] else { return }
        r.done(now: wall)
        reminders[kind] = r
        store.setReminder(r, for: kind)
        scheduleReminder(kind)
        env.needsArm()
    }

    /// The partner's reminder to me was accepted (v0.10 Task 3 posts `didComply`): same as pressing 「喝了 / 好的」.
    private func partnerReminderAccepted(_ kind: ReminderKind) {
        NSLog("[lulu] tools: partner %@ reminder accepted", kind.rawValue)
        if kind == .water { addCup() }
        store.setRemindSnooze(nil, for: kind)
        resetReminder(kind)
    }

    private func partnerReminderSnoozed(_ kind: ReminderKind, ackOf: String?) {
        NSLog("[lulu] tools: partner %@ reminder snoozed", kind.rawValue)
        guard isEnabled(kind) else { return }
        snoozed(kind)
        // v0.14.4: remember that this snooze came from TA's reminder, so 「喝了」 on the re-reminder can say so.
        if let ackOf { store.setRemindSnooze(RemindSnoozeOrigin(ackOf: ackOf, at: wall), for: kind) }
    }

    /// 「喝了 / 好的」 on the local re-reminder: if it came from a partner-remind 「等会儿」 (≤ 2 h ago), tell TA.
    private func completeSnoozeOrigin(_ kind: ReminderKind) {
        guard let o = store.remindSnooze(kind) else { return }
        store.setRemindSnooze(nil, for: kind)
        guard RemindReply.isWithinLateWindow(snoozedAt: o.at, now: wall) else { return }
        NSLog("[lulu] tools: %@ done after all (snoozed %.0f s ago): telling TA", kind.rawValue, wall - o.at)
        NotificationCenter.default.post(name: PersonalToolsNotification.didCompleteLate, object: nil,
                                        userInfo: ["kind": kind.rawValue, "ackOf": o.ackOf])
    }

    private func addCup() {
        waterLog.add(now: Date())
        store.waterLog = waterLog
        refreshMenu()
    }

    private func setReminder(_ kind: ReminderKind, enabled: Bool) {
        var s = settings
        if kind == .water { s.waterEnabled = enabled } else { s.standEnabled = enabled }
        apply(settings: s)
    }

    // MARK: Settings

    /// Saves and applies new settings at once (menu switches, the 小工具 page).
    func apply(settings new: ToolsSettings) {
        guard new != settings else { return }
        let old = settings
        settings = new
        store.settings = new
        for kind in ReminderKind.allCases {
            let was = kind == .water ? old.waterEnabled : old.standEnabled
            let changedInterval = interval(kind) != (kind == .water ? old.waterInterval : old.standInterval)
            if isEnabled(kind) != was || changedInterval { loadReminder(kind) }
        }
        NSLog("[lulu] tools: settings applied (water %@ / %.0f s, stand %@ / %.0f s, focus %.0f s)", settings.waterEnabled ? "on" : "off",
              settings.waterInterval, settings.standEnabled ? "on" : "off", settings.standInterval, settings.pomodoro.focus)
        refreshMenu()
        env.needsArm()
    }

    /// v0.13.1: 「还差约 N 分钟…」 under an enabled reminder in the 小工具 tab (a live estimate, read-only).
    private func cycleLine(_ kind: ReminderKind) -> String? {
        let on = kind == .water ? settings.waterEnabled : settings.standEnabled
        guard on else { return nil }
        let r = reminders[kind] ?? ActiveTimeReminder(interval: kind == .water ? settings.waterInterval : settings.standInterval)
        return ToolsCopy.cycleLine(kind, r.status(now: wall, idleSeconds: Self.idleSeconds(), blocked: env.blocked() || isFocusing))
    }

    private func refreshMenu() {
        menu?.setPomodoro(pomodoro, now: wall)
        menu?.setReminders(water: settings.waterEnabled, stand: settings.standEnabled, cups: waterLog.cups(on: Date()),
                           waterInterval: settings.waterInterval, standInterval: settings.standInterval)
        panel.update(settings: settings, pomodoro: pomodoro, cups: waterLog.cups(on: Date()))
    }

    private func describe(_ s: PomodoroState) -> String {
        let left = s.remaining(now: wall).map { String(format: "%.0f s left", $0) } ?? "-"
        return "\(s.phase.rawValue)\(s.isPaused ? " (paused)" : ""), \(left), round \(s.completedFocus)"
    }
}
