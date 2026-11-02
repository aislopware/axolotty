import AppKit
import AxModel

/// The sidebar's bottom row (36 pt, on the frame, no rule): it anchors the
/// column at low session counts, and holds only things that act or count.
///
///     [⚙]                             ● 2 waiting  ◌ 3 working
///
/// - Leading: Settings.
/// - Trailing: the census across every host, each count a button that jumps
///   to the next session in that state. Nothing shows at zero.
final class SidebarFooter: NSView {
    var onJump: ((Activity) -> Void)?

    private let settings = IconButton(symbol: "gearshape", label: "Settings", size: .small)
    private let waiting = RollupButton()
    private let failed = RollupButton()
    private let working = RollupButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        settings.action = #selector((any AxActions).showSettings(_:))
        settings.tooltip = "Settings  ⌘,"
        for (b, a) in [(waiting, Activity.blocked), (failed, .error), (working, .working)] {
            b.activity = a
            b.compact = true
            b.target = self
            b.action = #selector(jump(_:))
        }
        for v in [settings, waiting, failed, working] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func jump(_ sender: RollupButton) { onJump?(sender.activity) }

    func update(counts: (blocked: Int, error: Int, working: Int, done: Int)) {
        waiting.count = counts.blocked
        failed.count = counts.error
        working.count = counts.working
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let s = Axo.Metric.controlSmall
        let mid = bounds.height / 2
        let x0 = SidebarMetric.listInset + 2
        settings.frame = NSRect(x: x0, y: (mid - s / 2).rounded(), width: s, height: s)
        var right = bounds.width - SidebarMetric.listInset
        for b in [working, failed, waiting] where !b.isHidden {
            let f = b.fittingSize
            b.frame = NSRect(x: right - f.width, y: (mid - f.height / 2).rounded(), width: f.width, height: f.height)
            right = b.frame.minX - 2
        }
    }
}

/// One roll-up segment: a status glyph and "2 working".
final class RollupButton: NSControl {
    var activity: Activity = .working {
        didSet { glyph.activity = activity }
    }

    /// Compact: the glyph and the number; the noun moves to the tooltip.
    var compact = false { didSet { let c = count; count = c } }

    var count = 0 {
        didSet {
            isHidden = count == 0
            let noun = switch activity {
            case .working: "working"
            case .blocked: "waiting"
            case .error: "failed"
            case .done: "done"
            case .idle: ""
            }
            label.stringValue = compact ? "\(count)" : "\(count) \(noun)"
            toolTip = compact ? "\(count) \(noun)" : nil
            setAccessibilityLabel("\(count) \(noun)")
        }
    }

    private let glyph = StatusGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let label = NSTextField(labelWithString: "")
    private let plate = Plate(radius: Axo.Radius.sm)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(plate.layer)
        label.font = Axo.Font.meta
        label.textColor = Axo.Color.textSecondary
        addSubview(glyph)
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 4 + 16 + 2 + ceil(label.fittingSize.width) + 8, height: 20) }

    override func layout() {
        super.layout()
        Axo.Motion.still { plate.layer.frame = bounds; plate.layer.radius = Axo.Radius.sm }
        glyph.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let s = label.fittingSize
        label.frame = NSRect(x: glyph.frame.maxX + 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { plate.refresh(effectiveAppearance) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { plate.set(.hover, appearance: effectiveAppearance) }
    override func mouseExited(with event: NSEvent) { plate.set(.rest, appearance: effectiveAppearance) }
    override func mouseDown(with event: NSEvent) { plate.set(.pressed, appearance: effectiveAppearance, animated: false) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.set(inside ? .hover : .rest, appearance: effectiveAppearance)
        if inside { sendAction(action, to: target) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
