import AppKit
import LuluCore

/// v0.10: a button on a text bubble (at most two are shown, bottom-right). Pressing it dismisses the bubble
/// first, then runs `action` (the bubble's `onClose` does NOT run for a button press).
struct BubbleButton {
    var title: String
    var action: () -> Void
}

/// One thing the partner "said".
struct BubbleItem {
    enum Content {
        case text(String)
        /// A sticker GIF with an optional caption line under it (the sticker's name, e.g. "抱抱～").
        case sticker(URL, caption: String? = nil)
        /// v0.4 "你不在的时候…" card: summary lines, an optional preview line and a button.
        case card(lines: [String], preview: String?, button: String)
    }
    var header: String
    var content: Content
    /// The source message, marked read once this bubble is dismissed (nil for local demo items).
    var message: Message?
    /// Dismisses itself this many seconds after it is shown (e.g. a visit's greeting); nil = stays until clicked.
    var autoHide: TimeInterval? = nil
    /// More messages this bubble stands for (a summary card), marked read with it.
    var alsoRead: [Message] = []
    /// A card's button (the bubble is dismissed first).
    var action: (() -> Void)? = nil
    /// v0.10 text bubbles with up to two buttons (「喝了 ✓」「等会儿」…); such a bubble has no「收到 ❤️」.
    var buttons: [BubbleButton] = []
    /// v0.10: the bubble went away without a button press (clicked away, auto-hide, cleared).
    var onClose: (() -> Void)? = nil
    /// v0.12.1: my own pet's bubble (pomodoro, reminders, receipts, upgrade nudge): it points at the home pet even
    /// while TA's visitor is here, so it never reads as if TA said it.
    var atHome = false
    /// prelaunch-B17: runs when this item actually becomes the bubble on screen (not while it waits in the queue).
    var onShown: (() -> Void)? = nil

    /// v0.7.4: text / sticker bubbles that stay until acknowledged get the「收到 ❤️」button.
    var wantsAck: Bool {
        guard autoHide == nil, buttons.isEmpty else { return false }
        if case .card = content { return false }
        return true
    }
}

/// Speech bubble floating above the pet. Items queue up and stay until acknowledged (「收到 ❤️」 or a click).
/// The queue is LuluCore `AckQueue`: only an acknowledged item is handed to `onDismiss` (marked read).
final class BubbleWindow: NSPanel {
    /// Called with the item that was just clicked away.
    var onDismiss: ((BubbleItem) -> Void)?
    /// v0.5: an item became the current bubble (for its sound).
    var onShow: ((BubbleItem) -> Void)?

