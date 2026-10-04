import AppKit
import LuluCore

/// v0.4: notices when another app is fullscreen on the pet's screen.
///
/// Signal: an on-screen, normal-level (layer 0) window of another process that exactly covers the whole
/// screen, menu bar area included — which is what a fullscreen space looks like. Window bounds need no
/// Screen Recording permission.
///
/// v0.8.1 省电: event-driven. Checked on every space switch (entering or leaving fullscreen always switches
/// spaces), app (de)activation, screen change and wake, plus a few one-shot re-checks shortly after (the
/// window list settles late). No periodic poll, except a slow 15 s one while a fullscreen app is detected,
/// in case the "left fullscreen" notification is missed (`FullscreenFallback`).
@MainActor
final class FullscreenWatcher {
    /// Called with the new state whenever it changes.
    var onChange: ((Bool) -> Void)?
    /// The screen the pet lives on.
    var screen: () -> NSScreen? = { NSScreen.main }

    /// v0.8 battery-aware fallback poll. Ignored since v0.8.1 (no poll unless fullscreen, then
    /// `FullscreenFallback.pollInterval`); kept so existing callers compile.
    var pollInterval: TimeInterval = 3

    private(set) var isFullscreen = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var timer: Timer?
    private var settleChecks: [DispatchWorkItem] = []
    private let pid = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let events: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.activeSpaceDidChangeNotification),
            (ws, NSWorkspace.didActivateApplicationNotification),
            (ws, NSWorkspace.didDeactivateApplicationNotification),
            (ws, NSWorkspace.didWakeNotification),
            (NotificationCenter.default, NSApplication.didChangeScreenParametersNotification),
        ]
        for (nc, name) in events {
            observers.append((nc, nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkSoon() }
            }))
        }
        check()
        updateTimer()
    }

    func stop() {
        for (nc, o) in observers { nc.removeObserver(o) }
        observers = []
        settleChecks.forEach { $0.cancel() }
        settleChecks = []
        timer?.invalidate()
        timer = nil
        if isFullscreen { isFullscreen = false; onChange?(false) }
    }

    /// Fallback poll only while fullscreen (15 s, 10 % tolerance); none otherwise.
    private func updateTimer() {
        let want = observers.isEmpty ? nil : FullscreenFallback.pollInterval(isFullscreen: isFullscreen)
        guard want != timer.map(\.timeInterval) else { return }
        timer?.invalidate()
        timer = nil
        guard let interval = want else { return }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Checks now and again shortly after; a new event restarts the pending re-checks instead of piling
    /// up more (an app switch posts deactivate + activate + often a space change at once).
    private func checkSoon() {
        check()
        settleChecks.forEach { $0.cancel() }
        settleChecks = FullscreenFallback.settleDelays.map { delay in
            let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.check() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
            return item
        }
    }

    func check() {
        let now = fullscreenWindowOwner()
        let fs = now != nil
        guard fs != isFullscreen else { return }
        isFullscreen = fs
        NSLog("[lulu] fullscreen: %@", fs ? "entered (\(now ?? "?"))" : "left")
        updateTimer()
        onChange?(fs)
    }

    /// Name of the app that is fullscreen on the pet's screen, nil if none.
    ///
    /// A fullscreen window of another app (layer 0) either covers the whole screen, or — on a display with a
    /// camera notch — everything below the notch, with a strip of the same app filling the menu-bar area.
    /// A zoomed window with the Dock hidden has that same size, so the notch case also needs the strip or a
    /// missing Finder desktop window (fullscreen spaces have no desktop). Measured on macOS 26: a borderless
    /// non-activating panel stays visible in fullscreen spaces even without `.fullScreenAuxiliary`, so
    /// the pet has to be taken off screen by hand.
    private func fullscreenWindowOwner() -> String? {
        guard let screen = screen(), let primary = NSScreen.screens.first else { return nil }
        // Cocoa (bottom-left origin) → CG (top-left origin of the primary screen).
        let f = screen.frame
        let full = CGRect(x: f.minX, y: primary.frame.maxY - f.maxY, width: f.width, height: f.height)
        let inset = screen.safeAreaInsets.top
        let belowNotch = CGRect(x: full.minX, y: full.minY + inset, width: full.width, height: full.height - inset)
        let strip = CGRect(x: full.minX, y: full.minY, width: full.width, height: inset)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }

        // Tolerant: the notch inset (32) and the menu-bar strip (33) differ by a point.
        func same(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        var windows: [(pid: Int32, layer: Int, rect: CGRect, name: String, id: Int, alpha: Double)] = []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.5 else { continue }   // invisible overlay windows (some apps keep one on every Space)
            windows.append((w[kCGWindowOwnerPID as String] as? Int32 ?? 0, w[kCGWindowLayer as String] as? Int ?? 0, rect,
                            w[kCGWindowOwnerName as String] as? String ?? "?", w[kCGWindowNumber as String] as? Int ?? 0, alpha))
        }
        // A fullscreen app is the frontmost app of its fullscreen Space. Without this, a full-screen-sized
        // window some app keeps on every Space (seen with Claude on an empty desktop) was mistaken for one.
        // (Our own app in front — compose / settings opened over a full-screen app — tells nothing.)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier.nonZeroUnless(pid)
        let hasDesktop = windows.contains { $0.layer == desktopLevel && same($0.rect, full) }
        for w in windows where w.layer == 0 && w.pid != pid && (front == nil || w.pid == front) {
            var rule: String?
            if same(w.rect, full) { rule = "covers whole screen" }
            else if inset > 0, same(w.rect, belowNotch) {
                let ownsStrip = windows.contains { $0.pid == w.pid && $0.layer > 0 && same($0.rect, strip) }
                if ownsStrip { rule = "below notch + own menu-bar strip" } else if !hasDesktop { rule = "below notch, no desktop" }
            }
            if let rule {
                NSLog("[lulu] fullscreen check: %@ window %ld %@ alpha %.2f matched \"%@\" (frontmost pid %d, desktop %@)",
                      w.name, w.id, NSStringFromRect(w.rect), w.alpha, rule, front ?? -1, hasDesktop ? "yes" : "no")
                return w.name
            }
        }
        return nil
    }
}

private extension pid_t {
    /// nil when this is `own` (our app being frontmost says nothing about the full-screen app behind it).
    func nonZeroUnless(_ own: pid_t) -> pid_t? { self == own ? nil : self }
}
