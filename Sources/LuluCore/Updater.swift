import Foundation

/// v0.14 one-click updater: the pure rules (release JSON, "is it newer", daily check, skip, install location,
/// bundle verification, the helper script). The network / ditto / codesign plumbing lives in LuluPet (`AppUpdater`).

/// What the GitHub Releases `latest` endpoint says about the newest release.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var tag: String
    /// The `LuluPet.zip` asset's `browser_download_url`.
    public var assetURL: URL
    /// The release notes (markdown body, may be empty).
    public var notes: String
    /// The release's web page (for the manual-update fallback); nil if the feed did not carry one.
    public var pageURL: URL?

    public init(version: AppVersion, tag: String, assetURL: URL, notes: String, pageURL: URL? = nil) {
        self.version = version; self.tag = tag; self.assetURL = assetURL; self.notes = notes; self.pageURL = pageURL
    }
}

public enum UpdateFeed {
    public static let repo = "richardzhuang0412/LuluPet"
    public static let assetName = "LuluPet.zip"
    public static let bundleID = "com.lulupet.app"
    /// The page to send people to when the app can not update itself.
    public static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// `override` (the hidden `--update-feed <url>`) is used as the whole feed URL; invalid / empty → the GitHub API.
    public static func latestURL(override: String? = nil) -> URL {
        if let s = override?.trimmingCharacters(in: .whitespaces), !s.isEmpty,
           let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil {
            return u
        }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    public static func userAgent(version: String?) -> String { "LuluPet/\(version ?? "dev")" }

    /// Headers of the (unauthenticated) request.
    public static func headers(version: String?) -> [String: String] {
        ["User-Agent": userAgent(version: version), "Accept": "application/vnd.github+json"]
    }

    /// `tag_name` "v0.14.0" / "0.14.0" (and a missing / unparseable tag, a draft, a prerelease, or no `LuluPet.zip`
    /// asset) → nil. The asset is looked up by name, not by position.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
        if (obj["draft"] as? Bool) == true || (obj["prerelease"] as? Bool) == true { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:))
        return ReleaseInfo(version: version, tag: tag, assetURL: url, notes: (obj["body"] as? String) ?? "", pageURL: page)
    }
}

public enum UpdateRules {
    public static let checkInterval: TimeInterval = 24 * 3600

    public static func isNewer(_ release: ReleaseInfo, than current: String?) -> Bool {
        guard let cur = AppVersion(current) else { return false }
        return release.version > cur
    }

    /// The automatic check runs once a day. `lastCheck` = `updateLastCheck` (Unix seconds); nil = never. A time in
    /// the future (clock set back) counts as due again.
    public static func isCheckDue(lastCheck: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last = lastCheck else { return true }
        return now < last || now - last >= checkInterval
    }

    /// When the next automatic check should run (Unix seconds).
    public static func nextCheck(lastCheck: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let last = lastCheck, last <= now else { return now }
        return last + checkInterval
    }

    /// Whether to tell me about `release`: it must be newer than me; an automatic check stays quiet about the
    /// version I skipped (「以后再说」), a manual check (menu / button) always answers.
    public static func shouldNotify(_ release: ReleaseInfo, current: String?, skipped: String?, manual: Bool) -> Bool {
        guard isNewer(release, than: current) else { return false }
        if manual { return true }
        guard let s = AppVersion(skipped) else { return true }
        return release.version > s
    }

    public enum Verify: Equatable, Sendable {
        case ok
        case wrongBundleID
        case notNewer
        case unreadable
    }

    /// The downloaded app must be ours (`com.lulupet.app`) and newer than the running one.
    public static func verify(bundleID: String?, version: String?, current: String?) -> Verify {
        guard let bundleID, let v = AppVersion(version) else { return .unreadable }
        if bundleID != UpdateFeed.bundleID { return .wrongBundleID }
        guard let cur = AppVersion(current), v > cur else { return .notNewer }
        return .ok
    }

