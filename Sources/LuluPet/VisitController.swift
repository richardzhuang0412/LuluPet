import AppKit
import LuluCore

/// v0.2 visits (docs/superpowers/specs/2026-09-28-visits-design.md):
/// - the partner's character runs in when they send something, meets the home pet (couple clip or
///   happy + hearts), says it (bubble above the visitor), then waves and runs back out;
/// - v0.6 every send (❤️ / text / sticker / 去找TA) is a delivery: the home pet runs off screen with it and
///   comes back ("送到啦 ❤️"), bounces off the edge when the partner is offline, meets the visitor right here
///   when the partner's pet is on our desk; collisions (both set off at once) are settled by `PetLocation`;
/// - dropping the home pet onto the visitor plays a couple clip.
/// The rules (couple choice, dwell, cooldown, positions, pet location) live in LuluCore `Visits` /
/// `VisitGeometry` / `PetLocation`.
@MainActor
final class VisitController {
    /// One partner message, prepared for the visit.
    struct Event {
        var kind: Message.Kind
        var bubble: BubbleItem?
        var move: Visits.CoupleMove
        /// Live (arrived while connected) vs backlog (arrived while we were away); backlog messages only
        /// queue their bubbles, without per-message reactions.
        var live: Bool
        /// v0.3 reactions.json entry for this message (couple clip / visitor clip), if any.
        var reaction: Reaction? = nil
        /// v0.5 sounds.json keys for the meeting (reactions.json `"sound"`), tried before anything else.
        var sounds: [String] = []
        /// v0.9 built-in sticker sound (angry / cry / happy): tried after the couple clip's own bound
        /// sound (couples.json `"sound"`), before the clip's category sound.
        var fallbackSounds: [String] = []
        /// v0.5 the sender's outfit (message field `outfit`): the visitor wears it if we have it.
        var outfit: String? = nil
        /// v0.6: our own message played as a meeting with the visitor already here (rule 4); never brings
        /// a visitor by itself.
        var local = false
    }

    enum VisitorState: String { case absent, entering, meeting, staying, leaving }

    private(set) var visitorState = VisitorState.absent
    /// v0.6: where our own pet is (home / leaving / away / returning) and the current trip (LuluCore).
    private(set) var location = PetLocation()
    var homeState: HomePlace { location.place }

    /// The bubble anchor may have changed (visitor arrived / left, pet ran): re-anchor the bubble.
    var onLayoutChanged: (() -> Void)?
    /// Sets up a freshly created visitor window (clicks, menu).
    var configureVisitor: ((PetWindow) -> Void)?
    /// Outfit the partner's character wears when visiting.
    var outfitFor: ((Role) -> String?)?
    /// No visitor can be shown (no sprites for the partner): the caller shows the event on the home pet.
    var onNoVisitor: ((Event) -> Void)?
    /// v0.5: play the first of these sounds.json keys that has a sound. v0.9 `visitor` = the character
    /// the sound is about (files restricted to a character in sounds.json only play for it).
    var onSound: (([String], Role?) -> Void)?
    /// v0.6: our pet is back on its desk after a trip (the app then shows the "在TA那边的时候" card).
    var onHome: (() -> Void)?
    /// v0.11 (modes): who the partner is and what may be shown, asked fresh whenever it matters (the partner can
    /// change character / mode while the app runs). `visitor` nil = unknown → the other character.
    var identity: (() -> (visitor: PetCharacter?, policy: ContentPolicy))?

    private let sprites: SpriteCatalog
    private let couples: CoupleCatalog
    private let bubble: BubbleWindow
    private let notice: NoticeWindow
    private weak var host: PetWindow?
    /// The character our own pet draws (v0.11: not necessarily the seat's namesake) and our seat (messages, collisions).
    private var hostCharacter: Role?
    private var hostSeat: Role?
    /// Set by the app before a send: the partner has never come online with this pair code.
    var partnerNotPaired = false
    /// v0.8: set by the app before a send: the partner has 勿扰 on (nil = no).
    var partnerDND: DNDStatus?
    /// v0.10: the partner is in a pomodoro focus round (held like 勿扰: sent, stored, our pet bounces).
    var partnerFocusHold = false
    /// v0.7 "大小": the visitor is drawn at the home pet's size, and the gaps between the pets follow it.
    private(set) var petScale: CGFloat = 1
    private var visitor: PetWindow?
    private var visitorLook: (Role, String)?
    private var plan: VisitPlan?

