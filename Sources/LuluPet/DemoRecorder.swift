import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Hidden `--record DIR` flag (README demo GIFs, `tools/make_demos.py`): renders this instance's visible
/// windows (pet, visitor, bubbles, notices, compose panel…) the same way as the `--snapshot` scene, `fps` times
/// a second on the main thread, at their screen positions over a wallpaper — no Screen Recording permission,
/// works with `--offscreen`. While recording only the windows are written (`layers/`, deduplicated); when it
/// ends (`--record-duration` S, then the app quits; or at quit) the frames are composited and cropped:
///
///     DIR/frame-00001.png …      composited frames (2x), all the same size
///     DIR/timestamps.txt         "<index> <unix ms>" per frame (aligns two instances' recordings)
///     DIR/region.txt             the cropped screen rect in points (x y w h)
///     DIR/windows.txt            per frame: each window's class, screen frame, rendered size and alpha
///
/// Options: `--record-fps N` (15), `--record-duration S`, `--record-region auto|x,y,w,h|bottom-right:w,h` (auto: the union of all
/// window frames over the recording, clipped to the screen, padded, even size), `--record-pad P` (36),
/// `--record-bg PATH` (aspect-fills the main screen; default a soft pastel gradient), `--record-menubar`
/// (a thin mock menu bar with 🍊 across the top of the crop), `--record-min W,H` (smallest auto crop).
@MainActor
final class DemoRecorder {
    struct Options {
        var dir: URL
        var fps: Double = 15
        var duration: TimeInterval?
        var region: NSRect?
        /// `--record-region bottom-right:W,H`: a W×H crop in the main screen's bottom-right corner (where the
        /// pets live by default; its bottom just above the Dock) — the same crop for two instances whose recordings go side by side.
        var anchoredSize: CGSize?
        var pad: CGFloat = 36
        var minSize = CGSize(width: 0, height: 0)
        var background: String?
        var menuBar = false

        init?(_ args: [String]) {
            guard let i = args.firstIndex(of: "--record"), i + 1 < args.count else { return nil }
            dir = URL(fileURLWithPath: args[i + 1])
            func value(_ flag: String) -> String? {
                args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            }
            if let f = value("--record-fps").flatMap(Double.init), f > 0 { fps = min(f, 60) }
            duration = value("--record-duration").flatMap(TimeInterval.init)
            if let p = value("--record-pad").flatMap(Double.init) { pad = CGFloat(p) }
            if let r = value("--record-region"), r != "auto" {
                if r.hasPrefix("bottom-right:") {
                    let n = r.dropFirst("bottom-right:".count).split(separator: ",").compactMap { Double($0) }
                    if n.count == 2 { anchoredSize = CGSize(width: n[0], height: n[1]) }
                } else {
                    let n = r.split(separator: ",").compactMap { Double($0) }
                    if n.count == 4 { region = NSRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
                }
            }
            if let m = value("--record-min") {
                let n = m.split(separator: ",").compactMap { Double($0) }
                if n.count == 2 { minSize = CGSize(width: n[0], height: n[1]) }
            }
            background = value("--record-bg")
            menuBar = args.contains("--record-menubar")
        }
    }

    private struct Layer { var file: String; var frame: NSRect; var alpha: CGFloat; var name: String; var image: CGSize }
    private struct Frame { var ts: Int64; var layers: [Layer] }

    static private(set) var shared: DemoRecorder?
    /// While recording, pets stay where their profile put them (no stepping aside for other instances' pets),
    /// so a scene's layout is the same on every run.
    nonisolated static let requested = CommandLine.arguments.contains("--record")

    /// Starts recording if `--record DIR` was given.
    static func startIfRequested() {
        guard shared == nil, let o = Options(CommandLine.arguments) else { return }
        let r = DemoRecorder(o)
        shared = r
        r.start()
    }

    private let options: Options
    private let scale: CGFloat = 2
    private var timer: Timer?
    private var frames: [Frame] = []
    /// Last layer written per window (number → (pixels, file)): unchanged windows reuse the file.
    private var lastLayer: [Int: (pixels: Data, file: String)] = [:]
    private var layerCount = 0
    private var finished = false
    private var layersDir: URL { options.dir.appendingPathComponent("layers") }