    private var items = AckQueue<BubbleItem>()
    private var current: BubbleItem? { items.current }
    /// The bubble on screen now (for its anchor).
    var currentItem: BubbleItem? { items.current }
    private var anchor: NSRect = .zero
    private let bubbleView = BubbleView(frame: .zero)
    private var autoHideWork: DispatchWorkItem?
    /// v0.4: while the pet is hidden the bubble stays off screen; its queue is kept for later.
    private(set) var isSuspended = false

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)   // our panels are drawn light (cream / orange); keep them light in Dark Mode
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        setLuluLevel(.floating)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = bubbleView
        bubbleView.onClick = { [weak self] in self?.dismissCurrent() }
        bubbleView.onButton = { [weak self] in self?.pressButton() }
        bubbleView.onAck = { [weak self] in self?.pressAck() }
        bubbleView.onToolButton = { [weak self] i in self?.pressToolButton(i) }
    }

    /// v0.10: button `index` of the current bubble: dismiss it, then run the button's action.
    func pressToolButton(_ index: Int) {
        guard let c = current, c.buttons.indices.contains(index) else { return }
        let action = c.buttons[index].action
        dismissCurrent(viaButton: true)
        action()
    }

    /// v0.7.4「收到 ❤️」: acknowledges the current text / sticker bubble (same as clicking it; also the hidden
    /// `--demo-ack` flag).
    func pressAck() {
        guard let c = current, c.wantsAck else { return }
        NSLog("[lulu] bubble: 收到 pressed (%@)", debugDescription_)
        dismissCurrent()
    }

    /// v0.7.4: the visitor's time is up. Every bubble stays (same order, still unread) and now reads
    /// "TA 留下的话" (text / sticker; cards and auto-hiding greetings keep theirs). Returns how many are waiting.
    @discardableResult
    func leaveAllForHost() -> Int {
        items.leaveAll { item in
            if item.wantsAck { item.header = Visits.pinnedHeader }
        }
        if current != nil {
            bubbleView.configure(current!, pending: items.waiting.count)
            relayout()
        }
        return items.count
    }

    /// A card's button: dismiss, then run its action (also the hidden `--demo-press-card` flag).
    func pressButton() {
        guard let action = current?.action else { return }
        dismissCurrent()
        action()
    }

    /// Hides the bubble (and pauses its auto-hide) without losing anything queued.
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        autoHideWork?.cancel()
        autoHideWork = nil
        orderOut(nil)
    }

    /// Shows the current bubble again after `suspend()`.
    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        if current != nil { render() }
    }

    /// For logs: "card(4 lines) +2".
    var debugDescription_: String {
        guard let c = current else { return "none" }
        let kind: String
        switch c.content {
        case .text: kind = "text"
        case .sticker: kind = "sticker"
        case .card(let lines, _, _): kind = "card(\(lines.count) lines)"
        }
        return "\(kind) +\(items.waiting.count)"
    }

    override var canBecomeKey: Bool { false }

    var isShowingSomething: Bool { current != nil }
    /// prelaunch-B11: a bubble is actually on screen (not just held in the queue while the pet is hidden / 勿扰).
    var isOnScreen: Bool { current != nil && !isSuspended }

    /// v0.12.1: enqueue one of my own pet's bubbles (anchored at the home pet, see `BubbleItem.atHome`).
    func enqueueAtHome(_ item: BubbleItem) {
        var item = item
        item.atHome = true
        enqueue(item)
    }

    func enqueue(_ item: BubbleItem) {
        if items.enqueue(item) {
            render()
            onShow?(item)
            item.onShown?()
        } else {
            bubbleView.setPendingCount(items.waiting.count)
            relayout()
        }
    }

    /// `anchor` is the pet sprite's rect in screen coordinates.
    func follow(_ anchor: NSRect) {
        self.anchor = anchor
        if current != nil { position(fresh: false) }
    }

    func clearAll() {
        autoHideWork?.cancel()
        autoHideWork = nil
        let dropped = items.all
        items.removeAll()
        orderOut(nil)
        dropped.forEach { $0.onClose?() }
    }

    /// Same as clicking the bubble (also used by the hidden `--demo-dismiss-bubble` flag).
    func dismissCurrent(viaButton: Bool = false) {
        autoHideWork?.cancel()
        autoHideWork = nil
        guard let done = items.acknowledge() else { return }
        if !viaButton { done.onClose?() }
        onDismiss?(done)
        if let next = current {
            render()
            onShow?(next)
            next.onShown?()
        } else {
            orderOut(nil)
        }
    }

    private func render() {
        guard let item = current else { return }
        bubbleView.configure(item, pending: items.waiting.count)
        relayout()
        guard !isSuspended else { return }
        orderFrontRegardless()
        autoHideWork?.cancel()
        autoHideWork = nil
        if let seconds = item.autoHide {
            let work = DispatchWorkItem { [weak self] in self?.dismissCurrent() }
            autoHideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private func relayout() {
        setContentSize(bubbleView.fittingBubbleSize)
        position()
    }

    /// `fresh: false` (following a drag) may reuse a recent look-up of the other pets.
    private func position(fresh: Bool = true) {
        let size = frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY - 4
        var below = false
        if y + size.height > vf.maxY {
            below = true
            y = anchor.minY - size.height + 4
        }
        x = min(max(x, vf.minX + 4), vf.maxX - size.width - 4)
        y = max(y, vf.minY)
        // Don't cover another instance's pet: slide sideways (the tail must still reach our pet).
        let sprites = PetNeighbors.others(maxAge: fresh ? 0 : 1).map(\.spriteFrame)
        let tailMin: CGFloat = anchor.midX - 30, tailMax: CGFloat = anchor.midX + 30, x0 = x, y0 = y
        var xs: [CGFloat] = []
        for s in sprites { xs.append(s.maxX + 4); xs.append(s.minX - size.width - 4) }
        xs = xs.filter { (c: CGFloat) -> Bool in c <= tailMin && c + size.width >= tailMax }
        xs.sort { (a: CGFloat, b: CGFloat) -> Bool in abs(a - x0) < abs(b - x0) }
        let candidates: [NSPoint] = ([x0] + xs).map { NSPoint(x: $0, y: y0) }
        let p = PetNeighbors.bestOrigin(candidates, size: size, in: vf, margin: 0, avoiding: sprites)
        x = p.x
        y = p.y
        bubbleView.tailOnTop = below
        // Keep the tail pointing at the pet even when the bubble is clamped sideways.
        bubbleView.tailX = min(max(anchor.midX - x, 30), size.width - 30)
        bubbleView.needsDisplay = true
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Draws the rounded white bubble with a tail and lays out header / content / footer.
private final class BubbleView: NSView {
    var onClick: (() -> Void)?
    var onButton: (() -> Void)?
    var onAck: (() -> Void)?
    /// v0.10: index of the pressed tool button.
    var onToolButton: ((Int) -> Void)?
    var tailOnTop = false { didSet { needsLayout = true } }
    var tailX: CGFloat = 0

    /// Most lines a text bubble shows: about 60 % of the main screen's height (at least 6).
    static var maxTextLines: Int {
        let h = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 800
        return max(6, Int((h * 0.6) / 18))
    }

    private static let pad: CGFloat = 12          // inner padding
    private static let margin: CGFloat = 10       // room for the shadow
    private static let tail: CGFloat = 10
    private static let radius: CGFloat = 16
    private static let accent = NSColor(calibratedRed: 0.91, green: 0.54, blue: 0.29, alpha: 1)

    private let header = NSTextField(labelWithString: "")
    private let footer = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let gifView = NSImageView()
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let button = PillButton()
    /// v0.7.4「收到 ❤️」(text / sticker bubbles), bottom-right, beside the "还有 n 条" footer.
    private let ackButton = PillButton(small: true)
    private var hasAck = false
    /// v0.10: up to two small buttons in the bottom row (right-aligned, like「收到 ❤️」, which they replace).
    private let toolButtons = [PillButton(small: true), PillButton(small: true)]
    private var toolButtonCount = 0
    private static let ackGap: CGFloat = 8
    private var contentSize: NSSize = .zero
    private var isSticker = false
    private var gifHeight: CGFloat = 0
    private var captionHeight: CGFloat = 0
    private static let captionGap: CGFloat = 4
    private var isCard = false
    private static let cardGap: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        header.font = Effects.roundedFont(12, weight: .bold)
        header.textColor = Self.accent
        footer.font = Effects.roundedFont(10, weight: .medium)
        footer.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        footer.alignment = .right
        textLabel.font = Effects.roundedFont(14, weight: .regular)
        textLabel.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
        textLabel.isSelectable = false
        textLabel.preferredMaxLayoutWidth = 240
        gifView.animates = true
        gifView.imageScaling = .scaleProportionallyUpOrDown
        gifView.wantsLayer = true
        gifView.layer?.cornerRadius = 10
        gifView.layer?.masksToBounds = true
        previewLabel.font = Effects.roundedFont(12, weight: .regular)
        previewLabel.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        previewLabel.isSelectable = false
        previewLabel.maximumNumberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        button.onClick = { [weak self] in self?.onButton?() }
        ackButton.title = Visits.ackTitle
        ackButton.onClick = { [weak self] in self?.onAck?() }
        for (i, b) in toolButtons.enumerated() {
            b.isHidden = true
            b.onClick = { [weak self] in self?.onToolButton?(i) }
        }
        ([header, footer, textLabel, gifView, previewLabel, button, ackButton] + toolButtons).forEach { addSubview($0) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        let p = convert(point, from: superview)
        if isCard, !button.isHidden, button.frame.contains(p) { return button }
        if hasAck, ackButton.frame.insetBy(dx: -3, dy: -3).contains(p) { return ackButton }
        for b in toolButtons.prefix(toolButtonCount) where b.frame.insetBy(dx: -3, dy: -3).contains(p) { return b }
        return self
    }

    func configure(_ item: BubbleItem, pending: Int) {
        header.stringValue = item.header
        isCard = false
        previewLabel.isHidden = true
        button.isHidden = true
        hasAck = item.wantsAck
        ackButton.isHidden = !hasAck
        toolButtonCount = min(toolButtons.count, item.buttons.count)
        for (i, b) in toolButtons.enumerated() {
            b.isHidden = i >= toolButtonCount
            if i < toolButtonCount { b.title = item.buttons[i].title }
        }
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        switch item.content {
        case .card(let lines, let preview, let title):
            isSticker = false; textLabel.alignment = .natural
            isCard = true
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 3
            textLabel.attributedStringValue = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                .font: Effects.roundedFont(14, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.22, alpha: 1),
                .paragraphStyle: para,
            ])
            textLabel.isHidden = false
            gifView.isHidden = true
            gifView.image = nil
            var fit = textLabel.sizeThatFits(NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
            fit.width = max(fit.width, header.intrinsicContentSize.width)
            linesHeight = ceil(fit.height)
            var h = linesHeight
            if let preview {
                previewLabel.stringValue = "“\(preview)”"
                previewLabel.isHidden = false
                previewHeight = ceil(previewLabel.intrinsicContentSize.height)
                h += 4 + previewHeight
                fit.width = max(fit.width, min(240, previewLabel.intrinsicContentSize.width))
            } else {
                previewHeight = 0
            }
            button.title = title
            button.isHidden = false
            h += Self.cardGap + PillButton.height
            contentSize = NSSize(width: min(240, max(ceil(fit.width), 150)), height: h)
        case .text(let s):
            isSticker = false
            textLabel.alignment = .natural
            textLabel.font = Effects.roundedFont(14, weight: .regular)
            textLabel.textColor = NSColor(calibratedWhite: 0.18, alpha: 1)
            // prelaunch: a very long message must not make the bubble taller than the screen: cap the lines
            // (the rest ends in 「…」; the full text is in the history).
            let maxLines = Self.maxTextLines
            textLabel.maximumNumberOfLines = maxLines
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.stringValue = s
            textLabel.isHidden = false
            gifView.isHidden = true
            gifView.image = nil
            let fit = textLabel.sizeThatFits(NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
            let lineH = ceil(textLabel.font?.boundingRectForFont.height ?? 18)
            contentSize = NSSize(width: min(240, ceil(fit.width)), height: min(ceil(fit.height), lineH * CGFloat(maxLines)))
        case .sticker(let url, let caption):
            isSticker = true
            let img = NSImage(contentsOf: url)
            gifView.image = img
            gifView.isHidden = false
            let w: CGFloat = 180
            let ratio = img.map { $0.size.width > 0 ? $0.size.height / $0.size.width : 1 } ?? 1
            gifHeight = round(w * ratio)
            captionHeight = 0
            if let caption, !caption.isEmpty {
                textLabel.font = Effects.roundedFont(15, weight: .semibold)
                textLabel.textColor = NSColor(calibratedRed: 0.86, green: 0.47, blue: 0.2, alpha: 1)
                textLabel.alignment = .center
                textLabel.stringValue = caption
                textLabel.isHidden = false
                captionHeight = ceil(textLabel.sizeThatFits(NSSize(width: w, height: .greatestFiniteMagnitude)).height)
            } else {
                textLabel.isHidden = true
            }
            contentSize = NSSize(width: w, height: gifHeight + (captionHeight > 0 ? Self.captionGap + captionHeight : 0))
        }
        setPendingCount(pending)
    }

    func setPendingCount(_ n: Int) {
        footer.stringValue = n > 0 ? "（还有 \(n) 条）" : ""
        footer.isHidden = n == 0
        footer.alignment = hasButtonRow ? .left : .right   // with buttons: footer on the left, buttons on the right
        needsLayout = true
    }

    private var linesHeight: CGFloat = 0
    private var previewHeight: CGFloat = 0

    private var headerHeight: CGFloat { ceil(header.intrinsicContentSize.height) }
    private var footerHeight: CGFloat { footer.isHidden ? 0 : ceil(footer.intrinsicContentSize.height) + 2 }
    private var footerWidth: CGFloat { footer.isHidden ? 0 : ceil(footer.intrinsicContentSize.width) }
    /// 收到 or the v0.10 tool buttons share the bottom row (right-aligned).
    private var hasButtonRow: Bool { hasAck || toolButtonCount > 0 }
    private var rowButtons: [PillButton] { hasAck ? [ackButton] : Array(toolButtons.prefix(toolButtonCount)) }
    private var rowButtonsWidth: CGFloat { rowButtons.map(\.fittingWidth).reduce(0, +) + CGFloat(max(0, rowButtons.count - 1)) * 6 }
    /// The bottom row: the buttons (and the footer beside them), or the footer alone.
    private var bottomHeight: CGFloat { hasButtonRow ? Self.ackGap + PillButton.smallHeight : footerHeight }

    var fittingBubbleSize: NSSize {
        let bottomW = hasButtonRow ? (footer.isHidden ? 0 : footerWidth + 8) + rowButtonsWidth : footerWidth
        let innerW = max(contentSize.width, header.intrinsicContentSize.width, bottomW, 60)
        let innerH = headerHeight + 6 + contentSize.height + bottomHeight
        return NSSize(width: ceil(innerW) + Self.pad * 2 + Self.margin * 2,
                      height: ceil(innerH) + Self.pad * 2 + Self.margin * 2 + Self.tail)
    }

    /// The rounded body rect (excluding tail and shadow margin).
    private var bodyRect: NSRect {
        var r = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        r.size.height -= Self.tail
        if !tailOnTop { r.origin.y += Self.tail }
        return r
    }

    override func layout() {
        super.layout()
        let body = bodyRect.insetBy(dx: Self.pad, dy: Self.pad)
        var y = body.maxY - headerHeight
        header.frame = NSRect(x: body.minX, y: y, width: body.width, height: headerHeight)
        y -= 6 + contentSize.height
        let contentFrame = NSRect(x: body.minX, y: y, width: body.width, height: contentSize.height)
        if isCard {
            textLabel.frame = NSRect(x: body.minX, y: contentFrame.maxY - linesHeight, width: body.width, height: linesHeight)
            previewLabel.frame = NSRect(x: body.minX, y: textLabel.frame.minY - 4 - previewHeight, width: body.width, height: previewHeight)
            let bw = button.fittingWidth
            button.frame = NSRect(x: body.maxX - bw, y: contentFrame.minY, width: bw, height: PillButton.height)
        } else if isSticker {
            gifView.frame = NSRect(x: body.midX - contentSize.width / 2, y: contentFrame.maxY - gifHeight, width: contentSize.width, height: gifHeight)
            if captionHeight > 0 {
                textLabel.frame = NSRect(x: body.minX, y: contentFrame.minY, width: body.width, height: captionHeight)
            }
        } else {
            textLabel.frame = contentFrame
        }
        if hasButtonRow {
            var x = body.maxX
            for b in rowButtons.reversed() {
                let bw = b.fittingWidth
                x -= bw
                b.frame = NSRect(x: x, y: body.minY, width: bw, height: PillButton.smallHeight)
                x -= 6
            }
            let fh = max(0, footerHeight - 2)
            footer.frame = NSRect(x: body.minX, y: body.minY + (PillButton.smallHeight - fh) / 2,
                                  width: max(0, x - body.minX - 2), height: fh)
        } else {
            footer.frame = NSRect(x: body.minX, y: body.minY, width: body.width, height: max(0, footerHeight - 2))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bodyRect
        let path = NSBezierPath(roundedRect: body, xRadius: Self.radius, yRadius: Self.radius)
        let tx = min(max(tailX, body.minX + Self.radius + 8), body.maxX - Self.radius - 8)
        let tail = NSBezierPath()
        if tailOnTop {
            tail.move(to: NSPoint(x: tx - 9, y: body.maxY - 1))
            tail.curve(to: NSPoint(x: tx + 2, y: body.maxY + Self.tail), controlPoint1: NSPoint(x: tx - 3, y: body.maxY + 2), controlPoint2: NSPoint(x: tx, y: body.maxY + Self.tail - 3))
            tail.curve(to: NSPoint(x: tx + 9, y: body.maxY - 1), controlPoint1: NSPoint(x: tx + 4, y: body.maxY + 4), controlPoint2: NSPoint(x: tx + 6, y: body.maxY))
        } else {
            tail.move(to: NSPoint(x: tx - 9, y: body.minY + 1))
            tail.curve(to: NSPoint(x: tx + 2, y: body.minY - Self.tail), controlPoint1: NSPoint(x: tx - 3, y: body.minY - 2), controlPoint2: NSPoint(x: tx, y: body.minY - Self.tail + 3))
            tail.curve(to: NSPoint(x: tx + 9, y: body.minY + 1), controlPoint1: NSPoint(x: tx + 4, y: body.minY - 4), controlPoint2: NSPoint(x: tx + 6, y: body.minY))
        }
        tail.close()
        path.append(tail)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        Self.accent.withAlphaComponent(0.25).setStroke()
        let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// Small filled capsule button used inside a bubble card (the bubble panel never becomes key, so this
/// reacts on mouse-up itself).
private final class PillButton: NSView {
    static let height: CGFloat = 26
    /// v0.7.4 the small「收到 ❤️」pill.
    static let smallHeight: CGFloat = 22
    private let small: Bool
    var onClick: (() -> Void)?
    var title = "" { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    private static let accent = NSColor(calibratedRed: 0.91, green: 0.54, blue: 0.29, alpha: 1)
    private var attributed: NSAttributedString {
        NSAttributedString(string: title, attributes: [.font: Effects.roundedFont(small ? 11.5 : 13, weight: .semibold),
                                                       .foregroundColor: NSColor.white])
    }
    var fittingWidth: CGFloat { ceil(attributed.size().width) + (small ? 20 : 30) }

    init(small: Bool = false) {
        self.small = small
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        (pressed ? Self.accent.blended(withFraction: 0.2, of: .black) ?? Self.accent : Self.accent).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        let a = attributed, size = a.size()
        a.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
