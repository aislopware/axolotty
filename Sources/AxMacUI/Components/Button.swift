import AppKit
import AxModel
import QuartzCore

/// The interactive plate every pressable component shares: a continuous rect
/// whose fill follows rest → hover → pressed (→ selected). Hover and press
/// appear instantly; leaving and releasing fade on the Tick beat (Raycast,
/// Linear, Otty all do this: feedback is instant, recovery is soft).
@MainActor final class Plate {
    let layer = ShapeLayer()
    var rest: NSColor?
    var hover: NSColor? = Axo.Color.hover
    var pressed: NSColor? = Axo.Color.pressed
    var selected: NSColor? = Axo.Color.selected

    enum State: Equatable { case rest, hover, pressed, selected, selectedHover }
    private(set) var state: State = .rest

    init(radius: CGFloat) {
        layer.radius = radius
    }

    func set(_ s: State, appearance: NSAppearance, animated: Bool = true) {
        let prev = state
        state = s
        let color: NSColor? = switch s {
        case .rest: rest
        case .hover: hover ?? rest
        case .pressed: pressed ?? hover ?? rest
        case .selected: selected
        case .selectedHover: Axo.Color.selectedHover
        }
        var cg: CGColor?
        appearance.performAsCurrentDrawingAppearance { cg = color?.cgColor }
        // Rising (rest→hover→pressed) is instant; falling back is soft.
        let rising = rank(s) > rank(prev)
        if animated, !rising, prev != s {
            let a = Axo.Motion.tick.animation("fillColor")
            a.fromValue = layer.presentation()?.fillColor ?? layer.fillColor
            Axo.Motion.still { layer.fillColor = cg }
            layer.add(a, forKey: "fill")
        } else {
            Axo.Motion.still {
                layer.removeAnimation(forKey: "fill")
                layer.fillColor = cg
            }
        }
    }

    /// Re-resolves the current state's colour (appearance or theme change).
    func refresh(_ appearance: NSAppearance) { set(state, appearance: appearance, animated: false) }

    private func rank(_ s: State) -> Int {
        switch s {
        case .rest: 0
        case .hover: 1
        case .selected: 2
        case .selectedHover: 3
        case .pressed: 4
        }
    }
}

/// A design-system button. Variants follow the research consensus:
/// - `.primary`: the neutral solid with inverted ink, one per surface.
/// - `.secondary`: a faint ink fill with a hairline ring.
/// - `.ghost`: no fill at rest; hover and press plates only.
/// - `.danger`: ghost in the error ink with an error wash on hover.
/// Sizes: 22 / 28 / 32. Icon-only buttons are square.
class Button: NSControl, DesignRefreshable {
    enum Variant { case primary, secondary, ghost, danger }
    enum Size {
        case small, regular, large

        var height: CGFloat {
            switch self {
            case .small: Axo.Metric.controlSmall
            case .regular: Axo.Metric.control
            case .large: Axo.Metric.controlLarge
            }
        }

        var font: NSFont {
            switch self {
            case .small: Axo.Font.smallStrong
            case .regular, .large: Axo.Font.bodyStrong
            }
        }

        var padding: CGFloat { self == .small ? Axo.Space.md : Axo.Space.lg }
        var glyph: CGFloat { self == .small ? 12 : Axo.Metric.iconGlyph }
        var radius: CGFloat { self == .small ? Axo.Radius.sm - 1 : Axo.Radius.sm }
    }

    let variant: Variant
    let size: Size
    private let plate: Plate
    private let ring = ShapeLayer()
    private let focus = ShapeLayer()
    private let icon = NSImageView()
    private let label = Label("")
    private var hovering = false
    private var pressing = false

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    var symbol: String? { didSet { applySymbol() } }

