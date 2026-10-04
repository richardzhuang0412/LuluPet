import AppKit
import LuluCore

/// v0.8.1 省电: the home pet's single housekeeping timer (quiet, doze, fidget, outfit rotation, 勿扰 end,
/// timed-hide end). One one-shot `Timer` aimed at the earliest deadline (`Housekeeping.plan`), re-armed
/// whenever the owner says something changed (`setNeedsArm`), after wake from sleep and after a clock change.
@MainActor
final class HousekeepingScheduler {
    /// Current deadlines (the owner's state; may draw a fresh fidget deadline).
    var deadlines: () -> HousekeepingDeadlines = { HousekeepingDeadlines() }
    /// Runs one due task. It must clear or move that task's deadline.
    var run: (HousekeepingTask) -> Void = { _ in }

    private var timer: Timer?
    private var armPending = false
    private var observers: [NSObjectProtocol] = []

    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var wall: TimeInterval { Date().timeIntervalSince1970 }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmNow(reason: "wake") }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmNow(reason: "clock changed") }
        })
    }

    /// Something changed: re-arm once at the end of this run-loop turn (several changes coalesce).
    func setNeedsArm() {
        guard !armPending else { return }
        armPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.armPending else { return }
            self.arm()
        }
    }

    /// Wall-clock deadlines may have passed while the Mac slept (a `Timer` doesn't count sleep).
    private func rearmNow(reason: String) {
        NSLog("[lulu] housekeeping: re-arm (%@)", reason)
        fire()
    }

    private func arm() {
        armPending = false
        timer?.invalidate()
        timer = nil
        guard let plan = Housekeeping.plan(deadlines(), uptime: uptime, wall: wall) else { return }
        let t = Timer(timeInterval: plan.delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        t.tolerance = plan.tolerance
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fire() {
        timer?.invalidate()
        timer = nil
        let due = Housekeeping.due(deadlines(), uptime: uptime, wall: wall)
        for task in due { run(task) }
        arm()
        if !due.isEmpty {
            let next = Housekeeping.plan(deadlines(), uptime: uptime, wall: wall)
            NSLog("[lulu] housekeeping: ran %@; next %@", due.map(\.rawValue).joined(separator: ", "),
                  next.map { p in String(format: "%@ in %.1f s (±%.1f s)", p.tasks.map(\.rawValue).joined(separator: "+"), p.delay, p.tolerance) } ?? "nothing")
        }
    }
}