    /// Self-update only for an `.app` bundle sitting directly in /Applications or ~/Applications (a place the
    /// user can write); anything else (Downloads, a DMG, `swift run`) → manual update. `extraAllowed` is the hidden
    /// test flag's folder.
    public static func canSelfUpdate(bundlePath: String?, home: String, extraAllowed: [String] = []) -> Bool {
        guard let bundlePath, bundlePath.hasSuffix(".app") else { return false }
        let parent = (bundlePath as NSString).deletingLastPathComponent
        let ok = ["/Applications", (home as NSString).appendingPathComponent("Applications")] + extraAllowed
        return ok.contains { (parent as NSString).standardizingPath == ($0 as NSString).standardizingPath }
    }
}

/// The helper shell script that swaps the app in once we have quit.
public enum UpdateInstaller {
    /// Single-quote for /bin/sh.
    public static func shQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Waits (at most ~2 min) for `pid` to exit, copies `newApp` next to `target` as `<target>.new`, swaps it in
    /// (the old one is kept as `<target>.old` until the swap worked and restored if it did not), clears quarantine,
    /// removes the staging folder and relaunches with `args`. Nothing here touches UserDefaults / Application Support.
    public static func script(pid: Int32, newApp: String, target: String, workDir: String, relaunchArgs: [String]) -> String {
        let t = shQuote(target), n = shQuote(target + ".new"), o = shQuote(target + ".old")
        let args = relaunchArgs.isEmpty ? "" : " --args " + relaunchArgs.map(shQuote).joined(separator: " ")
        return """
        #!/bin/sh
        # LuluPet updater helper (generated). Runs detached after the app quits.
        i=0
        while kill -0 \(pid) 2>/dev/null && [ $i -lt 400 ]; do sleep 0.3; i=$((i+1)); done
        sleep 0.5
        rm -rf \(n) \(o)
        if ! /usr/bin/ditto \(shQuote(newApp)) \(n); then
          echo "ditto failed"; rm -rf \(n); /usr/bin/open \(t)\(args); exit 1
        fi
        if ! mv \(t) \(o); then
          echo "could not move the old app away"; rm -rf \(n); /usr/bin/open \(t)\(args); exit 1
        fi
        if ! mv \(n) \(t); then
          echo "swap failed, restoring"; mv \(o) \(t); /usr/bin/open \(t)\(args); exit 1
        fi
        rm -rf \(o)
        /usr/bin/xattr -dr com.apple.quarantine \(t) 2>/dev/null
        rm -rf \(shQuote(workDir))
        /usr/bin/open \(t)\(args)
        echo "updated"

        """
    }
}

/// Chinese UI strings of the updater (kept here so they are covered by tests).
public enum UpdateCopy {
    public static func upToDate(_ v: String?) -> String { "已经是最新版\(v.map { " v\($0)" } ?? "")" }
    public static func menuLine(_ v: String) -> String { "有新版本 v\(v)" }
    public static func cardText(_ v: String) -> String { "有新版本 v\(v) · 更新\n点「更新」会自动下载并安装" }
    public static func downloading(_ fraction: Double?) -> String {
        guard let f = fraction else { return "正在下载…" }
        return "正在下载… \(Int((min(max(f, 0), 1) * 100).rounded()))%"
    }
    public static let verifying = "正在检查新版本…"
    public static let installing = "正在安装，马上重启…"
    public static let checkFailed = "检查更新失败了，稍后再试试吧"
    public static let manualNeeded = "请手动更新"
    public static func manualBody(_ v: String) -> String {
        "噜噜桌宠不在「应用程序」文件夹里，没法自动替换自己。请到发布页下载 v\(v)，把「应用程序」里的旧版换成新的。"
    }
    public static func confirmTitle(_ v: String) -> String { "更新到 v\(v)？" }
    public static let confirmBody = "会下载新版本并替换现在的 App，然后自动重启。聊天记录和设置不会丢。"
    public static func failed(_ reason: String) -> String { "更新没成功：\(reason)" }
    public static func upgradeHelp(version: String?) -> String {
        "让 TA 点一下 🍊 菜单里的「检查更新…」，有新版本就能一键更新。如果不行，就把桌面上的 LuluPet-v\(version ?? "X").zip 发给 TA，TA 解压后，把「应用程序」里的旧版噜噜桌宠替换成新的。"
    }
}
