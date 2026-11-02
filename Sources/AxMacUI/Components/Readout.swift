import AppKit

/// A small float that states a number while something is being dragged or
/// resized (`120 × 32`, `62 %`). Tabular figures; centred text.
final class Readout: Surface {
    private let label = Label("", font: Axo.Font.numeric, color: Axo.Color.text)
    var text: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            needsLayout = true
        }
    }

    init() {
        super.init(elevation: .float, radius: Axo.Radius.md)
        label.alignment = .center
        content.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let s = label.intrinsicContentSize
        return NSSize(width: ceil(s.width) + Axo.Space.lg * 2, height: 28)
    }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: ((bounds.height - s.height) / 2).rounded(), width: bounds.width, height: s.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
