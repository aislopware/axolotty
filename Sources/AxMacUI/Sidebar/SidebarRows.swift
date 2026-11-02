import AppKit
import AxModel

// Sidebar anatomy (see .research/design-system.md §Sidebar; measured from
// Codex, Linear, Zed, Conductor, Claude desktop, Raycast, Mail; contrasted
// with the noisy ones, Warp and cmux):
//
//   column 248 · plates inset 8, 28 tall, 2 apart, radius 8
//   project: 20 pt solid hue tile at x 16, name 13 semibold at x 44, 32
//            tall, 20 above every project but the first. Projects are the
//            objects of the list (the tile is the loudest mark at rest).
//   session: icon under the project's name (x 44), title at x 67 (Codex's
//            indent: hierarchy from position, not from louder type)
//
// A session row is its program icon and title. State sits on the icon as a
// badge (mini spinner while working, a dot when it wants a look), so the
// agent's identity never disappears. Hover adds close; holding ⌘ shows ⌘n.

enum SidebarMetric {
    static let listInset: CGFloat = 8
    static let rowPad: CGFloat = 8
    static let sessionRow: CGFloat = 30  // 28 plate + 2 gap
    static let headerRow: CGFloat = 32
    static let headerGap: CGFloat = 20  // above every project but the first
    static let firstGap: CGFloat = 2
    static let slot: CGFloat = 16
    static let slotGap: CGFloat = 7
    static let tile: CGFloat = 20
    static let tileGap: CGFloat = 8
    /// The project tile's x.
    static var textX: CGFloat { listInset + rowPad }
    /// The project name's x, and the session icon's.
    static var nameX: CGFloat { textX + tile + tileGap }
    /// The session title's x.
    static var titleX: CGFloat { nameX + slot + slotGap }
    /// Right edge of the trailing slot.
    static func slotRight(_ width: CGFloat) -> CGFloat { width - listInset - 5 }
}

/// An outline item. Identity is stable per `kind` so expansion and selection
/// survive document updates.
final class SidebarNode: NSObject {
    enum Kind: Hashable {
        case workspace(UUID, WorkspaceID)
        case session(UUID, SessionID)
    }

    let kind: Kind
    var children: [SidebarNode] = []

    init(_ kind: Kind) { self.kind = kind }

    var hostID: UUID {
        switch kind {
        case let .workspace(h, _), let .session(h, _): h
        }
    }

    var isSession: Bool {
        if case .session = kind { true } else { false }
    }
}

/// The outline: one selection plate that springs between rows and one hover
/// plate; no disclosure triangles (groups expand from their header), no
/// indentation (hierarchy is spacing and type tier), no per-row highlights.
final class SidebarOutlineView: NSOutlineView {
    let plate = CALayer()
    private let hoverPlate = CALayer()
    private var plateRow = -1
    private(set) var hoverRow = -1
    var onHoverChange: ((Int, Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for p in [hoverPlate, plate] {
            p.cornerRadius = Axo.Radius.md
            p.cornerCurve = .continuous
            p.opacity = 0
            layer?.insertSublayer(p, at: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // No disclosure triangle, no indentation: cells span the full row.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let r = rect(ofRow: row)
        return NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolor()
    }

    private var keyObservers: [any NSObjectProtocol] = []

    /// Like every Mac sidebar, the selection steps back when the window does.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let w = window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recolor() }
            })
        }
    }

    private func recolor() {
        let key = window?.isKeyWindow ?? true
        plate.backgroundColor = effectiveAppearance.resolve(key ? Axo.Color.selected : Axo.Color.hover)
        hoverPlate.backgroundColor = effectiveAppearance.resolve(Axo.Color.hover)
    }

    override func layout() {
        super.layout()
        movePlate(animated: false)
        placeHover()
    }

    private func plateRect(_ row: Int) -> CGRect {
        let r = rect(ofRow: row)
        let i = SidebarMetric.listInset
        return CGRect(x: i, y: r.minY + 1, width: bounds.width - i * 2, height: r.height - 2)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHover(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHover(-1)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        if let w = window { setHover(row(at: convert(w.mouseLocationOutsideOfEventStream, from: nil))) }
    }

    /// Hover is tracked for every row (cells reveal their actions); the plate
    /// is drawn only on unselected session rows.
    private func setHover(_ row: Int) {
        guard row != hoverRow else { return }
        let old = hoverRow
        hoverRow = row
        onHoverChange?(old, row)
        placeHover()
    }

    private func placeHover() {
        let row = hoverRow
        let show = row >= 0 && row < numberOfRows && row != selectedRow && (item(atRow: row) as? SidebarNode)?.isSession == true
        recolor()
        CATransaction.begin()
        if show {
            // In: instant.
            CATransaction.setDisableActions(true)
            hoverPlate.frame = plateRect(row)
            hoverPlate.opacity = 1
        } else {
            // Out: Tick.
            CATransaction.setDisableActions(Axo.Motion.reduced)
            CATransaction.setAnimationDuration(Axo.Motion.tick.duration)
            hoverPlate.opacity = 0
        }
        CATransaction.commit()
    }

    /// Slides the plate to the selected row with `Motion.snap`.
    func movePlate(animated: Bool) {
        recolor()
        let row = selectedRow
        guard row >= 0 else {
            plate.opacity = 0
            plateRow = -1
            return
        }
        let target = plateRect(row)
        let animate = animated && plateRow >= 0 && plate.opacity > 0 && !Axo.Motion.reduced
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animate {
            let spring = Axo.Motion.snap.animation("position")
            spring.fromValue = plate.presentation()?.position ?? plate.position
            spring.toValue = CGPoint(x: target.midX, y: target.midY)
            spring.duration = spring.settlingDuration
            plate.add(spring, forKey: "position")
            let size = Axo.Motion.snap.animation("bounds.size")
            size.fromValue = plate.presentation()?.bounds.size ?? plate.bounds.size
            size.toValue = target.size
            size.duration = size.settlingDuration
            plate.add(size, forKey: "size")
        }
        plate.frame = target
        plate.opacity = 1
        CATransaction.commit()
        plateRow = row
        placeHover()
    }

    /// Source lists keep the selection on click but never take keyboard focus:
    /// the terminal stays first responder.
    override var acceptsFirstResponder: Bool { false }
}

