import AppKit

/// Shown while the person reads scrollback and output keeps arriving: the
/// view never yanks them down, it says how much is waiting below.
///
///     ( ↓  12 new lines )
///
/// A float capsule, 26 tall, centred 10 above the sheet's bottom edge; the
/// arrow is an SF Symbol, the count tabular. Click returns to the bottom
/// (so does typing). Gone the moment the view is back at the bottom.
final class NewOutputPill: Surface {
    var onClick: (() -> Void)?
    private let arrow = Symbol("arrow.down", size: 10, weight: .semibold, color: Axo.Color.textSecondary)
    private let label = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    static let height: CGFloat = 26

    init() {
        super.init(elevation: .float, radius: Self.height / 2)
        content.addSubview(arrow)
        content.addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(lines: Int) {
        let text = lines == 1 ? "1 new line" : "\(lines) new lines"
        guard text != label.stringValue else { return }
        label.stringValue = text
        setAccessibilityLabel("\(text). Scroll to bottom")
        needsLayout = true
    }

    var preferredWidth: CGFloat { 12 + 12 + 6 + ceil(label.intrinsicContentSize.width) + 14 }

    override func layout() {
        super.layout()
        content.frame = bounds
        let mid = bounds.height / 2
        arrow.frame = NSRect(x: 12, y: (mid - 7).rounded(), width: 12, height: 14)
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: arrow.frame.maxX + 6, y: (mid - s.height / 2).rounded(), width: ceil(s.width), height: s.height)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
