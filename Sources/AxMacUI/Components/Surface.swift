import AppKit
import QuartzCore

/// The one rounded shape every surface uses: a continuous-corner ("squircle")
/// rect. Fill, ring, rim and shadow all come from this path, so their edges
/// coincide exactly; nothing relies on a window's or layer's own idea of its
/// corners.
nonisolated enum ContinuousRect {
    /// Continuous corners (the iOS 7+ curve: three cubics per corner, 1.528·r
    /// of edge consumed). Falls back to a capsule when r ≥ min(w,h)/2.
    static func path(_ rect: CGRect, radius r0: CGFloat) -> CGPath {
        let p = CGMutablePath()
        guard rect.width > 0, rect.height > 0 else { return p }
        let limit = min(rect.width, rect.height) / 2
        if r0 >= limit - 0.01 {
            p.addRoundedRect(in: rect, cornerWidth: limit, cornerHeight: limit)
            return p
        }
        let r = min(r0, limit / 1.52866483)
        guard r > 0 else {
            p.addRect(rect)
            return p
        }
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        p.move(to: pt(x0 + 1.52866483 * r, y0))
        // top edge → top-right corner
        p.addLine(to: pt(x1 - 1.52866483 * r, y0))
        p.addCurve(to: pt(x1 - 0.63149399 * r, y0 + 0.07491100 * r),
                   control1: pt(x1 - 1.08849323 * r, y0), control2: pt(x1 - 0.86840689 * r, y0))
        p.addCurve(to: pt(x1 - 0.07491100 * r, y0 + 0.63149399 * r),
                   control1: pt(x1 - 0.37282392 * r, y0 + 0.16905899 * r), control2: pt(x1 - 0.16905899 * r, y0 + 0.37282392 * r))
        p.addCurve(to: pt(x1, y0 + 1.52866483 * r),
                   control1: pt(x1, y0 + 0.86840689 * r), control2: pt(x1, y0 + 1.08849323 * r))
        // right edge → bottom-right
        p.addLine(to: pt(x1, y1 - 1.52866483 * r))
        p.addCurve(to: pt(x1 - 0.07491100 * r, y1 - 0.63149399 * r),
                   control1: pt(x1, y1 - 1.08849323 * r), control2: pt(x1, y1 - 0.86840689 * r))
        p.addCurve(to: pt(x1 - 0.63149399 * r, y1 - 0.07491100 * r),
                   control1: pt(x1 - 0.16905899 * r, y1 - 0.37282392 * r), control2: pt(x1 - 0.37282392 * r, y1 - 0.16905899 * r))
        p.addCurve(to: pt(x1 - 1.52866483 * r, y1),
                   control1: pt(x1 - 0.86840689 * r, y1), control2: pt(x1 - 1.08849323 * r, y1))
        // bottom edge → bottom-left
        p.addLine(to: pt(x0 + 1.52866483 * r, y1))
        p.addCurve(to: pt(x0 + 0.63149399 * r, y1 - 0.07491100 * r),
                   control1: pt(x0 + 1.08849323 * r, y1), control2: pt(x0 + 0.86840689 * r, y1))
        p.addCurve(to: pt(x0 + 0.07491100 * r, y1 - 0.63149399 * r),
                   control1: pt(x0 + 0.37282392 * r, y1 - 0.16905899 * r), control2: pt(x0 + 0.16905899 * r, y1 - 0.37282392 * r))
        p.addCurve(to: pt(x0, y1 - 1.52866483 * r),
                   control1: pt(x0, y1 - 0.86840689 * r), control2: pt(x0, y1 - 1.08849323 * r))
        // left edge → top-left
        p.addLine(to: pt(x0, y0 + 1.52866483 * r))
        p.addCurve(to: pt(x0 + 0.07491100 * r, y0 + 0.63149399 * r),
                   control1: pt(x0, y0 + 1.08849323 * r), control2: pt(x0, y0 + 0.86840689 * r))
        p.addCurve(to: pt(x0 + 0.63149399 * r, y0 + 0.07491100 * r),
                   control1: pt(x0 + 0.16905899 * r, y0 + 0.37282392 * r), control2: pt(x0 + 0.37282392 * r, y0 + 0.16905899 * r))
        p.addCurve(to: pt(x0 + 1.52866483 * r, y0),
                   control1: pt(x0 + 0.86840689 * r, y0), control2: pt(x0 + 1.08849323 * r, y0))
        p.closeSubpath()
        return p
    }
}

/// A shape layer that fills (and optionally strokes) one continuous rect.
/// Strokes are drawn *inside* the edge so a ring never grows the shape.
/// The backing scale layers we create render at. AppKit keeps the layers it
/// owns (view backing layers) in step with the window's screen, but never the
/// sublayers we add: those default to 1× and rasterise soft on Retina. Every
/// layer we make starts at this scale (`crisp()`), and `ShellView` re-syncs
/// the whole tree when the window changes screens.
nonisolated enum LayerScale {
    nonisolated(unsafe) static var current: CGFloat = 2
}

extension CALayer {
    /// Renders at the current backing scale (see `LayerScale`).
    @discardableResult
    nonisolated func crisp() -> Self {
        contentsScale = LayerScale.current
        return self
    }

