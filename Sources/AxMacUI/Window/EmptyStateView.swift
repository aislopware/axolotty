import AppKit
import AxModel

enum EmptyState: Equatable {
    case noSessions
    /// The host of this window is out of reach: what is happening, one line
    /// on what brings it back, and the one thing to do (nil: just wait).
    /// `machine`: an SF Symbol of that Mac, shown (quiet) where the brand mark
    /// would be: the sheet is about a machine, so it shows which one.
    case away(title: String, detail: String, retrying: Bool, action: String?, machine: String? = nil)
}

/// The window with no session open: a sheet like any pane (the frame stays),
/// and the most on-brand screen in the app, because it says what the app is
/// for: running agents.
///
///                         [mark 48, brand]
///                         Start a session          20 semibold
///          [Shell 1] [Claude 2] [Codex 3] [Gemini 4]   88×72 tiles, 10 apart
///                       [T] tmp ⌃⌄               where it starts
///
/// Keys 1–n launch the tile. The pill picks the project (recent projects with
/// their tiles, then Open Folder…); it defaults to the last one used. No copy
/// paragraph and no shortcut hints: those live in tooltips.
///
/// Away (a remote host dropped, or waits on the person): that Mac's symbol in
/// place of the mark, wearing its state as a badge (the dashed circle while
/// something is under way, amber while it waits on the person, nothing while
/// it is only offline), a title, one line on what brings it back, and at most
/// one button for it. No status circle floats alone in the middle: the state
/// is the machine's.
final class EmptyStateView: NSView {
    struct Project: Equatable {
        var id: WorkspaceID?
        var name: String
        var key: String
    }

    var onLaunch: ((AgentKind?, WorkspaceID?) -> Void)?
    var onOpenFolder: (() -> Void)?
    /// The away sheet's button (set up, update, reconnect).
    var onRemedy: (() -> Void)?

    private let mark = AxoMarkView(frame: .zero)
    private let stateMark = StatusGlyphView(frame: .zero)
    private let machine = NSImageView()
    /// The ground behind the state badge, cut out of the machine's symbol.
    private let badgeBack = NSView()
    private let title = Label("", font: NSFont.systemFont(ofSize: Prim.Size.t7, weight: .semibold), color: Axo.Color.text)
    private let detail = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private var tiles: [LaunchTile] = []
    private let pill = ProjectPill()
    private let remedy = Button("", variant: .secondary, size: .regular)
    private(set) var state = EmptyState.noSessions
    private var agents: [AgentKind] = []
    private var projects: [Project] = []
    private var selected: Project?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Axo.Metric.sheetRadius
        layer?.cornerCurve = .continuous
        title.alignment = .center
        detail.alignment = .center
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        title.usesSingleLineMode = false
        badgeBack.wantsLayer = true
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.usesSingleLineMode = false
        pill.onClick = { [weak self] in self?.showProjects() }
        remedy.target = self
        remedy.action = #selector(runRemedy)
        machine.imageScaling = .scaleNone
        machine.contentTintColor = Axo.Color.textDisabled
        for v in [mark, machine, badgeBack, stateMark, title, detail, pill, remedy] as [NSView] { addSubview(v) }
        set(.noSessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Axo.Color.ground.cgColor
        badgeBack.layer?.backgroundColor = Axo.Color.ground.cgColor
    }
    override var acceptsFirstResponder: Bool { state == .noSessions }

    /// What can be launched, and where.
    func configure(agents: [AgentKind], projects: [Project], selected: Project?) {
        if agents != self.agents {
            self.agents = agents
            tiles.forEach { $0.removeFromSuperview() }
            // Same keys as the "+" menu: 1 Shell, 2–9 agents.
        let all: [AgentKind?] = [nil] + agents.prefix(8).map { Optional($0) }
            tiles = all.enumerated().map { i, a in
                let t = LaunchTile(identity: a.map(ProgramIdentity.of) ?? .shell, name: a?.shortName ?? "Shell", digit: i + 1)
                t.onClick = { [weak self] in self?.launch(a) }
                addSubview(t)
                return t
            }
        }
        self.projects = projects
        self.selected = selected ?? projects.first
        pill.set(self.selected ?? Project(id: nil, name: "Home", key: "Home"))
        set(state)
    }

