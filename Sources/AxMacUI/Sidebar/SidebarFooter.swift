import AppKit
import AxModel

/// The sidebar's bottom row (36 pt, on the frame, no rule): it anchors the
/// column at low session counts, and holds only things that act or count.
///
///     [⚙] [◐]                         ● 2 waiting  ◌ 3 working
///
/// - Leading: Settings, and the appearance (Match System → Night → Day; the
///   glyph says which).
/// - Trailing: the census across every host, each count a button that jumps
///   to the next session in that state. Nothing shows at zero.
final class SidebarFooter: NSView {
    var onJump: ((Activity) -> Void)?
    var onCycleAppearance: (() -> Void)?

    private let settings = IconButton(symbol: "gearshape", label: "Settings", size: .small)
    private let themeButton = IconButton(symbol: "circle.lefthalf.filled", label: "Appearance", size: .small)
    private let waiting = RollupButton()
    private let failed = RollupButton()
    private let working = RollupButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        settings.action = #selector((any AxActions).showSettings(_:))
        settings.tooltip = "Settings  ⌘,"
        themeButton.target = self
        themeButton.action = #selector(cycle)
        for (b, a) in [(waiting, Activity.blocked), (failed, .error), (working, .working)] {
            b.activity = a
            b.compact = true
            b.target = self
            b.action = #selector(jump(_:))
        }
        for v in [settings, themeButton, waiting, failed, working] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func cycle() { onCycleAppearance?() }
    @objc private func jump(_ sender: RollupButton) { onJump?(sender.activity) }

    func update(counts: (blocked: Int, error: Int, working: Int, done: Int)) {
        waiting.count = counts.blocked
        failed.count = counts.error
        working.count = counts.working
        needsLayout = true
    }

    func update(theme mode: Preferences.ThemeMode) {
        let (symbol, name) = switch mode {
        case .system: ("circle.lefthalf.filled", "Match System")
        case .night: ("moon", "Night")
        case .day: ("sun.max", "Day")
        }
        themeButton.symbol = symbol
        themeButton.tooltip = "Appearance: \(name)"
        themeButton.setAccessibilityValue(name)
    }

    override func layout() {
        super.layout()
        let s = Axo.Metric.controlSmall
        let mid = bounds.height / 2
        let x0 = SidebarMetric.listInset + 2
        settings.frame = NSRect(x: x0, y: (mid - s / 2).rounded(), width: s, height: s)
        themeButton.frame = NSRect(x: settings.frame.maxX + 2, y: (mid - s / 2).rounded(), width: s, height: s)
        var right = bounds.width - SidebarMetric.listInset
        for b in [working, failed, waiting] where !b.isHidden {
            let f = b.fittingSize
            b.frame = NSRect(x: right - f.width, y: (mid - f.height / 2).rounded(), width: f.width, height: f.height)
            right = b.frame.minX - 2
        }
    }
}