    /// Re-applies `scale` to this tree's self-made layers (view-owned layers,
    /// whose delegate is a view, are AppKit's to manage).
    func syncContentsScale(_ scale: CGFloat) {
        if !(delegate is NSView), contentsScale != scale { contentsScale = scale }
        sublayers?.forEach { $0.syncContentsScale(scale) }
        mask?.syncContentsScale(scale)
    }
}

nonisolated final class ShapeLayer: CAShapeLayer {
    var radius: CGFloat = 0 { didSet { reshape() } }
    var inset: CGFloat = 0 { didSet { reshape() } }

    override init() {
        super.init()
        contentsScale = LayerScale.current
        fillColor = nil
        strokeColor = nil
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var bounds: CGRect { didSet { reshape() } }

    private func reshape() {
        let d = inset + lineWidth / 2
        let r = bounds.insetBy(dx: d, dy: d)
        path = ContinuousRect.path(r, radius: max(0, radius - d))
    }

    override var lineWidth: CGFloat { didSet { reshape() } }
}

/// A design-system surface: fill, inner hairline ring, a lit top rim (dark),
/// an outer contact ring (dark floats) and drop shadows, all from one shape.
/// Content goes in `content`, which is clipped to nothing: give it padding
/// at least the corner radius minus the inner radius (concentric rule).
class Surface: NSView, DesignRefreshable {
    let content = FlippedView()
    var elevation: Axo.Elevation { didSet { restyle() } }
    var radius: CGFloat { didSet { needsLayout = true } }
    /// Overrides the plane colour (defaults: elevated for float/rest, none for flat).
    var fill: NSColor? { didSet { restyle() } }
    var ringColor: NSColor? { didSet { restyle() } }

    private let shadows = [CALayer(), CALayer()]
    private let outer = CALayer()
    private let body = ShapeLayer()
    private let ring = ShapeLayer()
    private let rim = ShapeLayer()
    private let rimMask = CAGradientLayer().crisp()

    init(elevation: Axo.Elevation, radius: CGFloat) {
        self.elevation = elevation
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = layer!
        root.masksToBounds = false
        for s in shadows + [outer] {
            s.shadowColor = .black
            s.shadowOffset = .zero
            root.addSublayer(s)
        }
        root.addSublayer(body)
        root.addSublayer(ring)
        rim.mask = rimMask
        rimMask.colors = [CGColor.black, CGColor.clear]
        root.addSublayer(rim)
        addSubview(content)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { restyle() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    func designDidChange() { restyle() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
        restyle()
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { restyleResolved() }
    }

    private func restyleResolved() {
        let t = tokens
        let px = hairline
        Axo.Motion.still {
            let plane: NSColor? = fill ?? (elevation == .flat ? nil : Axo.Color.elevated)
            body.fillColor = plane?.cgColor
            let ringInk: NSColor? = ringColor ?? (elevation == .flat ? nil : t.ring.ns)
            ring.lineWidth = px
            ring.strokeColor = ringInk?.cgColor
            rim.lineWidth = px
            rim.strokeColor = elevation == .flat ? nil : (elevation == .float ? t.rim : t.rim.a(t.rim.alpha * 0.66)).cg
            rim.isHidden = t.rim.alpha == 0 || elevation == .flat
            switch elevation {
            case .flat:
                for s in shadows { s.shadowOpacity = 0 }
                outer.shadowOpacity = 0
            case .rest:
                apply(t.restShadow, to: shadows[0])
                shadows[1].shadowOpacity = 0
                outer.shadowOpacity = 0
            case .float:
                for (i, s) in shadows.enumerated() {
                    if i < t.floatShadows.count { apply(t.floatShadows[i], to: s) } else { s.shadowOpacity = 0 }
                }
                outer.shadowOpacity = Float(t.outerRing.alpha)
                outer.shadowRadius = 0
            }
        }
    }

    private func apply(_ s: Shadow, to l: CALayer) {
        l.shadowOpacity = s.alpha
        l.shadowRadius = s.blur / 2
        // Flipped view: positive y is down, which is where shadows fall.
        l.shadowOffset = CGSize(width: 0, height: s.y)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let px = hairline
        Axo.Motion.still {
            let path = ContinuousRect.path(b, radius: radius)
            for s in shadows {
                s.frame = b
                s.shadowPath = path
            }
            outer.frame = b
            outer.shadowPath = ContinuousRect.path(b.insetBy(dx: -px, dy: -px), radius: radius + px)
            for l in [body, ring, rim] as [ShapeLayer] {
                l.frame = b
                l.radius = radius
            }
            rim.inset = 0
            rimMask.frame = b
            let edge = min(1, (radius + 2) / max(1, b.height))
            rimMask.startPoint = CGPoint(x: 0.5, y: 0)
            rimMask.endPoint = CGPoint(x: 0.5, y: edge)
        }
        content.frame = b
    }
}

/// A flipped plain container.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A one-device-pixel rule (horizontal when wider than tall).
final class Rule: NSView {
    var color: NSColor = Axo.Color.border { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    convenience init(_ color: NSColor) {
        self.init(frame: .zero)
        self.color = color
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }

    /// Use this thickness for the rule's frame.
    var thickness: CGFloat { hairline }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
