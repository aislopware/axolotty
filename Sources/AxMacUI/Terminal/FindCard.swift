import AppKit

/// Find in the pane's scrollback: a small card in the pane's top-right corner
/// (Ghostty's placement), so the rows it covers are the oldest on screen and
/// the match it scrolls to is never under it.
///
///     ⌕ [needle            ]  3 of 12  ⌃ ⌄ ✕
///
/// Matches are painted by the terminal itself, as cell grounds under the text
/// (every match light, the current one strong), so they read like a
/// highlighter, not a box drawn over the glyphs. Matching is literal, ASCII
/// letters ignore case, and it follows the live screen while open.
///
/// Keys: return next (older), ⇧return previous, ↑/↓ the same, esc closes.
/// ⌘G / ⇧⌘G work from the terminal too (the card stays open).
final class FindCard: Surface, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    /// `true`: toward older output (up the screen), as return does.
    var onStep: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    static let size = NSSize(width: 304, height: 34)

    private let glyph = Symbol("magnifyingglass", size: 12, weight: .medium, color: Axo.Color.textTertiary)
    let field = SearchField(placeholder: "Find", font: Axo.Font.body)
    private let count = Label("", font: Axo.Font.meta, color: Axo.Color.textTertiary)
    private let prev = IconButton(symbol: "chevron.up", label: "Previous Match", size: .small)
    private let next = IconButton(symbol: "chevron.down", label: "Next Match", size: .small)
    private let close = IconButton(symbol: "xmark", label: "Close Find", size: .small)

    init() {
        super.init(elevation: .float, radius: 10)
        field.delegate = self
        count.alignment = .right
        prev.tooltip = "Previous Match  ⇧⌘G"
        next.tooltip = "Next Match  ⌘G"
        close.tooltip = "Close  ⎋"
        prev.target = self
        prev.action = #selector(stepNewer)
        next.target = self
        next.action = #selector(stepOlder)
        close.target = self
        close.action = #selector(dismiss)
        for v in [glyph, field, count, prev, next, close] as [NSView] { content.addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var needle: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// "3 of 12", "No matches", or nothing while the field is empty.
    func show(total: Int, index: Int?) {
        let text: String
        if needle.isEmpty {
            text = ""
        } else if total == 0 {
            text = "No matches"
        } else if let index {
            text = "\(index + 1) of \(total)"
        } else {
            text = total == 1 ? "1 match" : "\(total) matches"
        }
        guard text != count.stringValue else { return }
        count.stringValue = text
        count.textColor = total == 0 && !needle.isEmpty ? Axo.Color.textSecondary : Axo.Color.textTertiary
        prev.isEnabled = total > 0
        next.isEnabled = total > 0
        setAccessibilityValue(text)
        needsLayout = true
    }

    @objc private func stepOlder() { onStep?(true) }
    @objc private func stepNewer() { onStep?(false) }
    @objc private func dismiss() { onClose?() }

    // MARK: Field

    func controlTextDidChange(_ obj: Notification) { onChange?(needle) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onStep?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
        case #selector(NSResponder.moveUp(_:)):
            onStep?(false)
        case #selector(NSResponder.moveDown(_:)):
            onStep?(true)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        content.frame = bounds
        let h = bounds.height, mid = h / 2
        let s = Axo.Metric.controlSmall
        var right = bounds.width - 6
        for b in [close, next, prev] {
            b.frame = NSRect(x: right - s, y: (mid - s / 2).rounded(), width: s, height: s)
            right = b.frame.minX
        }
        let cw = count.stringValue.isEmpty ? 0 : ceil(count.intrinsicContentSize.width)
        let ch = count.intrinsicContentSize.height
        count.frame = NSRect(x: right - 6 - cw, y: (mid - ch / 2).rounded(), width: cw, height: ch)
        glyph.frame = NSRect(x: 11, y: (mid - 7).rounded(), width: 14, height: 14)
        let fx = glyph.frame.maxX + 6
        let fh = field.intrinsicContentSize.height
        let fieldRight = (cw > 0 ? count.frame.minX - 8 : right - 4)
        field.frame = NSRect(x: fx, y: (mid - fh / 2).rounded(), width: max(40, fieldRight - fx), height: fh)
    }
}