    private var pending: [BubbleItem] = []
    private var pendingDwell: TimeInterval = 0
    private var pendingMove: Visits.CoupleMove = .hug
    private var pendingHearts = false
    /// reactions.json: couple clip pool for the meeting, and a clip the visitor plays once after it.
    private var pendingCouples: [String] = []
    private var pendingVisitorClip: String?
    private var pendingSounds: [String] = []
    private var pendingFallbackSounds: [String] = []
    /// v0.3.1: a live message that arrived while the visitor was already here gets its own meeting,
    /// played after the current one (at most one waits; a newer message replaces it).
    private var nextMeeting: Event?
    /// Previous picks, so the same couple / visitor clip isn't chosen twice in a row.
    private var lastCouple: String?
    private var lastVisitorClip: String?
    private var rng: any RandomNumberGenerator = SystemRandomNumberGenerator()
    /// The visitor's `stay` pose for this visit (nil = idle).
    private var visitStay: String?
    private var stayUntil: TimeInterval = 0
    private var leaveTimer: Timer?
    /// v0.7.4: the visitor stays at most `Visits.visitorMaxStay` (restarted by a new live message); then it
    /// leaves and its unacknowledged bubbles stay on our pet as "TA 留下的话" (LuluCore `VisitorStayClock`).
    private var stayClock = VisitorStayClock()
    private var limitTimer: Timer?
    /// Hidden `--visitor-max-stay S` (tests).
    var visitorMaxStay: TimeInterval {
        get { stayClock.limit }
        set { stayClock.limit = newValue }
    }
    /// Partner events held until our pet is home again (then shown as a visitor).
    private var queuedWhileAway: [Event] = []
    private var homeOrigin: NSPoint = .zero
    private var awayTimer: Timer?
    /// prelaunch-B17: the partner-offline bounce's 「look around off-screen」 wait; cancellable by `reset()`.
    private var bounceTimer: Timer?
    /// prelaunch-B7: bumped by `reset()`. Clip / run completions started before a reset must not resume the old visit.
    private var epoch = 0
    /// prelaunch-B15: a partner reply (「TA 说马上喝」) that could not ride the return toast home: the app shows it as a home bubble.
    var onToastLost: ((String) -> Void)?
    /// v0.6: shown when the pet is back from a bounce (partner offline) instead of the delivered toast.
    private var homeNotice: String?
    /// v0.14.4: the partner answered a 叫 TA 喝水 / 起来动动 while our pet was at their desk: the return toast says it
    /// (「TA 说马上喝 💧」…) instead of 「送到啦」. Cleared when used / on the next trip.
    var homeToastOverride: String?
    /// v0.6: the message our current delivery trip carries (the collision plan compares it).
    private var tripMessage: Message?
    /// v0.6 collision dance: the steps still to run, and the partner's message as a meeting.
    private var dance: [Visits.CollisionStep] = []
    private var danceEvent: Event?
    private var danceTimer: Timer?
    /// Collision dance: run once the visitor has met the host (instead of the normal stay).
    private var afterMeeting: (() -> Void)?

    init(sprites: SpriteCatalog, couples: CoupleCatalog, bubble: BubbleWindow, notice: NoticeWindow) {
        self.sprites = sprites
        self.couples = couples
        self.bubble = bubble
        self.notice = notice
    }

    private static func log(_ s: String) { NSLog("[lulu] visit: %@", s) }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Wraps a completion so it does nothing once `reset()` has run since it was created (B7).
    private func current(_ f: @escaping () -> Void) -> () -> Void {
        let e = epoch
        return { [weak self] in
            guard let self, self.epoch == e else { return }
            f()
        }
    }

    /// The reply that was to ride the return toast is handed to the app instead of being dropped (B15).
    private func flushToastOverride() {
        guard let line = homeToastOverride else { return }
        homeToastOverride = nil
        onToastLost?(line)
    }

    /// True while anything visit-related is on screen or in motion.
    var isActive: Bool { visitorState != .absent || homeState != .home }

    /// Where partner bubbles point: the visitor while it is here, else nil (= the home pet). A leaving visitor
    /// has nothing left to say (v0.7.4: bubbles left at time-up stay with the home pet).
    var bubbleAnchor: NSRect? {
        guard visitorState != .absent, visitorState != .leaving, let visitor, visitor.isVisible else { return nil }
        return visitor.spriteScreenRect
    }

    var visitorWindow: PetWindow? { visitorState == .absent ? nil : visitor }

    /// New home pet / character (config applied): drops any visit in progress.
    func setHost(_ pet: PetWindow, character: Role, seat: Role? = nil) {
        reset()
        host = pet
        hostCharacter = character
        hostSeat = seat ?? character
    }

    // MARK: v0.11 partner character + content policy

    /// The character of the visiting pet: the partner's as far as known (never changes during a visit), else the
    /// character that isn't ours.
    var visitorCharacter: PetCharacter {
        if visitorState != .absent, let look = visitorLook { return PetCharacter(look.0) }
        return identity?().visitor ?? hostCharacter.map { PetCharacter($0).other } ?? .lumei
    }
    /// The sprite catalog / sounds / reactions still key characters by `Role` (same raw values).
    private var visitorRole: Role { Role(rawValue: visitorCharacter.rawValue) ?? .lumei }

    /// Which two-person clips and sounds may play with this partner (couple default when nobody told us).
    var policy: ContentPolicy {
        if let p = identity?().policy { return p }
        let me = hostCharacter.map(PetCharacter.init) ?? .lulu
        return ContentPolicy(myMode: .couple, partnerMode: .couple, me: me, partner: me.other)
    }

    /// v0.4 (the pet is being hidden): ends any visit like `reset()`, but hands back the bubbles that
    /// were waiting to be shown so nothing unread is lost.
    func resetKeepingBubbles() -> [BubbleItem] {
        var items = pending + queuedWhileAway.compactMap(\.bubble)
        // A collision dance can't go on: the partner's message it was keeping back is handed back too (B8: whoever won;
        // only the loser's one was kept back under the 「TA 留下的话」 header).
        if location.collision != nil, var b = danceEvent?.bubble {
            if location.collision == .partner { b.header = Visits.pinnedHeader }
            items.append(b)
        }
        reset()
        return items
    }

    func reset() {
        epoch += 1
        bounceTimer?.invalidate(); bounceTimer = nil
        flushToastOverride()
        dance = []
        danceEvent = nil
        danceTimer?.invalidate(); danceTimer = nil
        afterMeeting = nil
        location.endCollision()
        leaveTimer?.invalidate(); leaveTimer = nil
        stopStayClock()
        awayTimer?.invalidate(); awayTimer = nil
        visitor?.stopRunning()
        visitor?.setRest(.idle)
        visitor?.orderOut(nil)
        if homeState != .home, let host {
            host.stopRunning()
            host.setFrameOrigin(homeOrigin)
            host.orderFrontRegardless()
        }
        host?.inputLocked = false
        host?.setPetHidden(false)
        visitorState = .absent
        location.arrivedHome()
        homeNotice = nil
        pending = []
        nextMeeting = nil
        queuedWhileAway = []
    }

    // MARK: Partner visits us

