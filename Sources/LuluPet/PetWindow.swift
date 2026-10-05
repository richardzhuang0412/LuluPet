import AppKit
import LuluCore

/// The transparent floating panel the pet lives in. Handles drag vs. click vs. double click,
/// remembers its position per profile, and hosts the sprite player plus effects.
///
/// The same class shows the visiting partner (`isVisitor`): a visitor never reads or writes the saved
/// position, isn't registered with other instances (PetNeighbors) and never dodges other pets.
final class PetWindow: NSPanel {
    /// Idle sprite height at `petScale` 1.0.
    static let displayHeight: CGFloat = 170
    /// Narrowest window at `petScale` 1.0.
    static let minWindowWidth: CGFloat = 120
    /// Transparent headroom above the sprite for hearts / Zzz / toasts.
    nonisolated static let topMargin: CGFloat = 44
    private static let originKey = "petOrigin"
    /// Gap kept between our pet and another instance's pet.
    static let neighborMargin: CGFloat = 12
    static let defaultSlotGap: CGFloat = 24
    nonisolated static let visitorWindowTitle = "LuluPetVisitor"

    /// Default spot when no position is saved: 0 = bottom-right corner of the main screen,
    /// 1 = one pet-width (+ gap) left of that. The pet showing 噜妹 uses 0, the one showing 噜噜 1,
    /// so two instances on one Mac start side by side.
    var defaultSlot = 0

    /// Single click: a local-only reaction (nothing is sent; hearts are sent from the compose panel).
    var onClick: (() -> Void)?
    var onCompose: (() -> Void)?
    var onMoved: (() -> Void)?
    /// Returned menu is shown on right click.
    var contextMenu: (() -> NSMenu?)?
    /// Called when a drag ends, with the origin the window had before the drag. Return true when the
    /// drop was handled (e.g. merged with the visitor); otherwise the pet dodges other pets as usual.
    var onDragEnded: ((NSPoint) -> Bool)?
    /// While true (running, couple clip), clicks and drags on the pet are ignored.
    var inputLocked = false
    /// Any mouse-down on the pet (click, double click, drag start, right click): user activity.
    var onInteraction: (() -> Void)?
    /// v0.7: the resize handle was released at this (normalized) scale; the app saves it and resizes the
    /// rest of the desk (visitor, bubble).
    var onScaleChosen: ((Double) -> Void)?

    /// v0.7 "大小" (`petScale`): multiplies the 170 pt idle height and everything drawn around it.
    private(set) var petScale: CGFloat = 1
    /// A scale requested while running / playing a couple clip, applied when that ends.
    private var pendingScale: CGFloat?
    /// Hidden `--demo-resize-handle`: keep the handle visible (snapshots).
    var forceResizeHandle = false { didSet { updateHandle(animated: false) } }
    private let handle = ResizeHandle(frame: NSRect(x: 0, y: 0, width: ResizeHandle.side, height: ResizeHandle.side))
    /// v0.8.1: mouse-moved monitors (global + local) of the event-driven hover watch; empty = not watching.
    private var hoverMonitors: [Any] = []
    /// v0.8.1: slow poll, only while the handle is visible (catches a missed exit).
    private var hoverFallback: Timer?
    private var handleShown = false

    let player = SpritePlayer(frame: .zero)
    let isVisitor: Bool
    private let petView = PetView(frame: .zero)
    private let defaults: UserDefaults?
    private var clips: [Action: SpriteClip] = [:]
    /// v0.3 optional clip lists of the current outfit.
    private var fidgets: [NamedClip] = []
    private var stays: [NamedClip] = []
    /// Clips only played by name (reactions.json).
    private var extras: [NamedClip] = []
    private var lastFidget: Int?
    /// v0.12 weather looks: clips of this character per look (Sprites/<char>/weather.json), mixed into the random fidgets.
    private var weatherClips: [WeatherLook: [NamedClip]] = [:]
    private var lastWeatherFidget: Int?
    /// What the pet loops when it isn't doing anything else.
    enum Rest: Equatable {
        case idle
        /// Dozing with the outfit's own `sleep` clip.
        case sleep
        /// The visitor's pose beside the host (a `stay` clip name).
        case stay(String)
        /// v0.8 省电 quiet mode / 勿扰: the outfit's still `quiet` frame (else idle frame 0), not animated.
        case quiet
    }
    /// v0.8: quiet mode or 勿扰 is on (the rest pose is `.quiet` unless dozing).
    private(set) var isQuiet = false
    /// v0.8 勿扰 mood sign above the head ("😤 生气中" …), nil = none.
    private var moodText: String?
    private var moodLayer: CALayer?
    /// v0.10 pomodoro countdown pill at the feet.
    private var countdownText: String?
    private var countdownLayer: CALayer?
    private let countdownHost = ClickThroughView()
    /// v0.8: the pointer came over the sprite (wakes quiet mode).
    var onHover: (() -> Void)?
    private var pointerOver = false
    /// The pointer is over the visible sprite (the 想 TA hover trigger checks it after its 1 s wait).
    var isPointerOver: Bool { pointerOver }
    /// v0.8 battery-aware hover interval. Since v0.8.1 the hover watch is event-driven; this is only a floor
    /// for the fallback poll that runs while the handle is visible (`HoverWatch.fallbackPoll`, 1 s).
    var hoverInterval: TimeInterval = 0.1
    /// v0.8: nothing of the pet can be seen (screen locked / displays asleep / occluded): no hover polling.
    var hoverPaused = false {
        didSet {
            guard hoverPaused != oldValue, appeared else { return }
            if hoverPaused { stopHoverWatch() } else { startHoverWatch() }
        }
    }
    private(set) var rest = Rest.idle
    /// v0.3 idle doze (home pet): the `sleep` clip if the outfit has one, else the frozen-idle fallback.
    private(set) var isDozing = false
    private var runTimer: Timer?
    private var runFinish: (() -> Void)?
    private var coupleRestore: (() -> Void)?
    private var sleepLayer: CALayer?
    private(set) var isSleeping = false
    /// Bumped by every outfit change so a stale fade never applies an old outfit.
    private var outfitGeneration = 0
    static let outfitFadeDuration: TimeInterval = 0.2   // each way (out, then in)

