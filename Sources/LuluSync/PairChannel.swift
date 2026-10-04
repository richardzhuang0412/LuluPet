import Foundation
import LuluCore

/// App-facing connection to the partner. All callbacks are delivered on the main actor.
@MainActor
public final class PairChannel {
    public enum ConnectionState: Equatable, Sendable {
        case connecting
        case connected
        /// Wrong URL / rules / pair code (HTTP 401/403/404 or stream `cancel`).
        case misconfigured(String)
        /// Network trouble; retrying automatically.
        case offline
    }

    public let config: AppConfig
    public let store: ConfigStore
    /// Durable local record of every message seen or sent (nil = don't record; tests).
    public let history: HistoryStore?

    /// Partner messages only, in timestamp order, deduplicated by id. Includes backlog received while offline;
    /// `live` is false for those (the first `put` of a stream connection) and true for messages that arrived
    /// while connected.
    public var onMessage: ((_ message: Message, _ live: Bool) -> Void)?
    public var onPartnerOnline: ((Bool) -> Void)?
    public var onConnection: ((ConnectionState) -> Void)?
    /// v0.8: the partner's 勿扰 changed (nil = off / expired).
    public var onPartnerDND: ((DNDStatus?) -> Void)?
    /// v0.8: my 勿扰, published with every heartbeat (set → published at once).
    public var dnd: DNDStatus? {
        didSet { if dnd != oldValue, !tasks.isEmpty { heartbeatNow() } }
    }
    /// v0.10: the partner's focus round changed (nil = none / over).
    public var onPartnerFocus: ((FocusStatus?) -> Void)?
    /// v0.10: my pomodoro focus round, published with every heartbeat (see `setFocus`).
    public private(set) var focus: FocusStatus?
    /// v0.10: the partner's focus round as last read (only while active).
    public private(set) var partnerFocus: FocusStatus?
    /// v0.8: the partner's 勿扰 as last read (only while active).
    public private(set) var partnerDND: DNDStatus?
    /// Last partner presence read (nil until the first successful poll / never written).
    public private(set) var partnerPresence: PresenceInfo?

    /// v0.11: who I am, published with every heartbeat (see `setIdentity`); nil = publish only `lastSeen` (as before).
    public private(set) var identity: PresenceIdentity?
    /// v0.11: the partner's presence read differs from the previous one (any field; `lastSeen` advances with every
    /// heartbeat, so this fires about once per partner heartbeat). The full `PresenceInfo` (character / mode /
    /// device / dnd / focus); nil = never written. `partnerPresence` always holds the latest.
    public var onPartnerPresence: ((PresenceInfo?) -> Void)?
    /// v0.11: the partner's resolved identity changed (`PartnerIdentity.resolve`: presence.character →
    /// latest partner message's `character` → the seat's namesake; mode: presence.mode ?? couple).
    public var onPartnerIdentity: ((PartnerIdentity) -> Void)?
    /// v0.11: the partner's identity as currently known (works before the first poll too: seat defaults).
    public var partnerIdentity: PartnerIdentity {
        PartnerIdentity.resolve(partnerSeat: config.role.partner, presence: partnerPresence, lastMessageCharacter: lastPartnerCharacter)
    }
    /// v0.11: my own seat's presence as last read (only polled once `setIdentity` gave this machine a device id).
    public private(set) var mySeatPresence: PresenceInfo?
    /// v0.11: another machine is online on my seat (`SeatClash.detect`); reported through `onSeatClash` on change.
    public private(set) var seatClash = false
    public var onSeatClash: ((Bool) -> Void)?

    /// Latest connection state (also reported through `onConnection`).
    public private(set) var connectionState: ConnectionState = .offline
    /// Last partner presence reported through `onPartnerOnline` (nil until the first successful poll).
    public private(set) var partnerOnline: Bool?
    /// True while the partner has never written presence for this pair code (not set up / not paired yet).
    public private(set) var partnerNeverSeen = false
    /// Messages waiting to be sent, oldest first.
    public private(set) var outbox: [Message] = []

