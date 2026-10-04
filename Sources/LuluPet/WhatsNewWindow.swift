import AppKit
import LuluCore
import SwiftUI

// v0.13 (docs/superpowers/specs/2026-10-07-whatsnew-design.md): the 更新日志 window with two pages,
// 更新内容 (the changelog) and 待设置 (setup to-dos). The rules live in LuluCore (`Changelog`, `SetupTodos`).

final class WhatsNewModel: ObservableObject {
    enum Page: String { case updates, todos }

    @Published var page: Page
    @Published var todos: [SetupTodo]
    /// The partner-upgrade explanation is unfolded.
    @Published var showUpgradeHelp = false
    /// v0.15.5 「📣 叫 TA 升级」 on the partner-upgrade row.
    enum PingStatus { case unavailable, ready, sent }
    @Published var pingStatus: PingStatus = .unavailable
    var pingStatusProvider: () -> PingStatus = { .unavailable }
    var ping: () -> Void = {}

    let entries: [ChangelogEntry]
    /// `whatsNewSeen` when the window opened: versions newer than this carry the 「新」 badge.
    let seenAtOpen: AppVersion?
    /// My version (nil under `swift run`).
    let current: String?

    /// Recomputes the list from the app's current state.
    var reload: () -> [SetupTodo]
    /// 「去设置」 for a to-do (not `.howToUpgradePartner`, which only unfolds the explanation here).
    var perform: (SetupTodo) -> Void
    /// 「不用了」.
    var dismiss: (String) -> Void
    /// v0.14 「检查更新」: runs a manual check; the closure gets the one-line result.
    var checkUpdate: (@escaping (String) -> Void) -> Void = { _ in }
    @Published var updateStatus: String?
    @Published var checkingUpdate = false
    /// The list changed (the menu's count follows).
    var onTodosChanged: ([SetupTodo]) -> Void = { _ in }

    init(entries: [ChangelogEntry], seen: String?, current: String?, page: Page, todos: [SetupTodo],
         reload: @escaping () -> [SetupTodo], perform: @escaping (SetupTodo) -> Void, dismiss: @escaping (String) -> Void) {
        self.entries = entries; seenAtOpen = AppVersion(seen); self.current = current; self.page = page; self.todos = todos
        self.reload = reload; self.perform = perform; self.dismiss = dismiss
    }

    func isNew(_ e: ChangelogEntry) -> Bool {
        guard let seen = seenAtOpen, let v = AppVersion(e.version) else { return false }
        return v > seen
    }

    func refresh() {
        let fresh = reload()
        if fresh != todos { todos = fresh }
        pingStatus = pingStatusProvider()
        onTodosChanged(fresh)
    }

    func go(_ todo: SetupTodo) {
        if todo.action == .howToUpgradePartner {
            showUpgradeHelp.toggle()
        } else {
            perform(todo)
            // The action may have finished the job (widget on); settings / panel come back through didBecomeKey.
            refresh()
        }
    }

    func sendPing() {
        guard pingStatus == .ready else { return }
        ping()
        pingStatus = pingStatusProvider()
    }

    func skip(_ todo: SetupTodo) {
        dismiss(todo.id)
        refresh()
    }

    func runCheckUpdate() {
        guard !checkingUpdate else { return }
        checkingUpdate = true
        updateStatus = "正在检查…"
        checkUpdate { [weak self] text in
            DispatchQueue.main.async { self?.updateStatus = text; self?.checkingUpdate = false }
        }
    }

    var upgradeHelp: String { UpdateCopy.upgradeHelp(version: current) }
}

final class WhatsNewWindow: NSWindow {
    let model: WhatsNewModel

    init(model: WhatsNewModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)   // drawn light like Settings, also in Dark Mode
        title = "噜噜桌宠 · 更新日志"
        isReleasedWhenClosed = false
        setLuluLevel(.normal)
        let host = NSHostingView(rootView: WhatsNewView(model: model))
        contentView = host
        setContentSize(NSSize(width: 420, height: 480))
        center()
        // Coming back from Settings / the tools panel: re-evaluate the list (no timers).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }

    func show(page: WhatsNewModel.Page) {
        model.page = page
        model.refresh()
        if Offscreen.enabled { orderFront(nil); return }
        DockPresence.shared.acquire("whatsnew")
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func close() {
        super.close()
        DockPresence.shared.release("whatsnew")
    }
}

private struct WhatsNewView: View {
    @ObservedObject var model: WhatsNewModel
    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.page) {
                Text("更新内容").tag(WhatsNewModel.Page.updates)
                Text(model.todos.isEmpty ? "待设置" : "待设置（\(model.todos.count)）").tag(WhatsNewModel.Page.todos)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 22)
            .padding(.top, 16)
            if model.page == .todos { todosPage } else { updatesPage }
        }
        .frame(width: 420, height: 480, alignment: .top)
        .tint(Self.accent)
    }

    private func header(_ icon: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Text(icon).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded))
                Text(sub).font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 22)
    }

    // MARK: 更新内容

    private var updatesPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("🍊", "更新内容", model.current.map { "当前版本 v\($0)" } ?? "噜噜桌宠的新变化")
            HStack(spacing: 8) {
                Button("检查更新") { model.runCheckUpdate() }
                    .controlSize(.small)
                    .disabled(model.checkingUpdate)
                if let s = model.updateStatus {
                    Text(s).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.entries.isEmpty {
                        Text("暂时没有更新记录").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    }
                    ForEach(model.entries, id: \.version) { e in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text("v\(e.version)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
                                if model.isNew(e) {
                                    Text("新").font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(Self.accent))
                                }
                                Text(e.date).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                            }
                            ForEach(Array(e.items.enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    Text(item).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(Color(white: 0.2))
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 待设置

    private var todosPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            header("🧰", "待设置", model.todos.isEmpty ? "没有要设置的事情啦" : "几件还没设置的小事，不急着做")
            if model.todos.isEmpty {
                Spacer()
                Text("都设置好啦 ✓").font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.36, green: 0.62, blue: 0.38))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.todos, id: \.id) { todo in row(todo) }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 18)
                }
            }
        }
    }

    private func row(_ todo: SetupTodo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(todo.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.15))
            Text(todo.detail).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if todo.action == .howToUpgradePartner && model.showUpgradeHelp {
                Text(model.upgradeHelp).font(.system(size: 12, design: .rounded)).foregroundStyle(Color(white: 0.25))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Self.accent.opacity(0.12)))
            }
            HStack(spacing: 8) {
                if todo.action == .howToUpgradePartner, model.pingStatus != .unavailable {
                    Button(model.pingStatus == .sent ? "已经叫过 TA 了 ✓" : "📣 叫 TA 升级") { model.sendPing() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(model.pingStatus == .sent)
                    Button(model.showUpgradeHelp ? "收起" : todo.button) { model.go(todo) }
                        .controlSize(.small)
                } else {
                    Button(todo.action == .howToUpgradePartner && model.showUpgradeHelp ? "收起" : todo.button) { model.go(todo) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button("不用了") { model.skip(todo) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.5).opacity(0.08)))
    }
}
