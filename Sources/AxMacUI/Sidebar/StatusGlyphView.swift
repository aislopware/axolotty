import AppKit
import AxModel
import QuartzCore

/// The 16 pt status mark. Two shapes only, so the sidebar never turns into a
/// column of coloured icons:
///
/// - idle: nothing
/// - working: a 10 pt spinner in the brand magenta (a 22 % track plus a
///   quarter arc, one turn per 0.9 s). Magenta means *working*, and only
///   that (design-system §1.4). A determinate arc when progress is known.
/// - waiting / failed / done: one 6 pt dot. Colour says which: amber needs
///   input, red failed, green finished-unseen. Dots never pulse.
final class StatusGlyphView: NSView {
    var activity: Activity = .idle {
        didSet { if activity != oldValue { rebuild() } }
    }

    /// Determinate progress (0…1) turns the working ring into an arc.
    var progress: Double? {
        didSet { if progress != oldValue, activity == .working { rebuild() } }
    }

    private let track = CAShapeLayer().crisp()
    private let mark = CAShapeLayer().crisp()
    private let dot = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in [track, mark] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        layer?.addSublayer(dot)
        setAccessibilityElement(false)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Axo.Metric.statusSlot, height: Axo.Metric.statusSlot) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild()  // CA animations are dropped when a layer leaves the tree
    }

    /// The dot colour for a state that wants a look.
    static func dotColor(_ a: Activity) -> NSColor {
        switch a {
        case .blocked, .error, .done: Axo.Color.status(a)
        default: Axo.Color.textSecondary
        }
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let b = bounds
        let c = CGPoint(x: b.midX, y: b.midY)
        mark.removeAllAnimations()
        mark.transform = CATransform3DIdentity
        let spinning = activity == .working
        track.isHidden = !spinning
        mark.isHidden = !spinning
        dot.isHidden = spinning || activity == .idle

        if spinning {
            let d: CGFloat = 10
            let f = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            let ring = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d).insetBy(dx: 0.75, dy: 0.75), transform: nil)
            for l in [track, mark] {
                l.frame = f
                l.path = ring
                l.lineWidth = 1.5
            }
            track.strokeColor = effectiveAppearance.resolve(Axo.Color.status(.working).withAlphaComponent(0.22))
            mark.strokeColor = effectiveAppearance.resolve(Axo.Color.status(.working))
            mark.strokeStart = 0
            if let p = progress {
                mark.strokeEnd = max(0.04, min(1, p))
                mark.transform = CATransform3DMakeRotation(.pi / 2, 0, 0, 1)
            } else {
                mark.strokeEnd = 0.28
                if !Axo.Motion.reduced {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = -2 * Double.pi
                    spin.duration = 0.9
                    spin.repeatCount = .infinity
                    spin.isRemovedOnCompletion = false
                    mark.add(spin, forKey: "spin")
                }
            }
        } else if activity != .idle {
            let d: CGFloat = 6
            dot.frame = CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = effectiveAppearance.resolve(Self.dotColor(activity))
        }
    }

    /// VoiceOver phrase for the state ("agent waiting for input").
    static func phrase(_ a: Activity) -> String? {
        switch a {
        case .idle: nil
        case .working: "agent working"
        case .blocked: "agent waiting for input"
        case .done: "agent finished"
        case .error: "agent failed"
        }
    }
}

extension NSAppearance {
    /// Resolves a dynamic colour against this appearance.
    func resolve(_ color: NSColor) -> CGColor {
        var out = color.cgColor
        performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }
}
