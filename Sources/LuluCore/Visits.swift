import CoreGraphics
import Foundation

/// Pure rules for visits (docs/superpowers/specs/2026-09-28-visits-design.md): which couple clip a message
/// gets, how long the visitor stays, where pets stand, and (v0.6) what each send does to our pet (`PetLocation`).
public enum Visits {
    /// Horizontal running speed, points per second.
    public static let runSpeed: CGFloat = 220
    /// Gap between the visitor's and the home pet's visible sprites.
    public static let standGap: CGFloat = 16
    /// Minimum time between two "去找TA".
    public static let goCooldown: TimeInterval = 10
    /// Stay after the last bubble is gone (text / sticker / unknown kinds).
    public static let bubbleDwell: TimeInterval = 2

    public static let visitGreeting = "来看看你～想你啦"
    public static let offlineLine = "TA 现在不在哦，等会儿再去找TA吧"

    /// Couple clip names, in `assets/couples.json`.
    public enum CoupleMove: String, Sendable, CaseIterable { case hug, kiss, nuzzle }

    /// The couple clip a message asks for: visits and 想你 / 抱抱 → hug, 亲亲 → kiss, anything else → nuzzle.
    /// `label` is the sticker's label (or nil); both it and the text are searched.
    public static func coupleMove(for kind: Message.Kind, text: String? = nil, label: String? = nil) -> CoupleMove {
        if kind == .visit { return .hug }
        let words = [text, label].compactMap { $0 }.joined(separator: " ")
        if words.contains("亲亲") { return .kiss }
        if words.contains("想你") || words.contains("抱抱") { return .hug }
        return .nuzzle
    }

    /// The clip to actually play: the preferred one if available, else hug; nil = no couple clip
    /// (both pets play `happy` with hearts instead).
    public static func resolveCouple(_ preferred: CoupleMove, available: Set<String>) -> CoupleMove? {
        if available.contains(preferred.rawValue) { return preferred }
        return available.contains(CoupleMove.hug.rawValue) ? .hug : nil
    }

    /// reactions.json `"couple": "none"`: meet without a couple clip.
    public static let noCouple = "none"

    /// v0.3: the couple clip name to play. The message's `reactions.json` couple wins when that clip
    /// exists (any couples.json key; "none" = no clip); otherwise the built-in rule (`resolveCouple`).
    /// Nil = no couple clip (both pets play `happy` with hearts instead).
    public static func coupleName(reaction: String?, preferred: CoupleMove, available: Set<String>) -> String? {
        var rng = SystemRandomNumberGenerator()
        return coupleName(pool: reaction.map { [$0] } ?? [], preferred: preferred, available: available, last: nil, using: &rng)
    }

    /// v0.3.1: picks the couple clip from the message's reaction pool: only built clips (or "none")
    /// count, and never `last` again when the pool has another choice. An empty / unbuilt pool falls
    /// back to the built-in rule (`resolveCouple`). Nil = no couple clip.
    public static func coupleName<G: RandomNumberGenerator>(pool: [String], preferred: CoupleMove, available: Set<String>,
                                                            last: String?, using rng: inout G) -> String? {
        let usable = pool.filter { $0 == noCouple || available.contains($0) }
        if let pick = PoolPick.pick(usable, last: last, using: &rng) { return pick == noCouple ? nil : pick }
        return resolveCouple(preferred, available: available)?.rawValue
    }

    /// v0.11: the couple clip for a meeting under `policy` (nil = no couple clip: both pets play `happy` + hearts).
    /// Same choice as `coupleName(pool:…)`, but only clips the policy allows are candidates: nothing for two of the
    /// same character, no intimate clip (kiss, hug…) unless couple mode. Couple mode keeps the old behaviour.
    public static func meetingCouple<G: RandomNumberGenerator>(pool: [String], preferred: CoupleMove, catalog: CoupleCatalog,
                                                               policy: ContentPolicy, last: String?, using rng: inout G) -> String? {
        guard policy.allowsCoupleClips else { return nil }
        if policy.allowsIntimate {
            return coupleName(pool: pool, preferred: preferred, available: catalog.names, last: last, using: &rng)
        }
        let allowed = Set(catalog.names.filter { policy.allowsCouple(named: $0, catalog: catalog) })
        return coupleName(pool: policy.filterCouplePool(pool, catalog: catalog), preferred: preferred, available: allowed, last: last, using: &rng)
    }