    /// A partner message arrived: run in (or continue the current visit) and say it.
    func partner(_ e: Event) {
        if homeState != .home {
            queuedWhileAway.append(e)
            Self.log("\(e.kind.rawValue) queued: home pet is out (\(homeState.rawValue))")
            return
        }
        guard let host, host.isVisible, let visitor = prepareVisitor(outfit: e.outfit) else {
            Self.log("no visitor sprites for \(visitorCharacter.rawValue), showing \(e.kind.rawValue) on the home pet")
            onNoVisitor?(e)
            return
        }
        let dwell = Visits.dwell(for: e.kind)
        switch visitorState {
        case .absent where e.local:
            Self.log("local \(e.kind.rawValue) meeting dropped: no visitor here")
        case .absent:
            arrive(e, host: host, visitor: visitor)
        case .entering, .meeting:
            if let b = e.bubble { pending.append(b) }
            pendingDwell = max(pendingDwell, dwell)
            pendingHearts = pendingHearts || e.kind == .poke
            if e.live {
                // Its own meeting once this one is over (bubble already queued above).
                if nextMeeting != nil { Self.log("replacing the waiting meeting (\(nextMeeting!.kind.rawValue))") }
                var next = e
                next.bubble = nil
                nextMeeting = next
                Self.log("\(e.kind.rawValue) arrived during the visit (\(visitorState.rawValue)): another meeting queued")
            } else {
                Self.log("\(e.kind.rawValue) joins the visit in progress (\(visitorState.rawValue))")
            }
        case .staying:
            if e.live {
                Self.log("\(e.kind.rawValue) while staying: meeting again")
                nextMeeting = nil   // this newer message takes the place of any waiting one
                meetAgain(e)
            } else {
                Self.log("\(e.kind.rawValue) continues the visit (dwell reset to \(Int(dwell)) s)")
                if let b = e.bubble { bubble.enqueue(b) }
                stayUntil = now + dwell
                scheduleLeaveCheck()
            }
        case .leaving:
            // Turn around and come back instead of leaving (and meet again for a live message).
            guard let plan else { return }
            visitorState = .entering
            pending = []
            load(e)
            Self.log("\(e.kind.rawValue) while leaving: visitor turns back")
            visitor.run(toX: plan.standX, completion: current { [weak self] in
                guard let self else { return }
                if e.live { self.meet() } else { self.stay() }
            })
        }
    }

    /// Takes over `e` as the message of the next meeting / stay (its bubble is added to `pending`).
    private func load(_ e: Event) {
        if let b = e.bubble { pending.append(b) }
        pendingDwell = Visits.dwell(for: e.kind)
        pendingMove = e.move
        pendingHearts = e.kind == .poke
        pendingCouples = e.reaction?.couples ?? []
        pendingVisitorClip = visitorClip(e)
        pendingSounds = e.sounds
        pendingFallbackSounds = e.fallbackSounds
    }

    /// A built-in sound about the visiting pet (arrive / leave / its pokes).
    private func sound(_ e: SoundEvent) { onSound?([e.rawValue], visitorRole) }
    /// A built-in sound about our own pet (it sets off / comes home).
    private func homeSound(_ e: SoundEvent) { onSound?([e.rawValue], hostCharacter) }

    /// Plays a reactions.json visitor clip once, with its bound sound (v0.9: the spec's `"sound"`, played
    /// as the clip starts so a voice line stays aligned with the picture).
    private func playVisitorClip(_ name: String, on visitor: PetWindow, completion: (() -> Void)?) -> Bool {
        guard visitor.playNamed(name, completion: completion) else { return false }
        if let key = visitor.namedSound(name) {
            Self.log("visitor reaction sound: \(key)")
            onSound?([key], visitorRole)
        }
        return true
    }

    /// A random clip from the reactions.json visitor pool for the visiting character.
    private func visitorClip(_ e: Event) -> String? {
        guard hostCharacter != nil, var pool = e.reaction?.visitorClips(for: visitorRole) else { return nil }
        // Only clips the visitor's current outfit actually has (an outfit never borrows another costume's).
        if let visitor { pool = pool.filter { visitor.hasNamed($0) } }
        guard let name = PoolPick.pick(pool, last: lastVisitorClip, using: &rng) else { return nil }
        lastVisitorClip = name
        return name
    }

    /// The visitor is already beside the host: play a new meeting for `e`, then stay again.
    private func meetAgain(_ e: Event) {
        guard visitorState == .staying else { return }
        leaveTimer?.invalidate(); leaveTimer = nil
        stayClock.restart(now: now)   // v0.7.4: a new live message → the visitor may stay the full time again
        visitorState = .entering   // meet() starts from here
        pending = []
        load(e)
        meet()
    }

    /// Call after a bubble was clicked away: the visitor may leave once all are read.
    func bubbleDismissed() { checkLeave() }

