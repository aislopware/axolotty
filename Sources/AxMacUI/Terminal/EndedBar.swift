import AppKit
import AxModel

/// Shown on a pane whose program has ended (a clean exit closes the pane;
/// this is everything else). The old screen stays readable above it.
///
///     ( ●  Exited with code 3      ⟳ Restart  ↩ )
///
/// A float surface, radius 10, 36 tall, centred 12 above the pane's bottom
/// edge: the error dot, what happened in caption type, then a small
/// secondary button and its key. Return restarts the same command in the same
/// directory in this slot; ⌘W closes the pane as always.
final class EndedBar: Surface {
    var onRestart: (() -> Void)?
    private let dot = CALayer()
    private let label = Label("", font: Axo.Font.caption, color: Axo.Color.textSecondary)
    private let restart = Button("Restart", symbol: "arrow.clockwise", variant: .secondary, size: .small)
    private let key = Keycaps()
    static let height: CGFloat = 36

    init() {
        super.init(elevation: .float, radius: Axo.Radius.lg)
        content.wantsLayer = true
        dot.cornerRadius = 3
        content.layer?.addSublayer(dot)
        content.addSubview(label)
        restart.target = self
        restart.action = #selector(restartClicked)
        restart.tooltip = "Run it again here"
        content.addSubview(restart)
        key.chord = "↩"
        content.addSubview(key)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// What ended it, in words: a shell's 128 + signal is named as the signal is known
    /// (⌃C is a person stopping it, a segmentation fault a crash), anything else by its code.
    static func describe(_ code: Int32) -> String {
        if code < 0 { return "Couldn’t start" }
        guard code > 128, code < 160 else { return "Exited with code \(code)" }
        return switch code - 128 {
        case SIGHUP: "Hung up"
        case SIGINT: "Stopped with ⌃C"
        case SIGQUIT: "Quit with ⌃\\"
        case SIGKILL: "Killed"
        case SIGTERM: "Terminated"
        case SIGSEGV: "Crashed: segmentation fault"
        case SIGBUS: "Crashed: bus error"
        case SIGABRT: "Crashed: aborted"
        case SIGILL: "Crashed: illegal instruction"
        case SIGTRAP: "Crashed: trap"
        case let n: "Ended by signal \(n)"
        }
    }

    /// Whether the person ended it (⌃C, ⌃\\): said in grey, not as a failure.
    static func byHand(_ code: Int32) -> Bool { code == 128 + SIGINT || code == 128 + SIGQUIT }

    private var code: Int32 = 0

    func set(code: Int32) {
        self.code = code
        label.stringValue = Self.describe(code)
        setAccessibilityLabel(label.stringValue + ". Press Return to restart")
        needsLayout = true
    }

    var preferredWidth: CGFloat {
        14 + 6 + 8 + ceil(label.intrinsicContentSize.width) + 16 + restart.intrinsicContentSize.width + 6
            + key.intrinsicContentSize.width + 8
    }

    override func layout() {
        super.layout()
        content.frame = bounds
        let mid = bounds.height / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = NSRect(x: 14, y: (mid - 3).rounded(), width: 6, height: 6)
        effectiveAppearance.performAsCurrentDrawingAppearance { dot.backgroundColor = (Self.byHand(code) ? Axo.Color.textTertiary : Axo.Color.status(.error)).cgColor }
        CATransaction.commit()
        let ls = label.intrinsicContentSize
        label.frame = NSRect(x: dot.frame.maxX + 8, y: (mid - ls.height / 2).rounded(), width: ceil(ls.width), height: ls.height)
        let ks = key.intrinsicContentSize
        key.frame = NSRect(x: bounds.width - 8 - ks.width, y: (mid - ks.height / 2).rounded(), width: ks.width, height: ks.height)
        let bs = restart.intrinsicContentSize
        restart.frame = NSRect(x: key.frame.minX - 6 - bs.width, y: (mid - bs.height / 2).rounded(), width: bs.width, height: bs.height)
    }

    @objc private func restartClicked() { onRestart?() }
}
