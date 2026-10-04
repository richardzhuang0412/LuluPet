import AppKit

/// Small decorative animations drawn on top of the pet: floating hearts, a "Z z z" sleep
/// indicator and a tiny pill toast (e.g. "已发送 ✓").
enum Effects {
    /// Renders a string (emoji or text) into a CGImage so colour emoji draw reliably in CALayers.
    static func textImage(_ s: String, font: NSFont, color: NSColor = .black, stroke: NSColor? = nil) -> (CGImage, CGSize)? {
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let stroke {
            attrs[.strokeColor] = stroke
            attrs[.strokeWidth] = -3.0
        }
        let str = NSAttributedString(string: s, attributes: attrs)
        let size = str.size()
        let scale: CGFloat = 2
        let img = NSImage(size: size, flipped: false) { _ in
            str.draw(at: .zero)
            return true
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return (cg, size)
    }

    static func roundedFont(_ size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    /// 2–4 hearts rise from around `origin` (view coordinates) and fade out over ~1.2 s.
    /// `scale` = the pet's size (v0.7): spread, rise and glyph size follow it.
    static func hearts(in view: NSView, from origin: CGPoint, scale k: CGFloat = 1) {
        guard let host = view.layer else { return }
        let glyphs = ["❤️", "💕", "💗", "❤️"]
        for i in 0..<Int.random(in: 2...4) {
            let fontSize = CGFloat.random(in: 16...24) * k
            guard let (img, size) = textImage(glyphs[i % glyphs.count], font: .systemFont(ofSize: fontSize)) else { continue }
            let layer = CALayer()
            layer.contents = img
            layer.contentsScale = 2
            layer.bounds = CGRect(origin: .zero, size: size)
            let start = CGPoint(x: origin.x + CGFloat.random(in: -30...30) * k, y: origin.y + CGFloat.random(in: -10...6) * k)
            layer.position = start
            layer.opacity = 0
            host.addSublayer(layer)

            let rise = CABasicAnimation(keyPath: "position")
            rise.fromValue = NSValue(point: start)
            rise.toValue = NSValue(point: CGPoint(x: start.x + CGFloat.random(in: -14...14) * k, y: start.y + CGFloat.random(in: 50...80) * k))
            rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.15, 0.6, 1]
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5
            grow.toValue = 1.1

            let group = CAAnimationGroup()
            group.animations = [rise, fade, grow]
            group.duration = 1.2
            group.beginTime = CACurrentMediaTime() + Double(i) * 0.12
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            layer.add(group, forKey: "float")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + Double(i) * 0.12 + 0.05) {
                layer.removeFromSuperlayer()
            }
        }
    }

    /// Looping "Z z z" letters drifting up-right from `origin`. Returns the container layer; remove it to stop.
    static func sleepIndicator(in view: NSView, at origin: CGPoint, scale k: CGFloat = 1) -> CALayer? {
        guard let host = view.layer else { return nil }
        let container = CALayer()
        container.frame = host.bounds
        host.addSublayer(container)
        let letters: [(String, CGFloat)] = [("Z", 18), ("z", 15), ("z", 12)]
        let color = NSColor(calibratedRed: 0.42, green: 0.52, blue: 0.82, alpha: 1)
        for (i, (s, size)) in letters.enumerated() {
            guard let (img, sz) = textImage(s, font: roundedFont(size * k, weight: .heavy), color: color, stroke: .white) else { continue }
            let layer = CALayer()
            layer.contents = img
            layer.contentsScale = 2
            layer.bounds = CGRect(origin: .zero, size: sz)
            layer.position = origin
            layer.opacity = 0
            container.addSublayer(layer)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: origin)
            move.toValue = NSValue(point: CGPoint(x: origin.x + 22 * k, y: origin.y + 34 * k))
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.2, 0.7, 1]
            let group = CAAnimationGroup()
            group.animations = [move, fade]
            // v0.8: a slow drift (render server only; the pet itself is a still frame while dozing).
            group.duration = 4.2
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime() + Double(i) * 1.4
            group.fillMode = .backwards
            layer.add(group, forKey: "zzz")
        }
        return container
    }

    /// v0.8 勿扰 sign: a cute cream pill ("😤 生气中") whose bottom sits at `bottomCenter`, scaled with the
    /// pet (kept below `maxTop`). Static: no animation, so it costs nothing while shown.
    static func moodSign(_ text: String, in view: NSView, bottomCenter: CGPoint, maxTop: CGFloat, scale k: CGFloat = 1) -> CALayer? {
        guard let host = view.layer,
              let (img, size) = textImage(text, font: roundedFont(12.5 * k, weight: .bold),
                                          color: NSColor(calibratedRed: 0.55, green: 0.33, blue: 0.2, alpha: 1)) else { return nil }
        let accent = NSColor(calibratedRed: 0.96, green: 0.6, blue: 0.3, alpha: 1)
        let pill = CALayer()
        let padX = 9 * k, padY = 3.5 * k
        pill.bounds = CGRect(x: 0, y: 0, width: size.width + padX * 2, height: size.height + padY * 2)
        let y = min(bottomCenter.y + pill.bounds.height / 2, maxTop - pill.bounds.height / 2)
        pill.position = CGPoint(x: bottomCenter.x, y: y)
        pill.backgroundColor = NSColor(calibratedRed: 1, green: 0.97, blue: 0.9, alpha: 0.97).cgColor
        pill.cornerRadius = pill.bounds.height / 2
        pill.borderColor = accent.withAlphaComponent(0.75).cgColor
        pill.borderWidth = 1.2 * k
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.18
        pill.shadowRadius = 2.5 * k
        pill.shadowOffset = CGSize(width: 0, height: -1)
        let label = CALayer()
        label.contents = img
        label.contentsScale = 2
        label.frame = CGRect(x: padX, y: padY, width: size.width, height: size.height)
        pill.addSublayer(label)
        host.addSublayer(pill)
        return pill
    }

    /// A small pill label at `center` that pops in and fades out.
    static func toast(_ text: String, in view: NSView, at center: CGPoint) {
        guard let host = view.layer,
              let (img, size) = textImage(text, font: roundedFont(12, weight: .semibold),
                                          color: NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.38, alpha: 1)) else { return }
        let pill = CALayer()
        let padX: CGFloat = 10, padY: CGFloat = 4
        pill.bounds = CGRect(x: 0, y: 0, width: size.width + padX * 2, height: size.height + padY * 2)
        pill.position = center
        pill.backgroundColor = NSColor.white.withAlphaComponent(0.95).cgColor
        pill.cornerRadius = pill.bounds.height / 2
        pill.borderColor = NSColor(calibratedRed: 0.36, green: 0.62, blue: 0.38, alpha: 0.35).cgColor
        pill.borderWidth = 1
        pill.shadowColor = NSColor.black.cgColor
        pill.shadowOpacity = 0.15
        pill.shadowRadius = 3
        pill.shadowOffset = CGSize(width: 0, height: -1)
        let label = CALayer()
        label.contents = img
        label.contentsScale = 2
        label.frame = CGRect(x: padX, y: padY, width: size.width, height: size.height)
        pill.addSublayer(label)
        host.addSublayer(pill)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.1, 0.75, 1]
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = center.y - 6
        rise.toValue = center.y + 10
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = 1.8
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        pill.add(group, forKey: "toast")
        pill.opacity = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) { pill.removeFromSuperlayer() }
    }
}