    /// v0.11: whether a couple clip drawn with 噜噜 on the left (or right) must be mirrored so each pet lands on its
    /// own side. Nil when both pets are the same character (no couple clip plays then, `ContentPolicy.allowsCoupleClips`).
    public static func coupleMirrored(clip: CoupleClip, host: PetCharacter, visitor: PetCharacter, hostIsLeft: Bool) -> Bool? {
        guard host != visitor else { return nil }
        return clip.mirrored(luluIsLeft: (host == .lulu) == hostIsLeft)
    }

    /// Couple pools for words in a text message (they win over the kind / default pools):
    /// 亲亲 → kisses, 想你 / 抱抱 → hugs. Nil = no such word.
    public static func keywordCouples(text: String?) -> [String]? {
        guard let text else { return nil }
        if text.contains("亲亲") { return ["kiss", "kiss_2", "kiss_sit"] }
        if text.contains("想你") || text.contains("抱抱") { return ["hug", "hug_sit", "nuzzle", "comfort", "hug_bed"] }
        return nil
    }

    /// Minimum stay after the meeting for a message kind. The visitor also waits until every bubble
    /// has been clicked away.
    public static func dwell(for kind: Message.Kind) -> TimeInterval {
        switch kind {
        case .poke: return 4
        case .visit: return 6
        default: return bubbleDwell
        }
    }
}

public enum Side: String, Sendable { case left, right }

/// Positions in screen points (x = window origin). Windows are wider than the visible sprite, which is
/// horizontally centred in its window, so gaps are measured between sprites.
public struct VisitPlan: Equatable, Sendable {
    /// Screen edge the visitor comes in from (and leaves by).
    public var entrySide: Side
    /// Window x off screen on the entry side.
    public var entryX: CGFloat
    /// Window x where the visitor stands, beside the home pet.
    public var standX: CGFloat
    /// Which side of the home pet the visitor stands on.
    public var standSide: Side
}

public struct GoPlan: Equatable, Sendable {
    /// The nearer screen edge.
    public var side: Side
    /// Window x where the sprite just touches that edge (offline: turn around here).
    public var edgeX: CGFloat
    /// Window x fully past that edge (online: gone visiting).
    public var offscreenX: CGFloat
}

public enum VisitGeometry {
    /// `host` = home pet's visible sprite rect; `visitorWindowWidth` / `visitorSpriteWidth` = the visitor's
    /// window and idle sprite widths; `screen` = visible frame of the home pet's screen.
    /// The visitor enters from the screen edge nearer the host and stands on that side, unless there is no
    /// room there, in which case it runs past the host and stands on the other side.
    public static func arrival(host: CGRect, visitorWindowWidth w: CGFloat, visitorSpriteWidth s: CGFloat,
                               screen: CGRect, gap: CGFloat = Visits.standGap) -> VisitPlan {
        let entry: Side = host.midX < screen.midX ? .left : .right
        let inset = (w - s) / 2
        let leftX = host.minX - gap - s - inset       // visitor sprite's maxX = host.minX - gap
        let rightX = host.maxX + gap - inset          // visitor sprite's minX = host.maxX + gap
        let leftFits = leftX + inset >= screen.minX
        let rightFits = rightX + inset + s <= screen.maxX
        let stand: Side
        switch entry {
        case .left: stand = leftFits || !rightFits ? .left : .right
        case .right: stand = rightFits || !leftFits ? .right : .left
        }
        let entryX = entry == .left ? screen.minX - w : screen.maxX
        return VisitPlan(entrySide: entry, entryX: entryX, standX: stand == .left ? leftX : rightX, standSide: stand)
    }

    /// Where the home pet runs for "去找TA". `window` = the home pet's window frame, `spriteWidth` its
    /// visible sprite width.
    public static func go(window: CGRect, spriteWidth s: CGFloat, screen: CGRect) -> GoPlan {
        let inset = (window.width - s) / 2
        if window.midX < screen.midX {
            return GoPlan(side: .left, edgeX: screen.minX - inset, offscreenX: screen.minX - window.width)
        }
        return GoPlan(side: .right, edgeX: screen.maxX - window.width + inset, offscreenX: screen.maxX)
    }