    /// `defaults` = where the home pet remembers its position; nil for the visitor.
    init(defaults: UserDefaults?, isVisitor: Bool = false) {
        self.defaults = defaults
        self.isVisitor = isVisitor
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: Self.displayHeight + Self.topMargin),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false            // we move it ourselves so we can tell clicks from drags
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Never shown (borderless); lets other instances find the home pet (and ignore the visitor).
        title = isVisitor ? Self.visitorWindowTitle : PetNeighbors.petWindowTitle

        petView.wantsLayer = true
        petView.owner = self
        contentView = petView
        player.autoresizingMask = [.width, .height]
        petView.addSubview(player)
        if !isVisitor {
            handle.owner = self
            handle.isHidden = true
            handle.alphaValue = 0
            petView.addSubview(handle)   // above the sprite
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: Character

    /// Loads the three clips for `character`/`outfit` and resizes the window so idle is 170 pt tall.
    func setCharacter(_ catalog: SpriteCatalog, character: Role, outfit: String) {
        outfitGeneration += 1
        player.alphaValue = restingAlpha   // in case a fade was cut short
        loadClips(catalog, character: character, outfit: outfit)
    }

    /// Soft outfit change: fades the sprite out, swaps clips, fades back in.
    func transitionOutfit(_ catalog: SpriteCatalog, character: Role, outfit: String, completion: (() -> Void)? = nil) {
        outfitGeneration += 1
        let generation = outfitGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.outfitFadeDuration
            player.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, generation == self.outfitGeneration else { return }
            self.loadClips(catalog, character: character, outfit: outfit)
            completion?()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.outfitFadeDuration
                self.player.animator().alphaValue = self.restingAlpha
            }
        })
    }

    /// True while a react / happy / couple clip is playing or the pet is running (not just idling).
    var isBusy: Bool { player.isPlayingOneShot || isRunning || coupleRestore != nil }

    var isRunning: Bool { runTimer != nil }

    private var restingAlpha: CGFloat { isSleeping ? 0.7 : 1 }

    private func loadClips(_ catalog: SpriteCatalog, character: Role, outfit: String) {
        clips = [:]
        fidgets = catalog.namedClips(character, outfit: outfit, list: .fidgets)
        stays = catalog.namedClips(character, outfit: outfit, list: .stay)
        extras = catalog.namedClips(character, outfit: outfit, list: .clips)
        lastFidget = nil
        queuedFidget = nil
        weatherClips = Dictionary(uniqueKeysWithValues: WeatherLook.allCases.compactMap { look in
            let list = catalog.weatherNamedClips(for: character, look: look)
            return list.isEmpty ? nil : (look, list)
        })
        lastWeatherFidget = nil
        for a in Action.allCases {
            // Base actions fall back to idle; optional ones (run / wave) stay absent so callers can
            // use their own fallbacks (idle + bob, happy).
            let clip = Action.base.contains(a) ? catalog.clip(character, outfit: outfit, action: a)
                                               : catalog.exactClip(character, outfit: outfit, action: a)
            if let c = clip { clips[a] = c }
        }
        // Keep only this outfit's core clips decoded (the previous outfit's are released); fidgets / stays / extras
        // are decoded on demand (prelaunch-F, SpritePlayer.prefetch).
        SpritePlayer.retain(Array(clips.values), owner: self)
        guard let (size, scale) = fittedLayout() else { return }
        player.pointScale = scale

        let origin = frame.size == .zero ? .zero : frame.origin
        setContentSize(size)
        player.frame = NSRect(origin: .zero, size: size)
        layoutHandle()
        if isVisible {
            setFrameOrigin(origin)
        } else {
            setFrameOrigin(savedOrigin() ?? defaultOrigin())
        }
        if isDozing { applyDoze() }
        returnToRest()
        if isSleeping || isDozing { refreshSleepIndicator() }
        layoutMoodSign()
        layoutCountdown()
        if !isVisitor { primeNextFidget(weather: nil, extra: []) }
    }

    /// Window size and points-per-pixel for the current outfit at `petScale` (idle = 170 pt x scale),
    /// wide / tall enough for every clip of the outfit. nil before an outfit is loaded.
    private func fittedLayout(scale petScale: CGFloat? = nil) -> (NSSize, CGFloat)? {
        guard let idle = clips[.idle] else { return nil }
        let k = petScale ?? self.petScale
        let scale = Self.displayHeight * k / idle.size.height
        let sizes = clips.values.map(\.size) + (fidgets + stays + extras).map(\.clip.size)
        let maxW = sizes.map(\.width).max() ?? idle.size.width
        let maxH = sizes.map(\.height).max() ?? idle.size.height
        return (NSSize(width: ceil(max(maxW * scale, Self.minWindowWidth * k)), height: ceil(maxH * scale) + Self.topMargin), scale)
    }

    // MARK: Size (v0.7)

    /// Sets the pet's size (1.0 = 170 pt idle). The sprite's bottom-left corner stays where it is (the feet
    /// keep their baseline; the pet grows up and to the right, towards the handle). `live` = while dragging
    /// the handle (nothing saved, may be off screen); otherwise the window is kept on screen and the
    /// home pet's position saved. While running / in a couple clip the change waits until that ends.
    func setPetScale(_ s: CGFloat, live: Bool = false, keepRightEdge: Bool = false) {
        guard s.isFinite, s > 0 else { return }
        if isRunning || coupleRestore != nil {
            pendingScale = s
            return
        }
        pendingScale = nil
        let oldFrame = frame, oldSpriteWidth = idleSpriteWidth
        petScale = s
        guard let (size, scale) = fittedLayout() else { return }
        player.pointScale = scale
        let newSpriteWidth = idleSpriteWidth
        var origin = PetScale.anchoredOrigin(oldFrame: oldFrame, oldSpriteWidth: oldSpriteWidth,
                                             newSpriteWidth: newSpriteWidth, newWindowWidth: size.width)
        if keepRightEdge {   // resizing from a left-side corner: the sprite's right edge stays put
            let spriteRight = oldFrame.midX + oldSpriteWidth / 2
            origin.x = spriteRight - newSpriteWidth / 2 - size.width / 2
        }
        if !live, let vf = (NSScreen.screens.first { $0.frame.intersects(oldFrame) } ?? NSScreen.main)?.visibleFrame {
            origin = PetScale.keepOnScreen(origin, size: size, screen: vf)
        }
        setFrame(NSRect(origin: origin, size: size), display: true)
        player.frame = NSRect(origin: .zero, size: size)
        player.needsLayout = true
        player.layoutSubtreeIfNeeded()
        layoutHandle()
        if isSleeping || isDozing { refreshSleepIndicator() }
        layoutMoodSign()
        layoutCountdown()
        if !live, isVisible, !isVisitor { saveOrigin() }
        onMoved?()
    }

    private func applyPendingScale() {
        guard let s = pendingScale, !isRunning, coupleRestore == nil else { return }
        setPetScale(s)
    }

    /// Screen rect of the resize handle (for logs / demos).
    var handleScreenRect: NSRect { handle.frame.offsetBy(dx: frame.minX, dy: frame.minY) }

    /// Which corner of the sprite the handle sits on: the one nearest the pointer (so a pet parked in the
    /// bottom-right corner of the screen gets its handle top-left). The opposite side stays put.
    private var handleCorner: ResizeHandle.Corner = .topLeft

    /// The handle sits on `handleCorner` of the visible sprite.
    private func layoutHandle() {
        guard !isVisitor else { return }
        let side = ResizeHandle.side
        let sprite = visibleSpriteScreenRect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let x = handleCorner.isLeft ? sprite.minX - side * 0.2 : sprite.maxX - side * 0.8
        let y = handleCorner.isTop ? sprite.maxY - side * 0.8 : sprite.minY + 2
        handle.frame = NSRect(x: min(max(x, 0), petView.bounds.maxX - side), y: min(max(y, 0), petView.bounds.maxY - side),
                              width: side, height: side)
        handle.corner = handleCorner
    }

    /// Corner of the visible sprite nearest to `p` (screen coordinates).
    private func nearestCorner(to p: NSPoint) -> ResizeHandle.Corner {
        let r = visibleSpriteScreenRect
        let left = p.x < r.midX, top = p.y > r.midY
        switch (left, top) {
        case (true, true): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }

    /// Hover watch (home pet only): the handle fades in while the pointer is over the sprite (or the
    /// handle) and nothing else is going on, and fades out otherwise; the first hover wakes quiet mode.
    ///
    /// v0.8.1 省电: event-driven instead of a 10 Hz poll. The window lets clicks through its transparent
    /// pixels, so its tracking area sees the pointer over the opaque sprite (where a hover actually
    /// happens) — enough to show the handle and wake quiet mode. No global mouse monitor on purpose: it
    /// would wake the app on every mouse move anywhere (60–120/s while the user works). A local monitor
    /// covers drags / mouse-ups in our own windows. While the handle is visible a 1 s fallback poll hides
    /// it after the pointer leaves (the handle's corner may sit over transparent pixels).
    private func startHoverWatch() {
        guard !isVisitor, hoverMonitors.isEmpty, !hoverPaused else { return }
        // Local: also drags / mouse-ups on our own windows (the handle hides while dragging the pet).
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return e
        }) { hoverMonitors.append(m) }
        petView.installHoverTracking()
        updateHandle(animated: false)   // the pointer may already be over the pet
    }

    private func stopHoverWatch() {
        hoverMonitors.forEach(NSEvent.removeMonitor)
        hoverMonitors = []
        stopHoverFallback()
    }

    /// Mouse-moved event (monitor or tracking area): check only when it can matter.
    fileprivate func pointerMoved() {
        guard HoverWatch.needsCheck(pointer: NSEvent.mouseLocation, window: frame,
                                    handleShown: handleShown, pointerOver: pointerOver) else { return }
        updateHandle(animated: true)
    }

    /// True while the event-driven hover watch is installed (logs / tests).
    var isHoverWatching: Bool { !hoverMonitors.isEmpty }
    /// True while the slow fallback poll runs (only while the handle is visible).
    var isHoverFallbackRunning: Bool { hoverFallback != nil }

    /// Hidden hook for tests / demos: the pointer "moved" to `p` (screen coordinates) — the same path a
    /// real mouse-moved event takes, with `p` instead of the real pointer. Returns (over, handle shown).
    @discardableResult
    func simulatePointer(at p: NSPoint) -> (over: Bool, shown: Bool) {
        simulatedPointer = p
        defer { simulatedPointer = nil }
        if HoverWatch.needsCheck(pointer: p, window: frame, handleShown: handleShown, pointerOver: pointerOver) {
            updateHandle(animated: false)
        }
        return (pointerOver, handleShown)
    }
    private var simulatedPointer: NSPoint?

    private func startHoverFallback() {
        guard hoverFallback == nil, !hoverMonitors.isEmpty else { return }
        let interval = max(HoverWatch.fallbackPoll, hoverInterval)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHandle(animated: true) }
        }
        t.tolerance = PowerProfile.tolerance(for: interval)
        RunLoop.main.add(t, forMode: .common)
        hoverFallback = t
    }

    private func stopHoverFallback() {
        hoverFallback?.invalidate()
        hoverFallback = nil
    }

    private func updateHandle(animated: Bool) {
        guard !isVisitor else { return }
        let show: Bool
        if forceResizeHandle || handle.isResizing {
            show = true
        } else if Offscreen.enabled || !isVisible || alphaValue < 0.5 || inputLocked || isRunning || isDragging || coupleRestore != nil {
            show = false
        } else {
            let p = simulatedPointer ?? NSEvent.mouseLocation
            let state = HoverWatch.state(pointer: p, sprite: visibleSpriteScreenRect, handle: handleScreenRect)
            show = state.show
            let over = state.over
            if over, !pointerOver { onHover?() }   // v0.8: hovering wakes quiet mode
            pointerOver = over
            if show, !handleScreenRect.insetBy(dx: -HoverWatch.handleSlack, dy: -HoverWatch.handleSlack).contains(p) {
                let c = nearestCorner(to: p)
                if c != handleCorner { handleCorner = c; layoutHandle() }
            }
        }
        guard show != handleShown else { return }
        handleShown = show
        // v0.8.1: the slow fallback poll runs only while the handle is visible.
        if show { startHoverFallback() } else { stopHoverFallback() }
        if show { handle.isHidden = false }
        guard animated else {
            handle.alphaValue = show ? 1 : 0
            handle.isHidden = !show
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? 0.18 : 0.3
            handle.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.handleShown else { return }
            self.handle.isHidden = true
        })
    }

    // Handle drag (ResizeHandle → here).
    private var resizeStart: (scale: CGFloat, sprite: CGSize)?
    private var resizeCorner: ResizeHandle.Corner = .bottomRight

    /// Pointer movement turned into "towards the corner" terms (right / up = grow for PetScale.dragged).
    private func outward(_ d: CGVector) -> CGVector {
        CGVector(dx: resizeCorner.isLeft ? -d.dx : d.dx, dy: resizeCorner.isTop ? d.dy : -d.dy)
    }

    fileprivate func beginResize() {
        onInteraction?()
        resizeStart = (petScale, CGSize(width: idleSpriteWidth, height: Self.displayHeight * petScale))
        resizeCorner = handleCorner
    }

    /// `delta` = pointer movement since mouse-down (screen points, y up). Returns the live scale.
    @discardableResult
    func resizeDragged(by delta: CGVector) -> CGFloat {
        guard let start = resizeStart else { return petScale }
        let raw = PetScale.dragged(start: Double(start.scale), delta: outward(delta), sprite: start.sprite)
        let s = CGFloat(PetScale.rubberBand(raw))
        setPetScale(s, live: true, keepRightEdge: resizeCorner.isLeft)
        return s
    }

    /// Mouse-up: snaps into the limits, keeps the pet on screen, and hands the value to the app.
    @discardableResult
    func endResize(by delta: CGVector) -> Double {
        guard let start = resizeStart else { return Double(petScale) }
        resizeStart = nil
        let final = PetScale.normalized(PetScale.dragged(start: Double(start.scale), delta: outward(delta), sprite: start.sprite))
        setPetScale(CGFloat(final), keepRightEdge: resizeCorner.isLeft)
        NSLog("[lulu] resize: %.2f → %.2f, frame %@", Double(start.scale), final, NSStringFromRect(frame))
        onScaleChosen?(final)
        avoidNeighbors(reason: "resize", yieldToOlder: false)
        return final
    }

    /// Hidden `--demo-resize-drag DX,DY`: the same calls a real handle drag makes, in a few steps.
    func simulateResizeDrag(to delta: CGVector, steps: Int = 8, completion: (() -> Void)? = nil) {
        beginResize()
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) { [weak self] in
                guard let self else { return }
                let f = CGFloat(i) / CGFloat(steps)
                let d = CGVector(dx: delta.dx * f, dy: delta.dy * f)
                if i < steps {
                    let s = self.resizeDragged(by: d)
                    NSLog("[lulu] resize drag step %d: scale %.3f frame %@", i, Double(s), NSStringFromRect(self.frame))
                } else {
                    self.endResize(by: d)
                    completion?()
                }
            }
        }
    }

    /// Plays an action once, then returns to idle. A missing `wave` plays `happy`; a missing
    /// `run` plays idle.
    func playOnce(_ action: Action, completion: (() -> Void)? = nil) {
        guard let clip = clips[action] ?? (action == .wave ? clips[.happy] : nil) ?? clips[.idle] else { completion?(); return }
        playClipOnce(clip, completion: completion)
    }

    /// Bumped by everything that starts or changes what the player shows; a lazily decoded clip that finishes
    /// decoding after that is dropped (prelaunch-F).
    private var playToken = 0

    private func playClipOnce(_ clip: SpriteClip, completion: (() -> Void)?) {
        playToken += 1
        guard !SpritePlayer.isReady(clip) else { startClipOnce(clip, completion: completion); return }
        // Not decoded yet (a fidget / extra that was not prefetched): decode off-main, play when ready (≈ tens of ms).
        let token = playToken, t0 = CACurrentMediaTime()
        SpritePlayer.prefetch(clip, owner: self) { [weak self] in
            guard let self, token == self.playToken, !self.isRunning, self.coupleRestore == nil else { return }
            NSLog("[lulu] lazy clip %@: not ready at play time, started %.0f ms late", clip.frames.first?.deletingLastPathComponent().lastPathComponent ?? "?",
                  (CACurrentMediaTime() - t0) * 1000)
            self.startClipOnce(clip, completion: completion)
        }
    }

    private func startClipOnce(_ clip: SpriteClip, completion: (() -> Void)?) {
        player.play(clip, loop: false) { [weak self] in
            self?.returnToRest()
            completion?()
        }
    }

    // MARK: Lazy fidget prefetch (prelaunch-F)

    /// The next random fidget, picked ahead (for `queuedFidget.look`) so its frames are decoded before it plays.
    private var queuedFidget: (look: WeatherLook?, choice: WeatherPlan.FidgetChoice)?

    private func fidgetClip(_ c: WeatherPlan.FidgetChoice, weather: [NamedClip]) -> NamedClip {
        switch c {
        case .plain(let i): return fidgets[i]
        case .weather(let i): return weather[i]
        }
    }

    /// Picks the following fidget now and decodes it in the background.
    private func primeNextFidget(weather look: WeatherLook?, extra: [NamedClip]) {
        guard let c = WeatherPlan.pickFidget(plain: fidgets.count, weather: extra.count, lastPlain: lastFidget, lastWeather: lastWeatherFidget,
                                             roll: { Int.random(in: 0..<$0) }) else { queuedFidget = nil; return }
        queuedFidget = (look, c)
        SpritePlayer.prefetch(fidgetClip(c, weather: extra).clip, owner: self)
    }

    /// Whether this outfit has its own clip for `action` (else a fallback is used).
    func hasClip(_ action: Action) -> Bool { clips[action] != nil }

    // MARK: Rest pose, fidgets, doze (v0.3)

    private var restClip: SpriteClip? {
        switch rest {
        case .idle: return clips[.idle]
        case .sleep: return clips[.sleep] ?? clips[.idle]
        case .stay(let name): return stays.first { $0.name == name }?.clip ?? clips[.idle]
        case .quiet: return clips[.quiet] ?? clips[.idle]
        }
    }

    /// Loops the rest pose (idle or the visitor's stay pose); v0.8: quiet and doze are held still (frame 0
    /// of the `quiet` clip / of the eyes-closed `sleep` clip), so nothing is drawn while the pet rests.
    private func returnToRest() {
        playToken += 1
        if case .stay(let name) = rest, let c = stays.first(where: { $0.name == name })?.clip {
            // The visitor's stay pose is kept decoded while it is the rest pose (decoded now if need be).
            if !SpritePlayer.isReady(c) {
                if let idle = clips[.idle] { player.idle(idle) }   // meanwhile
                SpritePlayer.prefetch(c, owner: self, pin: true) { [weak self] in
                    guard let self, self.rest == .stay(name), !self.isBusy else { return }
                    self.returnToRest()
                }
                return
            }
            SpritePlayer.prefetch(c, owner: self, pin: true)
        } else {
            SpritePlayer.unpin(owner: self)
        }
        if let c = restClip { player.idle(c, still: rest == .quiet || rest == .sleep) }
    }

    /// The rest pose when not dozing.
    private var awakeRest: Rest { isQuiet ? .quiet : .idle }

    /// v0.8 quiet mode / 勿扰 on or off (applied now unless a clip is playing; dozing keeps its pose).
    func setQuiet(_ on: Bool) {
        guard on != isQuiet else { return }
        isQuiet = on
        if !isDozing, rest == .idle || rest == .quiet { setRest(awakeRest) }
    }

    /// True when nothing on the pet is animating (for logs).
    var isStill: Bool { !player.isAnimating }

    /// v0.8 勿扰 sign above the head (a small pill), nil removes it. Follows `petScale` and the pet.
    func setMoodSign(_ text: String?) {
        guard text != moodText else { return }
        moodText = text
        layoutMoodSign()
    }

    private func layoutMoodSign() {
        moodLayer?.removeFromSuperlayer()
        moodLayer = nil
        guard let text = moodText, let idle = clips[.idle] else { return }
        let top = idle.size.height * player.pointScale
        moodLayer = Effects.moodSign(text, in: petView, bottomCenter: CGPoint(x: petView.bounds.midX, y: top + 3 * petScale),
                                     maxTop: petView.bounds.height - 1, scale: petScale)
    }

    /// v0.10 pomodoro countdown ("🍅 12") at the pet's feet, nil removes it. A static pill (no animation, redrawn
    /// only when the text changes: once a minute, every second in the last minute).
    func setCountdown(_ text: String?) {
        guard text != countdownText else { return }
        countdownText = text
        layoutCountdown()
    }

    private func layoutCountdown() {
        countdownLayer?.removeFromSuperlayer()
        countdownLayer = nil
        guard let text = countdownText, clips[.idle] != nil else {
            countdownHost.removeFromSuperview()
            return
        }
        // Its own click-through view on top of the sprite (the pill hangs over the feet).
        if countdownHost.superview == nil {
            countdownHost.wantsLayer = true
            petView.addSubview(countdownHost)
        }
        countdownHost.frame = petView.bounds
        countdownLayer = Effects.moodSign(text, in: countdownHost, bottomCenter: CGPoint(x: petView.bounds.midX, y: 1 * petScale),
                                          maxTop: petView.bounds.height - 1, scale: petScale)
    }

    /// Changes the rest pose; applied now unless a one-shot clip / run / couple clip is playing
    /// (they return to it when they finish).
    func setRest(_ r: Rest) {
        guard r != rest else { return }
        rest = r
        if !isBusy { returnToRest() }
    }

    /// Names of this outfit's `stay` clips (the visitor picks one per visit).
    var stayNames: [String] { stays.map(\.name) }

    var fidgetCount: Int { fidgets.count }

    /// True when this character has at least one weather clip (any look): the weather then matters even without the widget.
    var hasWeatherClips: Bool { !weatherClips.isEmpty }

    /// Plays one random fidget once (never the previous one again when there is a choice), then
    /// returns to rest. Returns its name, or nil when the outfit has none. v0.12: while `weather` is a look this
    /// character has clips for, about a third of the picks are one of those (`lastFidgetWasWeather` says so).
    @discardableResult
    func playFidget(weather: WeatherLook? = nil) -> String? {
        lastFidgetWasWeather = false
        let extra = weather.flatMap { weatherClips[$0] } ?? []
        let picked: WeatherPlan.FidgetChoice?
        if let q = queuedFidget, q.look == weather { picked = q.choice }   // the one decoded ahead
        else { picked = WeatherPlan.pickFidget(plain: fidgets.count, weather: extra.count, lastPlain: lastFidget, lastWeather: lastWeatherFidget,
                                               roll: { Int.random(in: 0..<$0) }) }
        queuedFidget = nil
        let name: String
        switch picked {
        case nil: return nil
        case .plain(let i)?:
            lastFidget = i
            playClipOnce(fidgets[i].clip, completion: nil)
            name = fidgets[i].name
        case .weather(let i)?:
            lastWeatherFidget = i
            lastFidgetWasWeather = true
            playClipOnce(extra[i].clip, completion: nil)
            name = extra[i].name
        }
        if !isVisitor { primeNextFidget(weather: weather, extra: extra) }
        return name
    }

    /// The last `playFidget` picked a weather clip.
    private(set) var lastFidgetWasWeather = false

    /// Plays a clip by name once (reactions.json `visitor`): an action name, else a fidget / stay
    /// / extra clip name. Returns false when the outfit has no such clip (nothing is played).
    @discardableResult
    /// True when `name` is an action or a named fidget / stay / extra clip of the current outfit.
    func hasNamed(_ name: String) -> Bool {
        if let a = Action(rawValue: name), clips[a] != nil { return true }
        return (fidgets + stays + extras).contains { $0.name == name }
    }

    /// v0.9: the sounds.json key bound to the named fidget / stay / extra clip (its spec's `"sound"`), if any.
    func namedSound(_ name: String) -> String? {
        (fidgets + stays + extras).first(where: { $0.name == name })?.sound
    }

    func playNamed(_ name: String, completion: (() -> Void)? = nil) -> Bool {
        if let a = Action(rawValue: name), let clip = clips[a] {
            playClipOnce(clip, completion: completion)
            return true
        }
        guard let c = (fidgets + stays + extras).first(where: { $0.name == name }) else { return false }
        playClipOnce(c.clip, completion: completion)
        return true
    }

    /// Doze on / off. With a `sleep` clip it loops that (plus Zzz); otherwise idle freezes on frame 0
    /// at 70 % opacity with a Zzz (the old sleeping look).
    func setDozing(_ on: Bool) {
        guard on != isDozing else { return }
        isDozing = on
        if on {
            applyDoze()
        } else {
            setSleeping(false)
            setRest(awakeRest)
            refreshSleepIndicator()
        }
    }

    private func applyDoze() {
        let hasSleep = clips[.sleep] != nil
        setSleeping(!hasSleep)
        setRest(hasSleep ? .sleep : awakeRest)
        refreshSleepIndicator()
    }

    /// True while the user is dragging the pet.
    var isDragging: Bool { petView.dragging }

    // MARK: Running (visits)

    /// Runs horizontally to window x `targetX` at `speed` pt/s, then idles and calls `completion`.
    /// Uses the `run` clip (facing right, mirrored when running left); without one, idle with a
    /// small vertical bob. The saved position is not touched.
    func run(toX targetX: CGFloat, speed: CGFloat = Visits.runSpeed, completion: (() -> Void)? = nil) {
        stopRunning()
        let startX = frame.minX, y = frame.minY
        let duration = max(0.05, VisitGeometry.runDuration(targetX - startX, speed: speed))
        let runClip = clips[.run]
        playToken += 1
        if let clip = runClip ?? clips[.idle] { player.play(clip, loop: true, completion: nil) }
        player.mirrored = runClip != nil && targetX < startX
        let start = CACurrentMediaTime()
        runFinish = completion
        defer { if handleShown { updateHandle(animated: true) } }   // v0.8.1: no poll to hide it any more
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - start
                let f = min(1, elapsed / duration)
                self.setFrameOrigin(NSPoint(x: startX + (targetX - startX) * CGFloat(f), y: y))
                if runClip == nil { self.player.verticalOffset = abs(sin(CGFloat(elapsed) * .pi * 4.5)) * 7 * self.petScale }
                self.onMoved?()
                if f >= 1 { self.finishRunning() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        runTimer = t
    }

    /// Cancels a run in place (no completion).
    func stopRunning() {
        guard runTimer != nil else { return }
        runFinish = nil
        finishRunning()
    }

    private func finishRunning() {
        runTimer?.invalidate()
        runTimer = nil
        player.verticalOffset = 0
        player.mirrored = false
        returnToRest()
        applyPendingScale()
        let done = runFinish
        runFinish = nil
        done?()
    }

    // MARK: Couple clip (visits)

    /// Temporarily turns this window into the stage for a two-character clip: resized so the pets
    /// keep their size, centred on `centerX` with its bottom on `baseline`, played once, then the
    /// window's own frame, scale and idle come back and `completion` runs.
    func playCouple(_ clip: SpriteClip, mirrored: Bool, heightFactor: CGFloat = 1, centerX: CGFloat, baseline: CGFloat, completion: @escaping () -> Void) {
        stopRunning()
        let savedFrame = frame, savedScale = player.pointScale
        let scale = Self.displayHeight * petScale * heightFactor / clip.size.height
        let size = NSSize(width: ceil(max(clip.size.width * scale, Self.minWindowWidth * petScale)), height: ceil(clip.size.height * scale) + Self.topMargin)
        player.pointScale = scale
        setFrame(NSRect(x: centerX - size.width / 2, y: baseline, width: size.width, height: size.height), display: true)
        player.frame = NSRect(origin: .zero, size: size)
        player.mirrored = mirrored
        alphaValue = 1
        coupleRestore = { [weak self] in
            guard let self else { return }
            self.player.mirrored = false
            self.player.pointScale = savedScale
            self.setFrame(savedFrame, display: true)
            self.player.frame = NSRect(origin: .zero, size: savedFrame.size)
            self.returnToRest()
            self.coupleRestore = nil
            self.applyPendingScale()
        }
        playToken += 1
        player.play(clip, loop: false) { [weak self] in
            self?.coupleRestore?()
            self?.coupleRestore = nil
            completion()
        }
    }

    /// Shows / hides the whole pet (used while a couple clip stands in for both).
    func setPetHidden(_ hidden: Bool) {
        alphaValue = hidden ? 0 : 1
    }

    /// Visible idle sprite width in points (the sprite is horizontally centred in the window).
    var idleSpriteWidth: CGFloat {
        guard let idle = clips[.idle] else { return frame.width }
        return idle.size.width * player.pointScale
    }

    /// Screen rect of just the visible idle sprite (narrower than the window).
    var visibleSpriteScreenRect: NSRect {
        let w = idleSpriteWidth
        return NSRect(x: frame.midX - w / 2, y: frame.minY, width: w, height: player.spriteTop)
    }

    /// Animates back to `origin` (e.g. after a merge) and optionally remembers it.
    func slide(to origin: NSPoint, save: Bool, completion: (() -> Void)? = nil) {
        let target = NSRect(origin: origin, size: frame.size)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.setFrameOrigin(origin)
            if save { self.saveOrigin() }
            self.onMoved?()
            completion?()
        })
    }

    func showHearts() {
        Effects.hearts(in: petView, from: CGPoint(x: petView.bounds.midX, y: player.spriteTop * 0.72), scale: petScale)
    }

    func showToast(_ text: String) {
        Effects.toast(text, in: petView, at: CGPoint(x: petView.bounds.midX, y: min(player.spriteTop + 12, petView.bounds.height - 14)))
    }

    func setSleeping(_ sleeping: Bool) {
        guard sleeping != isSleeping else { return }
        isSleeping = sleeping
        player.setFrozen(sleeping)
        player.alphaValue = restingAlpha
        refreshSleepIndicator()
    }

    private func refreshSleepIndicator() {
        sleepLayer?.removeFromSuperlayer()
        sleepLayer = nil
        guard isSleeping || isDozing else { return }   // Zzz for both the sleep clip and the fallback
        let top = player.spriteTop
        sleepLayer = Effects.sleepIndicator(in: petView, at: CGPoint(x: petView.bounds.midX + 22 * petScale, y: top - 6 * petScale), scale: petScale)
    }

    /// Screen rect of the visible sprite (without the transparent headroom).
    var spriteScreenRect: NSRect {
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: player.spriteTop)
    }

    // MARK: Position

    private func savedOrigin() -> NSPoint? {
        guard let s = defaults?.string(forKey: Self.originKey) else { return nil }
        let p = NSPointFromString(s)
        let rect = NSRect(origin: p, size: frame.size)
        // Only reuse it if the pet would still be (mostly) on a connected screen.
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3)) } ? p : nil
    }

    private func defaultOrigin() -> NSPoint {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = vf.maxX - frame.width - 24 - CGFloat(defaultSlot) * (frame.width + Self.defaultSlotGap * petScale)
        return NSPoint(x: max(vf.minX, x), y: vf.minY + 8)
    }

    // MARK: Neighbours (other LuluPet instances)

    /// Registers this pet with other instances and starts watching for screen changes.
    /// Call once the window is on screen.
    func didAppear() {
        guard !appeared, !isVisitor else { return }
        appeared = true
        startHoverWatch()
        PetNeighbors.register(windowNumber: windowNumber)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.avoidNeighbors(reason: "screen change", yieldToOlder: true) }
        }
        avoidNeighbors(reason: "launch", yieldToOlder: true)
        // A pet launched at the same moment may not have been on screen yet: look once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.avoidNeighbors(reason: "launch recheck", yieldToOlder: true)
        }
    }
    private var appeared = false

    /// If we overlap another instance's pet, slide horizontally (left first, else right) to the
    /// nearest free spot on this screen, animate there and remember it. With `yieldToOlder`, only
    /// pets that were on screen before us (lower window number) make us move, so two instances
    /// never both dodge at once; after a drag we always move out of the way.
    func avoidNeighbors(reason: String, yieldToOlder: Bool) {
        // Never while running / playing a visit (the visit puts the pet back where it was).
        guard isVisible, !isVisitor, !isRunning, !inputLocked, !DemoRecorder.requested else { return }
        let pets = PetNeighbors.others()
        let obstacles = pets.map { $0.frame.insetBy(dx: -Self.neighborMargin, dy: -Self.neighborMargin) }
        let triggers = pets.filter { !yieldToOlder || $0.windowNumber < windowNumber }
            // A couple of points of slack so a pet that just slid into place (the window server
            // may round the animated frame) isn't nudged again.
            .map { $0.frame.insetBy(dx: -Self.neighborMargin + 2, dy: -Self.neighborMargin + 2) }
        let current = frame
        guard triggers.contains(where: { $0.intersects(current) }) else {
            NSLog("[lulu] pet frame: %@ (%@, %ld other pet(s))", NSStringFromRect(current), reason, pets.count)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(current) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let y = min(max(current.minY, vf.minY), vf.maxY - current.height)
        func free(_ x: CGFloat) -> Bool {
            let r = NSRect(x: x, y: y, width: current.width, height: current.height)
            return x >= vf.minX && r.maxX <= vf.maxX && !obstacles.contains { $0.intersects(r) }
        }
        // Candidate spots hug an obstacle's left or right edge.
        let lefts = obstacles.map { $0.minX - current.width }.filter { $0 <= current.minX && free($0) }
        let rights = obstacles.map { $0.maxX }.filter { $0 >= current.minX && free($0) }
        guard let x = lefts.max() ?? rights.min() else {
            NSLog("[lulu] pet frame: %@ (%@, overlaps but no free spot)", NSStringFromRect(current), reason)
            return
        }
        let target = NSRect(x: x, y: y, width: current.width, height: current.height)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.setFrameOrigin(target.origin)
            self.saveOrigin()
            self.onMoved?()
            NSLog("[lulu] pet frame: %@ (%@, slid away from another pet)", NSStringFromRect(self.frame), reason)
        })
    }

    fileprivate func saveOrigin() {
        defaults?.set(NSStringFromPoint(frame.origin), forKey: Self.originKey)
    }
}