/// Row views draw nothing themselves (the plates live in the outline).
final class SidebarRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A label that fades its last 20 pt instead of an ellipsis when it overflows.
final class FadingLabel: NSView {
    let label = Label("")
    private let fade = CAGradientLayer().crisp()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.lineBreakMode = .byClipping
        addSubview(label)
        fade.colors = [CGColor.black, CGColor.black, CGColor.clear]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var naturalWidth: CGFloat { label.intrinsicContentSize.width }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: ((bounds.height - s.height) / 2).rounded(), width: max(bounds.width, s.width), height: s.height)
        Axo.Motion.still {
            if s.width > bounds.width + 1 {
                fade.frame = bounds
                let start = max(0, (bounds.width - 20) / max(1, bounds.width))
                fade.locations = [0, NSNumber(value: Double(start)), 1]
                layer?.mask = fade
            } else {
                layer?.mask = nil
            }
        }
    }
}

/// A project header: hue tile + name (13 semibold, near-full ink). Nothing
/// else at rest; when collapsed, one dot after the name if a session inside
/// waits or failed. Hover reveals the disclosure chevron and `+`.
final class WorkspaceCell: NSTableCellView {
    let tile = ProjectTile()
    let title = Label("", font: Axo.Font.title, color: Axo.Color.text)
    let rollup = StatusGlyphView(frame: .zero)
    let add = IconButton(symbol: "plus", label: "New Session in Project", size: .small)
    let chevron = Symbol("chevron.down", size: 9, weight: .semibold, color: Axo.Color.textTertiary)
    /// Gets the "+" button, to anchor the presets menu.
    var onAdd: ((NSView) -> Void)?
    var active = false { didSet { restyle() } }
    var expanded = true { didSet { restyle() } }
    var hovering = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        add.target = self
        add.action = #selector(addClicked)
        add.tooltip = "New Session"
        for v in [tile, title, rollup, add, chevron] as [NSView] { addSubview(v) }
        textField = title
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func addClicked() { onAdd?(add) }

    func set(name: String, key: String) {
        title.stringValue = name
        tile.set(name: name, key: key)
    }

