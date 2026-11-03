import AppKit
import AxModel

/// A pane's identity strip: 28 pt inside the top of its sheet, shown only
/// when a session has two or more panes and none is zoomed (one pane is named
/// by the header). It makes a split read as several agents, each with a face.
///
///     [icon] name   cwd                      ◌ 4:12   [zoom][close]
///
/// - Leading: the program icon on the text column, the name (12 medium),
///   then the cwd relative to the project (12, tertiary; hidden below 280 pt).
/// - Trailing: the state circle (`StatusGlyphView`), with elapsed m:ss
///   while working; zoom and close on hover only.
/// - Focus is ink, not a border: the focused strip's name is full ink, the
///   others tertiary.
/// - Needs you: the name becomes the agent's own question in full ink; the
///   circle carries the state's colour and what it waits for. No stripe or wash.
///
/// No rule under it: the terminal's rows start 6 pt below.
final class PaneStripView: NSView {
    static let height: CGFloat = 28

    private let icon = ProgramIcon(frame: .zero)
    private let state = StatusGlyphView(frame: .zero)
    private let name = Label("", font: Axo.Font.smallStrong, color: Axo.Color.text)
    private let path = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    private let elapsed = Label("", font: Axo.Font.meta, color: Axo.Color.textTertiary)
    private let zoom = IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Zoom Pane", size: .small)
    private let close = IconButton(symbol: "xmark", label: "Close Pane", size: .small)
    var onZoom: (() -> Void)?
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?

    struct Model: Equatable {
        var identity: ProgramIdentity
        var name: String
        var path: String
        var activity: Activity
        var since: Double
        /// The agent's question while it waits (or "Failed").
        var question: String?
        var need: StatusRecord.Need?
        var focused: Bool
    }

    private var model: Model?
    var hovering = false { didSet { if hovering != oldValue { restyle(); tickElapsed(); needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        name.lineBreakMode = .byTruncatingTail
        path.lineBreakMode = .byTruncatingMiddle
        zoom.target = self
        zoom.action = #selector(zoomClicked)
        close.target = self
        close.action = #selector(closeClicked)
        for v in [icon, name, path, state, elapsed, zoom, close] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func zoomClicked() { onZoom?() }
    @objc private func closeClicked() { onClose?() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onZoom?() } else { onActivate?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func update(_ m: Model) {
        guard m != model else { return tickElapsed() }
        model = m
        icon.identity = m.identity
        state.activity = m.activity
        state.need = m.need
        icon.lit = m.focused
        path.stringValue = m.path
        restyle()
        tickElapsed()
        needsLayout = true
    }

    private func needsYou(_ m: Model) -> Bool { m.activity == .blocked || m.activity == .error }

    /// Called by the update path and by the owner's 1 s tick while working.
    func tickElapsed() {
        guard let m = model else { return }
        guard m.activity == .working, m.since > 0 else {
            elapsed.stringValue = ""
            return
        }
        let s = max(0, Int(Date().timeIntervalSince1970 - m.since))
        let text = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                             : String(format: "%d:%02d", s / 60, s % 60)
        if elapsed.stringValue.count != text.count { needsLayout = true }
        elapsed.stringValue = text
    }

    private func restyle() {
        guard let m = model else { return }
        let urgent = needsYou(m)
        name.stringValue = urgent ? (m.question ?? m.name) : m.name
        name.textColor = urgent || m.focused ? Axo.Color.text : Axo.Color.textTertiary
        path.textColor = m.focused ? Axo.Color.textTertiary : Axo.Color.textDisabled
        elapsed.isHidden = urgent || hovering
        state.isHidden = m.activity == .idle || hovering
        path.isHidden = urgent
        zoom.isHidden = !hovering
        close.isHidden = !hovering
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        var right = bounds.width - 8
        let c = Axo.Metric.controlSmall
        if !close.isHidden {
            close.frame = NSRect(x: right - c, y: (mid - c / 2).rounded(), width: c, height: c)
            zoom.frame = NSRect(x: close.frame.minX - 4 - c, y: (mid - c / 2).rounded(), width: c, height: c)
            right = zoom.frame.minX - Axo.Space.sm
        } else {
            right = bounds.width - Axo.Metric.panePaddingX
        }
        if !elapsed.isHidden, !elapsed.stringValue.isEmpty {
            let e = elapsed.intrinsicContentSize
            elapsed.frame = NSRect(x: right - ceil(e.width), y: (mid - e.height / 2).rounded(), width: ceil(e.width), height: e.height)
            right = elapsed.frame.minX - Axo.Space.xs
        }
        if !state.isHidden {
            state.frame = NSRect(x: right + 1.5 - 16, y: (mid - 8).rounded(), width: 16, height: 16)
            right = state.frame.minX - Axo.Space.md
        }
        // The mark's ink (14 of the 16 pt slot) starts on the terminal's text column.
        icon.frame = NSRect(x: Axo.Metric.panePaddingX - 1, y: (mid - 8).rounded(), width: 16, height: 16)
        var x = icon.frame.maxX + Axo.Space.sm
        let ns = name.intrinsicContentSize
        // The name never takes more than 140 pt while a path follows it.
        let nameCap = path.isHidden || path.stringValue.isEmpty ? right - x : min(right - x, 140)
        name.frame = NSRect(x: x, y: (mid - ns.height / 2).rounded(), width: max(0, min(ceil(ns.width), nameCap)), height: ns.height)
        x = name.frame.maxX + Axo.Space.sm
        let ps = path.intrinsicContentSize
        let showPath = !path.isHidden && bounds.width >= 280 && right - x > 40
        path.alphaValue = showPath ? 1 : 0
        path.frame = NSRect(x: x, y: (mid - ps.height / 2).rounded(), width: max(0, min(ceil(ps.width), right - x)), height: ps.height)
    }
}
