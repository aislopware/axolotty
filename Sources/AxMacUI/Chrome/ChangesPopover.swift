import AppKit
import AxModel

/// The band's diff chip: "+412 −96" in 11 pt tabular green and red, on a
/// hover plate. Hidden when the tree is clean or not a repository. Click (or
/// ⌘⇧D) opens the Changes popover.
final class DiffChip: NSControl {
    private let plus = Label("", font: Axo.Font.meta, color: Axo.Color.status(.done))
    private let minus = Label("", font: Axo.Font.meta, color: Axo.Color.status(.error))
    private let plate = CALayer()
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.cornerRadius = Axo.Radius.sm
        plate.cornerCurve = .continuous
        plate.opacity = 0
        plate.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(plate)
        addSubview(plus)
        addSubview(minus)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Changes  ⇧⌘C"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func set(_ c: GitChanges?) {
        guard let c, !c.isEmpty else {
            isHidden = true
            return
        }
        isHidden = false
        plus.stringValue = "+\(c.added)"
        minus.stringValue = "−\(c.removed)"
        let files = c.files.count == 1 ? "1 file" : "\(c.files.count) files"
        setAccessibilityLabel("\(files) changed, \(c.added) lines added, \(c.removed) removed")
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: 6 + ceil(plus.intrinsicContentSize.width) + 4 + ceil(minus.intrinsicContentSize.width) + 6, height: 20)
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        let p = plus.intrinsicContentSize, m = minus.intrinsicContentSize
        plus.frame = NSRect(x: 6, y: (mid - p.height / 2).rounded(), width: ceil(p.width), height: p.height)
        minus.frame = NSRect(x: plus.frame.maxX + 4, y: (mid - m.height / 2).rounded(), width: ceil(m.width), height: m.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        plate.backgroundColor = effectiveAppearance.resolve(Axo.Color.hover)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { plate.opacity = 1 }
    override func mouseExited(with event: NSEvent) { plate.opacity = 0 }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The Changes popover (design-system §5): what the agents changed, without a
/// diff engine or an inspector column.
///
/// - Surface: opaque float, radius 12, padding 6, 380 wide, at most 420 tall;
///   6 pt below the chip with the palette's motion.
/// - Header 34: branch 13 semibold, "vs HEAD" 12 tertiary, totals trailing.
/// - Rows 28 (radius-6 hover plates): a kind glyph, the file name 13, its
///   folder 12 tertiary (middle-truncated), "+n −m" trailing.
/// - Click opens the file in its default app. ⌥-click shows `git diff` for it
///   in a new split to the right (the person's pager and `delta` apply).
/// - Footer: "Review Changes" starts the first installed agent in a new
///   session with a review prompt.
/// - Esc or a click outside closes it.
final class ChangesPopover: Surface {
    struct Actions {
        var open: (String) -> Void
        var diff: (String) -> Void
        var review: (() -> Void)?
    }

    private static let pad: CGFloat = 6, rowH: CGFloat = 28, headerH: CGFloat = 34, footerH: CGFloat = 34, width: CGFloat = 380

    private let changes: GitChanges
    private let actions: Actions
    private let branch = Label("", font: Axo.Font.title, color: Axo.Color.text)
    private let versus = Label("vs HEAD", font: Axo.Font.small, color: Axo.Color.textTertiary)
    private let totals = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    private let scroll = NSScrollView()
    private let list = FlippedView()
    private var rows: [ChangeRow] = []
    private let review = Button("Review Changes", symbol: "sparkles", variant: .ghost, size: .small)
    private let rule = CALayer()
    private weak var host: OverlayHostView?
    private var keyMonitor: Any?

    nonisolated(unsafe) private static weak var current: ChangesPopover?

    static var isOpen: Bool { current != nil }

    static func toggle(_ changes: GitChanges, branch: String?, from anchor: NSView, actions: Actions) {
        if let c = current {
            c.close()
            return
        }
        guard let wc = anchor.window?.windowController as? MainWindowController else { return }
        let p = ChangesPopover(changes, branch: branch, actions: actions)
        p.present(in: wc.shell.overlay, anchor: anchor)
    }

    private init(_ changes: GitChanges, branch name: String?, actions: Actions) {
        self.changes = changes
        self.actions = actions
        super.init(elevation: .float, radius: 12)
        branch.stringValue = name ?? URL(filePath: changes.root).lastPathComponent
        branch.lineBreakMode = .byTruncatingTail
        let files = changes.files.count == 1 ? "1 file" : "\(changes.files.count) files"
        totals.stringValue = "\(files)  +\(changes.added) −\(changes.removed)"
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        for f in changes.files {
            let r = ChangeRow(f)
            r.onPick = { [weak self] alt in self?.pick(f.path, alt: alt) }
            list.addSubview(r)
            rows.append(r)
        }
        review.target = self
        review.action = #selector(reviewClicked)
        review.isHidden = actions.review == nil
        content.wantsLayer = true
        rule.actions = ["bounds": NSNull(), "position": NSNull()]
        content.layer?.addSublayer(rule)
        for v in [branch, versus, totals, scroll, review] as [NSView] { content.addSubview(v) }
        setAccessibilityRole(.popover)
        setAccessibilityLabel("Changes")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var listHeight: CGFloat { CGFloat(rows.count) * Self.rowH }

    private func present(in overlay: OverlayHostView, anchor: NSView) {
        host = overlay
        Tooltip.shared.suppressed = true
        let footer = review.isHidden ? 0 : Self.footerH
        let h = min(420, Self.pad * 2 + Self.headerH + listHeight + footer)
        let a = overlay.convert(anchor.bounds, from: anchor)
        let x = min(max(8, a.maxX - Self.width), overlay.bounds.width - Self.width - 8)
        frame = NSRect(x: x.rounded(), y: (a.maxY + 6).rounded(), width: Self.width, height: h)
        overlay.addSubview(self)
        overlay.capturesOutsideClicks = true
        overlay.onOutsideClick = { [weak self] in self?.close() }
        Self.current = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            if e.keyCode == 53 {
                self.close()
                return nil
            }
            if !e.modifierFlags.intersection([.command, .control, .option]).isEmpty { self.close() }
            return e
        }
        alphaValue = 0
        layoutSubtreeIfNeeded()
        Axo.Motion.run(Axo.Motion.Beat(duration: 0.16, curve: Axo.Motion.easeOut)) { animator().alphaValue = 1 }
    }

    func close() {
        guard superview != nil else { return }
        if let host {
            host.capturesOutsideClicks = false
            host.onOutsideClick = nil
        }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if Self.current === self {
            Self.current = nil
            Tooltip.shared.suppressed = false
        }
        Axo.Motion.run(Axo.Motion.tickOut, { animator().alphaValue = 0 }) { [weak self] in self?.removeFromSuperview() }
    }

    private func pick(_ path: String, alt: Bool) {
        close()
        let full = URL(filePath: changes.root).appending(path: path).path(percentEncoded: false)
        if alt { actions.diff(path) } else { actions.open(full) }
    }

    @objc private func reviewClicked() {
        close()
        actions.review?()
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let p = Self.pad
        let inner = bounds.width - p * 2
        let hmid = p + Self.headerH / 2
        let ts = totals.intrinsicContentSize
        totals.frame = NSRect(x: bounds.width - p - 10 - ceil(ts.width), y: (hmid - ts.height / 2).rounded(), width: ceil(ts.width), height: ts.height)
        let bs = branch.intrinsicContentSize, vs = versus.intrinsicContentSize
        let bw = min(ceil(bs.width), totals.frame.minX - 12 - (p + 10) - ceil(vs.width) - 6)
        branch.frame = NSRect(x: p + 10, y: (hmid - bs.height / 2).rounded(), width: max(0, bw), height: bs.height)
        versus.frame = NSRect(x: branch.frame.maxX + 6, y: (hmid - vs.height / 2).rounded() + 1, width: ceil(vs.width), height: vs.height)
        let footer = review.isHidden ? 0 : Self.footerH
        let listTop = p + Self.headerH
        scroll.frame = NSRect(x: p, y: listTop, width: inner, height: max(0, bounds.height - listTop - p - footer))
        list.frame = NSRect(x: 0, y: 0, width: inner, height: listHeight)
        for (i, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: CGFloat(i) * Self.rowH, width: inner, height: Self.rowH)
        }
        if !review.isHidden {
            let rs = review.intrinsicContentSize
            let fy = bounds.height - p - footer
            review.frame = NSRect(x: p + 4, y: (fy + (footer - rs.height) / 2).rounded(), width: rs.width, height: rs.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rule.frame = CGRect(x: p + 8, y: fy, width: inner - 16, height: hairline)
            rule.backgroundColor = effectiveAppearance.resolve(Axo.Color.borderSubtle)
            CATransaction.commit()
        }
    }
}

/// One changed file.
private final class ChangeRow: NSView {
    var onPick: ((Bool) -> Void)?
    private let glyph = Symbol("doc", size: 11, weight: .medium, color: Axo.Color.textTertiary)
    private let name = Label("", font: Axo.Font.body, color: Axo.Color.text)
    private let folder = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    private let plus = Label("", font: Axo.Font.meta, color: Axo.Color.status(.done))
    private let minus = Label("", font: Axo.Font.meta, color: Axo.Color.status(.error))
    private let plate = CALayer()

    init(_ f: GitChanges.File) {
        super.init(frame: .zero)
        wantsLayer = true
        plate.cornerRadius = 6
        plate.cornerCurve = .continuous
        plate.opacity = 0
        plate.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(plate)
        let url = URL(filePath: f.path)
        name.stringValue = url.lastPathComponent
        let dir = url.deletingLastPathComponent().relativePath
        folder.stringValue = dir == "." ? "" : dir
        folder.lineBreakMode = .byTruncatingMiddle
        name.lineBreakMode = .byTruncatingMiddle
        let symbol = switch f.kind {
        case .added, .untracked: "doc.badge.plus"
        case .deleted: "minus.circle"
        case .renamed: "arrow.right.doc.on.clipboard"
        case .modified: "doc"
        }
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if f.kind == .deleted { name.textColor = Axo.Color.textTertiary }
        if f.binary {
            plus.stringValue = "binary"
            plus.textColor = Axo.Color.textTertiary
            minus.stringValue = ""
        } else {
            plus.stringValue = f.added > 0 ? "+\(f.added)" : ""
            minus.stringValue = f.removed > 0 ? "−\(f.removed)" : ""
        }
        for l in [plus, minus] { l.alphaValue = 0.85 }
        for v in [glyph, name, folder, plus, minus] as [NSView] { addSubview(v) }
        toolTip = f.path + "\nClick to open · ⌥-click for the diff"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(f.path), \(f.added) added, \(f.removed) removed")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        plate.backgroundColor = effectiveAppearance.resolve(Axo.Color.hover)
        CATransaction.commit()
        let mid = bounds.height / 2
        glyph.frame = NSRect(x: 8, y: (mid - 8).rounded(), width: 16, height: 16)
        var right = bounds.width - 10
        for l in [minus, plus] where !l.stringValue.isEmpty {
            let s = l.intrinsicContentSize
            l.frame = NSRect(x: right - ceil(s.width), y: (mid - s.height / 2).rounded(), width: ceil(s.width), height: s.height)
            right = l.frame.minX - 4
        }
        right -= 8
        let x = glyph.frame.maxX + 8
        let ns = name.intrinsicContentSize
        let nw = min(ceil(ns.width), max(60, (right - x) * 0.6))
        name.frame = NSRect(x: x, y: (mid - ns.height / 2).rounded(), width: nw, height: ns.height)
        let fs = folder.intrinsicContentSize
        let fx = name.frame.maxX + 6
        folder.frame = NSRect(x: fx, y: (mid - fs.height / 2).rounded() + 1, width: max(0, min(ceil(fs.width), right - fx)), height: fs.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { plate.opacity = 1 }
    override func mouseExited(with event: NSEvent) { plate.opacity = 0 }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPick?(event.modifierFlags.contains(.option))
    }
    override func mouseDown(with event: NSEvent) {}
}
