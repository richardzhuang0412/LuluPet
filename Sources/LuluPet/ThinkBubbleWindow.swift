import AppKit
import ImageIO
import LuluCore

/// v0.13.3 「想 TA」: three little circles rise from my pet's head, then a cloud pops in with TA's character (a small
/// idle sprite), a pill with TA's weather and local time under it, and a tiny weather flourish (rain / snow / sun).
/// A separate click-through borderless window above the pet; about 6 s in all. No timers while it is hidden: the
/// animation is Core Animation on the render server and one one-shot work item closes the window.
final class ThinkBubbleWindow: NSPanel {
    struct Content {
        var clip: SpriteClip?
        var barText: String?
        var flourish: ThinkFlourish
    }

    private static let size = NSSize(width: 214, height: 236)
    private static let cloudRect = CGRect(x: 22, y: 64, width: 180, height: 164)
    /// Local x of the three circles (they rise from the pet's head towards the cloud's lower-left).
    private static let circleX: [CGFloat] = [34, 44, 58]
    private static let circleY: [CGFloat] = [8, 28, 46]
    private static let circleR: [CGFloat] = [4.5, 7, 10]

    private let root = NSView(frame: NSRect(origin: .zero, size: ThinkBubbleWindow.size))
    private let player = SpritePlayer(frame: .zero)
    private var closeWork: DispatchWorkItem?
    private var anchor: NSRect = .zero
    private(set) var isShowing = false
    var onFinished: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        ignoresMouseEvents = true   // click-through
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Show / hide

    func show(_ c: Content, anchor: NSRect, now: TimeInterval = ThinkRules.duration) {
        dismiss(notify: false)
        isShowing = true
        buildScene(c)
        follow(anchor)
        alphaValue = 1
        orderFrontRegardless()
        animateScene(duration: now)
        let work = DispatchWorkItem { [weak self] in self?.dismiss(notify: true) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + now, execute: work)
    }

    func dismiss(notify: Bool = true) {
        closeWork?.cancel()
        closeWork = nil
        guard isShowing else { return }
        isShowing = false
        player.stop()
        root.layer?.removeAllAnimations()
        root.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        root.layer?.sublayers = nil
        root.subviews.forEach { $0.removeFromSuperview() }
        orderOut(nil)
        if notify { onFinished?() }
    }

