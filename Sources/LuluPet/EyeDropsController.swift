import AppKit
import Combine
import LuluCore
import LuluSync
import UserNotifications

/// v0.18 眼药水提醒 (spec docs/superpowers/specs/2026-10-12-eyedrops-and-web-v2.md §2). The rules are LuluCore
/// `EyeDrops` (pure); this class runs them on the Mac:
/// - local state in `PersonalToolsStore` (`eyedrops` / `eyedropsNag` / `eyedropsPending`); in paired modes it mirrors
///   `/pairs/{code}/tools/{seat}/eyedrops` through `ToolsSync` (my Mac ↔ my web page; TA never reads it);
/// - energy: NO timer of its own. One wall-clock `HousekeepingTask.eyedrops` deadline (`fill`) = the earliest of the
///   plan's next wake-up, the 10-min settings refresh (paired), a pending-write retry and local midnight;
/// - the reminder: a bubble at the home pet (「滴了 ✓」「等会儿」) and, in the packaged app with 「同时发系统通知」 on, a
///   system notification with the same buttons. 勿扰 / 专注 do NOT hold it (user decision 2026-10-12: personal
///   reminders always fire, with sound). Only a hidden pet (hide / full screen) makes it notification-only, or wait.
@MainActor
final class EyeDropsController: NSObject {
    struct Environment {
        var pet: () -> PetWindow?
        var character: () -> Role?
        /// My own pet's bubble (the app picks the window; personal reminders are never held by 勿扰).
        var showBubble: (BubbleItem) -> Void
        /// The current config; nil = nothing to sync with (placeholder demo config).
        var config: () -> AppConfig?
        var deviceId: String
        /// The home pet is on screen (not hidden / full-screen-hidden).
        var petVisible: () -> Bool
        var menu: () -> StatusMenu?
        var openPanel: () -> Void
        var openSettings: () -> Void
        var needsArm: () -> Void
        /// Takes the eye-drop bubble (by header) off screen if it is the one showing (checked in elsewhere).
        var closeBubble: (String) -> Void = { _ in }
    }

    /// Hidden test flags (spec §7 W2), read straight from the command line (`--fake-idle S` lives in
    /// `PersonalToolsController.idleSeconds()`, shared with water / stand).
    struct TestOptions {
        var demoTimes: [String]?        // --demo-eyedrops "08:00,12:00": switch on with these times (not validated)
        var nagSeconds: Double?         // --eyedrops-nag-seconds S: nag every S s instead of 15 min
        var catchUpSeconds: Double?     // --eyedrops-catchup-seconds S: catch-up window S s instead of 2 h

        static func parse(_ args: [String]) -> TestOptions {
            var o = TestOptions()
            var it = args.makeIterator()
            while let a = it.next() {
                switch a {
                case "--demo-eyedrops": o.demoTimes = (it.next() ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case "--eyedrops-nag-seconds": o.nagSeconds = it.next().flatMap(Double.init)
                case "--eyedrops-catchup-seconds": o.catchUpSeconds = it.next().flatMap(Double.init)
                default: break
                }
            }
            return o
        }
    }

    let panel = EyeDropsPanelModel.shared

    private let env: Environment
    private let store: PersonalToolsStore
    private let test = TestOptions.parse(CommandLine.arguments)
    /// Nag gap / catch-up window (the test flags shorten them).
    private let nagMs: Int64
    private let catchUpMs: Int64

    /// A slot of `settings` by id ("yyyy-MM-dd/HHmm"), with its place among the day's times (for the bubble copy).
    private struct Slot {
        var id: String, day: String, key: String, time: String, index: Int, total: Int
    }

    private var data: EyeDropsLocal
    private var nag: EyeDropsNag?
    private var pending: EyeDropsPending

    /// The sync target (nil = solo / placeholder) and what it is for, so a new pair / seat is noticed.
    private var sync: ToolsSync?
    private var syncKey: String?
    private enum SyncState { case solo, unknown, ok, failed }
    private var syncState: SyncState = .unknown

