import AppKit
import ImageIO
import LuluCore

/// Plays a `SpriteClip` (image sequence: WebP / PNG frames) in a CALayer (v0.8: animated by Core Animation), bottom-centred in the view.
/// Decoded frames are cached per file URL only for the clips a pet `retain`s (its current outfit), see
/// `retain(_:owner:)`; other clips (couple clips) are decoded for one playback. The sprite can be mirrored horizontally
/// (layer transform, no duplicated frames) and lifted by `verticalOffset` (run fallback bob).
final class SpritePlayer: NSView {
    /// Points per source pixel; the pet window sets this so the idle clip is 170 pt tall.
    var pointScale: CGFloat = 1

    /// Flips the sprite horizontally (e.g. the right-facing run clip running left).
    var mirrored = false {
        didSet { if mirrored != oldValue { spriteLayer.transform = mirrored ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity } }
    }

    /// Lifts the sprite this many points (the "idle + bob" run fallback).
    var verticalOffset: CGFloat = 0 {
        didSet { if verticalOffset != oldValue { layoutSprite() } }
    }

    private let spriteLayer = CALayer()
    private var frames: [CGImage] = []
    private var delays: [Double] = []
    private var currentSize: CGSize = .zero
    private var loop = true
    private var completion: (() -> Void)?
    private var isIdle = false
    private var frozen = false
    private var idleClip: SpriteClip?