    private func restyle() {
        // Full ink always: a project never reads quieter than its sessions.
        title.textColor = Axo.Color.text
        add.isHidden = !hovering
        chevron.isHidden = !hovering
        chevron.frameCenterRotation = expanded ? 0 : 90
        rollup.isHidden = expanded || !(rollup.activity == .blocked || rollup.activity == .error)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = SidebarMetric.headerRow
        let mid = bounds.height - h / 2  // the gap above sits on top
        let ts = title.intrinsicContentSize
        var right = SidebarMetric.slotRight(bounds.width) + 3
        if !add.isHidden {
            let s = Axo.Metric.controlSmall
            add.frame = NSRect(x: right - s, y: (mid - s / 2).rounded(), width: s, height: s)
            right = add.frame.minX
            chevron.frame = NSRect(x: right - s, y: (mid - s / 2).rounded(), width: s, height: s)
            right = chevron.frame.minX
        }
        let s = SidebarMetric.tile
        tile.frame = NSRect(x: SidebarMetric.textX, y: (mid - s / 2).rounded(), width: s, height: s)
        let x = SidebarMetric.nameX
        let w = max(0, min(ts.width, right - x - 4 - (rollup.isHidden ? 0 : 14)))
        title.frame = NSRect(x: x, y: (mid - ts.height / 2).rounded(), width: w, height: ts.height)
        rollup.frame = NSRect(x: title.frame.maxX - 1, y: (mid - 8).rounded(), width: 16, height: 16)
    }
}

/// A session row: program icon (carrying the state) and title (secondary ink
/// at rest; full ink when selected, hovered, or when its agent wants a look).
/// A row whose agent needs you (waiting or failed) sits on a wash plate of
/// that state's colour, the same geometry as the selection plate, so "who
/// needs me" is answered by area, not by a 6 px dot.
/// Trailing slot: hover → close; ⌘ held → `⌘n`.
final class SessionCell: NSTableCellView {
    private let wash = CALayer()
    let icon = ProgramIcon(frame: .zero)
    let titleView = FadingLabel()
    var title: Label { titleView.label }
    let shortcut = Label("", font: Axo.Font.meta, color: Axo.Color.textTertiary)
    let close = IconButton(symbol: "xmark", label: "Close Session", size: .small)
    var onClose: (() -> Void)?
    /// Shown in the hover card after 550 ms; replaced in place when it changes.
    var card: HoverCard? {
        didSet {
            guard hovering, let card, card != oldValue else { return }
            Tooltip.shared.refresh(self, card: card)
        }
    }
    /// The pointer arrived: a chance to fetch facts the card lacks.
    var onHover: (() -> Void)?

    var activity: Activity = .idle { didSet { restyle() } }
    var selected = false { didSet { restyle() } }
    var showShortcut = false { didSet { restyle() } }
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            restyle()
            if hovering, let card {
                Tooltip.shared.hover(self, card: card)
                onHover?()
            } else {
                Tooltip.shared.leave(self)
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        shortcut.alignment = .right
        close.target = self
        close.action = #selector(closeClicked)
        close.tooltip = nil
        wantsLayer = true
        wash.cornerRadius = Axo.Radius.md
        wash.cornerCurve = .continuous
        wash.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(wash)
        for v in [icon, titleView, shortcut, close] as [NSView] { addSubview(v) }
        textField = title
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func closeClicked() { onClose?() }

    /// Live rows (an agent working, waiting, failed or finished-unseen) take full ink.
    private var wantsLook: Bool { activity != .idle }

    private func restyle() {
        let lit = selected || hovering
        title.font = Axo.Font.body
        title.textColor = lit || wantsLook ? Axo.Color.text : Axo.Color.textSecondary
        icon.activity = activity
        icon.lit = lit
        let keyOn = showShortcut && !shortcut.stringValue.isEmpty
        shortcut.isHidden = !keyOn
        close.isHidden = keyOn || !hovering
        let needsYou = activity == .blocked || activity == .error
        wash.isHidden = !needsYou
        if needsYou { wash.backgroundColor = effectiveAppearance.resolve(Axo.Color.statusWash(activity)) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let mid = h / 2
        let i = SidebarMetric.listInset
        wash.frame = CGRect(x: i, y: 1, width: bounds.width - i * 2, height: h - 2)
        let s = SidebarMetric.slot
        icon.frame = NSRect(x: SidebarMetric.nameX, y: (mid - s / 2).rounded(), width: s, height: s)
        let right = SidebarMetric.slotRight(bounds.width)
        let c = Axo.Metric.controlSmall
        close.frame = NSRect(x: right + 3 - c, y: (mid - c / 2).rounded(), width: c, height: c)
        let k = shortcut.intrinsicContentSize
        shortcut.frame = NSRect(x: right - k.width, y: (mid - k.height / 2).rounded(), width: k.width, height: k.height)
        var titleRight = right + 3
        if !close.isHidden { titleRight = close.frame.minX }
        if !shortcut.isHidden { titleRight = shortcut.frame.minX }
        let x = SidebarMetric.titleX
        titleView.frame = NSRect(x: x, y: 0, width: max(0, titleRight - 4 - x), height: h)
    }
}
