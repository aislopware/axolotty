import AppKit

/// A word centred on the pane, on a float surface (radius 8, 28 tall,
/// tabular meta type), in on Tick and out on Tick-out.
///
/// - "120 × 40" while the grid changes size (a window resize, a divider
///   drag, zoom), so the person can size a pane for a program that wants a
///   width; out 700 ms after the last change. Not on the first layout.
/// - "Sending report.pdf to Mac Studio · 42%" while a file dropped on a
///   far pane goes across, for as long as it takes; a failure says so in
///   the failure ink and lingers long enough to read.
final class PaneBadge: Surface {
    private let label = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    static let height: CGFloat = 28
    private var fade: Timer?

    init() {
        super.init(elevation: .float, radius: Axo.Radius.md)
        content.addSubview(label)
        label.lineBreakMode = .byTruncatingMiddle
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { fade?.invalidate() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var preferredWidth: CGFloat { Self.width(of: label.stringValue) }

    /// How wide the badge is with `text` in it, measured by a label like its
    /// own: the string alone is a few points short of what the field draws,
    /// and a text that "fits" by that count still loses its middle.
    static func width(of text: String) -> CGFloat {
        ruler.stringValue = text
        return ceil(ruler.intrinsicContentSize.width) + 2 * 12
    }

    private static let ruler = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)

    /// Shows `cols × rows` and (re)starts the fade-out clock.
    func show(cols: Int, rows: Int) { show("\(cols) × \(rows)", linger: 0.7) }

    /// Shows `text`; it goes `linger` seconds later, or stays until `hide`.
    func show(_ text: String, color: NSColor = Axo.Color.textSecondary, linger: Double?) {
        label.stringValue = text
        label.textColor = color
        needsLayout = true
        if isHidden || alphaValue < 1 {
            Axo.Motion.reveal(self, on: Axo.Motion.tick)
        }
        fade?.invalidate()
        fade = nil
        guard let linger else { return }
        fade = Timer.scheduledTimer(withTimeInterval: linger, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        fade?.invalidate()
        fade = nil
        guard !isHidden else { return }
        Axo.Motion.run(Axo.Motion.tickOut, { animator().alphaValue = 0 }) { [weak self] in
            if self?.alphaValue == 0 { self?.isHidden = true }
        }
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let s = label.intrinsicContentSize
        let w = min(ceil(s.width), bounds.width - 24)
        label.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                             width: w, height: s.height)
    }
}