    func set(_ s: EmptyState) {
        state = s
        let reconnecting = s != .noSessions
        var waits = false
        var symbol: String?
        switch s {
        case .noSessions:
            title.stringValue = "Start a session"
            detail.stringValue = ""
            remedy.isHidden = true
        case let .away(t, d, retrying, action, m):
            symbol = m
            title.stringValue = t
            detail.stringValue = d
            waits = !retrying
            remedy.isHidden = action == nil
            if let action, remedy.title != action { remedy.title = action }
        }
        mark.isHidden = reconnecting && symbol != nil
        machine.isHidden = !reconnecting || symbol == nil
        machine.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(.init(pointSize: 30, weight: .light))
        // Offline with nothing to do: no state glyph at all.
        let idle = waits && remedy.isHidden
        stateMark.isHidden = !reconnecting || idle || symbol == nil
        badgeBack.isHidden = stateMark.isHidden
        stateMark.activity = !reconnecting || idle ? .idle : waits ? .blocked : .working
        detail.isHidden = !reconnecting
        pill.isHidden = reconnecting
        tiles.forEach { $0.isHidden = reconnecting }
        needsLayout = true
    }

    @objc private func runRemedy() { onRemedy?() }

    private func launch(_ agent: AgentKind?) {
        onLaunch?(agent, selected?.id)
    }

    override func keyDown(with event: NSEvent) {
        guard state == .noSessions, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let c = event.charactersIgnoringModifiers, let n = Int(c), n >= 1, n <= tiles.count
        else { return super.keyDown(with: event) }
        tiles[n - 1].flash()
        launch(n == 1 ? nil : agents[n - 2])
    }

    private func showProjects() {
        var items: [PopMenu.Item?] = projects.map { p in
            PopMenu.Item(title: p.name, image: ProjectTile.menuImage, key: nil, checked: p == selected) {
                [weak self] in
                guard let self else { return }
                self.selected = p
                self.pill.set(p)
                self.needsLayout = true
                self.window?.makeFirstResponder(self)
            }
        }
        if !projects.isEmpty { items.append(nil) }
        items.append(PopMenu.Item(title: "Open Folder…", image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil),
                                  key: nil) { [weak self] in self?.onOpenFolder?() })
        PopMenu.show(items, from: pill)
    }

    /// The size `label` takes within `width`, its lines evened out: text
    /// that needs two lines gets two of a length, not a lone word under a
    /// full one (the width is narrowed to about half, then a margin).
    private static func balanced(_ label: NSTextField, within width: CGFloat) -> NSSize {
        func size(_ w: CGFloat) -> NSSize {
            label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 400)) ?? .zero
        }
        let one = ceil(size(10_000).width)
        let full = ceil(size(width).height)
        var w = width
        if one > width {
            let lines = max(2, (one / width).rounded(.up))
            let even = min(width, ceil(one / lines) + 24)
            if ceil(size(even).height) <= full { w = even }
        }
        label.preferredMaxLayoutWidth = w
        return NSSize(width: w, height: ceil(size(w).height))
    }

    override func layout() {
        super.layout()
        let markH: CGFloat = 48
        let reconnecting = state != .noSessions
        let tileW: CGFloat = 88, tileH: CGFloat = 72, gap: CGFloat = 10
        let w = min(bounds.width - 48, 360)
        let ts = Self.balanced(title, within: w)
        let ds = reconnecting ? Self.balanced(detail, within: w) : .zero
        let dh = ds.height
        let ps = pill.fittingSize
        let bs = remedy.isHidden ? .zero : remedy.intrinsicContentSize
        let body = reconnecting
            ? Axo.Space.sm + dh + (remedy.isHidden ? 0 : Axo.Space.lg + bs.height)
            : 20 + tileH + 16 + ps.height
        let total = markH + 16 + ts.height + body
        // Optically a little above centre (the eye reads true centre as low).
        var y = ((bounds.height - total) / 2 - bounds.height * 0.04).rounded()
        let m = NSRect(x: (bounds.midX - markH / 2).rounded(), y: y, width: markH, height: markH)
        mark.frame = m
        machine.frame = m
        y += markH + 16
        // The badge sits on the machine's lower trailing corner, on a disc of
        // ground that parts it from the symbol's strokes.
        let slot = Axo.Metric.statusSlot, disc = slot + 4
        let c = NSPoint(x: m.midX + 17, y: m.midY + 10)
        badgeBack.frame = NSRect(x: (c.x - disc / 2).rounded(), y: (c.y - disc / 2).rounded(), width: disc, height: disc)
        badgeBack.layer?.cornerRadius = disc / 2
        stateMark.frame = NSRect(x: (c.x - slot / 2).rounded(), y: (c.y - slot / 2).rounded(), width: slot, height: slot)
        title.frame = NSRect(x: (bounds.midX - ts.width / 2).rounded(), y: y, width: ts.width, height: ts.height)
        y += ts.height
        if reconnecting {
            y += Axo.Space.sm
            detail.frame = NSRect(x: (bounds.midX - ds.width / 2).rounded(), y: y, width: ds.width, height: dh)
            if !remedy.isHidden {
                y += dh + Axo.Space.lg
                remedy.frame = NSRect(x: (bounds.midX - bs.width / 2).rounded(), y: y, width: ceil(bs.width), height: bs.height)
            }
            return
        }
        y += 20
        // Tiles wrap only when the sheet is narrower than the row, and then
        // into rows as even as they go (2 + 2, never 3 + 1).
        let fits = max(1, min(tiles.count, Int((bounds.width - 48 + gap) / (tileW + gap))))
        let rows = (tiles.count + fits - 1) / fits
        let perRow = (tiles.count + rows - 1) / max(1, rows)
        for (i, t) in tiles.enumerated() {
            let r = i / perRow, c = i % perRow
            let inRow = min(perRow, tiles.count - r * perRow)
            let rowW = CGFloat(inRow) * tileW + CGFloat(inRow - 1) * gap
            t.frame = NSRect(x: (bounds.midX - rowW / 2).rounded() + CGFloat(c) * (tileW + gap),
                             y: y + CGFloat(r) * (tileH + gap), width: tileW, height: tileH)
        }
        y += CGFloat(rows) * tileH + CGFloat(rows - 1) * gap + 16
        pill.frame = NSRect(x: (bounds.midX - ps.width / 2).rounded(), y: y, width: ps.width, height: ps.height)
    }
}