    /// Seconds to run `distance` points.
    public static func runDuration(_ distance: CGFloat, speed: CGFloat = Visits.runSpeed) -> TimeInterval {
        TimeInterval(abs(distance) / speed)
    }
}

// MARK: - v0.6 送信串门 (every send is a delivery visit)

extension Visits {
    /// Partner offline: how long our pet stays off-screen "looking for TA" before coming back.
    public static let bounceAwaySeconds: TimeInterval = 1.6

    /// How long our pet stays at the partner's after running off with a message.
    public static func deliveryAway(for kind: Message.Kind) -> TimeInterval {
        switch kind {
        case .text, .sticker, .remind: return 12
        case .poke, .visit: return 10
        case .unknown: return 10
        }
    }

    /// Toast when the pet is back from a delivery.
    public static let deliveredToast = "送到啦 ❤️"
    /// Partner offline, a text / sticker was still sent (queued on the server for them).
    public static let offlineQueuedLine = "TA 不在，先放在 TA 那儿啦"
    /// Partner never came online with this pair code (not set up / not paired yet).
    public static let notPairedLine = "还没和 TA 配对哦～把配对码发给 TA，TA 填好就能串门啦"
    public static let notPairedQueuedLine = "还没和 TA 配对哦～消息先存着，TA 配好就能收到"
    /// Card title for what the partner sent while our pet was over at theirs.
    public static let tripCardTitle = "在TA那边的时候，TA说："

    /// Text and stickers are worth leaving for an offline partner; a poke / "去找TA" is only meaningful live.
    public static func sendsWhenOffline(_ kind: Message.Kind) -> Bool { kind == .text || kind == .sticker }

    public enum CollisionWinner: String, Sendable { case me, partner }

    /// Collision: after meeting #1 at the loser's desk, both pets stay this long, then leave together.
    public static let collisionDwell: TimeInterval = 4
    /// Collision: the winner's pet comes home (with the loser's pet) this long after the collision was seen.
    public static let collisionWinnerAway: TimeInterval = 12
    /// Collision: the loser's pet stays at the winner's desk this long, then runs home.
    public static let collisionLoserAway: TimeInterval = 12
    /// Header of the winner's message, kept on the loser's desk until the loser's pet is home again.
    public static let pinnedHeader = "TA 留下的话"

    /// One step of the collision dance, for "my side".
    public enum CollisionStep: Equatable, Sendable {
        // Loser (the partner went first)
        /// Our pet turns back and runs home.
        case turnBack
        /// The partner's pet comes in; meeting #1 for their message (its bubble is kept back, see `showPinned`).
        case hostVisitor(Message)
        /// Both stay together this long (a fixed timer, not bubble clicks, so both Macs stay in step).
        case dwell(TimeInterval)
        /// Both pets run off together, by the edge the visitor came in from.
        case leaveTogether
        /// Our pet stays at the partner's this long.
        case stayAway(TimeInterval)
        /// Our pet runs back home.
        case comeHome
        /// The partner's message, shown now (header `pinnedHeader`), before anything else.
        case showPinned(Message)
        // Winner (we went first)
        /// Our pet stays at the partner's until this long after the collision was seen.
        case stayAwayFor(TimeInterval)
        /// Our pet runs home with the partner's pet alongside; meeting #2 for their message, bubble as usual.
        case comeHomeWithVisitor(Message)
    }

    public struct CollisionPlan: Equatable, Sendable {
        public var winner: CollisionWinner
        public var steps: [CollisionStep]
    }

