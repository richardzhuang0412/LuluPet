import CryptoKit
import Foundation

/// v0.14 one-click updater: the pure rules (release JSON, "is it newer", daily check, skip, install location,
/// bundle verification, the helper script). The network / ditto / codesign plumbing lives in LuluPet (`AppUpdater`).

/// What the GitHub Releases `latest` endpoint says about the newest release.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var tag: String
    /// The `LuluPet.zip` asset's `browser_download_url`.
    public var assetURL: URL
    /// The `LuluPet.zip.sig` asset (base64 Ed25519 signature of the zip bytes); nil = the release is unsigned.
    public var sigURL: URL?
    /// The release notes (markdown body, may be empty).
    public var notes: String
    /// The release's web page (for the manual-update fallback); nil if the feed did not carry one.
    public var pageURL: URL?

    public init(version: AppVersion, tag: String, assetURL: URL, notes: String, pageURL: URL? = nil, sigURL: URL? = nil) {
        self.version = version; self.tag = tag; self.assetURL = assetURL; self.notes = notes; self.pageURL = pageURL
        self.sigURL = sigURL
    }
}

public enum UpdateFeed {
    public static let repo = "richardzhuang0412/LuluPet"
    public static let assetName = "LuluPet.zip"
    public static let sigAssetName = "LuluPet.zip.sig"
    public static let bundleID = "com.lulupet.app"
    /// The page to send people to when the app can not update itself.
    public static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!

    /// The hidden `--update-feed <url>` is accepted only as https, or http to this Mac (127.0.0.1 / localhost / ::1);
    /// anything else (plain http to a remote host, file:, junk) → nil.
    public static func sanitizedOverride(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else { return nil }
        if scheme == "https" { return u }
        return scheme == "http" && UpdateURLPolicy.isLoopback(host) ? u : nil
    }

    /// `override` (the hidden `--update-feed <url>`) is used as the whole feed URL; invalid / empty → the GitHub API.
    public static func latestURL(override: String? = nil) -> URL {
        sanitizedOverride(override) ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    public static func userAgent(version: String?) -> String { "LuluPet/\(version ?? "dev")" }

    /// Headers of the (unauthenticated) request.
    public static func headers(version: String?) -> [String: String] {
        ["User-Agent": userAgent(version: version), "Accept": "application/vnd.github+json"]
    }

    /// `tag_name` "v0.14.0" / "0.14.0" (and a missing / unparseable tag, a draft, a prerelease, or no `LuluPet.zip`
    /// asset) → nil. The asset is looked up by name, not by position.
    public static func parse(_ data: Data, allowLoopback: Bool = false) -> ReleaseInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = AppVersion(tag) else { return nil }
        if (obj["draft"] as? Bool) == true || (obj["prerelease"] as? Bool) == true { return nil }
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlString = asset["browser_download_url"] as? String, let url = URL(string: urlString),
              UpdateURLPolicy.isTrustedAsset(url, allowLoopback: allowLoopback) else { return nil }
        // The signature asset is optional here (an unsigned release is refused at install time, with a reason).
        let sig = assets.first(where: { ($0["name"] as? String) == sigAssetName })
            .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            .flatMap { UpdateURLPolicy.isTrustedAsset($0, allowLoopback: allowLoopback) ? $0 : nil }
        // The page is only ever opened in the browser: https on github.com or nothing (→ the fixed releases page).
        let page = (obj["html_url"] as? String).flatMap(URL.init(string:)).flatMap { UpdateURLPolicy.isTrustedPage($0) ? $0 : nil }
        return ReleaseInfo(version: version, tag: tag, assetURL: url, notes: (obj["body"] as? String) ?? "", pageURL: page, sigURL: sig)
    }
}

/// Where release files and pages may come from.
public enum UpdateURLPolicy {
    /// What GitHub serves release downloads from: github.com redirects to release-assets.githubusercontent.com
    /// (objects.githubusercontent.com is the older host and is still allowed).
    public static let assetHosts: Set<String> = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"]

    public static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
    }

    /// https on an allowed GitHub host; with `allowLoopback` (a test feed on this Mac) also http(s) to loopback.
    public static func isTrustedAsset(_ url: URL, allowLoopback: Bool = false) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" && assetHosts.contains(host) { return true }
        return allowLoopback && (scheme == "http" || scheme == "https") && isLoopback(host)
    }

    /// The release web page we open in the browser: https on github.com.
    public static func isTrustedPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
    }
}

/// Ed25519 check of a downloaded zip against the compiled-in public key. Fails closed: no usable key, no
/// signature or a bad one → not `.ok`.
public enum UpdateSignature {
    public enum Result: Equatable, Sendable {
        case ok
        case noKey       // the build has the placeholder / a malformed key: nothing can verify
        case missing     // the release has no signature
        case malformed   // the signature is not base64 of 64 bytes
        case mismatch    // does not verify (tampered zip, wrong key)
    }

    public static func verify(zip: Data, signatureBase64: String?, publicKeyBase64: String = UpdateKey.publicKeyBase64) -> Result {
        guard let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return .noKey }
        guard let text = signatureBase64?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return .missing }
        guard let sig = Data(base64Encoded: text), sig.count == 64 else { return .malformed }
        return key.isValidSignature(sig, for: zip) ? .ok : .mismatch
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

    /// Waits (at most ~2 min) for `pid` to exit (if it is still alive after that, aborts and leaves the old app
    /// alone: nothing is replaced, the staging folder is removed), copies `newApp` next to `target` as `<target>.new`, swaps it in
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
        if kill -0 \(pid) 2>/dev/null; then
          echo "old app (pid \(pid)) still running after the wait, leaving it alone"; rm -rf \(shQuote(workDir)); exit 1
        fi
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

extension UpdateInstaller {
    /// The launch arguments the new instance should get: a profile / test flags survive the restart, but every
    /// `--update-*` (feed, allow-dir, auto-confirm) and one-shot `--demo-update*` flag is dropped, so a test feed
    /// never outlives the instance it was given to.
    public static func relaunchArguments(_ all: [String]) -> [String] {
        var out: [String] = []
        var skipValue = false
        for a in all.dropFirst() {
            if skipValue { skipValue = false; if !a.hasPrefix("-") { continue } }
            if a == "--update-auto-confirm" { continue }                       // bare flag, takes no value
            if a.hasPrefix("--update-") || a.hasPrefix("--demo-update") { skipValue = true; continue }
            if a.hasPrefix("-psn_") { continue }
            out.append(a)
        }
        return out
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
    /// Unsigned release, bad / missing signature, or a build without a signing key: refuse.
    public static let badSignature = "更新包签名不对，已取消（为了安全）"
    public static let badURL = "更新地址不在 GitHub 上，已取消（为了安全）"
    public static let installing = "正在安装，马上重启…"
    public static let checkFailed = "检查更新失败了，稍后再试试吧"
    /// The releases feed answered 404: the GitHub repo isn't public (yet) or has no release.
    public static let feedNotFound = "还连不上 GitHub 的发布页（仓库可能还没公开），这次先用安装包更新吧"
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
