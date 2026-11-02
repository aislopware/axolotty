import AppKit
import AxModel
import AxProtocol

/// The band's diff chip: "+412 −96" in 11 pt tabular green and red, on a
/// hover plate. Hidden when the tree is clean or not a repository. A click
/// opens the project in the editor, where the diff is read.
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
        toolTip = "Open in Editor  ⌥⌘O"
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
