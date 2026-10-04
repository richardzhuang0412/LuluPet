import AppKit
import IOKit.ps
import LuluCore

/// v0.8 省电: is anything of the pet visible? Unseen = the screen is locked, the displays sleep, or the pet
/// window is fully occluded. Then every sprite animation and the hover watch stop (resumed on the reverse).
@MainActor
final class VisibilityMonitor {
    var onChange: ((_ unseen: Bool, _ why: String) -> Void)?
    private(set) var locked = false
    private(set) var displaysAsleep = false
    private(set) var occluded = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private weak var window: NSWindow?

    var unseen: Bool { locked || displaysAsleep || occluded }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        for (name, value) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            tokens.append((dnc, dnc.addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(\.locked, value, "screen \(value ? "locked" : "unlocked")") }
            }))
        }
        let ws = NSWorkspace.shared.notificationCenter
        for (name, value) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            tokens.append((ws, ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(\.displaysAsleep, value, "displays \(value ? "asleep" : "awake")") }
            }))
        }
    }

    /// Watches the (home) pet window's occlusion. `--offscreen` test windows sit below the desktop and are
    /// always occluded, so they are not watched (tests behave like a visible pet).
    func watch(_ w: NSWindow) {
        guard window !== w, !Offscreen.enabled else { return }
        window = w
        let nc = NotificationCenter.default
        tokens.append((nc, nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self, weak w] _ in
            MainActor.assumeIsolated {
                guard let w else { return }
                // An ordered-out window (hidden pet / away on a trip) isn't "occluded": nothing is drawn anyway.
                let hidden = w.isVisible && !w.occlusionState.contains(.visible)
                self?.set(\.occluded, hidden, hidden ? "pet window occluded" : "pet window visible")
            }
        }))
    }

    private func set(_ key: ReferenceWritableKeyPath<VisibilityMonitor, Bool>, _ value: Bool, _ why: String) {
        guard self[keyPath: key] != value else { return }
        let before = unseen
        self[keyPath: key] = value
        if unseen != before { onChange?(unseen, why) }
    }
}

/// v0.8 省电: on battery (IOPowerSources) or in Low Power Mode → `PowerProfile.battery` timings.
/// `--battery-mode` forces it (tests / measurements).
@MainActor
final class PowerMonitor {
    var onChange: ((_ onBattery: Bool) -> Void)?
    private(set) var onBattery = false
    private let forced: Bool
    private var source: CFRunLoopSource?
    private var token: NSObjectProtocol?

    init(forceBattery: Bool) { forced = forceBattery }

    func start() {
        onBattery = compute()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.update() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
        token = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func update() {
        let now = compute()
        guard now != onBattery else { return }
        onBattery = now
        onChange?(now)
    }

    private func compute() -> Bool {
        if forced { return true }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
