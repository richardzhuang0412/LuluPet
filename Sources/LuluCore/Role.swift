import Foundation

/// Which partner is using this copy of the app. Since v0.2 the desktop shows the user's *own*
/// character; the partner's character only appears while visiting (docs/superpowers/specs/2026-09-28-visits-design.md).
public enum Role: String, Codable, CaseIterable, Sendable {
    case lulu, lumei

    public var partner: Role { self == .lulu ? .lumei : .lulu }
    public var displayName: String { self == .lulu ? "噜噜" : "噜妹" }
}

/// v0.11: which character is drawn. `Role` is the *seat* (A = lulu, B = lumei: the wire value, Firebase paths,
/// `message.from`); the character defaults to the seat's namesake (couple mode) but can be chosen freely.
public enum PetCharacter: String, Codable, Sendable, CaseIterable {
    case lulu, lumei

    public var displayName: String { self == .lulu ? "噜噜" : "噜妹" }
    public var other: PetCharacter { self == .lulu ? .lumei : .lulu }
    /// A seat's namesake character.
    public init(_ seat: Role) { self = seat == .lulu ? .lulu : .lumei }
}

/// v0.11: 一个人 / 情侣 / 朋友. Absent in a stored config = couple (every install before v0.11).
public enum PairMode: String, Codable, Sendable, CaseIterable {
    case solo, couple, friend

    /// Talks to a partner through Firebase.
    public var isPaired: Bool { self == .couple || self == .friend }
}

/// Current time in Unix milliseconds.
public func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
