import AppKit
import QuartzCore

/// The Axolotty mark: a wide head with knocked-out eyes and three gill strokes
/// a side, drawn as geometry (no artwork), so it scales to the app icon and
/// stays crisp at 1×. The smile is cut out of the head only from 28 pt up;
/// smaller it muddies the eyes.
///
/// Unit geometry (y down, mirrored per side):
/// - head: ellipse x 0.22…0.78, y 0.42…0.78
/// - eyes: 0.07 circles at (0.38, 0.565) and (0.62, 0.565), even-odd holes
/// - gills: stroke 0.075, round caps; roots (0.32, 0.46), (0.26, 0.53),
///   (0.24, 0.62) at 52°, 24°, −2° above the outward horizontal, lengths
///   0.22, 0.21, 0.18
/// - smile: quad (0.44, 0.665) → (0.56, 0.665) through (0.50, 0.705), 0.035
nonisolated enum AxoMarkGeometry {
    static func head(_ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: 0.22 * s, y: 0.42 * s, width: 0.56 * s, height: 0.36 * s))
        for ex in [0.38, 0.62] as [CGFloat] {
            p.addEllipse(in: CGRect(x: (ex - 0.035) * s, y: 0.53 * s, width: 0.07 * s, height: 0.07 * s))
        }
        return p
    }

    static func gills(_ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let spec: [(x: CGFloat, y: CGFloat, deg: CGFloat, len: CGFloat)] =
            [(0.32, 0.46, 52, 0.22), (0.26, 0.53, 24, 0.21), (0.24, 0.62, -2, 0.18)]
        for side in [-1.0, 1.0] as [CGFloat] {
            for g in spec {
                let rx = side < 0 ? g.x : 1 - g.x
                let r = g.deg * .pi / 180
                p.move(to: CGPoint(x: rx * s, y: g.y * s))
                p.addLine(to: CGPoint(x: (rx + side * cos(r) * g.len) * s, y: (g.y - sin(r) * g.len) * s))
            }
        }
        return p
    }

    static func smile(_ s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0.44 * s, y: 0.665 * s))
        p.addQuadCurve(to: CGPoint(x: 0.56 * s, y: 0.665 * s), control: CGPoint(x: 0.50 * s, y: 0.705 * s))
        return p
    }

    static let gillWidth: CGFloat = 0.075
    static let smileWidth: CGFloat = 0.035
}

/// The mark as a view, in one ink (the accent by default). The smile is cut
/// in `cutout` (the surface it sits on).
final class AxoMarkView: NSView {
    var ink: NSColor = Axo.Color.accent { didSet { restyle() } }
    var cutout: NSColor = Axo.Color.ground { didSet { restyle() } }

    private let gills = CAShapeLayer()
    private let head = CAShapeLayer()
    private let smile = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        gills.lineCap = .round
        gills.fillColor = nil
        head.fillRule = .evenOdd
        smile.lineCap = .round
        smile.fillColor = nil
        for l in [gills, head, smile] {
            l.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(l)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let s = min(bounds.width, bounds.height)
        let origin = CGPoint(x: ((bounds.width - s) / 2).rounded(), y: ((bounds.height - s) / 2).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [gills, head, smile] {
            l.frame = CGRect(origin: origin, size: CGSize(width: s, height: s))
            l.contentsScale = window?.backingScaleFactor ?? LayerScale.current
        }
        // A flipped view's sublayers are y-down, as the geometry is authored.
        gills.path = AxoMarkGeometry.gills(s)
        head.path = AxoMarkGeometry.head(s)
        smile.path = AxoMarkGeometry.smile(s)
        gills.lineWidth = AxoMarkGeometry.gillWidth * s
        smile.lineWidth = max(1, AxoMarkGeometry.smileWidth * s)
        smile.isHidden = s < 28
        CATransaction.commit()
        restyle()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gills.strokeColor = effectiveAppearance.resolve(ink)
        head.fillColor = effectiveAppearance.resolve(ink)
        smile.strokeColor = effectiveAppearance.resolve(cutout)
        CATransaction.commit()
    }
}
