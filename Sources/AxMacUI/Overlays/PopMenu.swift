import AppKit

/// Axolotty's own pop-up menu: an opaque float surface in the window's
/// overlay layer, replacing NSMenu where we choose the look (the system menu
/// is translucent glass on macOS 26+, and the design system has none).
///
/// Geometry follows the palette's concentric rule: radius 14, padding 6, so
/// row plates are radius 8. Rows are 28: a 16 pt image, the title in 13, and
/// a trailing key (1–9, tabular, tertiary) or a check. Separators are a
/// 1 px `borderSubtle` line with 4 above and below.
///
/// Keyboard: ↑↓ move, return picks, 1–9 pick directly, esc closes. Keys are
/// read by a local monitor while the menu is open, so they reach it whoever
/// holds focus (the click that opened it often hands focus back to a pane),
/// and focus is never moved.
/// Motion: the palette's (160 ms from 98 %, 4 pt rise); out on the tick.
final class PopMenu: Surface {
    struct Item {
        var title: String
        var image: NSImage?
        /// Tint for template images (nil: secondary ink).
        var tint: NSColor?
        var key: String?
        var checked = false
        var run: () -> Void
    }

    enum Align { case leading, trailing }

    /// Opens below `anchor` (or above, when there is no room), with the
    /// anchor's leading or trailing edge (a button at a column's end opens
    /// back into the column).
    @discardableResult
    static func show(_ items: [Item?], from anchor: NSView, align: Align = .leading) -> PopMenu? {
        guard let window = anchor.window, let wc = window.windowController as? MainWindowController else { return nil }
        current?.close()
        let menu = PopMenu(items: items)
        menu.present(in: wc.shell.overlay, anchor: anchor, align: align)
        return menu
    }

    nonisolated(unsafe) private static weak var current: PopMenu?

    private let items: [Item?]
    private var rows: [Row] = []
    private var separators: [CALayer] = []
    var highlighted: Int? { didSet { if highlighted != oldValue { restyleRows() } } }
    private weak var host: OverlayHostView?
    private var keyMonitor: Any?

    private static let pad: CGFloat = 6
    private static let rowH: CGFloat = 28
    private static let sepH: CGFloat = 9