    /// Follows the pet: the circles start just above its head (`anchor` = the sprite's rect, screen coordinates).
    func follow(_ anchor: NSRect) {
        self.anchor = anchor
        guard isShowing else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        var x = anchor.midX - Self.circleX[0]
        var y = anchor.maxY - 8
        if let vf = screen?.visibleFrame {
            x = min(max(x, vf.minX + 4), vf.maxX - Self.size.width - 4)
            y = min(y, vf.maxY - Self.size.height)
        }
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Scene

    private var circleLayers: [CAShapeLayer] = []
    private var cloudGroup = CALayer()
    private var flourishLayers: [CALayer] = []

    private func buildScene(_ c: Content) {
        let layer = root.layer!
        layer.sublayers = nil
        circleLayers = []
        flourishLayers = []
        let border = NSColor(calibratedRed: 0.86, green: 0.80, blue: 0.70, alpha: 1).cgColor
        let fill = NSColor(calibratedWhite: 1, alpha: 0.97).cgColor

        // three circles
        for i in 0..<3 {
            let r = Self.circleR[i]
            let l = CAShapeLayer()
            l.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            l.position = CGPoint(x: Self.circleX[i], y: Self.circleY[i])
            l.path = CGPath(ellipseIn: l.bounds, transform: nil)
            l.fillColor = fill
            l.strokeColor = border
            l.lineWidth = 1.2
            l.opacity = 0
            layer.addSublayer(l)
            circleLayers.append(l)
        }

        // cloud group (scaled as one around its lower-left corner, towards the circles)
        let cr = Self.cloudRect
        cloudGroup = CALayer()
        cloudGroup.frame = cr
        cloudGroup.anchorPoint = CGPoint(x: 0.12, y: 0)
        cloudGroup.position = CGPoint(x: cr.minX + cr.width * 0.12, y: cr.minY)
        cloudGroup.opacity = 0
        layer.addSublayer(cloudGroup)

        let path = Self.cloudPath(in: CGRect(origin: .zero, size: cr.size))
        let outline = CAShapeLayer()
        outline.path = path
        outline.fillColor = border
        outline.strokeColor = border
        outline.lineWidth = 3
        outline.lineJoin = .round
        cloudGroup.addSublayer(outline)
        let body = CAShapeLayer()
        body.path = path
        body.fillColor = fill
        cloudGroup.addSublayer(body)

        // flourish (clipped to the cloud's body so nothing falls outside it)
        let clip = CALayer()
        clip.frame = CGRect(origin: .zero, size: cr.size)
        let mask = CAShapeLayer()
        mask.path = path
        clip.mask = mask
        cloudGroup.addSublayer(clip)
        buildFlourish(c.flourish, in: clip, size: cr.size)

        // TA, ~90 pt tall, standing on the pill
        let pillH: CGFloat = c.barText == nil ? 0 : 24
        let spriteH: CGFloat = 92
        let view = NSView(frame: NSRect(x: cr.minX + (cr.width - 110) / 2, y: cr.minY + 18 + pillH + 4, width: 110, height: spriteH))
        player.removeFromSuperview()
        player.frame = view.bounds
        player.autoresizingMask = []
        view.addSubview(player)
        if let clip = c.clip {
            player.pointScale = spriteH / max(1, clip.size.height)
            player.idle(clip)
        }
        view.wantsLayer = true
        view.alphaValue = 1
        root.addSubview(view)
        spriteHost = view
        view.layer?.opacity = 0
        view.layer?.zPosition = 2   // above the cloud layer whatever order AppKit puts the layers in

        // pill (plain layers inside the cloud group, above its body)
        pillHost = nil
        if let text = c.barText {
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            let textW = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            let w = min(cr.width - 12, textW + 20), h = pillH - 2
            let pill = CALayer()
            pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            pill.position = CGPoint(x: cr.width / 2, y: 20 + h / 2)
            pill.cornerRadius = h / 2
            pill.backgroundColor = NSColor(calibratedRed: 1, green: 0.93, blue: 0.82, alpha: 1).cgColor
            pill.borderColor = NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.55, alpha: 1).cgColor
            pill.borderWidth = 0.8
            let label = CATextLayer()
            label.string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(calibratedWhite: 0.3, alpha: 1)])
            label.alignmentMode = .center
            label.contentsScale = 2
            label.frame = CGRect(x: 0, y: (h - 14) / 2 - 1, width: w, height: 16)
            pill.addSublayer(label)
            pill.opacity = 0
            cloudGroup.addSublayer(pill)
            pillHost = pill
        }
    }
    private var spriteHost: NSView?
    private var pillHost: CALayer?

    /// A puffy cloud: base rounded rect + bumps (union; the outline layer strokes the whole shape).
    private static func cloudPath(in r: CGRect) -> CGPath {
        let p = CGMutablePath()
        let w = r.width, h = r.height
        p.addRoundedRect(in: CGRect(x: r.minX + 0.07 * w, y: r.minY + 0.04 * h, width: 0.86 * w, height: 0.62 * h),
                         cornerWidth: 0.26 * h, cornerHeight: 0.26 * h)
        func bump(_ cx: CGFloat, _ cy: CGFloat, _ rad: CGFloat) {
            p.addEllipse(in: CGRect(x: r.minX + cx * w - rad, y: r.minY + cy * h - rad, width: rad * 2, height: rad * 2))
        }
        bump(0.27, 0.66, 0.19 * w)
        bump(0.52, 0.72, 0.23 * w)
        bump(0.77, 0.64, 0.18 * w)
        bump(0.14, 0.40, 0.12 * w)
        bump(0.87, 0.40, 0.12 * w)
        return p
    }

    private func buildFlourish(_ kind: ThinkFlourish, in host: CALayer, size: CGSize) {
        switch kind {
        case .rain:
            let blue = NSColor(calibratedRed: 0.42, green: 0.66, blue: 0.92, alpha: 0.75).cgColor
            for i in 0..<9 {
                let l = CAShapeLayer()
                l.path = { let q = CGMutablePath(); q.move(to: .zero); q.addLine(to: CGPoint(x: -2, y: -9)); return q }()
                l.strokeColor = blue
                l.lineWidth = 1.6
                l.lineCap = .round
                let x = size.width * (0.1 + 0.8 * CGFloat(i) / 8)
                l.position = CGPoint(x: x, y: size.height)
                l.opacity = 0
                host.addSublayer(l)
                flourishLayers.append(l)
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = size.height - 14
                fall.toValue = 14
                fall.duration = 0.9 + 0.12 * Double(i % 3)
                fall.repeatCount = .infinity
                fall.beginTime = CACurrentMediaTime() + 0.9 + 0.11 * Double(i)
                fall.fillMode = .backwards
                l.add(fall, forKey: "fall")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.15, 0.8, 1]
                fade.duration = fall.duration
                fade.repeatCount = .infinity
                fade.beginTime = fall.beginTime
                fade.fillMode = .backwards
                l.add(fade, forKey: "fade")
            }
        case .snow:
            for i in 0..<9 {
                let l = CATextLayer()
                l.string = "❄︎"
                l.fontSize = 9 + CGFloat(i % 3) * 2
                l.foregroundColor = NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 0.9).cgColor
                l.contentsScale = 2
                l.bounds = CGRect(x: 0, y: 0, width: 16, height: 16)
                let x = size.width * (0.1 + 0.8 * CGFloat(i) / 8)
                l.position = CGPoint(x: x, y: size.height)
                l.opacity = 0
                host.addSublayer(l)
                flourishLayers.append(l)
                let begin = CACurrentMediaTime() + 0.9 + 0.2 * Double(i)
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = size.height - 16
                fall.toValue = 12
                fall.duration = 2.2 + 0.2 * Double(i % 3)
                fall.repeatCount = .infinity
                fall.beginTime = begin
                fall.fillMode = .backwards
                l.add(fall, forKey: "fall")
                let sway = CABasicAnimation(keyPath: "position.x")
                sway.fromValue = x - 5
                sway.toValue = x + 5
                sway.duration = 1.1
                sway.autoreverses = true
                sway.repeatCount = .infinity
                sway.beginTime = begin
                sway.fillMode = .backwards
                l.add(sway, forKey: "sway")
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 1, 1, 0]
                fade.keyTimes = [0, 0.12, 0.8, 1]
                fade.duration = fall.duration
                fade.repeatCount = .infinity
                fade.beginTime = begin
                fade.fillMode = .backwards
                l.add(fade, forKey: "fade")
            }
        case .sun:
            let sun = CALayer()
            sun.bounds = CGRect(x: 0, y: 0, width: 40, height: 40)
            sun.position = CGPoint(x: size.width - 30, y: size.height - 40)
            let orange = NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.20, alpha: 1).cgColor
            let rays = CAShapeLayer()
            let rp = CGMutablePath()
            for k in 0..<8 {
                let a = CGFloat(k) * .pi / 4
                rp.move(to: CGPoint(x: 20 + cos(a) * 12, y: 20 + sin(a) * 12))
                rp.addLine(to: CGPoint(x: 20 + cos(a) * 18, y: 20 + sin(a) * 18))
            }
            rays.path = rp
            rays.strokeColor = orange
            rays.lineWidth = 2.2
            rays.lineCap = .round
            rays.frame = sun.bounds
            sun.addSublayer(rays)
            let disc = CAShapeLayer()
            disc.path = CGPath(ellipseIn: CGRect(x: 11, y: 11, width: 18, height: 18), transform: nil)
            disc.fillColor = NSColor(calibratedRed: 1, green: 0.84, blue: 0.30, alpha: 1).cgColor
            disc.strokeColor = orange
            disc.lineWidth = 1.2
            sun.addSublayer(disc)
            host.addSublayer(sun)
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 12
            spin.repeatCount = .infinity
            rays.add(spin, forKey: "spin")
            flourishLayers.append(sun)
        case .none:
            break
        }
    }

    // MARK: Timeline: circles 0–0.8 s, cloud pops at 0.8 s, hold, fade over the last 0.6 s

    private func animateScene(duration: TimeInterval) {
        let t0 = CACurrentMediaTime()
        func pop(_ layer: CALayer, at: Double, from: CGFloat, dur: Double) {
            layer.opacity = 1
            let s = CAKeyframeAnimation(keyPath: "transform.scale")
            s.values = [from, 1.12, 1.0]
            s.keyTimes = [0, 0.6, 1]
            s.duration = dur
            s.beginTime = t0 + at
            s.fillMode = .backwards
            s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(s, forKey: "pop")
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = dur * 0.6
            a.beginTime = t0 + at
            a.fillMode = .backwards
            layer.add(a, forKey: "popFade")
        }
        for (i, l) in circleLayers.enumerated() { pop(l, at: 0.25 * Double(i), from: 0.2, dur: 0.3) }
        pop(cloudGroup, at: 0.85, from: 0.25, dur: 0.45)
        for host in [spriteHost?.layer, pillHost].compactMap({ $0 }) {
            host.opacity = 1
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = 0.3
            a.beginTime = t0 + 1.05
            a.fillMode = .backwards
            host.add(a, forKey: "appear")
        }
        // fade everything out at the end
        let fadeAt = max(1.5, duration - 0.6)
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = 0.6
        out.beginTime = t0 + fadeAt
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        root.layer?.add(out, forKey: "out")
    }
}