    private init(_ options: Options) { self.options = options }

    private func start() {
        let fm = FileManager.default
        try? fm.removeItem(at: options.dir)
        try? fm.createDirectory(at: layersDir, withIntermediateDirectories: true)
        let t = Timer(timeInterval: 1 / options.fps, repeats: true) { _ in
            MainActor.assumeIsolated { DemoRecorder.shared?.tick() }
        }
        t.tolerance = 0.2 / options.fps
        RunLoop.main.add(t, forMode: .common)
        timer = t
        NSLog("[lulu] record: %@ at %.0f fps%@", options.dir.path, options.fps,
              options.duration.map { String(format: " for %.1f s", $0) } ?? "")
        if let d = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                DemoRecorder.shared?.finish()
                NSApp.terminate(nil)
            }
        }
    }

    /// Windows to record: visible content windows of this process, back to front.
    private func shownWindows() -> [NSWindow] {
        NSApp.windows
            .filter { w in
                let name = String(describing: type(of: w))
                return w.isVisible && w.alphaValue > 0.01 && w.contentView != nil
                    && !name.contains("StatusBar") && !name.contains("Menu") && w.frame.width > 1
            }
            .sorted { $0.orderedIndex > $1.orderedIndex }
    }

    private func tick() {
        guard !finished else { return }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var layers: [Layer] = []
        for w in shownWindows() {
            guard let view = w.contentView, view.bounds.width > 0,
                  let img = DebugSnapshot.render(view, over: nil) else { continue }
            let pixels = Self.pixels(img)
            let file: String
            if let last = lastLayer[w.windowNumber], last.pixels == pixels {
                file = last.file
            } else {
                layerCount += 1
                file = String(format: "l%06d.png", layerCount)
                Self.writePNG(img, to: layersDir.appendingPathComponent(file))
                lastLayer[w.windowNumber] = (pixels, file)
            }
            layers.append(Layer(file: file, frame: w.frame, alpha: w.alphaValue, name: String(describing: type(of: w)),
                                image: CGSize(width: img.width, height: img.height)))
        }
        frames.append(Frame(ts: ts, layers: layers))
    }

    /// Stops recording and writes the composited frames (once).
    func finish() {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        guard let main = NSScreen.main ?? NSScreen.screens.first else { return }
        let screen = main.frame
        let bottom = max(screen.minY, main.visibleFrame.minY - 12)   // just below the pets' feet (above the Dock)
        let anchored = options.anchoredSize.map { NSRect(x: screen.maxX - $0.width, y: bottom, width: $0.width, height: $0.height) }
        let region = (options.region ?? anchored ?? autoRegion(screen: screen)).integral
        let w = Int(region.width * scale) / 2 * 2, h = Int(region.height * scale) / 2 * 2
        let bg = backgroundImage(screen: screen)
        var cache: [String: CGImage] = [:]
        var stamps: [String] = []
        var windows: [String] = []   // windows.txt: what each frame shows (debugging a scene)
        for (i, f) in frames.enumerated() {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -region.minX, y: -region.minY)
            if let bg { ctx.draw(bg, in: screen) }
            for l in f.layers {
                if cache[l.file] == nil { cache[l.file] = Self.readPNG(layersDir.appendingPathComponent(l.file)) }
                guard let img = cache[l.file] else { continue }
                ctx.saveGState()
                ctx.setAlpha(l.alpha)
                ctx.draw(img, in: l.frame)
                ctx.restoreGState()
            }
            if options.menuBar { drawMenuBar(in: ctx, region: region) }
            if let img = ctx.makeImage() {
                Self.writePNG(img, to: options.dir.appendingPathComponent(String(format: "frame-%05d.png", i + 1)))
            }
            stamps.append("\(i + 1) \(f.ts)")
            windows.append("\(i + 1) " + f.layers.map { "\($0.name) \(NSStringFromRect($0.frame)) img \(Int($0.image.width))x\(Int($0.image.height)) a \(String(format: "%.2f", $0.alpha))" }.joined(separator: " | "))
            if cache.count > 400 { cache.removeAll() }
        }
        try? stamps.joined(separator: "\n").write(to: options.dir.appendingPathComponent("timestamps.txt"), atomically: true, encoding: .utf8)
        try? windows.joined(separator: "\n").write(to: options.dir.appendingPathComponent("windows.txt"), atomically: true, encoding: .utf8)
        try? "\(Int(region.minX)) \(Int(region.minY)) \(Int(region.width)) \(Int(region.height))"
            .write(to: options.dir.appendingPathComponent("region.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: layersDir)
        NSLog("[lulu] record: %ld frames (%ld window images), region %@ → %@", frames.count, layerCount, NSStringFromRect(region), options.dir.path)
    }

    /// Union of every recorded window frame, clipped to the screen, padded, at least `minSize`, kept on screen.
    private func autoRegion(screen: NSRect) -> NSRect {
        var u = NSRect.null
        for f in frames { for l in f.layers { u = u.union(l.frame.intersection(screen)) } }
        if u.isNull || u.isEmpty { return NSRect(x: screen.maxX - 480, y: screen.minY, width: 480, height: 320) }
        u = u.insetBy(dx: -options.pad, dy: -options.pad)
        if options.menuBar { u.size.height += 24 }
        if u.width < options.minSize.width { u = u.insetBy(dx: -(options.minSize.width - u.width) / 2, dy: 0) }
        if u.height < options.minSize.height { u.size.height = options.minSize.height }
        u = u.intersection(screen)
        // Clipping can cut the padding / minimum on one side: shift back inside instead where possible.
        u.size.width = min(max(u.width, options.minSize.width), screen.width)
        u.size.height = min(max(u.height, options.minSize.height), screen.height)
        u.origin.x = min(max(u.minX, screen.minX), screen.maxX - u.width)
        u.origin.y = min(max(u.minY, screen.minY), screen.maxY - u.height)
        return u
    }

    private func backgroundImage(screen: NSRect) -> CGImage? {
        let w = Int(screen.width * scale), h = Int(screen.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if let path = options.background, let img = Self.readPNG(URL(fileURLWithPath: path)) {
            // Aspect fill.
            let s = max(rect.width / CGFloat(img.width), rect.height / CGFloat(img.height))
            let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: (rect.width - dw) / 2, y: (rect.height - dh) / 2, width: dw, height: dh))
        } else {
            let colors = [CGColor(srgbRed: 0.99, green: 0.87, blue: 0.83, alpha: 1),
                          CGColor(srgbRed: 0.86, green: 0.85, blue: 0.97, alpha: 1),
                          CGColor(srgbRed: 0.80, green: 0.92, blue: 0.96, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.55, 1]) {
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: rect.height), end: CGPoint(x: rect.width, y: 0), options: [])
            }
        }
        return ctx.makeImage()
    }

    /// A thin translucent mock menu bar across the top of the crop, with 🍊 and a clock on the right.
    private func drawMenuBar(in ctx: CGContext, region: NSRect) {
        let bar = NSRect(x: region.minX, y: region.maxY - 24, width: region.width, height: 24)
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.fill(bar)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.08))
        ctx.fill(NSRect(x: bar.minX, y: bar.minY, width: bar.width, height: 0.5))
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                    .foregroundColor: NSColor(white: 0.12, alpha: 1)]
        let clock = NSAttributedString(string: "周三 下午3:14", attributes: attrs)
        let orange = NSAttributedString(string: "🍊", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let cs = clock.size(), os = orange.size()
        clock.draw(at: NSPoint(x: bar.maxX - cs.width - 14, y: bar.minY + (bar.height - cs.height) / 2))
        orange.draw(at: NSPoint(x: bar.maxX - cs.width - 14 - 16 - os.width, y: bar.minY + (bar.height - os.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: Image I/O

    /// The image's raw pixels plus its size (compared with memcmp; `Data`'s hash only looks at a prefix).
    private static func pixels(_ img: CGImage) -> Data {
        var d = (img.dataProvider?.data as Data?) ?? Data()
        withUnsafeBytes(of: (img.width, img.height)) { d.append(contentsOf: $0) }
        return d
    }

    private static func writePNG(_ img: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func readPNG(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