    // Deadlines (Unix seconds).
    private var planWake: TimeInterval?
    private var nextSettingsFetch: TimeInterval = 0
    private var nextPendingRetry: TimeInterval?
    private var pendingFailures = 0
    /// `step` is running (it awaits the network); a second request just asks for another pass.
    private var stepping = false
    private var stepAgain = false

    /// The reminder bubble that is up (its slot id and serial); its buttons only act while it is still the live one.
    private var liveBubble: (slot: String, serial: Int)?
    private var bubbleSerial = 0
    private var lastClip: String?
    private var observers: [NSObjectProtocol] = []

    /// System notifications only exist in the packaged app (`swift run` / test instances have no bundle).
    private let notificationsAvailable = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    private var notifyAuthorized = false
    private static let category = "EYEDROPS"
    private static let notificationId = "eyedrops"

    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var wall: TimeInterval { Date().timeIntervalSince1970 }
    private var tz: TimeZone { TimeZone.current }
    private var settings: EyeDropsSettings { data.settings ?? EyeDropsSettings() }

    init(env: Environment, store: PersonalToolsStore, sync: ToolsSync? = nil) {
        self.env = env
        self.store = store
        self.sync = sync
        data = store.eyedrops
        pending = store.eyedropsPending
        nagMs = test.nagSeconds.map { Int64($0 * 1000) } ?? EyeDrops.nagEveryMs
        catchUpMs = test.catchUpSeconds.map { Int64($0 * 1000) } ?? EyeDrops.catchUpMs
        super.init()
        nag = store.eyedropsNag(nowMs: nowMs).map { n in var n = n; n.next = min(n.next, nowMs + nagMs); return n }
        panel.myDevice = env.deviceId
        panel.notifyAvailable = notificationsAvailable
        panel.apply = { [weak self] in self?.apply(settings: $0) }
        panel.toggle = { [weak self] time in self?.toggle(time: time) }
        panel.refresh = { [weak self] in self?.refreshFromPanel() }
        panel.openSettings = { [weak self] in self?.env.openSettings() }
    }

    // MARK: Launch / housekeeping

    func start() {
        if let menu = env.menu() {
            menu.onEyedrops = { [weak self] in self?.env.openPanel() }
            let previous = menu.onToolsOpen   // the 🍊 menu is opening: today's count is read fresh
            menu.onToolsOpen = { [weak self] in previous?(); self?.refreshUI() }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        if notificationsAvailable { setUpNotifications() }
        if let times = test.demoTimes, !times.isEmpty {
            var s = settings
            s.enabled = true
            s.times = EyeDrops.normalizeTimes(times)
            commitSettings(s, reason: "--demo-eyedrops")
        }
        if settings.enabled { NSLog("[lulu] eyedrops: on, %@%@", settings.times.joined(separator: " "), nag.map { ", nag \($0.slot) #\($0.shown)" } ?? "") }
        step(reason: "launch")
    }

    func fill(_ d: inout HousekeepingDeadlines) {
        var due = [planWake, nextPendingRetry].compactMap { $0 }
        if sync != nil { due.append(nextSettingsFetch) }
        if settings.enabled { due.append(nextMidnight()) }   // the menu's 「今天 n/N」 starts over
        d.eyedrops = due.min()
    }

    func run(_ task: HousekeepingTask) {
        guard task == .eyedrops else { return }
        planWake = nil
        step(reason: "timer")
    }

    /// The Mac woke up: a slot may have come due while it slept (still inside its catch-up window → shown at once).
    func didWake() {
        nextSettingsFetch = 0
        step(reason: "wake")
    }

    private func nextMidnight() -> TimeInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return (cal.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(86_400)).timeIntervalSince1970 + 1
    }

    // MARK: The step

    /// Sync what is due, decide (`EyeDrops.plan`), show / wait, re-arm.
    private func step(reason: String) {
        if stepping { stepAgain = true; return }
        stepping = true
        Task { @MainActor in
            await self.stepBody(reason: reason)
            self.stepping = false
            if self.stepAgain { self.stepAgain = false; self.step(reason: "again") }
        }
    }

