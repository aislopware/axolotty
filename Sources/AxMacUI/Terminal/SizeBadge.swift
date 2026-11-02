import AppKit

/// "120 × 40", centred on the pane while its grid changes size (a window
/// resize, a divider drag, zoom), so the person can size a pane for a
/// program that wants a width. Not on the pane's first layout. A float
/// surface, radius 8, 28 tall, tabular meta type; in on Tick, out 700 ms
/// after the last change. Also says what a pane command just did ("Copied
/// 42 lines"), where the eyes are, without a toast.
final class SizeBadge: Surface {
    private let label = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    static let height: CGFloat = 28
    private var fade: Timer?

    init() {
        super.init(elevation: .float, radius: Axo.Radius.md)
        content.addSubview(label)
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { fade?.invalidate() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var preferredWidth: CGFloat { ceil(label.intrinsicContentSize.width) + 2 * 12 }

    /// Shows `cols × rows` and (re)starts the fade-out clock.
    func show(cols: Int, rows: Int) { show("\(cols) × \(rows)") }

    func show(_ text: String, for seconds: TimeInterval = 0.7) {
        label.stringValue = text
        needsLayout = true
        if isHidden || alphaValue < 1 {
            isHidden = false
            Axo.Motion.run(Axo.Motion.tick) { animator().alphaValue = 1 }
        }
        fade?.invalidate()
        fade = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Axo.Motion.run(Axo.Motion.tickOut, { self.animator().alphaValue = 0 }) { [weak self] in
                    if self?.alphaValue == 0 { self?.isHidden = true }
                }
            }
        }
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: ((bounds.width - ceil(s.width)) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                             width: ceil(s.width), height: s.height)
    }
}