    /// Decoded frames of the retained clips (shared: identical frames have the same URL).
    private static var cache: [URL: CGImage] = [:]
    /// Frame URLs each pet window keeps decoded (its current outfit's clips).
    private static var retained: [ObjectIdentifier: Set<URL>] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .trilinear
        spriteLayer.minificationFilter = .trilinear
        spriteLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "transform": NSNull()]
        layer?.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override var isFlipped: Bool { false }

    /// v0.5 memory: `owner` (a pet window) now needs exactly `clips` (its current outfit). Their frames
    /// are decoded ahead of time so playback never stutters, and frames no pet needs any more (the
    /// previous outfit's) are dropped from the cache. With ~20 outfits only the home pet's and the
    /// visitor's current outfits stay in memory.
    static func retain(_ clips: [SpriteClip], owner: AnyObject) {
        let mine = Set(clips.flatMap(\.frames))
        retained[ObjectIdentifier(owner)] = mine
        let keep = retained.values.reduce(into: Set<URL>()) { $0.formUnion($1) }
        let before = cache.count
        cache = cache.filter { keep.contains($0.key) }
        let dropped = before - cache.count
        for url in mine where cache[url] == nil { cache[url] = decode(url) }
        let mb = Double(cache.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }) / 1_048_576
        NSLog("[lulu] frames: %ld decoded (%.0f MB), %ld released", cache.count, mb, dropped)
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Cached frames of a retained clip; anything else is decoded now and not cached (the player holds
    /// the images only while the clip plays).
    private static func images(for clip: SpriteClip) -> [CGImage] {
        clip.frames.compactMap { cache[$0] ?? decode($0) }
    }

    /// Plays `clip`; when `loop` is false, `completion` runs after the last frame.
    func play(_ clip: SpriteClip, loop: Bool, completion: (() -> Void)?) {
        load(clip, loop: loop, completion: completion)
        isIdle = false
        still = false
        startAnimation()
    }

    /// Sets and loops the idle clip (or holds frame 0 while frozen). v0.8 `still`: hold frame 0 without
    /// animating at all (quiet mode / 勿扰 / doze: the pet stops drawing).
    func idle(_ clip: SpriteClip, still: Bool = false) {
        idleClip = clip
        load(clip, loop: true, completion: nil)
        isIdle = true
        self.still = still
        startAnimation()
    }

    /// Frozen = sleeping: the idle loop holds on frame 0. One-shot clips still finish first.
    func setFrozen(_ frozen: Bool) {
        guard self.frozen != frozen else { return }
        self.frozen = frozen
        if isIdle { startAnimation() }
    }

    func stop() { stopAnimation() }

    // MARK: v0.8 frames on the render server

    /// Frames are shown by a `CAKeyframeAnimation` on `contents` (discrete, per-frame key times from the
    /// clip's delays), run by the render server: no main-thread timer per frame, so an idling pet costs the
    /// app no wake-ups at all. A one-shot clip's completion is one timer at the clip's total length.
    private static let animationKey = "frames"
    /// All players, to pause / resume them together (`setPaused`).
    private static let players = NSHashTable<SpritePlayer>.weakObjects()
    /// While true (screen locked, displays asleep, pet window occluded) nothing animates.
    private(set) static var paused = false
    private var still = false
    private var completionTimer: Timer?

    /// Stops / restarts drawing on every player. A clip interrupted by a pause freezes on its current frame
    /// (its completion still fires on time); looping clips start again on resume.
    static func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        for player in players.allObjects {
            if p {
                if let shown = player.spriteLayer.presentation()?.contents { player.spriteLayer.contents = shown }
                player.spriteLayer.removeAnimation(forKey: animationKey)
            } else if player.loop {
                player.startAnimation()
            }
        }
    }

    /// True while frames are being animated (for logs / tests).
    var isAnimating: Bool { spriteLayer.animation(forKey: Self.animationKey) != nil }

    private func load(_ clip: SpriteClip, loop: Bool, completion: (() -> Void)?) {
        stopAnimation()
        let imgs = Self.images(for: clip)
        frames = imgs
        delays = clip.delays
        currentSize = clip.size
        self.loop = loop
        self.completion = completion
        layoutSprite()
        if imgs.isEmpty {
            let done = completion
            self.completion = nil
            done?()
        }
    }

    private func startAnimation() {
        spriteLayer.removeAnimation(forKey: Self.animationKey)
        guard !frames.isEmpty else { return }
        Self.players.add(self)
        let steps = frames.indices.map { max(0.02, $0 < delays.count ? delays[$0] : 0.1) }
        let total = steps.reduce(0, +)
        spriteLayer.contents = loop ? frames[0] : frames[frames.count - 1]
        if !loop, completionTimer == nil, completion != nil {
            let t = Timer(timeInterval: total, target: self, selector: #selector(finished), userInfo: nil, repeats: false)
            t.tolerance = 0.01
            RunLoop.main.add(t, forMode: .common)
            completionTimer = t
        }
        let hold = isIdle && (still || frozen)
        guard frames.count > 1, !hold, !Self.paused else { return }
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = frames
        var t = 0.0
        var times: [NSNumber] = []
        for d in steps { times.append(NSNumber(value: t / total)); t += d }
        times.append(1)   // discrete: one more key time than values
        anim.keyTimes = times
        anim.calculationMode = .discrete
        anim.duration = total
        anim.repeatCount = loop ? .infinity : 1
        anim.isRemovedOnCompletion = true
        spriteLayer.add(anim, forKey: Self.animationKey)
    }

    private func stopAnimation() {
        spriteLayer.removeAnimation(forKey: Self.animationKey)
        completionTimer?.invalidate()
        completionTimer = nil
    }

    @objc private func finished() {
        completionTimer = nil
        let done = completion
        completion = nil
        done?()
    }

    /// True while a one-shot clip (react / happy) is playing.
    var isPlayingOneShot: Bool { !isIdle && !frames.isEmpty }

    override func layout() {
        super.layout()
        layoutSprite()
    }

    private func layoutSprite() {
        let w = currentSize.width * pointScale, h = currentSize.height * pointScale
        // bounds + position (not frame), which stay well-defined while the layer is mirrored.
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        spriteLayer.position = CGPoint(x: bounds.width / 2, y: verticalOffset + h / 2)
        spriteLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Top of the currently displayed sprite, in this view's coordinates.
    var spriteTop: CGFloat { currentSize.height * pointScale }

    /// Width of the currently displayed sprite, in points.
    var spriteWidth: CGFloat { currentSize.width * pointScale }
}