    private func stepBody(reason: String) async {
        updateSyncTarget()
        if let sync {
            if !pending.isEmpty, (nextPendingRetry ?? 0) <= wall { await flushPending(sync) }
            if nextSettingsFetch <= wall { await fetchSettings(sync) }
        }
        dropStaleNag()
        var p = currentPlan()
        if p.action == .show, let slot = p.slot.flatMap(slot(_:)), let sync {
            // Right before every (re)show: did another of my devices already check this one in?
            await fetchDays(sync, [slot.day])
            if data.days[slot.day]?[slot.key] != nil {
                NSLog("[lulu] eyedrops: skip %@ done-elsewhere", slot.key)
                endReminder(slot.id)
            }
            p = currentPlan()
        }
        if p.action == .show, let slot = p.slot.flatMap(slot(_:)) { show(slot) }
        p = currentPlan()
        planWake = TimeInterval(p.nextWakeMs) / 1000
        refreshUI()
        env.needsArm()
    }

    private func currentPlan() -> EyeDropsPlan {
        EyeDrops.plan(settings: settings, today: data.days, nag: nag, now: nowMs, active: isActive(), tz: tz, nagMs: nagMs, catchUp: catchUpMs)
    }

    private func slot(_ id: String) -> Slot? {
        guard let p = EyeDrops.parseSlotId(id) else { return nil }
        let times = settings.times
        return Slot(id: id, day: p.day, key: p.key, time: p.time, index: (times.firstIndex(of: p.time) ?? 0) + 1, total: times.count)
    }

    /// The user is at the Mac (input within 5 min) and the reminder can reach them (pet on screen, or a notification).
    private func isActive() -> Bool {
        let idle = PersonalToolsController.idleSeconds()   // honours --fake-idle
        guard idle < EyeDrops.activeIdleS else { return false }
        return env.petVisible() || notificationsOn
    }

    private var notificationsOn: Bool { notificationsAvailable && settings.notify && notifyAuthorized }

    /// Past midnight / window over: the nag belongs to nothing any more.
    private func dropStaleNag() {
        guard let n = nag else { return }
        let now = nowMs
        if let p = EyeDrops.parseSlotId(n.slot), settings.enabled, settings.times.contains(p.time),
           let inst = EyeDrops.slotInstant(day: p.day, time: p.time, tz: tz), inst <= now, now < inst + catchUpMs { return }
        endReminder(n.slot)
    }

    // MARK: Showing

    private func show(_ slot: Slot) {
        nag = EyeDrops.afterShow(nag, slot: slot.id, now: nowMs, nagMs: nagMs)
        store.setEyedropsNag(nag)
        let shown = nag?.shown ?? 1
        NSLog("[lulu] eyedrops: shown %@ #%ld", slot.key, shown)
        if env.petVisible() {
            if liveBubble?.slot == slot.id {
                NSLog("[lulu] eyedrops: %@ bubble still up, not stacked", slot.key)   // the 2nd / 3rd show replaces = keeps the one that is up
            } else {
                if shown == 1 { playClip() }
                bubbleSerial += 1
                let serial = bubbleSerial
                liveBubble = (slot.id, serial)
                let copy = EyeDrops.bubbleCopy(slot: slot.id, index: slot.index, total: slot.total)
                let item = BubbleItem(
                    header: copy.header, content: .text(copy.line), message: nil,
                    buttons: [BubbleButton(title: copy.done, action: { [weak self] in
                                  if self?.claim(slot.id, serial) == true { self?.markDone(day: slot.day, key: slot.key) } }),
                              BubbleButton(title: copy.later, action: { [weak self] in
                                  if self?.claim(slot.id, serial) == true { self?.later(slot.key, source: "bubble") } })],
                    onClose: { [weak self] in if self?.claim(slot.id, serial) == true { self?.later(slot.key, source: "closed") } },
                    onShown: { [weak self] in
                        // Queued behind other bubbles and checked in meanwhile (here or elsewhere): don't show it stale.
                        guard let self, self.liveBubble?.serial != serial else { return }
                        DispatchQueue.main.async { self.env.closeBubble(copy.header) }
                    })
                env.showBubble(item)
            }
        }
        if notificationsOn { postNotification(slot) }
    }

