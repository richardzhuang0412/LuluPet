import Foundation

/// v0.11.2: a comparable "major.minor.patch" app version (`CFBundleShortVersionString`, `presence/<seat>/app`).
public struct AppVersion: Comparable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    /// "0.11.2" → (0, 11, 2); "0.12" → (0, 12, 0); a leading "v" is tolerated. Anything else (empty, letters,
    /// negative, more than three parts) → nil.
    public init?(_ string: String?) {
        guard var s = string?.trimmingCharacters(in: .whitespaces) else { return nil }
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        self.init(nums[0], nums[1], nums[2])
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// v0.11.2: what to tell me about the partner's app version. Unknown versions (older client that publishes none,
/// or running outside a bundle) never nudge either way.
public enum UpgradeNudge: Equatable, Sendable {
    /// The partner runs a newer version `version` ("0.12.0"). `shouldBubble` is true only the first time for that version.
    case partnerNewer(version: String, shouldBubble: Bool)
    /// The partner runs an older version.
    case partnerOlder(version: String)
    /// Same version, or one side unknown.
    case none

    /// `lastNudged` = the `upgradeNudgedFor` value (the partner version I was already bubbled about).
    public static func evaluate(mine: String?, partner: String?, lastNudged: String?) -> UpgradeNudge {
        guard let m = AppVersion(mine), let p = AppVersion(partner) else { return .none }
        if p > m {
            let already = AppVersion(lastNudged).map { $0 >= p } ?? false
            return .partnerNewer(version: p.description, shouldBubble: !already)
        }
        if p < m { return .partnerOlder(version: p.description) }
        return .none
    }
}