    /// Presence timing (`Presence` / `PowerProfile`: AC 20 s heartbeat + 15 s poll, battery 30 s + 30 s,
    /// offline after 75 s). Both run from one coalesced wake-up (`PresenceSchedule`); a change takes effect
    /// at the next wake-up. Tests shorten them (hidden `--presence-fast` flag).
    public var heartbeatInterval: TimeInterval = Presence.heartbeatInterval
    public var presencePollInterval: TimeInterval = Presence.pollInterval
    public var presenceThresholdMs: Int64 = Presence.thresholdMs
    /// v0.11: time between reads of my own seat (`SeatClashMonitor`); tests shorten it (hidden `--seat-check-interval`).
    public var seatCheckInterval: TimeInterval = SeatClashMonitor.defaultInterval
    static let outboxRetryInterval: TimeInterval = 5
    static let misconfiguredRetryInterval: TimeInterval = 60
    static let maxBackoff: TimeInterval = 30
    /// Firebase sends `keep-alive` roughly every 30 s; a stream silent for longer is considered dead.
    nonisolated static let streamIdleTimeout: TimeInterval = 90

    private let client: FirebaseClient
    private var lastPartnerCharacter: PetCharacter?
    private var lastPartnerCharacterTs: Int64 = 0
    private var lastReportedIdentity: PartnerIdentity?
    private var seatMonitor = SeatClashMonitor()
    private var tasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var flushGeneration = 0
    private var delivered = Set<String>()
    /// Delivered but not yet marked read: id → ts.
    private var unread: [String: Int64] = [:]
    private var readHigh: Int64 = 0
    private var lastStreamActivity = Date()
    private var lastSentTs: Int64 = 0
    private var backfillTask: Task<Void, Never>?
    private var backfilled = false

    public convenience init(config: AppConfig, store: ConfigStore, history: HistoryStore? = nil) {
        self.init(config: config, store: store,
                  client: FirebaseClient(databaseURL: config.databaseURL, pairCode: config.pairCode),
                  history: history)
    }

    /// Lets tests inject a client backed by a stubbed `URLSession`.
    public init(config: AppConfig, store: ConfigStore, client: FirebaseClient, history: HistoryStore? = nil) {
        self.config = config
        self.store = store
        self.client = client
        self.history = history
    }

    /// v0.10: publish my focus round (nil = not focusing). Sends a heartbeat at once when it changed (and the
    /// channel runs); every later heartbeat carries it until it is cleared or runs out.
    public func setFocus(_ focus: FocusStatus?) {
        guard focus != self.focus else { return }
        self.focus = focus
        if !tasks.isEmpty { heartbeatNow() }
    }

    /// v0.11: publish who I am (`character`, `mode`, `device`) in every heartbeat from now on; also starts reading my
    /// own seat's presence on each poll so a second machine on the seat is noticed (`seatClash`). Heartbeats at once
    /// when it changed and the channel runs.
    public func setIdentity(character: PetCharacter, mode: PairMode, device: String) {
        let new = PresenceIdentity(character: character, mode: mode, device: device)
        guard new != identity else { return }
        identity = new
        if !tasks.isEmpty { heartbeatNow() }
    }

    /// v0.11.2: my app version ("0.11.2"), published as `presence/<seat>/app` with every heartbeat and the sign-off;
    /// nil (running outside a bundle) = not published. The partner's is `partnerPresence?.app`.
    public private(set) var appVersion: String?

    public func setAppVersion(_ version: String?) {
        guard version != appVersion else { return }
        appVersion = version
        if !tasks.isEmpty { heartbeatNow() }
    }

    /// v0.12: my city, published as `presence/<seat>/place` with every heartbeat and the sign-off (so TA can look up
    /// my weather even while I am offline); nil = none. A change heartbeats at once. The partner's is `partnerPresence?.place`.
    public private(set) var place: WeatherPlace?

    public func setPlace(_ place: WeatherPlace?) {
        guard place != self.place else { return }
        self.place = place
        if !tasks.isEmpty { heartbeatNow() }
    }

    /// v0.14.2: how my pet looks on my desk (outfit + pose), published with every heartbeat. A change heartbeats at
    /// once, at most every `lookBeatGap` seconds (a flurry of changes is folded into one trailing heartbeat).
    public private(set) var look: PresenceLook?
    public var lookBeatGap: TimeInterval = 5
    private var lastLookBeat: Date?
    private var lookBeatTask: Task<Void, Never>?