/// One launch tile: 88×72, radius 12, a resting card. The program's mark at
/// 24, its name in 12 medium, and its key in the top-right corner. Hover
/// lifts it to a float instantly; it settles back on the tick.
private final class LaunchTile: Surface {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let name = Label("", font: Axo.Font.smallStrong, color: Axo.Color.textSecondary)
    private let digit = Label("", font: Axo.Font.meta, color: Axo.Color.textDisabled)
    private let identity: ProgramIdentity

    init(identity: ProgramIdentity, name text: String, digit n: Int) {
        self.identity = identity
        super.init(elevation: .rest, radius: 12)
        name.stringValue = text
        name.alignment = .center
        digit.stringValue = "\(n)"
        icon.imageScaling = .scaleNone
        for v in [icon, name, digit] as [NSView] { content.addSubview(v) }
        toolTip = "\(text)  \(n)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Start \(text)")
        refreshIcon()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refreshIcon() {
        icon.image = identity.image(side: 24)
        icon.contentTintColor = identity.brand == nil ? Axo.Color.textSecondary : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshIcon()
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        icon.frame = NSRect(x: (bounds.midX - 12).rounded(), y: 22 - 12, width: 24, height: 24)
        let ns = name.intrinsicContentSize
        name.frame = NSRect(x: 4, y: (50 - ns.height / 2).rounded(), width: bounds.width - 8, height: ns.height)
        let ds = digit.intrinsicContentSize
        digit.frame = NSRect(x: bounds.width - 8 - ceil(ds.width), y: 6, width: ceil(ds.width), height: ds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        elevation = .float
        name.textColor = Axo.Color.text
    }

    override func mouseExited(with event: NSEvent) {
        elevation = .rest
        name.textColor = Axo.Color.textSecondary
    }

    override func mouseDown(with event: NSEvent) { flash() }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    /// The pressed look, for a click or its key.
    func flash() {
        fill = Axo.Color.pressed
        DispatchQueue.main.asyncAfter(deadline: .now() + Axo.Motion.tick.duration) { [weak self] in self?.fill = nil }
    }
}

/// Where a launch starts: the project's tile, its name, and a chevron, as one
/// borderless pop-up (a hover plate, no ring).
private final class ProjectPill: NSView {
    var onClick: (() -> Void)?
    private let tile = ProjectTile()
    private let name = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private let chevron = Symbol("chevron.up.chevron.down", size: 9, weight: .semibold, color: Axo.Color.textTertiary)
    private let plate = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.cornerRadius = Axo.Radius.md
        plate.cornerCurve = .continuous
        plate.opacity = 0
        layer?.addSublayer(plate)
        for v in [tile, name, chevron] as [NSView] { addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func set(_ p: EmptyStateView.Project) {
        name.stringValue = p.name
        setAccessibilityLabel("Start in \(p.name)")
        toolTip = "Start in \(p.name)"
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: 8 + 16 + 6 + ceil(name.intrinsicContentSize.width) + 6 + 10 + 8, height: Axo.Metric.control)
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        tile.frame = NSRect(x: 8, y: (mid - 8).rounded(), width: 16, height: 16)
        let ns = name.intrinsicContentSize
        name.frame = NSRect(x: tile.frame.maxX + 6, y: (mid - ns.height / 2).rounded(), width: ceil(ns.width), height: ns.height)
        chevron.frame = NSRect(x: name.frame.maxX + 6, y: (mid - 8).rounded(), width: 10, height: 16)
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

    override func mouseEntered(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.opacity = 1
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Axo.Motion.tick.duration)
        plate.opacity = 0
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