    /// The visitor window, dressed (when it isn't on screen) in `requested` (the message's outfit) if
    /// this app has it, else the partner character's preferred outfit.
    private func prepareVisitor(outfit requested: String?) -> PetWindow? {
        let partner = visitorRole
        guard hostCharacter != nil,
              let outfit = OutfitRules.visitorOutfit(requested: requested, available: sprites.outfits(for: partner),
                                                     fallback: outfitFor?(partner) ?? sprites.preferredOutfit(for: partner))
        else { return nil }
        if let requested, requested != outfit { Self.log("outfit \(requested) not available here, wearing \(outfit)") }
        let w: PetWindow
        if let visitor { w = visitor } else {
            w = PetWindow(defaults: nil, isVisitor: true)
            configureVisitor?(w)
            visitor = w
        }
        if visitorState == .absent, w.petScale != petScale { w.setPetScale(petScale) }
        if visitorLook.map({ $0 != (partner, outfit) }) ?? true, visitorState == .absent {
            w.setCharacter(sprites, character: partner, outfit: outfit)
            visitorLook = (partner, outfit)
            Self.log("visitor wears \(outfit)\(requested == outfit ? " (sender's outfit)" : "")")
        }
        return w
    }

    /// Every display's frame, so "off screen" never lands on a neighbouring monitor (B16).
    private var allScreenFrames: [NSRect] { NSScreen.screens.map(\.frame) }

    private func screenFrame(for rect: NSRect) -> NSRect {
        (NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func arrive(_ e: Event, host: PetWindow, visitor: PetWindow) {
        let p = VisitGeometry.arrival(host: host.visibleSpriteScreenRect, visitorWindowWidth: visitor.frame.width,
                                      visitorSpriteWidth: visitor.idleSpriteWidth, screen: screenFrame(for: host.frame),
                                      gap: Visits.standGap * petScale, others: allScreenFrames)
        startVisitor(e, plan: p, host: host, visitor: visitor)
        visitor.run(toX: p.standX, completion: current { [weak self] in self?.meet() })
    }

    /// Puts the visitor at the edge, ready to run in for `e` (the caller starts the run).
    private func startVisitor(_ e: Event, plan p: VisitPlan, host: PetWindow, visitor: PetWindow) {
        plan = p
        visitorState = .entering
        pending = []
        nextMeeting = nil
        load(e)
        visitStay = visitor.stayNames.randomElement()
        visitor.setRest(.idle)
        visitor.setFrameOrigin(NSPoint(x: p.entryX, y: host.frame.minY))
        visitor.setPetHidden(false)
        visitor.inputLocked = true
        visitor.orderFrontRegardless()
        sound(.arrive)
        Self.log("visitor entering from \(p.entrySide.rawValue) edge, will stand \(p.standSide.rawValue) of host "
                 + "(\(e.kind.rawValue), \(e.live ? "live" : "backlog"), run clip: \(visitor.hasClip(.run) ? "yes" : "fallback idle+bob"))")
    }

    private func meet() {
        guard visitorState == .entering, let host, let visitor else { return }
        visitorState = .meeting
        let available = couples.names
        let policy = self.policy
        let name = Visits.meetingCouple(pool: pendingCouples, preferred: pendingMove, catalog: couples, policy: policy, last: lastCouple, using: &rng)
        lastCouple = name ?? Visits.noCouple
        let clip = name.flatMap { couples.clip(named: $0) }
        onSound?(SoundEvent.meetingKeys(reaction: pendingSounds, clipSound: clip?.sound, fallback: pendingFallbackSounds, couple: name),
                 visitorRole)
        pendingSounds = []
        pendingFallbackSounds = []
        let poolText = pendingCouples.isEmpty ? "built-in \(pendingMove.rawValue)" : "pool \(pendingCouples)"
        if let name, let cc = clip {
            Self.log("meeting: picked \(name) from \(poolText)")
            playCouple(cc, name: name, host: host, visitor: visitor, completion: current { [weak self] in self?.stay() })
        } else {
            Self.log("meeting: no couple clip from \(poolText) (have \(available.sorted()); policy \(policy.mode.rawValue), "
                     + "\(policy.allowsCoupleClips ? "intimate \(policy.allowsIntimate ? "ok" : "refused")" : "same character")), both play happy + hearts")
            bothHappy(host: host, visitor: visitor, completion: current { [weak self] in self?.stay() })
        }
    }

    private func playCouple(_ cc: CoupleClip, name: String, host: PetWindow, visitor: PetWindow, completion: @escaping () -> Void) {
        let h = host.visibleSpriteScreenRect, v = visitor.visibleSpriteScreenRect
        let luluIsLeft = (hostCharacter == .lulu) == (h.midX < v.midX)
        let mirrored = Visits.coupleMirrored(clip: cc, host: hostCharacter.map(PetCharacter.init) ?? .lulu, visitor: visitorCharacter,
                                             hostIsLeft: h.midX < v.midX) ?? false
        Self.log("meeting: couple \(name) (\(mirrored ? "mirrored" : "as drawn"), 噜噜 on the \(luluIsLeft ? "left" : "right"))")
        host.setPetHidden(true)
        host.inputLocked = true
        visitor.playCouple(cc.clip, mirrored: mirrored, heightFactor: CGFloat(cc.heightFactor), centerX: (h.midX + v.midX) / 2, baseline: host.frame.minY) { [weak host] in
            host?.setPetHidden(false)
            host?.inputLocked = false
            // Never stand there frozen next to the visitor: a happy beat, then back to idle.
            host?.playOnce(.happy)
            completion()
        }
    }

    private func bothHappy(host: PetWindow, visitor: PetWindow, completion: @escaping () -> Void) {
        host.playOnce(.happy)
        host.showHearts()
        visitor.showHearts()
        visitor.playOnce(.happy, completion: completion)
    }

    private func stay() {
        // B7: only a visit that is still on its way in / meeting (a reset in between leaves `.absent`).
        guard let visitor, visitorState == .entering || visitorState == .meeting else { return }
        visitorState = .staying
        if visitor.petScale != petScale { setPetScale(petScale) }   // the size changed during its run / meeting
        if let next = afterMeeting {
            // Collision dance (meeting #1 at the loser's desk): the dance decides when to go.
            afterMeeting = nil
            visitor.inputLocked = false
            visitor.setRest(visitStay.map { .stay($0) } ?? .idle)
            pendingVisitorClip.map { _ = playVisitorClip($0, on: visitor, completion: nil) }
            pendingVisitorClip = nil
            if pendingHearts { visitor.showHearts(); sound(.poke) }
            pendingHearts = false
            pending = []
            onLayoutChanged?()
            Self.log("visitor staying beside host for the collision dance")
            next()
            return
        }
        visitor.inputLocked = false
        visitor.setRest(visitStay.map { .stay($0) } ?? .idle)
        // Visitor reaction clip once, then (if another live message came meanwhile) the next meeting.
        let startNext: () -> Void = { [weak self] in
            guard let self, self.visitorState == .staying, let next = self.nextMeeting else { return }
            self.nextMeeting = nil
            Self.log("next meeting for the \(next.kind.rawValue) that arrived during the last one")
            self.meetAgain(next)
        }
        if let name = pendingVisitorClip, playVisitorClip(name, on: visitor, completion: startNext) {
            Self.log("visitor reaction: \(name)")
        } else {
            if let name = pendingVisitorClip { Self.log("visitor reaction: no clip \(name), skipped") }
            if nextMeeting != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { startNext() } }
        }
        // In case the reaction clip is cut short (its completion is then dropped).
        if nextMeeting != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 6) { startNext() } }
        pendingVisitorClip = nil
        onLayoutChanged?()   // bubble now points at the visitor
        if pendingHearts {
            visitor.showHearts()
            sound(.poke)
        }
        let items = pending
        pending = []
        pendingHearts = false
        items.forEach(bubble.enqueue)
        stayUntil = now + pendingDwell
        stayClock.start(now: now)
        Self.log("visitor staying beside host (at least \(Int(pendingDwell)) s, \(items.count) bubble(s), pose \(visitStay.map { "stay \($0)" } ?? "idle (no stay clip)"), "
                 + String(format: "leaves by itself in %.0f s); frame %@", stayClock.remaining(now: now) ?? 0, NSStringFromRect(visitor.frame)))
        scheduleLeaveCheck()
        scheduleLimitTimer()
    }

    /// v0.7.4: fires when the visitor's time is up.
    private func scheduleLimitTimer() {
        limitTimer?.invalidate()
        guard let wait = stayClock.remaining(now: now) else { limitTimer = nil; return }
        let t = Timer(timeInterval: max(0.05, wait), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeave() }
        }
        RunLoop.main.add(t, forMode: .common)
        limitTimer = t
    }

