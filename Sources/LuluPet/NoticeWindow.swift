import AppKit
import SwiftUI

/// Small soft notice shown beside the pet, e.g. "还没和TA连上哦" with a「去设置」button,
/// or a one-line hint that auto-hides. Dismissed by ✕, the button, or clicking anywhere else.
final class NoticeWindow: NSPanel {
    private var monitors: [Any] = []
    private var hideWork: DispatchWorkItem?
    /// v0.4: while the pet is hidden no notice pops up.
    var suppressed = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)   // our panels are drawn light (cream / orange); keep them light in Dark Mode
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the notice beside `petFrame` (the pet sprite's screen rect). With `autoHide`, it
    /// fades away by itself after that many seconds.
    func show(title: String?, body: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
              autoHide: TimeInterval? = nil, beside petFrame: NSRect) {
        guard !suppressed else { return }
        let view = NoticeView(
            title: title, message: body, actionTitle: actionTitle,
            onAction: { [weak self] in self?.dismiss(); action?() },
            onClose: { [weak self] in self?.dismiss() }
        )
        let host = FirstClickHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        contentView = host
        setContentSize(host.fittingSize)
        position(beside: petFrame)
        orderFrontRegardless()

        installMonitors()
        hideWork?.cancel()
        hideWork = nil
        if let autoHide {
            let work = DispatchWorkItem { [weak self] in self?.dismiss() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHide, execute: work)
        }
    }

    func dismiss() {
        hideWork?.cancel()
        hideWork = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        orderOut(nil)
    }

    private func position(beside petFrame: NSRect) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(petFrame) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = petFrame.maxY - size.height + 10
        y = min(max(y, vf.minY + 4), vf.maxY - size.height - 4)
        // Left of the pet if there is room, else right; flip if that would cover another pet.
        let left = NSPoint(x: petFrame.minX - size.width + 6, y: y), right = NSPoint(x: petFrame.maxX - 6, y: y)
        setFrameOrigin(PetNeighbors.bestOrigin([left, right], size: size, in: vf))
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Clicks in other apps…
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(m) }
        // …and in our own other windows (pet, bubble, compose).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated {
                if let self, e.window !== self { self.dismiss() }
            }
            return e
        }) { monitors.append(m) }
    }
}

/// Lets the ✕ / button react on the first click even though the panel never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct NoticeView: View {
    let title: String?
    let message: String
    let actionTitle: String?
    let onAction: () -> Void
    let onClose: () -> Void

    private static let accent = Color(red: 0.91, green: 0.54, blue: 0.29)
    private static let cream = Color(red: 1.0, green: 0.97, blue: 0.93)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Self.accent)
                    Spacer(minLength: 8)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("关闭")
                }
            }
            Text(message)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Color(white: 0.3))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                HStack {
                    Spacer()
                    Button(action: onAction) {
                        Text(actionTitle)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Self.accent))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, title == nil ? 9 : 12)
        .frame(width: title == nil ? nil : 240, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Self.cream)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Self.accent.opacity(0.25), lineWidth: 1))
        .padding(12)
        .fixedSize()
        .environment(\.colorScheme, .light)
    }
}