    private func claim(_ slot: String, _ serial: Int) -> Bool {
        guard let live = liveBubble, live.slot == slot, live.serial == serial else { return false }
        liveBubble = nil
        return true
    }

    private func playClip() {
        guard let pet = env.pet(), !pet.isBusy else { return }
        if let who = env.character() {
            var rng = SystemRandomNumberGenerator()
            if let name = ToolClips.pick(.eyedrops, for: who, last: lastClip, has: pet.hasNamed, using: &rng), pet.playNamed(name) {
                lastClip = name
                return
            }
        }
        pet.playOnce(.happy)   // no eye-drop clip yet: `happy` stands in (spec §2.5)
    }

    /// 「等会儿」 / clicked away: only the bubble goes; `nag.next` is already 15 min ahead.
    private func later(_ key: String, source: String) {
        NSLog("[lulu] eyedrops: later %@ (%@)", key, source)
        removeNotification()
    }

    /// The reminder for `slotId` is over (done here or elsewhere): forget the nag, drop bubble + notification.
    private func endReminder(_ slotId: String) {
        if nag?.slot == slotId {
            nag = EyeDrops.afterDone(nag)
            store.setEyedropsNag(nag)
        }
        if liveBubble?.slot == slotId {   // checked in from the tab / a notification / another device: the bubble goes
            liveBubble = nil
            env.closeBubble(EyeDrops.header)
        }
        removeNotification()
    }

    // MARK: Check-ins

    /// 「滴了」 for a slot id ("yyyy-MM-dd/HHmm").
    func markDone(_ slotId: String) {
        if let p = EyeDrops.parseSlotId(slotId) { markDone(day: p.day, key: p.key) }
    }

    func undo(_ slotId: String) {
        if let p = EyeDrops.parseSlotId(slotId) { undo(day: p.day, key: p.key) }
    }

    private func markDone(day: String, key: String) {
        let entry = EyeDropsMark(done: nowMs, device: env.deviceId)
        data.days[day, default: [:]][key] = entry
        trimDays()
        store.eyedrops = data
        endReminder("\(day)/\(key)")
        pending.addDone(.init(day: day, slot: key, done: entry.done, device: env.deviceId))
        store.eyedropsPending = pending
        refreshUI()
        writeThrough(log: { remote in NSLog("[lulu] eyedrops: done %@ (%@)", key, remote ? "remote" : "local") })
    }

    private func undo(day: String, key: String) {
        guard let e = data.days[day]?[key], e.device == env.deviceId else { return }   // only my own check-ins
        data.days[day]?[key] = nil
        store.eyedrops = data
        pending.addUndo(day: day, slot: key)
        store.eyedropsPending = pending
        refreshUI()
        writeThrough(log: { remote in NSLog("[lulu] eyedrops: undo %@ (%@)", key, remote ? "remote" : "local") })
        step(reason: "undo")
    }

    /// A dot in the 小工具 tab: check in (补记), or undo my own check-in. Today's slots only.
    private func toggle(time: String) {
        let day = EyeDrops.dayKey(nowMs, tz: tz)
        guard let key = EyeDrops.slotKey(time) else { return }
        if let e = data.days[day]?[key] {
            if e.device == env.deviceId { undo(day: day, key: key) }
        } else {
            markDone(day: day, key: key)
        }
    }

    private func trimDays() {
        let keep = Set((0..<14).map { EyeDrops.dayKey(nowMs - Int64($0) * 86_400_000, tz: tz) })
        data.days = data.days.filter { keep.contains($0.key) }
    }

    // MARK: Settings

    /// The 小工具 tab / Settings: saves at once (stamped now, this device), uploads, re-plans.
    func apply(settings new: EyeDropsSettings) {
        var s = new
        let v = EyeDrops.validateTimes(s.times)
        guard v.ok else { panel.error = v.error; return }
        panel.error = nil
        s.times = v.times
        let turnedOnNotify = s.notify && !settings.notify
        guard s.enabled != settings.enabled || s.times != settings.times || s.notify != settings.notify else { return }
        commitSettings(s, reason: "edit")
        if turnedOnNotify { requestNotificationPermission() }
        step(reason: "settings")
    }