    private func stopStayClock() {
        stayClock.stop()
        limitTimer?.invalidate(); limitTimer = nil
    }

    private func scheduleLeaveCheck() {
        leaveTimer?.invalidate()
        let t = Timer(timeInterval: max(0.05, stayUntil - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLeave() }
        }
        RunLoop.main.add(t, forMode: .common)
        leaveTimer = t
    }

    private func checkLeave() {
        guard visitorState == .staying, location.collision == nil else { return }
        switch Visits.stayDecision(now: now, stayUntil: stayUntil, bubblesWaiting: bubble.isShowingSomething, clock: stayClock) {
        case .wait:
            // Leaves after the last bubble is acknowledged (bubbleDismissed) or when its time is up (limitTimer).
            if now < stayUntil - 0.01 { scheduleLeaveCheck() }
        case .leave:
            leave()
        case .leaveLeavingBubbles:
            nextMeeting = nil   // its bubble is already queued
            let n = bubble.leaveAllForHost()
            Self.log(String(format: "time up (%.0f s): visitor leaves, %ld bubble(s) stay with the host as \"%@\" (unread)",
                            stayClock.limit, n, Visits.pinnedHeader))
            leave()
        }
    }

    private func leave() {
        guard let visitor, let plan else { return }
        leaveTimer?.invalidate(); leaveTimer = nil
        stopStayClock()
        visitorState = .leaving
        onLayoutChanged?()   // v0.7.4: bubbles left at time-up point at our pet right away
        visitor.inputLocked = true
        visitor.setRest(.idle)
        Self.log("visitor leaving: \(visitor.hasClip(.wave) ? "wave" : "happy (no wave clip)"), then back to the \(plan.entrySide.rawValue) edge")
        visitor.playOnce(.wave, completion: current { [weak self, weak visitor] in
            guard let self, let visitor, self.visitorState == .leaving else { return }
            self.sound(.leave)   // v0.15.4: the footsteps start with the walk off screen (after the wave)
            visitor.run(toX: plan.entryX) { [weak self, weak visitor] in
                guard let self, self.visitorState == .leaving else { return }
                visitor?.orderOut(nil)
                self.visitorState = .absent
                self.onLayoutChanged?()
                Self.log("visitor gone")
            }
        })
    }

    // MARK: v0.7 size

    /// The pet size changed (menu 大小 / handle released; the home pet is already resized). A visitor
    /// standing beside the host is resized and moved to its new spot at once; one on the move keeps its
    /// size until this visit is over (the next one comes at the new size).
    func setPetScale(_ s: CGFloat) {
        petScale = s
        guard let host, let visitor else { return }
        switch visitorState {
        case .absent:
            visitor.setPetScale(s)
        case .staying:
            visitor.setPetScale(s)
            let p = VisitGeometry.arrival(host: host.visibleSpriteScreenRect, visitorWindowWidth: visitor.frame.width,
                                          visitorSpriteWidth: visitor.idleSpriteWidth, screen: screenFrame(for: host.frame),
                                          gap: Visits.standGap * s, others: allScreenFrames)
            plan = p
            visitor.setFrameOrigin(NSPoint(x: p.standX, y: host.frame.minY))
            Self.log("visitor resized to \(String(format: "%.2f", Double(s))), now \(p.standSide.rawValue) of host; frame \(NSStringFromRect(visitor.frame))")
            onLayoutChanged?()
        case .entering, .meeting, .leaving:
            Self.log("visitor busy (\(visitorState.rawValue)): new size from its next visit")
        }
    }

    /// True while the home pet may change size right now (not on a trip / in a couple clip).
    var hostCanResize: Bool { homeState == .home && visitorState != .meeting }

    // MARK: Drag the home pet onto the visitor

