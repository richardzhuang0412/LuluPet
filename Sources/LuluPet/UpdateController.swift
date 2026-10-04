import AppKit
import LuluCore
import SwiftUI

// v0.14 one-click updater, the flow: daily check (a housekeeping task, no timer of its own), manual checks (menu,
// 更新日志 window, partner-upgrade bubble), the 「有新版本」 card, the progress panel, and the hand-over to the helper.

/// Hidden test flags (`--update-feed`, `--update-auto-confirm`, `--update-allow-dir`).
struct UpdateOptions {
    var feed: String?
    var autoConfirm = false
    var allowDir: String?
}

@MainActor
final class UpdateController {
    struct Env {
        var store: ConfigStore
        var options: UpdateOptions
        /// My pet's screen rect (nil = none on screen).
        var petRect: () -> NSRect?
        var bubble: BubbleWindow
        var notice: NoticeWindow
        /// The pet is on screen and nothing (hidden / 勿扰 / focus round) holds bubbles back.
        var bubbleFree: () -> Bool
        var menuLine: (String?) -> Void
        var needsArm: () -> Void
        var terminate: () -> Void
    }

    private let env: Env
    private let progress = UpdateProgressPanel()
    private let launchWall = Date().timeIntervalSince1970
    private var checking = false
    private var updating = false
    private var updateTask: Task<Void, Never>?
    /// The newest release known to be newer than me (feeds the menu line and 「更新」).
    private(set) var available: ReleaseInfo?
    /// A found release whose card still has to be shown (the pet was busy), and the versions already carded this run.
    private var pendingCard: ReleaseInfo?
    private var carded: Set<String> = []

    init(env: Env) { self.env = env }

    private var current: String? { AppVersionSource.current }
    private var now: TimeInterval { Date().timeIntervalSince1970 }

    /// No version (swift run) or a test instance without its own feed: no automatic checks, so tests never hit GitHub.
    private var autoEnabled: Bool {
        current != nil && (!Offscreen.enabled || env.options.feed != nil)
    }

    // MARK: Daily check (housekeeping `.updateCheck`)

    /// Wall-clock deadline of the next automatic check; nil while one is running / an update is under way / disabled.
    /// A due check waits 20 s after launch so it never competes with the start-up.
    func deadline() -> TimeInterval? {
        guard autoEnabled, !checking, !updating else { return nil }
        return max(UpdateRules.nextCheck(lastCheck: env.store.updateLastCheck, now: now), launchWall + 20)
    }

    func runAuto() {
        guard autoEnabled, !checking, !updating, UpdateRules.isCheckDue(lastCheck: env.store.updateLastCheck, now: now) else { return }
        check(manual: false)
    }

    /// Something that was holding bubbles back ended.
    func showCardIfFree() {
        guard let r = pendingCard, env.bubbleFree() else { return }
        pendingCard = nil
        showCard(r)
    }

    // MARK: Checks

    /// `report` (the 更新日志 window's button) gets the one-line result; then the pet does not repeat the plain messages.
    /// `thenUpdate`: a found update goes straight to the confirm step (「一键更新」 on the partner-upgrade bubble).
    func check(manual: Bool, thenUpdate: Bool = false, report: ((String) -> Void)? = nil) {
        guard !checking, !updating else { report?("正在更新…"); return }
        if thenUpdate, let r = available { begin(r); return }
        checking = true
        env.needsArm()
        let feed = env.options.feed
        Task { @MainActor in
            let result: Result<ReleaseInfo, Error>
            do { result = .success(try await AppUpdater.fetchLatest(override: feed)) }
            catch { result = .failure(error) }
            self.checking = false
            self.env.store.updateLastCheck = self.now   // failures count too: no retry storm when offline
            self.env.needsArm()
            self.finishCheck(result, manual: manual, thenUpdate: thenUpdate, report: report)
        }
    }

    private func finishCheck(_ result: Result<ReleaseInfo, Error>, manual: Bool, thenUpdate: Bool, report: ((String) -> Void)?) {
        switch result {
        case .failure(let error):
            NSLog("[lulu] update: check failed: %@", error.localizedDescription)
            if manual { report?(UpdateCopy.checkFailed); if report == nil { say(UpdateCopy.checkFailed) } }
        case .success(let release):
            NSLog("[lulu] update: latest is v%@ (mine %@)", release.version.description, current ?? "?")
            guard UpdateRules.isNewer(release, than: current) else {
                available = nil
                env.menuLine(nil)
                if manual { let t = UpdateCopy.upToDate(current); report?(t); if report == nil { say(t) } }
                return
            }
            available = release
            env.menuLine(UpdateCopy.menuLine(release.version.description))
            if thenUpdate { begin(release); return }
            guard UpdateRules.shouldNotify(release, current: current, skipped: env.store.updateSkipped, manual: manual) else {
                NSLog("[lulu] update: v%@ was skipped, staying quiet", release.version.description)
                return
            }
            report?(UpdateCopy.menuLine(release.version.description))
            if manual || !carded.contains(release.version.description) { showCard(release, force: manual) }
        }
    }

    // MARK: Card, messages

    private func showCard(_ r: ReleaseInfo, force: Bool = false) {
        guard force || env.bubbleFree() else { pendingCard = r; return }
        let v = r.version.description
        carded.insert(v)
        NSLog("[lulu] update: card for v%@", v)
        env.bubble.enqueueAtHome(BubbleItem(
            header: "🆕 新版本", content: .text(UpdateCopy.cardText(v)), message: nil,
            buttons: [BubbleButton(title: "更新", action: { [weak self] in self?.begin(r) }),
                      BubbleButton(title: "以后再说", action: { [weak self] in
                          self?.env.store.updateSkipped = v
                          NSLog("[lulu] update: v%@ skipped", v)
                      })]))
    }

