import AppKit

/// Hidden `--snapshot DIR` helper: renders every visible app window over a dark and a light
/// backdrop into PNGs, so the UI can be checked without Screen Recording permission.
/// `scene-*.png` composites all windows at their screen positions (bottom strip of the main screen).
@MainActor
enum DebugSnapshot {
    private static let backdrops: [(String, NSColor)] = [
        ("dark", NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.24, alpha: 1)),
        ("light", NSColor(calibratedRed: 0.78, green: 0.86, blue: 0.93, alpha: 1)),
    ]

    static func capture(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let shown = NSApp.windows.filter { $0.isVisible && $0.alphaValue > 0.01 }
        let frames = shown.map { w -> String in
            let title = w.title.isEmpty ? "" : " \"\(w.title)\""
            return "\(type(of: w))\(title) \(NSStringFromRect(w.frame))"
        }
        let screens = NSScreen.screens.map { "screen visible \(NSStringFromRect($0.visibleFrame))" }
        try? (frames + screens).joined(separator: "\n").write(to: dir.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
        for (i, window) in NSApp.windows.enumerated() where shown.contains(window) {
            guard let view = window.contentView, view.bounds.width > 0 else { continue }
            let name = "\(i)-\(String(describing: type(of: window)))"
            for (suffix, bg) in backdrops {
                if let img = render(view, over: bg), let data = png(img) {
                    try? data.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
            // Titled windows (Settings): also over their own window background, as seen on screen.
            if window.styleMask.contains(.titled) {
                var bg = NSColor.windowBackgroundColor
                window.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white }
                if let img = render(view, over: bg), let data = png(img) {
                    try? data.write(to: dir.appendingPathComponent("\(name)-window.png"))
                }
            }
        }
        scene(shown, into: dir)
        NSLog("[lulu] snapshot: %@", dir.path)
    }

    /// All windows placed at their screen positions over the bottom 520 pt of the main screen
    /// (`scene-*.png` at 1x; `scene-2x-*.png` at 2x covers the whole screen, for crops of menus / panels).
    private static func scene(_ windows: [NSWindow], into dir: URL) {
        guard let screen = (NSScreen.main ?? NSScreen.screens.first)?.frame else { return }
        let strip = NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(520, screen.height))
        for (suffix, bg, area, scale) in backdrops.map({ ($0.0, $0.1, strip, CGFloat(1)) }) + backdrops.map({ ("2x-" + $0.0, $0.1, screen, CGFloat(2)) }) {
            guard let ctx = CGContext(data: nil, width: Int(area.width * scale), height: Int(area.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.scaleBy(x: scale, y: scale)
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(origin: .zero, size: area.size))
            for w in windows.sorted(by: { $0.orderedIndex > $1.orderedIndex }) {   // back to front
                guard let view = w.contentView, view.bounds.width > 0, let img = render(view, over: nil) else { continue }
                ctx.setAlpha(w.alphaValue)
                ctx.draw(img, in: CGRect(x: w.frame.minX - area.minX, y: w.frame.minY - area.minY, width: w.frame.width, height: w.frame.height))
            }
            if let img = ctx.makeImage(), let data = png(img) {
                try? data.write(to: dir.appendingPathComponent("scene-\(suffix).png"))
            }
        }
    }

    /// `--demo-menu`: every on-screen window of this process above normal level (menus, submenus) as
    /// PNGs, plus `menus.png` with all of them at their relative positions.
    nonisolated static func captureOwnMenus(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        var ids: [CGWindowID] = []
        var lines: [String] = []
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= Int(CGWindowLevelForKey(.popUpMenuWindow)) - 1, layer < Int(CGWindowLevelForKey(.statusWindow)) + 200,
                  let n = w[kCGWindowNumber as String] as? UInt32 else { continue }
            ids.append(n)
            lines.append("window \(n) layer \(layer) \(w[kCGWindowBounds as String] ?? "")")
            if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, n, [.boundsIgnoreFraming, .bestResolution]), let data = png(img) {
                try? data.write(to: dir.appendingPathComponent("menu-\(n).png"))
            }
        }
        if !ids.isEmpty {
            let arr = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) } as CFArray
            if let img = CGImage(windowListFromArrayScreenBounds: .null, windowArray: arr, imageOption: [.boundsIgnoreFraming, .bestResolution]),
               let data = png(img) {
                try? data.write(to: dir.appendingPathComponent("menus.png"))
            }
        }
        try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
        NSLog("[lulu] snapshot: %ld menu window(s) → %@", ids.count, dir.path)
    }

    nonisolated private static func png(_ img: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// Renders `layer` at `frame` (its parent's coordinates), honouring a mirror / affine transform.
    private static func draw(_ layer: CALayer, frame: CGRect, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: frame.midX, y: frame.midY)
        ctx.concatenate(CATransform3DGetAffineTransform(layer.transform))
        ctx.translateBy(x: -layer.bounds.width / 2, y: -layer.bounds.height / 2)
        layer.render(in: ctx)
        ctx.restoreGState()
    }

    /// The window's content as seen on screen (2x): AppKit drawing plus the current (presentation) state of
    /// raw CALayers (sprite frames mid-animation, effect layers). Also used by `DemoRecorder`.
    static func render(_ view: NSView, over bg: NSColor?) -> CGImage? {
        let scale: CGFloat = 2
        let size = view.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        if let bg {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        // Raw CALayers (sprite frames, effect layers): drawn below at their presentation (mid-animation) state.
        // They are hidden while AppKit draws, so cacheDisplay can't add their stale model state on top.
        var raw: [(layer: CALayer, shown: CALayer, offset: CGPoint)] = []
        if !String(describing: type(of: view)).contains("Hosting") {
            for sub in view.layer?.sublayers ?? [] where (sub.delegate as? NSView) == nil && (sub.contents != nil || !(sub.sublayers ?? []).isEmpty) {
                raw.append((sub, sub.presentation() ?? sub, .zero))
            }
            for subview in view.subviews { collectLayers(of: subview, offset: subview.frame.origin, into: &raw) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wasHidden = raw.map(\.layer.isHidden)
        raw.forEach { $0.layer.isHidden = true }
        // AppKit drawing (text, bezier paths, SwiftUI) via cacheDisplay…
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let cg = rep.cgImage { ctx.draw(cg, in: CGRect(origin: .zero, size: size)) }
        }
        for (r, hidden) in zip(raw, wasHidden) { r.layer.isHidden = hidden }
        CATransaction.commit()
        // …plus the raw layers.
        for r in raw where !r.shown.isHidden {
            draw(r.shown, frame: r.shown.frame.offsetBy(dx: r.offset.x, dy: r.offset.y), in: ctx)
        }
        return ctx.makeImage()
    }

    /// Raw (non-view) sublayers of `view` and its visible descendants, with their presentation state.
    private static func collectLayers(of view: NSView, offset: CGPoint, into out: inout [(layer: CALayer, shown: CALayer, offset: CGPoint)]) {
        guard !view.isHidden, view.alphaValue > 0.01, !String(describing: type(of: view)).contains("Hosting") else { return }
        for sub in view.layer?.sublayers ?? [] where (sub.delegate as? NSView) == nil {
            out.append((sub, sub.presentation() ?? sub, offset))
        }
        for subview in view.subviews {
            collectLayers(of: subview, offset: CGPoint(x: offset.x + subview.frame.minX, y: offset.y + subview.frame.minY), into: &out)
        }
    }
}