    /// Home pet dropped after a drag that started at `origin`. If it overlaps the visitor, both merge
    /// into a couple clip (hug or kiss) and then return to where they were. Returns true when handled.
    func homeDragEnded(from origin: NSPoint) -> Bool {
        // B6: not during a collision dance (the dance owns both pets; a merge would hide the home pet for good).
        guard visitorState == .staying, location.collision == nil, let host, let visitor,
              host.visibleSpriteScreenRect.intersects(visitor.visibleSpriteScreenRect) else { return false }
        leaveTimer?.invalidate(); leaveTimer = nil
        stayClock.restart(now: now)   // v0.7.4: playing with the visitor gives it the full time again
        visitorState = .meeting
        pendingDwell = max(Visits.bubbleDwell, stayUntil - now)
        let name = Visits.meetingCouple(pool: ["hug", "kiss", "hug_sit", "kiss_sit"].filter(couples.names.contains),
                                        preferred: .hug, catalog: couples, policy: policy, last: lastCouple, using: &rng)
        lastCouple = name
        let merged = name.flatMap { couples.clip(named: $0) }
        onSound?(SoundEvent.meetingKeys(reaction: [], clipSound: merged?.sound, fallback: [], couple: name), visitorRole)
        Self.log("merge: home pet dropped onto visitor")
        let done: () -> Void = current { [weak self, weak host] in
            host?.slide(to: origin, save: true, completion: self?.current { self?.stay() })
        }
        if let name, let cc = couples.clip(named: name) {
            playCouple(cc, name: name, host: host, visitor: visitor, completion: done)
        } else {
            Self.log("merge: no hug/kiss clip (have \(couples.names.sorted())), both play happy + hearts")
            host.slide(to: origin, save: true, completion: current { [weak self, weak host, weak visitor] in
                guard let self, let host, let visitor else { return }
                self.bothHappy(host: host, visitor: visitor, completion: self.current { self.stay() })
            })
        }
        return true
    }

    // MARK: v0.6 every send is a delivery visit (docs/superpowers/specs/2026-09-28-visits-design.md §12)

    /// What a partner message does given where our pet is (LuluCore `PetLocation.incoming`).
    func incomingAction(for m: Message) -> IncomingAction {
        let action = location.incoming(m)
        if homeState != .home {
            Self.log("incoming \(m.kind.rawValue) ts \(m.ts) trip \(m.trip ?? "(none)") while \(homeState.rawValue)"
                     + "\(location.bouncing ? " (bounce)" : ""), my trip ts \(location.tripTs.map(String.init) ?? "-")"
                     + " → \(action.rawValue)")
        }
        return action
    }

    /// Every send (❤️, text, sticker, 去找TA). `send(trip)` transmits the message with that `trip` value and
    /// returns the timestamp it went out with (nil = not sent). `local` = the message as a meeting event
    /// (no bubble), used when the partner's pet is on our desk.
    @discardableResult
    func dispatchSend(kind: Message.Kind, reachable: Bool, partnerDND dnd: Bool = false, local: Event, send: (String) -> Message?) -> SendAction {
        let before = homeState
        let action = location.planSend(kind: kind, now: now, visitorHere: visitorState != .absent, reachable: reachable, partnerDND: dnd)
        Self.log("send \(kind.rawValue) (home \(before.rawValue), visitor \(visitorState.rawValue), partner \(dnd ? "勿扰" : reachable ? "reachable" : "offline")) → \(action)")
        guard let host else { return action }
        switch action {
        case .coolingDown(let remaining):
            Self.log(String(format: "go: ignored, cooling down (%.1f s left)", remaining))
        case .deliver(let away):
            if before == .home { homeOrigin = host.frame.origin }
            homeNotice = nil
            flushToastOverride()   // B15: a new trip replaces the toast; the reply it would have carried shows as a bubble
            host.inputLocked = true
            notice.dismiss()
            homeSound(.goVisit)
            let m = send(Message.tripDeliver) ?? Message(from: hostSeat ?? hostCharacter ?? .lulu, kind: kind, ts: nowMs(), trip: Message.tripDeliver)
            tripMessage = m
            location.sent(ts: m.ts)
            let p = VisitGeometry.go(window: host.frame, spriteWidth: host.idleSpriteWidth, screen: screenFrame(for: host.frame), others: allScreenFrames)
            Self.log("deliver: \(before == .returning ? "turning around, " : "")running off the \(p.side.rawValue) edge with the \(kind.rawValue) "
                     + "(trip ts \(location.tripTs.map(String.init) ?? "-"), away \(Int(away)) s)")
            host.run(toX: p.offscreenX) { [weak self, weak host] in
                guard let self, self.homeState == .leaving, !self.location.bouncing else { return }
                self.location.reachedAway(now: self.now)
                host?.orderOut(nil)
                self.scheduleAwayTimer()
            }
        case .sendOnly:
            _ = send(Message.tripLocal)
            Self.log("collision dance running (\(location.collision?.rawValue ?? "-") first): just sent, the pets keep to the dance")
        case .extendAway:
            _ = send(Message.tripLocal)
            if homeState == .away { scheduleAwayTimer() }
            Self.log(homeState == .away
                     ? String(format: "deliver: already away, back in %.1f s", location.awayRemaining(now: now) ?? 0)
                     : "deliver: still leaving, will stay away \(Int(location.awayFor)) s")
        case .localMeeting:
            _ = send(Message.tripLocal)
            Self.log(visitorState != .absent ? "local meeting with the visitor (our pet stays home)"
                                             : "local meeting once the visitor has come in")
            partner(local)
        case .bounce(let sent):
            if sent { _ = send(Message.tripLocal) }
            if dnd {
                homeNotice = partnerDND == nil && partnerFocusHold ? Visits.focusBounceLine
                                                                   : DND.bounceLine(partnerDND)   // v0.8: everything was sent and is stored for TA
            } else if sent || homeNotice == nil {
                homeNotice = partnerNotPaired ? (sent ? Visits.notPairedQueuedLine : Visits.notPairedLine)
                                              : (sent ? Visits.offlineQueuedLine : Visits.offlineLine)
            }
            if location.bouncing, before == .home {
                homeOrigin = host.frame.origin
                host.inputLocked = true
                notice.dismiss()
                homeSound(.goVisit)
                let p = VisitGeometry.go(window: host.frame, spriteWidth: host.idleSpriteWidth, screen: screenFrame(for: host.frame), others: allScreenFrames)
                Self.log("bounce: partner \(dnd ? (partnerDND == nil && partnerFocusHold ? "专注" : "勿扰") : "offline") → run off the \(p.side.rawValue) edge, look for TA, come back (\(sent ? "sent, queued for TA" : "nothing sent"))")
                // Run off-screen like a real trip, "look around" out there for a moment, then come back.
                host.run(toX: p.offscreenX) { [weak self] in
                    guard let self, self.homeState == .leaving else { return }
                    Self.log(String(format: "bounce: off-screen, back in %.1f s", Visits.bounceAwaySeconds))
                    self.bounceTimer?.invalidate()
                    let t = Timer(timeInterval: Visits.bounceAwaySeconds, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.bounceTimer = nil; self?.runHome() }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    self.bounceTimer = t
                }
            } else {
                Self.log("bounce: pet already on the move (\(homeState.rawValue)), \(sent ? "sent" : "nothing sent")")
            }
        }
        return action
    }

