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
    private let onProgress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var moveError: Error?
    private var finished = false

    init(dest: URL, onProgress: @escaping @Sendable (Double?) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
    }

    func run(_ url: URL, userAgent: String) async throws {
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

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = UpdateError.badDownload("HTTP \(http.statusCode)")
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
        guard let info = UpdateFeed.parse(data) else { throw UpdateError.badFeed }
        return info
    }

    /// A fresh scratch folder for one update attempt.
    static func makeWorkDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("LuluPetUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Downloads the asset to `<workDir>/LuluPet.zip`.
    static func download(_ release: ReleaseInfo, into workDir: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let dest = workDir.appendingPathComponent(UpdateFeed.assetName)
        try await DownloadJob(dest: dest, onProgress: progress).run(release.assetURL, userAgent: UpdateFeed.userAgent(version: AppVersionSource.current))
        return dest
    }

    private static func runTool(_ path: String, _ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { c in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { proc in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                c.resume(returning: (proc.terminationStatus, String(decoding: d, as: UTF8.self)))
            }
            do { try p.run() } catch { c.resume(returning: (-1, "\(error)")) }
        }
    }

    /// Unzips with ditto and checks the app: bundle id, version > mine, `codesign --verify --deep --strict`.
    static func stage(zip: URL, in workDir: URL, current: String?) async throws -> URL {
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

    /// The launch arguments the new instance should get (a profile / test flags survive the restart; the one-shot
    /// `--demo-update*` triggers do not).
    static func relaunchArguments(_ all: [String]) -> [String] {
        var out: [String] = []
        var skipValue = false
        for a in all.dropFirst() {
            if skipValue { skipValue = false; if !a.hasPrefix("-") { continue } }
            if a.hasPrefix("--demo-update") { skipValue = true; continue }
            if a.hasPrefix("-psn_") { continue }
            out.append(a)
        }
        return out
    }
}