    /// The collision dance for my side, from the two delivery messages (both sides get mirror-image plans):
    /// the winner's pet visits the loser's desk (meeting #1), both walk back to the winner's desk together
    /// (meeting #2 there), then the loser's pet goes home and finds the winner's message waiting.
    public static func collisionPlan(mine: Message, theirs: Message, me: Role) -> CollisionPlan {
        let winner = resolveCollision(partnerTs: theirs.ts, myTs: mine.ts, partner: me.partner)
        switch winner {
        case .partner:
            return CollisionPlan(winner: .partner, steps: [
                .turnBack, .hostVisitor(theirs), .dwell(collisionDwell), .leaveTogether,
                .stayAway(collisionLoserAway), .comeHome, .showPinned(theirs),
            ])
        case .me:
            return CollisionPlan(winner: .me, steps: [.stayAwayFor(collisionWinnerAway), .comeHomeWithVisitor(theirs)])
        }
    }

    /// Both pets set off at the same time (each side's message has a delivery trip): the earlier message
    /// goes first; on the same millisecond 噜噜 goes first. Both sides compare the same two timestamps
    /// (each sender's own `ts`), so they always agree.
    public static func resolveCollision(partnerTs: Int64, myTs: Int64, partner: Role) -> CollisionWinner {
        if partnerTs < myTs || (partnerTs == myTs && partner == .lulu) { return .partner }
        return .me
    }
}

/// Where our own (home) pet is.
public enum HomePlace: String, Sendable {
    /// On our desk.
    case home
    /// Running off (a delivery) or towards the edge (a bounce).
    case leaving
    /// Off screen, at the partner's.
    case away
    /// Running back home.
    case returning
}

/// What a send does to our pet.
public enum SendAction: Equatable, Sendable {
    /// Run off screen with it (message `trip: "deliver"`), come back after `away` seconds.
    case deliver(away: TimeInterval)
    /// Already out delivering: no new run, stay away at least `away` more seconds (`trip: "local"`).
    case extendAway(away: TimeInterval)
    /// The partner's pet is visiting our desk: meet it right here (`trip: "local"`).
    case localMeeting
    /// Partner offline: run to the edge and turn back; `send` = still send it (`trip: "local"`).
    case bounce(send: Bool)
    /// "去找TA" pressed again within `Visits.goCooldown`: nothing happens.
    case coolingDown(remaining: TimeInterval)
    /// A collision dance is running: just send it (`trip: "local"`), the pets keep to the dance.
    case sendOnly
}

/// What an incoming partner message does, given where our pet is.
public enum IncomingAction: String, Sendable {
    /// Normal visit: the partner's pet runs in, meets ours, says it.
    case showVisitor
    /// Our pet is out (at the partner's), or a collision dance is running: no visitor; shown on the
    /// "在TA那边的时候" card once home.
    case queueForCard
    /// Our pet is on its way home (bounced / returning): show the visitor once it is home.
    case holdUntilHome
    /// Both pets set off at once: run the collision dance (`Visits.collisionPlan`).
    case collision
}

/// v0.6 pure state machine for our pet's location (docs/superpowers/specs/2026-09-28-visits-design.md §12).
/// The app drives it: `planSend` for every send, `sent(ts:)` with the delivered message's timestamp,
/// `reachedAway` / `startReturn` / `arrivedHome` as the pet moves, and `incoming` for partner messages.
public struct PetLocation: Sendable {
    public private(set) var place: HomePlace = .home
    /// `ts` of the message this delivery trip carries (the collision rule compares it).
    public private(set) var tripTs: Int64?
    /// The current trip is a bounce (partner offline): the pet only goes to the edge.
    public private(set) var bouncing = false
    /// Seconds to stay away once off screen (extended by sends while leaving).
    public private(set) var awayFor: TimeInterval = 0
    /// While away: when to come back (same clock as `now`).
    public private(set) var awayEnds: TimeInterval?
    public private(set) var lastGo: TimeInterval?
    public let cooldown: TimeInterval
    /// While a collision dance runs: who went first.
    public private(set) var collision: Visits.CollisionWinner?
    /// Set by the dance: come back at this time (instead of `awayFor` after going off screen).
    private var returnAt: TimeInterval?

    public init(cooldown: TimeInterval = Visits.goCooldown) { self.cooldown = cooldown }

    public var isOut: Bool { place != .home }

