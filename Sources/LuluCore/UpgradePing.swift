import Foundation

/// v0.15.5 「📣 叫 TA 升级」: a normal TEXT message (every older version shows it as a regular text bubble + visit)
/// plus the additive field `upgradeTo` = the sender's app version. Older clients keep the field in `Message.extra`
/// and just show the text; a newer client whose own version is below `upgradeTo` adds a 「一键更新」 button.
public enum UpgradePing {
    /// Wire key (additive, docs/upgrade-compat.md §14).
    public static let field = "upgradeTo"

    public static func text(version: String) -> String {
        "我升级到 v\(version) 啦，你也点 🍊 →「检查更新…」升级一下吧～"
    }

    /// The ping message; nil when `version` is not a parseable version (nothing is sent then).
    public static func message(from: Role, version: String?, ts: Int64 = nowMs()) -> Message? {
        guard let v = AppVersion(version)?.description else { return nil }
        return Message(from: from, kind: .text, text: text(version: v), ts: ts, extra: [field: .string(v)])
    }

    /// Already pinged for my current version (`upgradePingSent` = the version I last pinged from).
    public static func alreadySent(mine: String?, sent: String?) -> Bool {
        guard let m = AppVersion(mine), let s = AppVersion(sent) else { return false }
        return s >= m
    }

    /// The button is offered only while the partner's version is known and older than mine and I have not pinged
    /// for this version yet (an upgrade of mine re-arms it).
    public static func canPing(mine: String?, partner: String?, sent: String?) -> Bool {
        guard let m = AppVersion(mine), let p = AppVersion(partner), p < m else { return false }
        return !alreadySent(mine: mine, sent: sent)
    }

    /// 「一键更新」 on a received ping: only when it names a version newer than mine (unparseable → plain text).
    public static func shouldShowUpdateButton(message: Message, mine: String?) -> Bool {
        guard message.kind == .text, let target = AppVersion(message.upgradeTo), let m = AppVersion(mine) else { return false }
        return target > m
    }
}

extension Message {
    /// v0.15.5 (optional, kind `text`): the sender's version in a 叫 TA 升级 ping. Lives in `extra`
    /// (older clients keep it there too); non-string values read as nil.
    public var upgradeTo: String? {
        if case .string(let s)? = extra[UpgradePing.field] { return s }
        return nil
    }
}