    init(items: [Item?]) {
        self.items = items
        super.init(elevation: .float, radius: 14)
        for item in items {
            if let item {
                let r = Row(item)
                content.addSubview(r)
                rows.append(r)
            } else {
                let l = CALayer()
                l.actions = ["bounds": NSNull(), "position": NSNull()]
                content.wantsLayer = true
                content.layer?.addSublayer(l)
                separators.append(l)
            }
        }
        setAccessibilityRole(.menu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredSize: NSSize {
        let widest = rows.map(\.fittingWidth).max() ?? 120
        let h = CGFloat(rows.count) * Self.rowH + CGFloat(separators.count) * Self.sepH + Self.pad * 2
        return NSSize(width: max(180, ceil(widest) + Self.pad * 2), height: h)
    }

    private func present(in overlay: OverlayHostView, anchor: NSView, align: Align) {
        guard let window = overlay.window else { return }
        host = overlay
        Tooltip.shared.suppressed = true
        let size = preferredSize
        let a = overlay.convert(anchor.bounds, from: anchor)
        var y = a.maxY + 4
        if y + size.height > overlay.bounds.height - 8 { y = max(8, a.minY - 4 - size.height) }
        let want = align == .leading ? a.minX : a.maxX - size.width
        let x = min(max(8, want), overlay.bounds.width - size.width - 8)
        frame = NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
        overlay.addSubview(self)
        overlay.capturesOutsideClicks = true
        overlay.onOutsideClick = { [weak self] in self?.close() }
        Self.current = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === window else { return e }
            return self.handle(e) ? nil : e
        }
        animateIn()
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

    private func pick(_ i: Int) {
        guard i >= 0, i < rows.count else { return }
        let run = rows[i].item.run
        close()
        run()
    }

    private func animateIn() {
        layoutSubtreeIfNeeded()
        Axo.Motion.rise(self, anchorX: layer?.bounds.minX ?? 0)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        content.frame = bounds
        var y = Self.pad
        var r = 0, s = 0
        for item in items {
            if item != nil {
                rows[r].frame = NSRect(x: Self.pad, y: y, width: bounds.width - Self.pad * 2, height: Self.rowH)
                r += 1
                y += Self.rowH
            } else {
                let l = separators[s]
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                l.frame = CGRect(x: Self.pad + 8, y: y + 4, width: bounds.width - (Self.pad + 8) * 2, height: hairline)
                l.backgroundColor = effectiveAppearance.resolve(Axo.Color.borderSubtle)
                CATransaction.commit()
                s += 1
                y += Self.sepH
            }
        }
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func row(at event: NSEvent) -> Int? {
        let p = content.convert(event.locationInWindow, from: nil)
        return rows.firstIndex { $0.frame.contains(p) }
    }

    override func mouseMoved(with event: NSEvent) { highlighted = row(at: event) }
    override func mouseExited(with event: NSEvent) { highlighted = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if let i = row(at: event) { pick(i) }
    }

    // MARK: Keyboard

    /// True when the menu used the key. Anything with ⌘/⌃/⌥ closes the menu
    /// and passes on (a shortcut means the person moved on).
    private func handle(_ event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            close()
            return false
        }
        switch event.keyCode {
        case 53: close()  // esc
        case 125: highlighted = min(rows.count - 1, (highlighted ?? -1) + 1)  // ↓
        case 126: highlighted = max(0, (highlighted ?? rows.count) - 1)  // ↑
        case 36, 76: if let h = highlighted { pick(h) }  // return, enter
        default:
            if let c = event.charactersIgnoringModifiers, let i = rows.firstIndex(where: { $0.item.key == c }) {
                pick(i)
            }
        }
        return true
    }

    private func restyleRows() {
        for (i, r) in rows.enumerated() { r.highlighted = i == highlighted }
    }
}

/// One menu row: plate, image, title, trailing key or check.
private final class Row: NSView {
    let item: PopMenu.Item
    private let plate = CALayer()
    private let image = NSImageView()
    private let title = Label("", font: Axo.Font.body, color: Axo.Color.text)
    private let key = Label("", font: Axo.Font.shortcut, color: Axo.Color.textTertiary)
    private let check = Symbol("checkmark", size: 11, weight: .semibold, color: Axo.Color.textSecondary)
    var highlighted = false { didSet { restyle() } }

    init(_ item: PopMenu.Item) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        plate.cornerRadius = 8
        plate.cornerCurve = .continuous
        plate.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(plate)
        image.image = item.image
        image.imageScaling = .scaleNone
        image.contentTintColor = item.tint ?? Axo.Color.textSecondary
        title.stringValue = item.title
        key.stringValue = item.key ?? ""
        key.isHidden = item.key == nil
        check.isHidden = !item.checked
        for v in [image, title, key, check] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(item.title)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var fittingWidth: CGFloat {
        let lead: CGFloat = item.image == nil ? 10 : 8 + 16 + 8
        let trail: CGFloat = item.key != nil || item.checked ? 10 + 16 + 10 : 12
        return lead + ceil(title.intrinsicContentSize.width) + trail
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.backgroundColor = highlighted ? effectiveAppearance.resolve(Axo.Color.selected) : nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        plate.frame = bounds
        let mid = bounds.height / 2
        var x: CGFloat = 10
        if item.image != nil {
            image.frame = NSRect(x: 8, y: (mid - 8).rounded(), width: 16, height: 16)
            x = image.frame.maxX + 8
        }
        let ts = title.intrinsicContentSize
        let ks = key.intrinsicContentSize
        let right = bounds.width - 10
        key.frame = NSRect(x: right - ceil(ks.width), y: (mid - ks.height / 2).rounded(), width: ceil(ks.width), height: ks.height)
        check.frame = NSRect(x: right - 14, y: (mid - 8).rounded(), width: 14, height: 16)
        title.frame = NSRect(x: x, y: (mid - ts.height / 2).rounded(), width: max(0, min(ceil(ts.width), right - 20 - x)),
                             height: ts.height)
    }
}