    /// Decides (and records) what sending a `kind` message does. `visitorHere` = the partner's pet is on
    /// our desk; `reachable` = connected and the partner is online. Only "去找TA" (`.visit`) has a cooldown.
    ///
    /// v0.8 `partnerDND`: the partner has 勿扰 on — our pet still runs out and comes back (a bounce), but
    /// everything is sent and stored for them, pokes and visits too (`bounce(send: true)`).
    public mutating func planSend(kind: Message.Kind, now: TimeInterval, visitorHere: Bool, reachable: Bool,
                                  partnerDND: Bool = false) -> SendAction {
        if kind == .visit {
            if let lastGo, now - lastGo < cooldown { return .coolingDown(remaining: cooldown - (now - lastGo)) }
            lastGo = now
        }
        let away = Visits.deliveryAway(for: kind)
        if collision != nil { return .sendOnly }
        if bouncing, place != .home {
            // Already bouncing off the edge (partner offline / 勿扰): no new run.
            return .bounce(send: partnerDND || Visits.sendsWhenOffline(kind))
        }
        switch place {
        case .away:
            awayEnds = max(awayEnds ?? now, now + away)
            return .extendAway(away: away)
        case .leaving:
            awayFor = max(awayFor, away)
            return .extendAway(away: away)
        case .home where visitorHere:
            return .localMeeting
        case .home, .returning:
            guard reachable else {
                if place == .home { begin(bounce: true, away: 0) }   // (already returning: just keep going)
                return .bounce(send: partnerDND || Visits.sendsWhenOffline(kind))
            }
            begin(bounce: false, away: away)   // from .returning: turn around and go again
            return .deliver(away: away)
        }
    }

    private mutating func begin(bounce: Bool, away: TimeInterval) {
        place = .leaving
        bouncing = bounce
        tripTs = nil
        awayFor = away
        awayEnds = nil
    }

    /// The delivery's message went out with this timestamp (`PairChannel.send` may bump it).
    public mutating func sent(ts: Int64) {
        guard place == .leaving, !bouncing, tripTs == nil else { return }
        tripTs = ts
    }

    /// Off screen now: come back after `awayFor` (or at the time the dance set).
    public mutating func reachedAway(now: TimeInterval) {
        guard place == .leaving, !bouncing else { return }
        place = .away
        awayEnds = returnAt ?? now + awayFor
        returnAt = nil
    }

    // Collision dance

    public mutating func beginCollision(_ winner: Visits.CollisionWinner) { collision = winner }

    public mutating func endCollision() {
        collision = nil
        returnAt = nil
    }

    /// Dance: come back at `time` (whether still leaving or already away).
    public mutating func setReturn(at time: TimeInterval) {
        if place == .away { awayEnds = time } else { returnAt = time }
    }

    /// Dance (loser): leave home again together with the visitor, to stay away `away` seconds.
    public mutating func leaveAgain(away: TimeInterval) {
        place = .leaving
        bouncing = false
        awayFor = away
        awayEnds = nil
    }

    /// Seconds until the pet should come back (nil unless away).
    public func awayRemaining(now: TimeInterval) -> TimeInterval? { awayEnds.map { max(0, $0 - now) } }

    /// Heading home: the away time is up, the bounce reached the edge, or the collision dance says so.
    public mutating func startReturn() {
        guard place != .home else { return }
        place = .returning
        awayEnds = nil
    }

    public mutating func arrivedHome() {
        place = .home
        returnAt = nil
        bouncing = false
        tripTs = nil
        awayFor = 0
        awayEnds = nil
    }

    /// Where a partner message goes. Only a message whose sender's pet really set off (`isDeliveryTrip`)
    /// can collide with our own delivery.
    public func incoming(_ m: Message) -> IncomingAction {
        if collision != nil { return .queueForCard }
        switch place {
        case .home:
            return .showVisitor
        case .returning:
            // Their pet really came over (or ours only bounced off the edge): meet it at home.
            return bouncing || m.isDeliveryTrip ? .holdUntilHome : .queueForCard
        case .leaving where bouncing:
            return .holdUntilHome
        case .leaving, .away:
            // Their pet set off too (a delivery) while ours is out delivering: both pets are on the road.
            return m.isDeliveryTrip && tripTs != nil ? .collision : .queueForCard
        }
    }
}

