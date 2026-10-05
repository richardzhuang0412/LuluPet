import AppKit
import LuluCore

// v0.14 one-click updater, the plumbing: fetch the release feed, download the zip, unzip + verify, hand over to
// the helper script. The rules (JSON, versions, daily check, install location, script text) are in LuluCore (`Updater.swift`).

enum UpdateError: Error, LocalizedError {
    case network(String)
    case badFeed
    case badDownload(String)
    case verification(String)
    case cancelled
    case install(String)

    var errorDescription: String? {
        switch self {
        case .network(let s): return "网络出了点问题（\(s)）"
        case .badFeed: return "发布信息读不懂"
        case .badDownload(let s): return "下载没成功（\(s)）"
        case .verification(let s): return s
        case .cancelled: return "已取消"
        case .install(let s): return "安装没成功（\(s)）"
        }
    }
}

/// One download with progress; the file lands at `dest`.
private final class DownloadJob: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let allowLoopback: Bool
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var moveError: Error?
    private var finished = false

    init(dest: URL, allowLoopback: Bool, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.dest = dest
        self.allowLoopback = allowLoopback
        self.onProgress = onProgress
    }

    func run(_ url: URL, userAgent: String) async throws {
        guard UpdateURLPolicy.isTrustedAsset(url, allowLoopback: allowLoopback) else { throw UpdateError.verification(UpdateCopy.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        let t = s.downloadTask(with: req)
        session = s
        task = t
        defer { s.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                t.resume()
            }
        } onCancel: { t.cancel() }
    }

    /// Every redirect hop must stay on an allowed host (github.com → release-assets.githubusercontent.com today).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url, UpdateURLPolicy.isTrustedAsset(u, allowLoopback: allowLoopback) {
            completionHandler(request)
        } else {
            NSLog("[lulu] update: refusing redirect to %@", request.url?.host ?? "?")
            moveError = UpdateError.verification(UpdateCopy.badURL)
            completionHandler(nil)   // the 3xx becomes the final response; didFinishDownloading reports moveError
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            if moveError == nil { moveError = UpdateError.badDownload("HTTP \(http.statusCode)") }
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)   // must happen before this callback returns
        } catch { moveError = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        if let error {
            if (error as? URLError)?.code == .cancelled { continuation?.resume(throwing: UpdateError.cancelled) }
            else { continuation?.resume(throwing: UpdateError.network(error.localizedDescription)) }
        } else if let moveError {
            continuation?.resume(throwing: moveError)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}

enum AppUpdater {
    /// The newest release from the feed (`override` = hidden `--update-feed`).
    static func fetchLatest(override: String?) async throws -> ReleaseInfo {
        var req = URLRequest(url: UpdateFeed.latestURL(override: override), timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in UpdateFeed.headers(version: AppVersionSource.current) { req.setValue(v, forHTTPHeaderField: k) }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw UpdateError.network(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.network("HTTP \(http.statusCode)") }
        guard let info = UpdateFeed.parse(data, allowLoopback: allowsLoopbackAssets(feedOverride: override)) else { throw UpdateError.badFeed }
        return info
    }

    /// A test feed on this Mac (`--update-feed http://127.0.0.1:…`) may point at assets on this Mac as well.
    static func allowsLoopbackAssets(feedOverride: String?) -> Bool {
        UpdateFeed.sanitizedOverride(feedOverride)?.host.map(UpdateURLPolicy.isLoopback) ?? false
    }

    /// A fresh scratch folder for one update attempt.
    static func makeWorkDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LuluPetUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads the signature (small, first: an unsigned release is refused before the big download) and the zip
    /// to `<workDir>/LuluPet.zip.sig` / `<workDir>/LuluPet.zip`.
    static func download(_ release: ReleaseInfo, into workDir: URL, allowLoopback: Bool,
                         progress: @escaping @Sendable (Double?) -> Void) async throws -> (zip: URL, sig: URL) {
        guard let sigURL = release.sigURL else { throw UpdateError.verification(UpdateCopy.badSignature) }
        let ua = UpdateFeed.userAgent(version: AppVersionSource.current)
        let sigDest = workDir.appendingPathComponent(UpdateFeed.sigAssetName)
        try await DownloadJob(dest: sigDest, allowLoopback: allowLoopback, onProgress: { _ in }).run(sigURL, userAgent: ua)
        let dest = workDir.appendingPathComponent(UpdateFeed.assetName)
        try await DownloadJob(dest: dest, allowLoopback: allowLoopback, onProgress: progress).run(release.assetURL, userAgent: ua)
        return (dest, sigDest)
    }

    /// Runs a tool and collects stdout+stderr. The pipe is drained WHILE the process runs (a tool writing more than the
    /// 64 KB pipe buffer would otherwise block forever, waiting for a reader that only starts at exit).
    private static func runTool(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch { c.resume(returning: (-1, "\(error)")); return }
                try? pipe.fileHandleForWriting.close()   // our copy: EOF arrives when the child exits
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
        }
    }

    /// Checks the Ed25519 signature over the downloaded zip's exact bytes, THEN unzips with ditto and checks the app:
    /// bundle id, version > mine, `codesign --verify --deep --strict`.
    static func stage(zip: URL, sig: URL, in workDir: URL, current: String?) async throws -> URL {
        let zipData = try Data(contentsOf: zip, options: .mappedIfSafe)
        let sigText = try? String(contentsOf: sig, encoding: .utf8)
        let verdict = UpdateSignature.verify(zip: zipData, signatureBase64: sigText)
        guard verdict == .ok else {
            NSLog("[lulu] update: signature check failed: %@", String(describing: verdict))
            throw UpdateError.verification(UpdateCopy.badSignature)
        }
        let out = workDir.appendingPathComponent("unzipped")
        let unzip = await runTool("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
        guard unzip.status == 0 else { throw UpdateError.verification("安装包解压失败") }
        let items = (try? FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)) ?? []
        guard let app = items.first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else {
            throw UpdateError.verification("安装包里没有 App")
        }
        let info = bundle.infoDictionary
        switch UpdateRules.verify(bundleID: bundle.bundleIdentifier, version: info?["CFBundleShortVersionString"] as? String, current: current) {
        case .ok: break
        case .wrongBundleID: throw UpdateError.verification("安装包不是噜噜桌宠")
        case .notNewer: throw UpdateError.verification("安装包的版本不比现在新")
        case .unreadable: throw UpdateError.verification("安装包读不出版本")
        }
        let sign = await runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard sign.status == 0 else {
            NSLog("[lulu] update: codesign verify failed: %@", sign.output)
            throw UpdateError.verification("安装包签名检查没通过")
        }
        return app
    }

    /// Writes the helper script next to the staged app and starts it detached (plain /bin/sh child; once we quit it is
    /// re-parented to launchd and keeps running). The caller terminates the app right after.
    static func launchInstaller(newApp: URL, target: URL, workDir: URL, relaunchArgs: [String]) throws {
        let script = UpdateInstaller.script(pid: ProcessInfo.processInfo.processIdentifier, newApp: newApp.path,
                                            target: target.path, workDir: workDir.path, relaunchArgs: relaunchArgs)
        let scriptURL = workDir.appendingPathComponent("install.sh")
        let logURL = workDir.deletingLastPathComponent().appendingPathComponent("LuluPetUpdate.log")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [scriptURL.path]
            p.standardInput = FileHandle.nullDevice
            if let log = try? FileHandle(forWritingTo: logURL) {
                log.seekToEndOfFile()
                p.standardOutput = log
                p.standardError = log
            }
            try p.run()
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
    }
}