    public func setLook(_ look: PresenceLook?) {
        guard look != self.look else { return }
        self.look = look
        guard !tasks.isEmpty else { return }
        let wait = lastLookBeat.map { max(0, lookBeatGap - Date().timeIntervalSince($0)) } ?? 0
        if wait <= 0 {
            lastLookBeat = Date()
            lookBeatTask?.cancel()
            lookBeatTask = nil
            heartbeatNow()
        } else if lookBeatTask == nil {
            lookBeatTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.lookBeatTask = nil
                self.lastLookBeat = Date()
                self.heartbeatNow()
            }
        }
    }

    /// What goes into a heartbeat: my focus round only while it is still running.
    private var publishedFocus: FocusStatus? { focus.flatMap { $0.isActive(nowMs: nowMs()) ? $0 : nil } }

    /// Opens the message stream and starts the presence heartbeat + partner polling (one loop).
    public func start() {
        stop()
        setState(.connecting)
        seatMonitor = SeatClashMonitor(interval: seatCheckInterval)
        tasks = [
            Task { [weak self] in await self?.streamLoop() },
            Task { [weak self] in await self?.presenceLoop() },
        ]
        flush()
    }

    /// Cancels all tasks; safe to call more than once.
    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        flushTask?.cancel()
        flushTask = nil
        backfillTask?.cancel()
        backfillTask = nil
    }

    /// Queues the message and sends it; retried every 5 s until it succeeds. Timestamps are made strictly
    /// increasing, because the partner's unread cursor (`startAt = lastReadTs + 1`) would otherwise skip a
    /// message sharing its millisecond with one already read. Returns the message as queued.
    @discardableResult
    public func send(_ message: Message) -> Message {
        var m = message
        m.ts = max(m.ts, lastSentTs + 1)
        lastSentTs = m.ts
        outbox.append(m)
        flush()
        return m
    }

    /// Advances the unread cursor (`store.lastReadTs`) once a message has been shown. Messages may be
    /// acknowledged out of order (a poke at once, bubbles when dismissed), so the cursor never moves past a
    /// delivered message that is still unread; otherwise it would be skipped after a restart.
    public func markRead(_ message: Message) {
        unread[message.id] = nil
        readHigh = max(readHigh, message.ts)
        var cursor = readHigh
        if let oldest = unread.values.min() { cursor = min(cursor, oldest - 1) }
        store.lastReadTs = max(store.lastReadTs, cursor)
    }

    // MARK: Stream

    private enum StreamEnd: Error { case idle, closed }

    private func streamLoop() async {
        var backoff: TimeInterval = 1
        while !Task.isCancelled {
            let error = await connectOnce()
            if Task.isCancelled { return }
            if connectionState == .connected { backoff = 1 }
            let wait: TimeInterval
            if let reason = Self.misconfigurationReason(error) {
                setState(.misconfigured(reason))
                wait = Self.misconfiguredRetryInterval
            } else {
                setState(.offline)
                wait = backoff
                backoff = min(backoff * 2, Self.maxBackoff)
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
    }

    /// Runs one stream connection until it fails, closes, or goes idle; returns why it ended.
    private func connectOnce() async -> Error {
        let stream = client.messageStream(since: store.lastReadTs)
        lastStreamActivity = Date()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await ev in stream { await self.handle(ev) }
                    throw StreamEnd.closed
                }
                group.addTask {
                    // v0.8.1: sleep until the stream would be idle for 90 s (was: check every 10 s).
                    while let wait = StreamWatchdog.sleep(idle: await self.streamIdleSeconds(), timeout: Self.streamIdleTimeout) {
                        try await Task.sleep(for: .seconds(wait), tolerance: .seconds(Presence.tolerance(for: wait)))
                    }
                    throw StreamEnd.idle
                }
                // The first child to throw ends this connection; cancel the other.
                defer { group.cancelAll() }
                try await group.next()
            }
            return StreamEnd.closed
        } catch {
            return error
        }
    }

    private func streamIdleSeconds() -> TimeInterval { Date().timeIntervalSince(lastStreamActivity) }

    private func handle(_ ev: SSEEvent) {
        lastStreamActivity = Date()
        if connectionState != .connected {
            setState(.connected)
            backfill()
        }
        let messages = FirebaseDecode.messages(from: ev)
        if let history, !messages.isEmpty { history.merge(messages) }
        let live = !FirebaseDecode.isBacklog(ev)
        for m in messages where m.from != config.role {
            guard delivered.insert(m.id).inserted else { continue }
            unread[m.id] = m.ts
            if let c = m.character, m.ts >= lastPartnerCharacterTs {   // v0.11: newest message's character
                lastPartnerCharacterTs = m.ts
                lastPartnerCharacter = c
                reportIdentity()
            }
            onMessage?(m, live)
        }
    }

    /// Chinese description when the error means retrying quickly is pointless, else nil.
    public nonisolated static func misconfigurationReason(_ error: Error) -> String? {
        switch error as? FirebaseError {
        case .http(let code) where code == 401 || code == 403:
            return "数据库规则拒绝访问 (HTTP \(code))"
        case .http(404):
            return "数据库地址有误 (HTTP 404)"
        case .http(400):
            // Most likely `.indexOn: ["ts"]` is missing from the rules.
            return "数据库规则缺少 ts 索引 (HTTP 400)"
        case .cancelled:
            return "数据库规则拒绝访问"
        case .badURL:
            return "数据库地址格式有误"
        default:
            return nil
        }
    }

    private func setState(_ s: ConnectionState) {
        guard s != connectionState else { return }
        connectionState = s
        onConnection?(s)
    }

    // MARK: History backfill

    /// Once per channel (i.e. per launch), after the first successful connection: fetch the pair's whole
    /// message list and merge it into the local history, so a fresh install / new Mac / lost file recovers
    /// everything. Retried on the next connection if it fails.
    private func backfill() {
        guard let history, !backfilled, backfillTask == nil else { return }
        let client = client
        backfillTask = Task.detached(priority: .background) { [weak self] in
            let result: Result<Int, Error>
            do { result = .success(history.merge(try await client.allMessages())) } catch { result = .failure(error) }
            await self?.backfillFinished(result)
        }
    }

    private func backfillFinished(_ result: Result<Int, Error>) {
        backfillTask = nil
        switch result {
        case .success(let added):
            backfilled = true
            NSLog("[lulu] history backfill: %ld added, %ld total", added, history?.count ?? 0)
        case .failure(let error):
            NSLog("[lulu] history backfill failed: %@", String(describing: error))
        }
    }

    // MARK: Presence

    /// v0.8.1: heartbeat and partner poll share one wake-up (`PresenceSchedule`); sleeps with 10 %
    /// tolerance (at most 3 s) so macOS can coalesce it with other timers.
    private func presenceLoop() async {
        // ContinuousClock (same as Task.sleep) keeps counting through system sleep, unlike systemUptime.
        let clock = ContinuousClock(), t0 = clock.now
        func now() -> TimeInterval {
            let d = t0.duration(to: clock.now).components
            return TimeInterval(d.seconds) + TimeInterval(d.attoseconds) / 1e18
        }
        var schedule = PresenceSchedule(start: now())
        while !Task.isCancelled {
            let due = schedule.fire(now: now(),
                                    heartbeat: heartbeatInterval, poll: presencePollInterval)
            let client = client, role = config.role, dnd = dnd, focus = publishedFocus, identity = identity, app = appVersion, place = place, look = look
            // v0.11: my own seat is read BEFORE this iteration's heartbeat PUT, at start and then every ~3 min. Only in
            // iterations that send a heartbeat: just before my PUT the seat still holds whoever wrote last since my
            // previous PUT (the other machine, if there is one), while between two of my PUTs it would be my own write.
            if identity != nil, due.heartbeat, seatMonitor.isDue(now: now()) {
                do {
                    let mine = try await client.presence(role)   // nil = never written: a (negative) read, not a failure
                    if !Task.isCancelled { applyMySeat(mine, at: now()) }
                } catch {
                    // Network trouble: not a read, try again at the next heartbeat.
                }
            }
            async let beat: Void = Self.heartbeat(client, role: role, dnd: dnd, focus: focus, identity: identity, app: app, place: place, look: look, if: due.heartbeat)
            if due.poll {
                do {
                    // v0.8: the whole presence object (lastSeen + the partner's 勿扰); nil = never seen → offline.
                    let info = try await client.presence(role.partner)
                    if !Task.isCancelled { apply(info) }
                } catch {
                    // Network trouble: keep the last known presence.
                }
            }
            _ = await beat
            let wait = schedule.delay(now: now())
            try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(Presence.tolerance(for: wait)))
        }
    }

    private nonisolated static func heartbeat(_ client: FirebaseClient, role: Role, dnd: DNDStatus?, focus: FocusStatus?, identity: PresenceIdentity?, app: String?, place: WeatherPlace?, look: PresenceLook?, if due: Bool) async {
        guard due else { return }
        try? await client.heartbeat(role, dnd: dnd, focus: focus, identity: identity, app: app, place: place, look: look)
    }

    private func applyMySeat(_ info: PresenceInfo?, at now: TimeInterval) {
        mySeatPresence = info
        guard let device = identity?.device else { return }
        let read = SeatClash.detect(mySeatPresence: info, myDevice: device, nowMs: nowMs())
        if let verdict = seatMonitor.record(read: read, now: now) {
            seatClash = verdict
            onSeatClash?(verdict)
        }
    }

    private func reportIdentity() {
        let id = partnerIdentity
        guard id != lastReportedIdentity else { return }
        lastReportedIdentity = id
        onPartnerIdentity?(id)
    }

    private func apply(_ info: PresenceInfo?) {
        let changed = info != partnerPresence
        partnerPresence = info
        partnerNeverSeen = info?.lastSeen == nil && info?.dnd == nil
        report(online: Presence.isOnline(lastSeen: info?.lastSeen, now: nowMs(), thresholdMs: presenceThresholdMs))
        let d = info?.dnd.flatMap { $0.isActive(nowMs: nowMs()) ? $0 : nil }
        if d != partnerDND {
            partnerDND = d
            onPartnerDND?(d)
        }
        let f = info?.focus.flatMap { $0.isActive(nowMs: nowMs()) ? $0 : nil }
        if f != partnerFocus {
            partnerFocus = f
            onPartnerFocus?(f)
        }
        if changed { onPartnerPresence?(info) }
        reportIdentity()
    }

    /// v0.8 send decision from the last presence read (see `Presence.reach`).
    public func partnerReach(connected: Bool) -> PartnerReach {
        Presence.reach(connected: connected, info: partnerPresence, nowMs: nowMs(), thresholdMs: presenceThresholdMs)
    }

    /// Fresh presence check (used right before a send so a partner who just quit is seen as offline).
    /// Returns nil when the check failed (the caller keeps the last known value).
    public func refreshPartnerPresence(timeout: TimeInterval = 1.5) async -> Bool? {
        let client = client, partner = config.role.partner, threshold = presenceThresholdMs
        let seen: PresenceInfo?? = await withTaskGroup(of: PresenceInfo??.self) { group in
            group.addTask {
                do { return .some(try await client.presence(partner)) }   // .some(nil) = never seen
                catch { return nil }                                        // nil = check failed
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let value = seen else { return nil }
        apply(value)
        return Presence.isOnline(lastSeen: value?.lastSeen, now: nowMs(), thresholdMs: threshold)
    }

    /// Clean sign-off before quitting or sleeping: blocks up to `timeout` so the write can finish.
    public func signOffBlocking(timeout: TimeInterval = 1.5) {
        let client = client, role = config.role, dnd = dnd, identity = identity, app = appVersion, place = place
        let signOffLook = look.map { PresenceLook(outfit: $0.outfit) }   // the pose is not on TA's desk any more
        let done = DispatchSemaphore(value: 0)
        Task.detached { try? await client.markOffline(role, dnd: dnd, identity: identity, app: app, place: place, look: signOffLook); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Heartbeat immediately (after wake).
    public func heartbeatNow() {
        let client = client, role = config.role, dnd = dnd, focus = publishedFocus, identity = identity, app = appVersion, place = place, look = look
        Task { try? await client.heartbeat(role, dnd: dnd, focus: focus, identity: identity, app: app, place: place, look: look) }
    }

    private func report(online: Bool) {
        guard online != partnerOnline else { return }
        partnerOnline = online
        onPartnerOnline?(online)
    }

    // MARK: Outbox

    private func flush() {
        guard flushTask == nil, !outbox.isEmpty else { return }
        flushGeneration += 1
        let generation = flushGeneration
        flushTask = Task { [weak self] in
            while let self, !Task.isCancelled, let next = self.outbox.first {
                do {
                    let pushId = try await self.client.post(next)
                    if self.outbox.first?.id == next.id { self.outbox.removeFirst() }
                    self.recordSent(next, pushId: pushId)
                } catch {
                    try? await Task.sleep(nanoseconds: UInt64(Self.outboxRetryInterval * 1_000_000_000))
                }
            }
            if let self, self.flushGeneration == generation { self.flushTask = nil }
        }
    }

    /// Stores a delivered message under its server push id (what the stream echo, the partner and
    /// backfill all see), remembering the local id; falls back to the local id if the server sent none.
    private func recordSent(_ m: Message, pushId: String?) {
        guard let history else { return }
        var record = m
        if let pushId {
            record.id = pushId
            record.localId = m.id
        }
        history.append(record)
    }
}