    private func scheduleAwayTimer() {
        awayTimer?.invalidate()
        let wait = location.awayRemaining(now: now) ?? 0
        let t = Timer(timeInterval: max(0.05, wait), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.awayTimeUp() }
        }
        RunLoop.main.add(t, forMode: .common)
        awayTimer = t
        Self.log(String(format: "deliver: away at the partner's (back in %.1f s)", wait))
    }

    private func awayTimeUp() {
        if location.collision != nil { nextStep() } else { runHome() }
    }

    /// `then` (collision dance): called once home instead of the usual toast / card / queued visitors.
    private func runHome(then: (() -> Void)? = nil) {
        guard let host, homeState == .leaving || homeState == .away else {
            // Already home (e.g. the loser's pet never left): the dance must still move on (B17).
            then?()
            return
        }
        awayTimer?.invalidate(); awayTimer = nil
        let bounced = location.bouncing
        // B16: the display it set off from may be gone (unplugged) — come home to one that exists.
        let safe = VisitGeometry.clampHome(origin: homeOrigin, size: host.frame.size, screens: NSScreen.screens.map(\.visibleFrame))
        if safe != homeOrigin {
            Self.log("home position \(NSStringFromPoint(homeOrigin)) is off every display → \(NSStringFromPoint(safe))")
            homeOrigin = safe
            host.setFrameOrigin(NSPoint(x: host.frame.minX, y: safe.y))
        }
        location.startReturn()
        host.orderFrontRegardless()
        if !bounced { Self.log("running home") }
        host.run(toX: homeOrigin.x) { [weak self, weak host] in
            guard let self, let host, self.homeState == .returning else { return }
            self.location.arrivedHome()
            host.inputLocked = false
            if let then {
                Self.log("back home (collision dance)")
                self.onLayoutChanged?()
                then()
                return
            }
            if let line = self.homeNotice {
                self.notice.show(title: nil, body: line, autoHide: 4, beside: host.spriteScreenRect)
                self.homeSound(.notHome)
                Self.log("back home, told \"\(line)\"")
                self.flushToastOverride()   // B15: the notice has no room for the partner's reply
            } else {
                let toast = self.homeToastOverride ?? Visits.deliveredToast
                host.showToast(toast)
                host.showHearts()
                self.homeSound(.goBack)
                Self.log("back home, toast \"\(toast)\"")
            }
            self.homeNotice = nil
            self.homeToastOverride = nil   // (consumed by the toast above, or flushed)
            self.onLayoutChanged?()
            self.onHome?()
            let queued = self.queuedWhileAway
            self.queuedWhileAway = []
            queued.forEach { self.partner($0) }
        }
    }

    // MARK: v0.6 collision dance (both pets set off at once)

    /// A partner delivery arrived while ours is on the road: run the collision dance from the two messages
    /// (LuluCore `Visits.collisionPlan`, the same on both Macs). `e` is their message as a meeting (with its bubble).
    func collide(with m: Message, event e: Event) {
        guard let me = hostSeat ?? hostCharacter else { return }
        let mine = tripMessage ?? Message(from: me, kind: .visit, ts: location.tripTs ?? nowMs())
        let plan = Visits.collisionPlan(mine: mine, theirs: m, me: me)
        location.beginCollision(plan.winner)
        dance = plan.steps
        danceEvent = e
        Self.log("collision: my \(mine.kind.rawValue) ts \(mine.ts) vs their \(m.kind.rawValue) ts \(m.ts) → "
                 + (plan.winner == .me ? "I go first (winner)" : "TA goes first (loser)")
                 + "; plan: \(plan.steps.map(Self.stepName).joined(separator: " → "))")
        nextStep()
    }

    private static func stepName(_ s: Visits.CollisionStep) -> String {
        switch s {
        case .turnBack: return "turnBack"
        case .hostVisitor(let m): return "hostVisitor(\(m.kind.rawValue))"
        case .dwell(let t): return "dwell(\(Int(t)) s)"
        case .leaveTogether: return "leaveTogether"
        case .stayAway(let t): return "stayAway(\(Int(t)) s)"
        case .comeHome: return "comeHome"
        case .showPinned(let m): return "showPinned(\(m.kind.rawValue))"
        case .stayAwayFor(let t): return "stayAwayFor(\(Int(t)) s)"
        case .comeHomeWithVisitor(let m): return "comeHomeWithVisitor(\(m.kind.rawValue))"
        }
    }

    private func nextStep() {
        guard location.collision != nil else { return }
        guard !dance.isEmpty else { finishDance(); return }
        let step = dance.removeFirst()
        Self.log("collision step: \(Self.stepName(step))")
        switch step {
        case .turnBack:
            if homeState == .leaving || homeState == .away {
                Self.log("turn back: TA goes first")
                runHome { [weak self] in self?.nextStep() }
            } else {
                nextStep()
            }
        case .hostVisitor:
            guard let host, var e = danceEvent, let visitor = prepareVisitor(outfit: e.outfit) else {
                // No sprites for the partner's pet: its message shows on the home pet instead of vanishing (B17).
                if let e = danceEvent { danceEvent?.bubble = nil; onNoVisitor?(e) }
                nextStep()
                return
            }
            e.bubble = nil   // kept back: shown when our pet is home again (showPinned)
            e.live = true
            afterMeeting = { [weak self] in self?.nextStep() }
            arrive(e, host: host, visitor: visitor)
        case .dwell(let t):
            danceTimer?.invalidate()
            let timer = Timer(timeInterval: t, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.nextStep() }
            }
            RunLoop.main.add(timer, forMode: .common)
            danceTimer = timer
        case .leaveTogether:
            leaveTogether()
        case .stayAway(let t), .stayAwayFor(let t):
            location.setReturn(at: now + t)
            if homeState == .away { scheduleAwayTimer() }   // still leaving: scheduled once off screen
            else { Self.log(String(format: "collision: back %.0f s from now (still leaving)", t)) }
        case .comeHome:
            runHome { [weak self] in self?.nextStep() }
        case .showPinned:
            showPinned()
            nextStep()
        case .comeHomeWithVisitor:
            comeHomeWithVisitor()
        }
    }

    /// Loser: the winner's message, kept back during meeting #1, now that our pet is home.
    private func showPinned() {
        guard var b = danceEvent?.bubble else { return }
        danceEvent?.bubble = nil
        b.header = Visits.pinnedHeader
        Self.log("pinned: showing \"\(Visits.pinnedHeader)\" (\(danceEvent?.kind.rawValue ?? "?"))")
        bubble.enqueue(b)
        onLayoutChanged?()
    }

    /// Loser: after meeting #1 both pets run off together by the edge the visitor came in from.
    private func leaveTogether() {
        guard let host, let visitor, let plan, visitorState != .absent else { nextStep(); return }
        leaveTimer?.invalidate(); leaveTimer = nil
        stopStayClock()
        visitorState = .leaving
        visitor.inputLocked = true
        visitor.setRest(.idle)
        homeOrigin = host.frame.origin
        host.setPetHidden(false)   // B6: never leave with the home pet drawn invisible
        host.inputLocked = true
        location.leaveAgain(away: 0)
        sound(.leave)
        let screen = screenFrame(for: host.frame)
        let hostX = VisitGeometry.offscreenX(side: plan.entrySide, windowWidth: host.frame.width, screen: screen, others: allScreenFrames)
        Self.log("leave together: both pets run off the \(plan.entrySide.rawValue) edge")
        var running = 2
        let done: () -> Void = { [weak self] in
            running -= 1
            guard running == 0, let self else { return }
            self.location.reachedAway(now: self.now)
            Self.log("leave together: both gone (our pet is at TA's now)")
            self.nextStep()
        }
        visitor.run(toX: plan.entryX) { [weak self, weak visitor] in
            visitor?.orderOut(nil)
            self?.visitorState = .absent
            self?.onLayoutChanged?()
            done()
        }
        host.run(toX: hostX) { [weak host] in
            host?.orderOut(nil)
            done()
        }
    }

    /// Winner: our pet runs home from the edge it left by, the partner's pet alongside; meeting #2 here,
    /// then the visitor stays and leaves by the usual rules (its bubble is shown as usual).
    private func comeHomeWithVisitor() {
        guard let host, let e = danceEvent, let visitor = prepareVisitor(outfit: e.outfit) else {
            if let e = danceEvent { danceEvent?.bubble = nil; onNoVisitor?(e) }   // B17: show it on the home pet
            runHome { [weak self] in self?.nextStep() }
            return
        }
        awayTimer?.invalidate(); awayTimer = nil
        location.startReturn()
        let homeFrame = NSRect(origin: homeOrigin, size: host.frame.size)
        let homeSprite = host.visibleSpriteScreenRect.offsetBy(dx: homeOrigin.x - host.frame.minX, dy: 0)
        let p = VisitGeometry.arrival(host: homeSprite, visitorWindowWidth: visitor.frame.width,
                                      visitorSpriteWidth: visitor.idleSpriteWidth, screen: screenFrame(for: homeFrame),
                                      gap: Visits.standGap * petScale, others: allScreenFrames)
        host.orderFrontRegardless()
        startVisitor(e, plan: p, host: host, visitor: visitor)
        danceEvent?.bubble = nil   // B8: now in `pending` (a reset hands it back from there, not twice)
        // A step behind ours, so the two are seen running in one after the other.
        let behind = visitor.idleSpriteWidth * 0.8
        visitor.setFrameOrigin(NSPoint(x: host.frame.minX + (p.entrySide == .left ? -behind : behind), y: visitor.frame.minY))
        Self.log("come home together: our pet and TA's pet run in from the \(p.entrySide.rawValue) edge")
        var running = 2
        let done: () -> Void = { [weak self] in
            running -= 1
            if running == 0 { self?.meet() }
        }
        host.run(toX: homeOrigin.x) { [weak self, weak host] in
            guard let self, let host else { return }
            self.location.arrivedHome()
            host.inputLocked = false
            self.onLayoutChanged?()
            done()
            self.nextStep()   // → finishDance
        }
        visitor.run(toX: p.standX) { done() }
    }

    private func finishDance() {
        dance = []
        danceEvent = nil
        danceTimer?.invalidate(); danceTimer = nil
        location.endCollision()
        flushToastOverride()   // B15: a dance never uses the return toast
        Self.log("collision: dance over")
        onHome?()
        let queued = queuedWhileAway
        queuedWhileAway = []
        queued.forEach { partner($0) }
    }
}