    private func commitSettings(_ new: EyeDropsSettings, reason: String) {
        var s = new
        s.at = nowMs
        s.device = env.deviceId
        data.settings = s
        store.eyedrops = data
        if let n = nag, !s.enabled || !s.times.contains(EyeDrops.parseSlotId(n.slot)?.time ?? "") { endReminder(n.slot) }
        pending.settings = true
        store.eyedropsPending = pending
        NSLog("[lulu] eyedrops: settings %@ (%@): %@ %@, notify %@", reason, s.enabled ? "on" : "off", "\(s.times.count)x", s.times.joined(separator: " "), s.notify ? "on" : "off")
        refreshUI()
        writeThrough(log: nil)
    }

    // MARK: Sync

    /// (Re)builds the `ToolsSync` for the current pair / seat; solo or a placeholder config = local only.
    private func updateSyncTarget() {
        guard let cfg = env.config(), cfg.effectiveMode != .solo, cfg.isComplete else {
            if syncKey != nil { NSLog("[lulu] eyedrops: local only (solo)") }
            sync = nil
            syncKey = nil
            syncState = .solo
            return
        }
        let key = "\(cfg.normalizedDatabaseURL)|\(cfg.pairCode)|\(cfg.role.rawValue)"
        guard key != syncKey else { return }
        let rebuilding = syncKey != nil
        syncKey = key
        sync = ToolsSync(client: FirebaseClient(databaseURL: cfg.normalizedDatabaseURL, pairCode: cfg.pairCode), seat: cfg.role)
        syncState = .unknown
        nextSettingsFetch = 0
        if rebuilding {   // another pair / seat: the local mirror is rebuilt from that remote (settings: newer `at` wins)
            data.days = [:]
            store.eyedrops = data
            pending.done = []
            pending.undo = []
            if data.settings != nil { pending.settings = true }
            store.eyedropsPending = pending
            NSLog("[lulu] eyedrops: sync target changed, mirror rebuilt")
        }
    }

    /// Writes what is pending now (no waiting for housekeeping); `log(remote)` after the attempt.
    private func writeThrough(log: ((Bool) -> Void)?) {
        updateSyncTarget()
        guard let sync else { log?(false); return }
        Task { @MainActor in
            await self.flushPending(sync)
            log?(self.syncState == .ok && self.pending.isEmpty)
            self.refreshUI()
            self.env.needsArm()
        }
    }

    private func flushPending(_ sync: ToolsSync) async {
        var failed = false
        if pending.settings == true, let local = data.settings {
            do {
                let remote = try await sync.getSettings()
                if let remote, remote.at > local.at { adopt(remote) } else { try await sync.putSettings(local) }
                pending.settings = nil
            } catch { failed = true }
        } else {
            pending.settings = nil
        }
        for leaf in pending.done {
            do {
                try await sync.putDone(day: leaf.day, slot: leaf.slot, device: leaf.device ?? env.deviceId, done: leaf.done ?? nowMs)
                pending.done.removeAll { $0 == leaf }
            } catch { failed = true }
        }
        for leaf in pending.undo {
            do {
                try await sync.deleteDone(day: leaf.day, slot: leaf.slot)
                pending.undo.removeAll { $0 == leaf }
            } catch { failed = true }
        }
        store.eyedropsPending = pending
        noteSync(ok: !failed)
        if failed {
            pendingFailures += 1
            nextPendingRetry = wall + min(300, 30 * pow(2, Double(min(pendingFailures, 4) - 1)))
            NSLog("[lulu] eyedrops: sync failed, %ld write(s) pending", pending.done.count + pending.undo.count + (pending.settings == true ? 1 : 0))
        } else {
            if pendingFailures > 0 { NSLog("[lulu] eyedrops: pending writes synced after %ld failed attempt(s)", pendingFailures) }
            pendingFailures = 0
            nextPendingRetry = nil
        }
    }

