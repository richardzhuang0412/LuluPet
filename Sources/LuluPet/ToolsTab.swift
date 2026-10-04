import LuluCore
import SwiftUI

/// v0.11.3: what the compose panel's 小工具 tab shows and does. A thin view model over
/// `PersonalToolsController` (the single source of truth): the controller pushes its state in through
/// `update(...)` whenever the menu is refreshed, and every edit goes back through `apply` / `act`.
@MainActor
final class ToolsPanelModel: ObservableObject {
    @Published private(set) var settings = ToolsSettings()
    @Published private(set) var pomodoro = PomodoroState.idle
    @Published private(set) var cups = 0

    var apply: (ToolsSettings) -> Void = { _ in }
    var act: (StatusMenu.PomodoroAction) -> Void = { _ in }
    /// 「调时长…」: opens Settings on the 小工具 page.
    var openSettings: () -> Void = {}
    /// v0.13.1: how much of a reminder's cycle is left (nil = reminder off).
    var cycleLine: (ReminderKind) -> String? = { _ in nil }

    func update(settings: ToolsSettings, pomodoro: PomodoroState, cups: Int) {
        if self.settings != settings { self.settings = settings }
        if self.pomodoro != pomodoro { self.pomodoro = pomodoro }
        if self.cups != cups { self.cups = cups }
    }

    func edit(_ change: (inout ToolsSettings) -> Void) {
        var s = settings
        change(&s)
        apply(s)
    }
}

struct ToolsTabView: View {
    @ObservedObject var model: ToolsPanelModel
    let onOpenSettings: () -> Void

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            pomodoroCard
            reminderCard(.water)
            reminderCard(.stand)
        }
    }

    // MARK: 番茄钟

    private var pomodoroCard: some View {
        card {
            HStack(spacing: 4) {
                Text("🍅 番茄钟").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Self.accent)
                InfoBadge(text: ToolsCopy.pomodoroHint)
            }
            stateLine
            HStack(spacing: 6) { pomodoroButtons }
            HStack(spacing: 4) {
                Text(ToolsCopy.pomodoroDurations(model.settings.pomodoro))
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
                Button("调时长…") { onOpenSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Self.accent)
                    .help("到设置 → 小工具 里改专注 / 休息时长")
            }
        }
    }

    /// The state line counts down only while this tab is on screen: once a minute, every second in the last minute.
    @ViewBuilder
    private var stateLine: some View {
        let p = model.pomodoro
        let running = p.phase != .idle && !p.isPaused
        if running {
            let rem = p.remaining(now: Date().timeIntervalSince1970) ?? 0
            TimelineView(.periodic(from: .now, by: rem > 60 ? 60 : 1)) { ctx in
                Text(ToolsCopy.pomodoroState(p, now: ctx.date.timeIntervalSince1970)).modifier(StateStyle())
            }
        } else {
            Text(ToolsCopy.pomodoroState(p, now: Date().timeIntervalSince1970)).modifier(StateStyle())
        }
    }

    private struct StateStyle: ViewModifier {
        func body(content: Content) -> some View {
            content.font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color(white: 0.25))
        }
    }

    @ViewBuilder
    private var pomodoroButtons: some View {
        let p = model.pomodoro
        if p.phase == .idle {
            pill("开始专注", filled: true) { model.act(.start) }
        } else {
            pill(p.isPaused ? "继续" : "暂停", filled: true) { model.act(.pauseResume) }
            if p.phase == .shortBreak || p.phase == .longBreak { pill("跳过休息", filled: false) { model.act(.skipBreak) } }
            pill("结束", filled: false) { model.act(.stop) }
        }
    }

    // MARK: 喝水 / 站立

    private func reminderCard(_ kind: ReminderKind) -> some View {
        let water = kind == .water
        let on = Binding(get: { water ? model.settings.waterEnabled : model.settings.standEnabled },
                         set: { v in model.edit { if water { $0.waterEnabled = v } else { $0.standEnabled = v } } })
        let interval = water ? model.settings.waterInterval : model.settings.standInterval
        let minutes = Binding<Int>(get: { ToolsCopy.minutes(interval) },
                                   set: { v in model.edit { if water { $0.waterInterval = TimeInterval(v * 60) } else { $0.standInterval = TimeInterval(v * 60) } } })
        return card {
            HStack {
                Text("\(ToolsCopy.emoji(kind)) \(ToolsCopy.name(kind))")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(Self.accent)
                InfoBadge(text: ToolsCopy.explanation(kind, interval: interval))
                Spacer(minLength: 0)
                Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Self.accent)
            }
            Stepper(value: minutes, in: 5...180, step: 5) {
                Text("每用电脑 \(minutes.wrappedValue) 分钟")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
            }
            .controlSize(.small)
            .disabled(!on.wrappedValue)
            if on.wrappedValue {
                // Refreshes twice a minute, only while this tab is on screen.
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(model.cycleLine(kind) ?? "")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Self.accent)
                }
            }
            if water {
                Text("今天喝了 \(model.cups) 杯 💧")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(Self.accent)
            }
        }
    }

    // MARK: pieces

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.85)))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .rounded))
            .foregroundStyle(Color(white: 0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(filled ? Color.white : Self.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(filled ? Self.accent : Color.white))
                .overlay(Capsule().strokeBorder(Self.accent.opacity(filled ? 0 : 0.6), lineWidth: 1))   // inside the pill, so the edge is never clipped
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // no focus ring cutting into the outlined pill
    }
}

/// v0.15: a small ⓘ that shows the long explanation in a popover while the pointer is over it (replaces the
/// always-visible paragraphs in the 小工具 tab). Clicking toggles it too.
private struct InfoBadge: View {
    let text: String
    @State private var shown = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
            .onHover { shown = $0 }
            .onTapGesture { shown.toggle() }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 11, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 230, alignment: .leading)
                    .padding(10)
            }
            .accessibilityLabel(text)
    }
}
