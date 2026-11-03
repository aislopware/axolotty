import AppKit
import AxModel
import QuartzCore
import Symbols

/// The status mark: one family of 13 pt circles (SF Symbols, one stroke), so
/// every state reads as the same object at a different moment.
///
/// - idle: nothing
/// - working: a dashed circle in the working cyan, open because it is not
///   finished yet. It breathes (opacity, every row in step) rather than
///   spins. A known percentage fills a wedge inside it, clockwise from 12.
/// - wants you (amber): the circle closes and holds what it waits for: a
///   lock to approve (macOS's own mark for a permission), a question mark
///   to answer, a person to sign in, pause when it does not say.
/// - failed (red): an exclamation mark.
/// - done (green, unseen): a check.
///
/// A change of state is one authored moment: the mark is replaced in place
/// (Magic Replace keeps the circle and swaps what is inside), then a mark
/// that wants you moves once (the hand waves, the others bounce) and stays
/// still. Reduce Motion swaps without moving.
///
/// Marks inside are the ones that stay legible at 13 pt on a 1× screen: the
/// raised hand and the key fill in to a blob there, so they are not used.
final class StatusGlyphView: NSView {
    var activity: Activity = .idle {
        didSet { if activity != oldValue { rebuild(animated: true) } }
    }

    /// What a waiting program waits for; picks the mark inside the circle.
    var need: StatusRecord.Need? {
        didSet { if need != oldValue, activity == .blocked { rebuild(animated: true) } }
    }

    /// Determinate progress (0…1) turns the working dashes into an arc.
    var progress: Double? {
        didSet { if progress != oldValue, activity == .working { rebuild(animated: false) } }
    }

    var pointSize: CGFloat = 13 { didSet { if pointSize != oldValue { rebuild(animated: false) } } }

    private let image = NSImageView()
    private let wedge = CAShapeLayer().crisp()
    private var shown: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        image.imageScaling = .scaleNone
        image.imageAlignment = .alignCenter
        addSubview(image)
        layer?.addSublayer(wedge)
        setAccessibilityElement(false)
        rebuild(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Axo.Metric.statusSlot, height: Axo.Metric.statusSlot) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        image.frame = bounds
        layoutRing()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuild(animated: false)  // effects are dropped when a layer leaves the tree
    }

    /// The SF Symbol for a state, nil for none.
    static func symbol(_ a: Activity, _ need: StatusRecord.Need?) -> String? {
        switch a {
        case .idle: nil
        case .working: "circle.dashed"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.circle"
        case .blocked:
            switch need {
            case .permission?: "lock.circle"
            case .question?: "questionmark.circle"
            case .auth?: "person.circle"
            case nil: "pause.circle"
            }
        }
    }

    /// The colour for a state that wants a look.
    static func dotColor(_ a: Activity) -> NSColor {
        switch a {
        case .blocked, .error, .done: Axo.Color.status(a)
        default: Axo.Color.textSecondary
        }
    }

    private var determinate: Bool { activity == .working && progress != nil }

    private func rebuild(animated: Bool) {
        let name = Self.symbol(activity, need)
        let moving = animated && window != nil && !Axo.Motion.reduced && shown != nil && name != shown
        image.isHidden = name == nil
        image.contentTintColor = Axo.Color.status(activity)
        image.removeAllSymbolEffects(animated: false)
        image.layer?.removeAnimation(forKey: "breathe")
        if let name, let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
           let img = base.withSymbolConfiguration(.init(pointSize: pointSize, weight: .medium)) {
            if moving {
                image.setSymbolImage(img, contentTransition: .replace.magic(fallback: .downUp))
            } else {
                image.image = img
            }
        } else {
            image.image = nil
        }
        shown = name
        if window != nil, !Axo.Motion.reduced {
            if activity == .working, !determinate { breathe() }
            if moving { announce() }
        }
        layoutRing()
    }

    /// The arrival moment, once: a mark that wants you moves (the hand
    /// waves, a question bounces, a failure shakes its head). A card that
    /// appears with a state already set calls it as it lands.
    func announce() {
        guard window != nil, !Axo.Motion.reduced else { return }
        switch activity {
        case .blocked where need == .permission: image.addSymbolEffect(.wiggle, options: .nonRepeating)
        case .blocked: image.addSymbolEffect(.bounce, options: .nonRepeating)
        case .error: image.addSymbolEffect(.wiggle.left, options: .nonRepeating)
        case .done: image.addSymbolEffect(.bounce, options: .nonRepeating)
        default: break
        }
    }

    /// Opacity 1 → 0.45 and back over 2 s. Every working mark shares one
    /// phase (from the clock, not from when it appeared), so a column of
    /// them breathes together instead of flickering.
    private func breathe() {
        guard let l = image.layer else { return }
        let period: CFTimeInterval = 2
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = 0.45
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let now = l.convertTime(CACurrentMediaTime(), from: nil)
        a.beginTime = now - now.truncatingRemainder(dividingBy: period)
        a.isRemovedOnCompletion = false
        l.add(a, forKey: "breathe")
    }

    private func layoutRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        wedge.isHidden = !determinate
        guard determinate, let p = progress else { return }
        // Inside the dashes with a clear gap, so ring and fill read as two
        // things: 13 pt circle, 2.75 pt in from its edge.
        let r = (pointSize - 0.5) / 2 - 2.75
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let start = CGFloat.pi / 2  // 12 o'clock; layer space is y-up
        let end = start - 2 * .pi * CGFloat(max(0.04, min(1, p)))
        let path = CGMutablePath()
        if p >= 1 {
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        } else {
            path.move(to: c)
            path.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
            path.closeSubpath()
        }
        wedge.frame = bounds
        wedge.path = path
        wedge.fillColor = effectiveAppearance.resolve(Axo.Color.status(.working))
    }

    /// VoiceOver phrase for the state ("agent waiting for input").
    static func phrase(_ a: Activity, _ need: StatusRecord.Need? = nil) -> String? {
        switch a {
        case .idle: nil
        case .working: "agent working"
        case .blocked: need.map { "agent \($0.words.lowercased())" } ?? "agent waiting for input"
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
