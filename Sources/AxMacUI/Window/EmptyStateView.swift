import AppKit
import AxModel

enum EmptyState: Equatable {
    case noSessions
    case reconnecting(host: String)
}

/// The window with no session open: a sheet like any pane (the frame stays),
/// and the most on-brand screen in the app, because it says what the app is
/// for: running agents.
///
///                         [mark 48, accent]
///                         Start a session          20 semibold
///          [Shell 1] [Claude 2] [Codex 3] [Gemini 4]   88×72 tiles, 10 apart
///                       [T] tmp ⌃⌄               where it starts
///
/// Keys 1–n launch the tile. The pill picks the project (recent projects with
/// their tiles, then Open Folder…); it defaults to the last one used. No copy
/// paragraph and no shortcut hints: those live in tooltips.
///
/// Reconnecting (a remote host dropped): a spinner in place of the mark, a
/// title and one line saying sessions keep running; no actions.
final class EmptyStateView: NSView {
    struct Project: Equatable {
        var id: WorkspaceID?
        var name: String
        var key: String
    }

    var onLaunch: ((AgentKind?, WorkspaceID?) -> Void)?
    var onOpenFolder: (() -> Void)?

    private let mark = AxoMarkView(frame: .zero)
    private let spinner = StatusGlyphView(frame: .zero)
    private let title = Label("", font: NSFont.systemFont(ofSize: Prim.Size.t7, weight: .semibold), color: Axo.Color.text)
    private let detail = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private var tiles: [LaunchTile] = []
    private let pill = ProjectPill()
    private var state = EmptyState.noSessions
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
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 3
        detail.usesSingleLineMode = false
        pill.onClick = { [weak self] in self?.showProjects() }
        for v in [mark, spinner, title, detail, pill] as [NSView] { addSubview(v) }
        set(.noSessions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Axo.Color.ground.cgColor }
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
        switch s {
        case .noSessions:
            title.stringValue = "Start a session"
            detail.stringValue = ""
        case let .reconnecting(host):
            title.stringValue = "Reconnecting to \(host)"
            detail.stringValue = "Your sessions keep running on the server. This window reattaches as soon as it answers."
        }
        mark.isHidden = reconnecting
        spinner.isHidden = !reconnecting
        spinner.activity = reconnecting ? .working : .idle
        detail.isHidden = !reconnecting
        pill.isHidden = reconnecting
        tiles.forEach { $0.isHidden = reconnecting }
        needsLayout = true
    }

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
            PopMenu.Item(title: p.name, image: ProjectTile.image(name: p.name, key: p.key), key: nil, checked: p == selected) {
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

    override func layout() {
        super.layout()
        let markH: CGFloat = 48
        let ts = title.intrinsicContentSize
        let reconnecting = state != .noSessions
        let tileW: CGFloat = 88, tileH: CGFloat = 72, gap: CGFloat = 10
        let w = min(bounds.width - 48, 360)
        detail.preferredMaxLayoutWidth = w
        let dh = reconnecting ? ceil(detail.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 200)).height ?? 0) : 0
        let ps = pill.fittingSize
        let body = reconnecting
            ? Axo.Space.sm + dh
            : 20 + tileH + 16 + ps.height
        let total = markH + 16 + ts.height + body
        // Optically a little above centre (the eye reads true centre as low).
        var y = ((bounds.height - total) / 2 - bounds.height * 0.04).rounded()
        let m = NSRect(x: (bounds.midX - markH / 2).rounded(), y: y, width: markH, height: markH)
        mark.frame = m
        spinner.frame = m.insetBy(dx: 16, dy: 16)
        y += markH + 16
        title.frame = NSRect(x: (bounds.midX - max(w, ts.width) / 2).rounded(), y: y, width: max(w, ts.width), height: ts.height)
        y += ts.height
        if reconnecting {
            y += Axo.Space.sm
            detail.frame = NSRect(x: (bounds.midX - w / 2).rounded(), y: y, width: w, height: dh)
            return
        }
        y += 20
        // Tiles wrap only when the sheet is narrower than the row.
        let perRow = max(1, min(tiles.count, Int((bounds.width - 48 + gap) / (tileW + gap))))
        let rows = (tiles.count + perRow - 1) / max(1, perRow)
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
        tile.set(name: p.name, key: p.key)
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