    private func fetchSettings(_ sync: ToolsSync) async {
        nextSettingsFetch = wall + 600
        do {
            let remote = try await sync.getSettings()
            noteSync(ok: true)
            let merged = EyeDrops.mergeSettings(local: data.settings, remote: remote)
            if let merged, merged != data.settings, merged == remote {
                adopt(merged)
            } else if let local = data.settings, remote != local, pending.settings != true {
                pending.settings = true   // ours is newer (or the remote has none): upload it
                store.eyedropsPending = pending
                await flushPending(sync)
            }
        } catch {
            noteSync(ok: false)
        }
    }

    private func adopt(_ remote: EyeDropsSettings) {
        guard remote != data.settings else { return }
        data.settings = remote
        store.eyedrops = data
        if let n = nag, !remote.enabled || !remote.times.contains(EyeDrops.parseSlotId(n.slot)?.time ?? "") { endReminder(n.slot) }
        NSLog("[lulu] eyedrops: settings from %@ (%@, %@)", remote.device.isEmpty ? "?" : remote.device, remote.enabled ? "on" : "off", remote.times.joined(separator: " "))
        refreshUI()
    }

    /// Today's (or the slot's day's) check-ins from the server: the remote is the truth, plus my writes still pending.
    private func fetchDays(_ sync: ToolsSync, _ days: [String]) async {
        for day in Set(days) {
            do {
                var merged = try await sync.getDay(day)
                for leaf in pending.done where leaf.day == day { merged[leaf.slot] = EyeDropsMark(done: leaf.done ?? nowMs, device: leaf.device ?? env.deviceId) }
                for leaf in pending.undo where leaf.day == day { merged[leaf.slot] = nil }
                data.days[day] = merged.isEmpty ? nil : merged
                noteSync(ok: true)
            } catch {
                noteSync(ok: false)   // 3 s and no answer: the local copy decides
            }
        }
        trimDays()
        store.eyedrops = data
    }

    private func noteSync(ok: Bool) {
        guard sync != nil else { return }
        syncState = ok ? .ok : .failed
    }

    /// The 小工具 tab / Settings page came on screen: settings and today's dots fresh from the server.
    private func refreshFromPanel() {
        updateSyncTarget()
        refreshNotificationStatus()
        guard let sync else { refreshUI(); return }
        Task { @MainActor in
            await self.fetchSettings(sync)
            await self.fetchDays(sync, [EyeDrops.dayKey(self.nowMs, tz: self.tz)])
            self.refreshUI()
            self.env.needsArm()
        }
    }

    // MARK: UI

    private func refreshUI() {
        let p = EyeDrops.progress(settings: settings, today: data.days, now: nowMs, tz: tz, nag: nag, catchUp: catchUpMs)
        let line: String
        switch syncState {
        case .solo: line = "只在这台 Mac（单人模式）"
        case .ok: line = pending.isEmpty ? "已和网页版同步 ✓" : "同步中…"
        case .failed: line = "同步失败，稍后重试"
        case .unknown: line = "正在和网页版同步…"
        }
        panel.update(settings: settings, progress: p, syncLine: line, syncOK: syncState == .ok && pending.isEmpty)
        env.menu()?.setEyedrops(settings.enabled ? "👁️ 眼药水 \(p.done)/\(p.total)" : nil)
    }

    // MARK: System notifications (packaged app only)

