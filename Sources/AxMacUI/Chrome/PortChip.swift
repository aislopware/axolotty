import AppKit

/// What the session serves: the ports something in it listens on (a dev
/// server an agent started), after the diff chip in the band.
///
///     ◎ 5173        ◎ 5173 +2
///
/// A 10 pt `network` glyph in tertiary ink, the first port in meta type;
/// more ports add "+n". A radius-6 hover plate, like the diff chip. Click
/// opens http://localhost:<port>; with several, a menu lists them. Local
/// hosts only: a remote host's localhost is not this Mac's.
final class PortChip: NSControl {
    private let glyph = Symbol("network", size: 10, weight: .medium, color: Axo.Color.textTertiary)
    private let label = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    private let plate = CALayer()
    private(set) var ports: [UInt16] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        plate.cornerRadius = Axo.Radius.sm
        plate.cornerCurve = .continuous
        plate.opacity = 0
        plate.actions = ["bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(plate)
        addSubview(glyph)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func set(_ ports: [UInt16]) {
        guard ports != self.ports else { return }
        self.ports = ports
        isHidden = ports.isEmpty
        guard let first = ports.first else { return }
        label.stringValue = ports.count > 1 ? "\(first) +\(ports.count - 1)" : "\(first)"
        toolTip = ports.count > 1 ? "Listening on \(ports.count) ports" : "Open localhost:\(first)"
        setAccessibilityLabel(ports.count > 1 ? "Listening on ports " + ports.map(String.init).joined(separator: ", ")
            : "Open localhost:\(first)")
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: 6 + 12 + 4 + ceil(label.intrinsicContentSize.width) + 6, height: 20)
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        glyph.frame = NSRect(x: 6, y: (mid - 7).rounded(), width: 12, height: 14)
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: glyph.frame.maxX + 4, y: (mid - s.height / 2).rounded(), width: ceil(s.width), height: s.height)
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
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        if ports.count == 1 {
            Self.open(ports[0])
            return
        }
        let globe = NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        PopMenu.show(ports.map { p in
            PopMenu.Item(title: "localhost:\(p)", image: globe) { Self.open(p) }
        }, from: self)
    }

    static func open(_ port: UInt16) {
        if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
    }
}
