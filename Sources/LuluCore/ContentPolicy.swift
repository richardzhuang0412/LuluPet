import Foundation

/// v0.11 (docs/superpowers/specs/2026-10-05-modes-design.md §2–3): who the partner is and what may be shown.

/// The partner as far as we can tell: the character they draw and their mode.
public struct PartnerIdentity: Equatable, Sendable {
    public var character: PetCharacter
    public var mode: PairMode

    public init(character: PetCharacter, mode: PairMode) {
        self.character = character
        self.mode = mode
    }

    /// Character: `presence.character` → the `character` of their latest message → the character named like
    /// their seat (the couple default). Mode: `presence.mode`, absent = couple.
    public static func resolve(partnerSeat: Role, presence: PresenceInfo?, lastMessageCharacter: PetCharacter?) -> PartnerIdentity {
        PartnerIdentity(character: presence?.character ?? lastMessageCharacter ?? PetCharacter(partnerSeat),
                        mode: presence?.mode ?? .couple)
    }
}

/// What my heartbeat says about me besides `lastSeen` (v0.11: `presence/<seat>/{character,mode,device}`).
public struct PresenceIdentity: Equatable, Sendable {
    public var character: PetCharacter
    public var mode: PairMode
    public var device: String

    public init(character: PetCharacter, mode: PairMode, device: String) {
        self.character = character
        self.mode = mode
        self.device = device
    }
}

/// One place that decides which two-person clips, stickers and sounds may appear.
public struct ContentPolicy: Equatable, Sendable {
    /// The effective mode: solo when I am solo, friend when either side is a friend, else couple.
    public var mode: PairMode
    public var me: PetCharacter
    /// nil when solo.
    public var partner: PetCharacter?

    /// `partnerMode` nil = unknown (older client / not seen yet) → follows my mode.
    public init(myMode: PairMode, partnerMode: PairMode?, me: PetCharacter, partner: PetCharacter?) {
        if myMode == .solo { mode = .solo }
        else if myMode == .friend || partnerMode == .friend { mode = .friend }
        else { mode = .couple }
        self.me = me
        self.partner = mode == .solo ? nil : partner
    }

    /// Kisses, hugs and the like: couple only.
    public var allowsIntimate: Bool { mode == .couple }

    /// Two-person clips need a partner who is a different character (two 噜噜 never hug).
    public var allowsCoupleClips: Bool { mode.isPaired && partner.map { $0 != me } == true }

    public func allowsCouple(_ clip: CoupleClip) -> Bool {
        allowsCoupleClips && (!clip.intimate || allowsIntimate)
    }

    /// Looks the clip up by name; an unknown clip is not allowed.
    public func allowsCouple(named name: String, catalog: CoupleCatalog) -> Bool {
        guard allowsCoupleClips, let clip = catalog.clip(named: name) else { return false }
        return allowsCouple(clip)
    }

    public func allowsSticker(intimate: Bool) -> Bool { !intimate || allowsIntimate }

    /// A reactions.json couple pool without what may not play; the pseudo entry "none" always stays.
    public func filterCouplePool(_ names: [String], catalog: CoupleCatalog) -> [String] {
        names.filter { $0 == "none" || allowsCouple(named: $0, catalog: catalog) }
    }

    /// Couple default: 噜噜 and 噜妹.
    public static let couple = ContentPolicy(myMode: .couple, partnerMode: .couple, me: .lulu, partner: .lumei)
}

/// Two machines on the same seat (both tapped 生成, or picked the same side).
public enum SeatClash {
    /// My seat's presence is online (within the presence threshold) and published by another device. A presence
    /// without `device` (older client) is never a clash. v0.17: neither is my own web version (`device` starting with
    /// `web-`): it shares the seat on purpose and stops writing while this Mac is online (web spec §4.2).
    public static func detect(mySeatPresence: PresenceInfo?, myDevice: String, nowMs: Int64) -> Bool {
        guard let p = mySeatPresence, let device = p.device, device != myDevice,
              !WebClient.isWebDevice(device) else { return false }
        return Presence.isOnline(lastSeen: p.lastSeen, now: nowMs)
    }

    /// 冲突提示.
    public static let message = "配对码好像两边都点了生成（或选了同一边），请一方改成粘贴"
}

/// v0.11 decision logic for the seat-clash notice (the channel only does the reading). A read is only taken at
/// start and then every `interval` (piggybacking on the presence poll, no timer of its own), and the verdict only
/// changes after `confirmations` consecutive reads that disagree with it, so one unlucky read (a heartbeat race,
/// a blip) neither raises nor dismisses the notice. The reads are taken just before my own heartbeat PUT, when the
/// seat still holds whoever wrote last (the other machine, if there is one).
public struct SeatClashMonitor: Sendable {
    /// ~3 min between checks.
    public static let defaultInterval: TimeInterval = 180
    public static let confirmations = 2

    public let interval: TimeInterval
    /// The verdict reported so far.
    public private(set) var clash = false
    private var lastCheck: TimeInterval?
    private var disagreeing = 0

    public init(interval: TimeInterval = SeatClashMonitor.defaultInterval) { self.interval = interval }

    /// True at start (no check yet), once `interval` has passed since the last recorded check, and right away while a
    /// read that disagrees with the verdict still waits for its confirmation (one extra read per change at most, so a
    /// clash is reported about one heartbeat after the read that first saw it instead of a whole interval later).
    public func isDue(now: TimeInterval) -> Bool {
        guard let last = lastCheck else { return true }
        return disagreeing > 0 || now - last >= interval
    }

    /// Records the result of a read taken at `now` (`SeatClash.detect`). Returns the new verdict when it changed,
    /// else nil. A failed read is simply not recorded (the next poll tries again).
    public mutating func record(read: Bool, now: TimeInterval) -> Bool? {
        lastCheck = now
        if read == clash { disagreeing = 0; return nil }
        disagreeing += 1
        guard disagreeing >= Self.confirmations else { return nil }
        disagreeing = 0
        clash = read
        return read
    }
}
