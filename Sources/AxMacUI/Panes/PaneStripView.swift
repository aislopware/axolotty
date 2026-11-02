import AppKit
import AxModel

/// A pane's identity strip: 28 pt inside the top of its sheet, shown only
/// when a session has two or more panes and none is zoomed (one pane is named
/// by the header). It makes a split read as several agents, each with a face.
///
///     [icon] name   cwd                         4:12   [zoom][close]
///
/// - Leading: the program icon (carrying its state badge) on the text column, the name
///   (12 medium), then the cwd relative to the project (12, tertiary; hidden
///   below 280 pt).
/// - Trailing: elapsed m:ss while working; after a run, its receipt ("✓ 4m
///   12s", the check green while unseen); zoom and close on hover only.
/// - Focus is ink, not a border: the focused strip's name is full ink, the
///   others tertiary.
/// - Needs you: the strip floods with the state's wash and the name becomes
///   the agent's own question. Area, not a stroke (it replaces the 1.5 pt
///   inner line panes used to carry).
///
/// No rule under it: the terminal's rows start 6 pt below.
final class PaneStripView: NSView {
    static let height: CGFloat = 28

    private let icon = ProgramIcon(frame: .zero)
    private let name = Label("", font: Axo.Font.smallStrong, color: Axo.Color.text)
    private let path = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    private let elapsed = Label("", font: Axo.Font.meta, color: Axo.Color.textTertiary)
    private let check = Symbol("checkmark", size: 9, weight: .bold, color: Axo.Color.textTertiary)
    private let zoom = IconButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Zoom Pane", size: .small)
    private let close = IconButton(symbol: "xmark", label: "Close Pane", size: .small)
    private let wash = CALayer()
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
        /// Seconds the last run took.
        var lastRun: Double?
        var focused: Bool
    }

    private var model: Model?
    private var hovering = false { didSet { if hovering != oldValue { restyle(); tickElapsed(); needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        wash.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(wash)
        name.lineBreakMode = .byTruncatingTail
        path.lineBreakMode = .byTruncatingMiddle
        zoom.target = self
        zoom.action = #selector(zoomClicked)
        close.target = self
        close.action = #selector(closeClicked)
        for v in [icon, name, path, check, elapsed, zoom, close] as [NSView] { addSubview(v) }
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
        let washChanged = model.map { needsYou($0) != needsYou(m) || $0.activity != m.activity } ?? true
        model = m
        icon.identity = m.identity
        icon.activity = m.activity
        icon.lit = m.focused
        path.stringValue = m.path
        restyle()
        if washChanged, needsYou(m), !Axo.Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0
            a.toValue = 1
            a.duration = 0.2
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            wash.add(a, forKey: "in")
        }
        tickElapsed()
        needsLayout = true
    }

    private func needsYou(_ m: Model) -> Bool { m.activity == .blocked || m.activity == .error }

    /// Called by the update path and by the owner's 1 s tick while working.
    func tickElapsed() {
        guard let m = model else { return }
        let receipt = (m.activity == .done || m.activity == .idle) ? m.lastRun : nil
        check.isHidden = receipt == nil || hovering
        check.contentTintColor = m.activity == .done ? Axo.Color.status(.done) : Axo.Color.textTertiary
        if let receipt {
            elapsed.stringValue = BandView.duration(receipt)
            return
        }
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
        path.isHidden = urgent
        zoom.isHidden = !hovering
        close.isHidden = !hovering
        Axo.Motion.still {
            wash.isHidden = !urgent
            if urgent { wash.backgroundColor = effectiveAppearance.resolve(Axo.Color.statusWash(m.activity)) }
        }
    }

    override func layout() {
        super.layout()
        Axo.Motion.still { wash.frame = bounds }
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
            right = elapsed.frame.minX - Axo.Space.md
            if !check.isHidden {
                check.frame = NSRect(x: elapsed.frame.minX - 2 - 12, y: (mid - 8).rounded(), width: 12, height: 16)
                right = check.frame.minX - Axo.Space.md
            }
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
