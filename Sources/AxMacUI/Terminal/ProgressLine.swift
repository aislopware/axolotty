import AppKit
import AxModel
import QuartzCore

/// The 2 pt line across the top inside edge of a sheet, driven only by the
/// program's own OSC 9;4 reports (never scraped). It sits under the sheet's
/// corner mask, so its ends follow the radius, and above a strip when there is
/// one, so the two read as one header.
///
/// - indeterminate: a 30 % segment of `working` magenta sweeping over 1.1 s,
///   ease-in-out, on a 12 % track of itself
/// - numeric: a determinate fill from the left
/// - error: red · paused: amber
/// - cleared: fades out over 250 ms
/// - Reduce Motion: the indeterminate state is a static line at half alpha
final class ProgressLine {
    static let height: CGFloat = 2

    /// Add this to the host layer and give it a frame through `frame`.
    let layer = CALayer()
    private let track = CALayer()
    private let bar = CALayer()
    private var value: Int?
    private var tone: ProgressTone = .normal

    init() {
        for l in [track, bar] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer.addSublayer(l)
        }
        layer.actions = ["bounds": NSNull(), "position": NSNull()]
        layer.opacity = 0
    }

    var frame: CGRect {
        get { layer.frame }
        set {
            guard newValue != layer.frame else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = newValue
            track.frame = layer.bounds
            CATransaction.commit()
            layoutBar()
        }
    }

    private var bounds: CGRect { layer.bounds }

    /// `value` is OSC 9;4's percentage, -1 while indeterminate, nil to clear.
    func set(_ value: Int?, tone: ProgressTone?, appearance: NSAppearance) {
        let tone = tone ?? .normal
        let changed = value != self.value || tone != self.tone
        let wasShown = self.value != nil
        self.value = value
        self.tone = tone
        let ink: NSColor = switch tone {
        case .normal: Axo.Color.status(.working)
        case .error: Axo.Color.status(.error)
        case .paused: Axo.Color.status(.blocked)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = appearance.resolve(ink.withAlphaComponent(0.12))
        bar.backgroundColor = appearance.resolve(ink)
        CATransaction.commit()
        guard changed else { return }
        if value == nil {
            guard wasShown else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(Axo.Motion.reduced ? 0 : 0.25)
            layer.opacity = 0
            CATransaction.commit()
            bar.removeAnimation(forKey: "sweep")
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        CATransaction.commit()
        layoutBar()
    }

    private func layoutBar() {
        guard let value else { return }
        let w = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if value >= 0 {
            bar.removeAnimation(forKey: "sweep")
            bar.opacity = 1
            bar.frame = CGRect(x: 0, y: 0, width: (w * CGFloat(min(100, value)) / 100).rounded(), height: bounds.height)
            return
        }
        // Indeterminate.
        let seg = (w * 0.3).rounded()
        if Axo.Motion.reduced {
            bar.removeAnimation(forKey: "sweep")
            bar.frame = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            bar.opacity = 0.5
            return
        }
        bar.opacity = 1
        let running = bar.animation(forKey: "sweep") != nil && bar.bounds.width == seg
        bar.frame = CGRect(x: 0, y: 0, width: seg, height: bounds.height)
        guard !running else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -seg / 2
        sweep.toValue = w + seg / 2
        sweep.duration = 1.1
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.repeatCount = .infinity
        sweep.isRemovedOnCompletion = false
        bar.add(sweep, forKey: "sweep")
    }
}