    private func applySymbol() {
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Toggled look (e.g. a panel toggle while its panel is open).
    var isSelected = false { didSet { syncPlate(animated: true) } }

    /// Shown in the design-system tooltip after the hover delay.
    var tooltip: String?

    init(_ title: String = "", symbol: String? = nil, variant: Variant = .secondary, size: Size = .regular) {
        self.variant = variant
        self.size = size
        plate = Plate(radius: size.radius)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(plate.layer)
        layer?.addSublayer(ring)
        layer?.addSublayer(focus)
        focus.isHidden = true
        icon.imageScaling = .scaleNone
        icon.symbolConfiguration = .init(pointSize: size.glyph, weight: .medium)
        label.font = size.font
        addSubview(icon)
        addSubview(label)
        self.title = title
        self.symbol = symbol
        applySymbol()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        configurePlate()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var iconOnly: Bool { label.isHidden }

    override var intrinsicContentSize: NSSize {
        let h = size.height
        if iconOnly { return NSSize(width: h, height: h) }
        var w = size.padding * 2 + ceil(label.intrinsicContentSize.width) + 2
        if !icon.isHidden { w += size.glyph + Axo.Space.sm - 2 }
        return NSSize(width: w, height: h)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    private func configurePlate() {
        switch variant {
        case .primary:
            plate.rest = Axo.Color.solid
            plate.hover = Axo.Color.solid.withAlphaComponent(0.88)
            plate.pressed = Axo.Color.solid.withAlphaComponent(0.76)
        case .secondary:
            plate.rest = Axo.Color.hover
            plate.hover = Axo.Color.selected
            plate.pressed = Axo.Color.pressed
        case .ghost:
            plate.rest = nil
            plate.hover = Axo.Color.hover
            plate.pressed = Axo.Color.pressed
        case .danger:
            plate.rest = nil
            plate.hover = Axo.Color.statusWash(.error)
            plate.pressed = Axo.Color.status(.error).withAlphaComponent(0.24)
        }
        syncPlate(animated: false)
    }

    private var ink: NSColor {
        guard isEnabled else { return Axo.Color.textDisabled }
        switch variant {
        case .primary: return Axo.Color.solidInk
        case .secondary: return Axo.Color.text
        case .ghost: return hovering || pressing || isSelected ? Axo.Color.text : Axo.Color.textSecondary
        case .danger: return Axo.Color.status(.error)
        }
    }

    private func syncPlate(animated: Bool) {
        let s: Plate.State = !isEnabled ? .rest
            : pressing && hovering ? .pressed
            : isSelected ? (hovering ? .selectedHover : .selected)
            : hovering ? .hover : .rest
        plate.set(s, appearance: effectiveAppearance, animated: animated)
        icon.contentTintColor = ink
        label.textColor = ink
    }

    override var isEnabled: Bool { didSet { syncPlate(animated: false) } }

    // MARK: Drawing

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func designDidChange() { restyle() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Axo.Motion.still {
                ring.lineWidth = hairline
                ring.strokeColor = variant == .secondary ? Axo.Color.border.cgColor : nil
                focus.lineWidth = 2
                focus.strokeColor = Axo.Color.accent.withAlphaComponent(0.7).cgColor
            }
        }
        plate.refresh(effectiveAppearance)
        icon.contentTintColor = ink
        label.textColor = ink
    }

    override func layout() {
        super.layout()
        let b = bounds
        Axo.Motion.still {
            for l in [plate.layer, ring] {
                l.frame = b
                l.radius = size.radius
            }
            // 2 pt gap, then a 2 pt ring (keyboard focus only).
            focus.frame = b.insetBy(dx: -4, dy: -4)
            focus.radius = size.radius + 4
        }
        let g = size.glyph + 4
        if iconOnly {
            icon.frame = NSRect(x: (b.width - g) / 2, y: (b.height - g) / 2, width: g, height: g)
            return
        }
        let ls = label.intrinsicContentSize
        var x = size.padding
        if !icon.isHidden {
            icon.frame = NSRect(x: x - 2, y: (b.height - g) / 2, width: g, height: g)
            x += size.glyph + Axo.Space.sm - 2
        }
        label.frame = NSRect(x: x, y: ((b.height - ls.height) / 2).rounded(), width: max(0, b.width - x - size.padding),
                             height: ls.height)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        syncPlate(animated: true)
        if let tooltip { Tooltip.shared.hover(self, text: tooltip) }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        syncPlate(animated: true)
        Tooltip.shared.leave(self)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        Tooltip.shared.dismiss()
        pressing = true
        hovering = true
        syncPlate(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressing else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != hovering {
            hovering = inside
            syncPlate(animated: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hovering = inside
        syncPlate(animated: true)
        if inside { fire() }
    }

    private func fire() {
        guard isEnabled, let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    // MARK: Keyboard (full keyboard access only)

    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool {
        focus.isHidden = false
        return true
    }

    override func resignFirstResponder() -> Bool {
        focus.isHidden = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { fire() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        fire()
        return true
    }
}

/// A square ghost button holding one SF Symbol (28 pt target, 14 pt glyph).
final class IconButton: Button {
    init(symbol: String, label: String, size: Size = .regular) {
        super.init("", symbol: symbol, variant: .ghost, size: size)
        setAccessibilityLabel(label)
        tooltip = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