// MARK: - v0.7.4 收到 ❤️ + visitor time limit (docs/superpowers/specs/2026-09-28-visits-design.md §14)

extension Visits {
    /// The longest the visitor stays beside our pet (counted from when it starts staying; a new live message
    /// during the visit starts the count again). Then it waves and leaves, and whatever it still had to say
    /// stays on our pet as "TA 留下的话" (unread until acknowledged).
    public static let visitorMaxStay: TimeInterval = 45
    /// The small button on a text / sticker bubble: acknowledges it (same as clicking the bubble).
    public static let ackTitle = "收到 ❤️"

    /// What the staying visitor does now.
    public enum StayDecision: Equatable, Sendable {
        /// Keep staying (minimum dwell not over, or bubbles still waiting and there is time left).
        case wait
        /// Every bubble was acknowledged and the minimum dwell is over: wave and leave.
        case leave
        /// Time is up: wave and leave; the bubbles still waiting move to our pet ("TA 留下的话"), unread.
        case leaveLeavingBubbles
    }

    /// `stayUntil` = end of the minimum dwell; `bubblesWaiting` = a bubble is still showing / queued.
    public static func stayDecision(now: TimeInterval, stayUntil: TimeInterval, bubblesWaiting: Bool,
                                    clock: VisitorStayClock) -> StayDecision {
        if clock.expired(now: now) { return bubblesWaiting ? .leaveLeavingBubbles : .leave }
        if now < stayUntil - 0.01 || bubblesWaiting { return .wait }
        return .leave
    }
}

/// v0.7.4: counts the visitor's stay against `limit` (`Visits.visitorMaxStay`). The app starts it when the
/// visitor starts staying, restarts it for a new live message during the visit, and stops it when the visitor
/// leaves (or the visit is reset).
public struct VisitorStayClock: Equatable, Sendable {
    public var limit: TimeInterval
    public private(set) var startedAt: TimeInterval?

    public init(limit: TimeInterval = Visits.visitorMaxStay) { self.limit = limit }

    public var isRunning: Bool { startedAt != nil }
    /// The visitor started staying: starts the count unless it is already running.
    public mutating func start(now: TimeInterval) { if startedAt == nil { startedAt = now } }
    /// A new live message arrived during the visit: count again from now.
    public mutating func restart(now: TimeInterval) { startedAt = now }
    public mutating func stop() { startedAt = nil }
    public var deadline: TimeInterval? { startedAt.map { $0 + limit } }
    public func remaining(now: TimeInterval) -> TimeInterval? { deadline.map { max(0, $0 - now) } }
    public func expired(now: TimeInterval) -> Bool { deadline.map { now >= $0 - 0.001 } ?? false }
}

/// v0.7.4: the speech-bubble queue (current bubble + waiting ones). Only `acknowledge()` hands an item back
/// as read (the app marks its message read); `leaveAll` (the visitor's time is up) keeps every item, in
/// order, only rewriting it (header "TA 留下的话") — nothing is dropped and nothing becomes read.
public struct AckQueue<Item> {
    public private(set) var current: Item?
    public private(set) var waiting: [Item] = []

    public init() {}

    public var isEmpty: Bool { current == nil }
    public var count: Int { (current == nil ? 0 : 1) + waiting.count }
    public var all: [Item] { (current.map { [$0] } ?? []) + waiting }

    /// Adds an item; true when it became the current bubble.
    @discardableResult
    public mutating func enqueue(_ item: Item) -> Bool {
        if current == nil { current = item; return true }
        waiting.append(item)
        return false
    }

    /// The current bubble was acknowledged (收到 ❤️ / click / auto-hide): returns it (to be marked read)
    /// and makes the next one current.
    public mutating func acknowledge() -> Item? {
        guard let done = current else { return nil }
        current = waiting.isEmpty ? nil : waiting.removeFirst()
        return done
    }

    /// The visitor's time is up: every item stays (same order, unread), rewritten by `transform`.
    public mutating func leaveAll(_ transform: (inout Item) -> Void) {
        if var c = current { transform(&c); current = c }
        for i in waiting.indices { transform(&waiting[i]) }
    }

    public mutating func removeAll() {
        current = nil
        waiting = []
    }
}