    private func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: "done", title: EyeDrops.buttonDone, options: [])
        let later = UNNotificationAction(identifier: "later", title: EyeDrops.buttonLater, options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.category, actions: [done, later], intentIdentifiers: [], options: [.customDismissAction])])
        refreshNotificationStatus()
    }

    private func refreshNotificationStatus() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let status = s.authorizationStatus
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.notifyAuthorized = status == .authorized || status == .provisional
                self.panel.notifyDenied = status == .denied
            }
        }
    }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { [weak self] in
                self?.notifyAuthorized = granted
                self?.panel.notifyDenied = !granted
                NSLog("[lulu] eyedrops: notification permission %@", granted ? "granted" : "denied")
                self?.step(reason: "notify permission")
            }
        }
    }

    private func postNotification(_ slot: Slot) {
        let copy = EyeDrops.bubbleCopy(slot: slot.id, index: slot.index, total: slot.total)
        let c = UNMutableNotificationContent()
        c.title = copy.header
        c.body = copy.line
        c.categoryIdentifier = Self.category
        c.userInfo = ["day": slot.day, "slot": slot.key]
        if !env.petVisible() { c.sound = .default }   // the bubble already made its sound
        // Same identifier: the 2nd / 3rd show replaces the first.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationId, content: c, trigger: nil))
    }

    private func removeNotification() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
    }

    /// A notification button: the same path as the bubble's; the bubble goes too.
    fileprivate func notificationAction(_ action: String, day: String, slot: String) {
        guard EyeDrops.slotTime(slot) != nil else { return }
        if action == "done" {
            markDone(day: day, key: slot)
        } else {
            later(slot, source: "notification")
        }
    }
}

extension EyeDropsController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let day = info["day"] as? String ?? "", slot = info["slot"] as? String ?? ""
        DispatchQueue.main.async { [weak self] in
            self?.notificationAction(action == "done" ? "done" : "later", day: day, slot: slot)
            completionHandler()
        }
    }
}

/// What the 小工具 tab card and the Settings → 小工具 section show and edit (one per app: the controller is the
/// single source of truth and pushes its state in; both views write back through `apply` / `toggle`).
@MainActor
final class EyeDropsPanelModel: ObservableObject {
    static let shared = EyeDropsPanelModel()

    @Published private(set) var settings = EyeDropsSettings()
    @Published private(set) var progress = EyeDropsProgress(done: 0, total: 0, slots: [])
    @Published private(set) var syncLine = ""
    @Published private(set) var syncOK = false
    @Published var notifyAvailable = false
    @Published var notifyDenied = false
    /// Why the last edit was refused (two times < 30 min apart).
    @Published var error: String?
    /// A controller is attached (else the views hide the section).
    @Published private(set) var attached = false

    var myDevice = ""
    var apply: (EyeDropsSettings) -> Void = { _ in } { didSet { attached = true } }
    var toggle: (String) -> Void = { _ in }
    var refresh: () -> Void = {}
    var openSettings: () -> Void = {}

    func update(settings: EyeDropsSettings, progress: EyeDropsProgress, syncLine: String, syncOK: Bool) {
        if self.settings != settings { self.settings = settings }
        if self.progress != progress { self.progress = progress }
        if self.syncLine != syncLine { self.syncLine = syncLine }
        if self.syncOK != syncOK { self.syncOK = syncOK }
    }

    func setEnabled(_ on: Bool) {
        edit { s in
            s.enabled = on
            if s.times.isEmpty { s.times = EyeDrops.suggestedTimes(4) }   // first switch-on: the suggested four
        }
    }
    func setNotify(_ on: Bool) { edit { $0.notify = on } }

    /// 「一天几次」: the times start over from the suggested ones for that count.
    func setCount(_ n: Int) {
        guard n != settings.times.count else { return }
        edit { $0.times = EyeDrops.suggestedTimes(n) }
    }

    func setTime(_ index: Int, _ time: String) {
        guard settings.times.indices.contains(index) else { return }
        edit { $0.times[index] = time }
    }

    private func edit(_ change: (inout EyeDropsSettings) -> Void) {
        var s = settings
        change(&s)
        apply(s)
    }

    /// 「这台 Mac」 / 「网页」 / 「另一台 Mac」.
    func deviceLabel(_ device: String?) -> String? {
        guard let device else { return nil }
        if device == myDevice { return "这台 Mac" }
        return device.hasPrefix("web-") ? "网页" : "另一台 Mac"
    }

    static let explanation = "每天到点，宠物冒个气泡提醒你滴眼药水。点「滴了」打卡；「等会儿」或不理，15 分钟后再提醒，每次最多提醒 3 遍。电脑睡着错过的，2 小时内醒来会补提醒。配对后设置和打卡会和你自己的网页版同步（TA 看不到）。勿扰 / 专注时也照常提醒。"
}