    /// A short message beside the pet (auto-hides); a plain alert when the pet is not on screen.
    private func say(_ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil, title: String? = nil) {
        if let rect = env.petRect(), !env.notice.suppressed {
            env.notice.show(title: title, body: text, actionTitle: actionTitle, action: action,
                            autoHide: actionTitle == nil ? 6 : 15, beside: rect)
        } else if !Offscreen.enabled {
            let alert = NSAlert()
            alert.messageText = title ?? text
            if title != nil { alert.informativeText = text }
            alert.addButton(withTitle: "好")
            if let actionTitle { alert.addButton(withTitle: actionTitle) }
            NSApp.activate()
            if alert.runModal() == .alertSecondButtonReturn { action?() }
        }
    }

    // MARK: Update

    /// 菜单「有新版本」 / the partner-upgrade bubble's 「一键更新」.
    func updateTapped() { check(manual: true, thenUpdate: true) }

    func begin(_ release: ReleaseInfo) {
        guard !updating, !checking else { return }
        let v = release.version.description
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundlePath = Bundle.main.bundlePath
        guard UpdateRules.canSelfUpdate(bundlePath: bundlePath, home: home, extraAllowed: env.options.allowDir.map { [$0] } ?? []) else {
            NSLog("[lulu] update: %@ is not in an Applications folder, manual update", bundlePath)
            say(UpdateCopy.manualBody(v), actionTitle: "打开发布页", action: {
                NSWorkspace.shared.open(release.pageURL ?? UpdateFeed.releasesPage)
            }, title: UpdateCopy.manualNeeded)
            return
        }
        if !env.options.autoConfirm {
            let alert = NSAlert()
            alert.messageText = UpdateCopy.confirmTitle(v)
            alert.informativeText = UpdateCopy.confirmBody
            alert.addButton(withTitle: "更新")
            alert.addButton(withTitle: "取消")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        updating = true
        env.needsArm()
        env.menuLine(nil)
        progress.show(text: UpdateCopy.downloading(0), fraction: 0, beside: env.petRect(), onCancel: { [weak self] in self?.updateTask?.cancel() })
        let target = URL(fileURLWithPath: bundlePath)
        updateTask = Task { @MainActor in
            var workDir: URL?
            do {
                let dir = try AppUpdater.makeWorkDir()
                workDir = dir
                let panel = self.progress
                let zip = try await AppUpdater.download(release, into: dir) { f in
                    DispatchQueue.main.async { panel.update(text: UpdateCopy.downloading(f), fraction: f) }
                }
                try Task.checkCancellation()
                self.progress.update(text: UpdateCopy.verifying, fraction: nil, cancellable: false)
                let app = try await AppUpdater.stage(zip: zip, in: dir, current: self.current)
                self.progress.update(text: UpdateCopy.installing, fraction: nil, cancellable: false)
                try AppUpdater.launchInstaller(newApp: app, target: target, workDir: dir,
                                               relaunchArgs: AppUpdater.relaunchArguments(CommandLine.arguments))
                NSLog("[lulu] update: installer started for v%@, quitting", v)
                self.env.terminate()   // presence sign-off path (applicationWillTerminate)
            } catch {
                if let dir = workDir { try? FileManager.default.removeItem(at: dir) }
                self.updating = false
                self.progress.dismiss()
                self.env.menuLine(UpdateCopy.menuLine(v))
                self.env.needsArm()
                if (error as? UpdateError).map({ if case .cancelled = $0 { return true } else { return false } }) ?? (error is CancellationError) {
                    NSLog("[lulu] update: cancelled")
                } else {
                    let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    NSLog("[lulu] update: failed: %@", reason)
                    self.say(UpdateCopy.failed(reason))
                }
            }
        }
    }
}

// MARK: Progress panel

@MainActor
final class UpdateProgressModel: ObservableObject {
    @Published var text = ""
    @Published var fraction: Double?
    @Published var cancellable = true
    var onCancel: () -> Void = {}
}

/// 「正在下载… 37%」: a small cream panel beside the pet (never key, floats above other windows).
@MainActor
final class UpdateProgressPanel: NSPanel {
    private let model = UpdateProgressModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: UpdateProgressView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(text: String, fraction: Double?, beside petRect: NSRect?, onCancel: @escaping () -> Void) {
        model.onCancel = onCancel
        model.cancellable = true
        update(text: text, fraction: fraction)
        setContentSize(contentView?.fittingSize ?? frame.size)
        let screen = (petRect.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main)
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let r = petRect {
            let y = min(max(r.maxY - frame.height + 10, vf.minY + 4), vf.maxY - frame.height - 4)
            let left = NSPoint(x: r.minX - frame.width + 6, y: y), right = NSPoint(x: r.maxX - 6, y: y)
            setFrameOrigin(PetNeighbors.bestOrigin([left, right], size: frame.size, in: vf))
        } else {
            setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 20, y: vf.minY + 40))
        }
        orderFrontRegardless()
    }

    func update(text: String, fraction: Double?, cancellable: Bool? = nil) {
        model.text = text
        model.fraction = fraction
        if let cancellable { model.cancellable = cancellable }
    }

    func dismiss() { orderOut(nil) }
}

private struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgressModel
    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.25))
            if let f = model.fraction {
                ProgressView(value: f).progressViewStyle(.linear).tint(Self.accent)
            } else {
                ProgressView().progressViewStyle(.linear).tint(Self.accent)
            }
            if model.cancellable {
                HStack {
                    Spacer()
                    Button("取消") { model.onCancel() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Self.cream).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Self.accent.opacity(0.25), lineWidth: 1))
        .padding(12)
        .fixedSize()
        .environment(\.colorScheme, .light)
    }
}
