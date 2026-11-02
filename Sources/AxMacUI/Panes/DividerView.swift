import AppKit
import AxModel

/// The hit area (9 pt) around one split divider. Nothing is drawn at rest:
/// the 6 pt gutter of frame between two sheets is the divider. Hover shows a
/// 2 × 28 pt `borderStrong` grip pill in the gutter's centre; dragging tints
/// it accent and stretches it to the full run so the edge being moved reads.
final class DividerView: NSView {
    var divider: SplitTree.Divider
    var onDrag: ((DragPhase, CGFloat) -> Void)?

    enum DragPhase { case began, changed, ended }

    private let line = CALayer()
    private var hovering = false { didSet { restyle(animated: true) } }
    private var dragging = false { didSet { restyle(animated: false) } }
    private var dragStart: CGFloat = 0

    init(_ divider: SplitTree.Divider) {
        self.divider = divider
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(line)
        restyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var vertical: Bool { divider.axis == .horizontal }  // a horizontal split has a vertical line

    override func layout() {
        super.layout()
        restyle(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle(animated: false)
    }

    private func restyle(animated: Bool) {
        let thick: CGFloat = 2
        var color = Axo.Color.borderStrong
        if dragging { color = Axo.Color.accent.withAlphaComponent(0.8) }
        line.opacity = hovering || dragging ? 1 : 0
        line.cornerRadius = thick / 2
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Axo.Motion.reduced)
        CATransaction.setAnimationDuration(hovering ? Axo.Motion.tick.duration : Axo.Motion.tickOut.duration)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            line.backgroundColor = color.cgColor
        }
        // Snap the line's offset to device pixels (at 2× a centred half-point
        // hairline would otherwise straddle two pixels and blur).
        let scale = 1 / hairline
        let snap = { (v: CGFloat) in (v * scale).rounded(.down) / scale }
        let across = vertical ? bounds.width : bounds.height
        let along = vertical ? bounds.height : bounds.width
        let at = snap((across - thick) / 2)
        let length = dragging ? along : min(28, along)
        let start = snap((along - length) / 2)
        line.frame = vertical
            ? NSRect(x: at, y: start, width: thick, height: length)
            : NSRect(x: start, y: at, width: length, height: thick)
        CATransaction.commit()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: vertical ? .columnResize : .rowResize)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func position(_ event: NSEvent) -> CGFloat {
        let p = superview?.convert(event.locationInWindow, from: nil) ?? .zero
        return vertical ? p.x : p.y
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDrag?(.ended, .nan)  // double-click: equalize
            return
        }
        dragging = true
        dragStart = position(event)
        onDrag?(.began, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        onDrag?(.changed, position(event) - dragStart)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDrag?(.ended, position(event) - dragStart)
    }
}