/// Content view: interprets mouse input for the pet window.
/// Draws above its siblings but never takes a click (the pet underneath keeps getting them).
private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PetView: NSView {
    weak var owner: PetWindow?

    private var downScreenPoint: NSPoint = .zero
    private var downOrigin: NSPoint = .zero
    private(set) var dragging = false
    private var pendingClick: DispatchWorkItem?
    private static let dragThreshold: CGFloat = 3

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// v0.8.1 hover watch: a window-level tracking area (fires over the opaque sprite pixels even while
    /// another app is active); the mouse-moved monitors in PetWindow cover the transparent parts.
    func installHoverTracking() {
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { owner?.pointerMoved() }
    override func mouseExited(with event: NSEvent) { owner?.pointerMoved() }
    override func mouseMoved(with event: NSEvent) { owner?.pointerMoved() }

    override func mouseDown(with event: NSEvent) {
        owner?.onInteraction?()
        guard let w = owner, !w.inputLocked else { dragging = false; return }
        downScreenPoint = NSEvent.mouseLocation
        downOrigin = w.frame.origin
        dragging = false
        if event.clickCount >= 2 {
            pendingClick?.cancel()
            pendingClick = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = owner, !w.inputLocked, !w.isVisitor else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - downScreenPoint.x, dy = p.y - downScreenPoint.y
        if !dragging && hypot(dx, dy) < Self.dragThreshold { return }
        if !dragging {
            dragging = true
            pendingClick?.cancel()
            pendingClick = nil
        }
        w.setFrameOrigin(NSPoint(x: downOrigin.x + dx, y: downOrigin.y + dy))
        w.onMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        guard let w = owner, !w.inputLocked else { dragging = false; return }
        if dragging {
            dragging = false
            w.saveOrigin()
            w.onMoved?()
            if w.onDragEnded?(downOrigin) != true {
                w.avoidNeighbors(reason: "drag", yieldToOlder: false)
            }
            return
        }
        if event.clickCount >= 2 {
            w.onCompose?()
        } else if event.clickCount == 1 {
            let item = DispatchWorkItem { [weak w] in w?.onClick?() }
            pendingClick = item
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: item)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.contextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// v0.7 resize handle: a small round grip on the sprite's bottom-right corner, shown on hover.
/// Dragging it up / right grows the pet (aspect locked), down / left shrinks it.
/// The grip is a sublayer image, so `--snapshot` renders it like the sprite.
final class ResizeHandle: NSView {
    enum Corner {
        case topLeft, topRight, bottomLeft, bottomRight
        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }
    static let side: CGFloat = 22
    weak var owner: PetWindow?
    /// ↖↘ on top-left / bottom-right corners, ↙↗ on the other two.
    var corner: Corner = .bottomRight {
        didSet { grip.contents = Self.image(backslash: corner == .topLeft || corner == .bottomRight) }
    }
    private(set) var isResizing = false
    private var downPoint: NSPoint = .zero
    private let grip = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        grip.frame = bounds
        grip.contentsScale = 2
        grip.contents = Self.image(backslash: true)
        grip.shadowOpacity = 0.25
        grip.shadowRadius = 2
        grip.shadowOffset = CGSize(width: 0, height: -1)
        layer?.addSublayer(grip)
        toolTip = "拖动来调整大小"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// White disc, soft orange rim, ↙↗ arrows (the pet grows towards the upper right).
    private static func image(backslash: Bool) -> CGImage? {
        let px = Int(side * 2)
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: 2, y: 2)
        let r = CGRect(x: 2, y: 2, width: side - 4, height: side - 4)
        ctx.setFillColor(NSColor(white: 1, alpha: 0.92).cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.2, alpha: 0.85).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: r)
        // Diagonal double arrow, lower-left ↔ upper-right.
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.3, alpha: 0.9).cgColor)
        ctx.setLineWidth(1.6)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let lo: CGFloat = 7.5, hi = side - 7.5, k: CGFloat = 4
        // backslash: upper-left ↔ lower-right (y up); otherwise lower-left ↔ upper-right.
        let a = backslash ? CGPoint(x: lo, y: hi) : CGPoint(x: lo, y: lo)
        let b = backslash ? CGPoint(x: hi, y: lo) : CGPoint(x: hi, y: hi)
        let sy: CGFloat = backslash ? -1 : 1
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.move(to: CGPoint(x: b.x - k, y: b.y)); ctx.addLine(to: b); ctx.addLine(to: CGPoint(x: b.x, y: b.y - sy * k))
        ctx.move(to: CGPoint(x: a.x + k, y: a.y)); ctx.addLine(to: a); ctx.addLine(to: CGPoint(x: a.x, y: a.y + sy * k))
        ctx.strokePath()
        return ctx.makeImage()
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner, !owner.inputLocked else { return }
        isResizing = true
        downPoint = NSEvent.mouseLocation
        owner.beginResize()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isResizing, let owner else { return }
        let p = NSEvent.mouseLocation
        owner.resizeDragged(by: CGVector(dx: p.x - downPoint.x, dy: p.y - downPoint.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard isResizing, let owner else { return }
        isResizing = false
        let p = NSEvent.mouseLocation
        owner.endResize(by: CGVector(dx: p.x - downPoint.x, dy: p.y - downPoint.y))
    }

    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
}
