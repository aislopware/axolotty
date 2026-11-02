import AxRender
import Foundation

/// Cursor motion (design spec §3.3): glide on short moves, an entrance pop on
/// focus, and a blink that dims rather than hides and stops after ten cycles.
/// Pure: the view feeds it the terminal's cursor and a clock, it returns a style.
struct CursorAnimator {
    struct Output {
        var style: CursorStyle
        /// More frames are needed (glide, pop or blink in progress).
        var animating: Bool
        /// Only the blink is animating (the view can drop to a low frame rate).
        var blinkOnly: Bool
    }

    var preferred: CursorStyle.Shape = .bar
    var blinkEnabled = true
    var reduceMotion = false

    static let glideDuration = 0.08
    static let entranceDuration = 0.22
    static let blinkDelay = 0.5
    static let blinkFade = 0.15
    static let blinkLowHold = 0.3
    static let blinkHighHold = 0.5
    static let blinkFloor = 0.25
    static let blinkCycles = 10
    static var blinkPeriod: Double { blinkFade * 2 + blinkLowHold + blinkHighHold }

    private var target: (x: Int, y: Int)?
    private var glideFrom: (x: Double, y: Double) = (0, 0)
    private var glideStart: Double?
    private var lastMove = -Double.infinity
    private var entranceStart: Double?
    private var activity = 0.0

    /// Any keystroke or output restarts the blink cycle.
    mutating func noteActivity(_ now: Double) { activity = now }

    mutating func focusGained(_ now: Double) {
        activity = now
        entranceStart = reduceMotion ? nil : now
    }

    mutating func frame(_ now: Double, cursor: CursorInfo, focused: Bool) -> Output {
        var style = CursorStyle()
        var animating = false

        // Position and glide.
        let cell = (x: cursor.x, y: cursor.y)
        if let t = target, t != cell {
            let dx = abs(cell.x - t.x), dy = abs(cell.y - t.y)
            let short = (dy == 0 && dx <= 8) || dy <= 2
            let streaming = now - lastMove < 0.05
            if short, !streaming, !reduceMotion, focused {
                glideFrom = displayed(now)
                glideStart = now
            } else {
                glideStart = nil
            }
            lastMove = now
            activity = now
        }
        target = cell
        if let start = glideStart {
            let t = (now - start) / Self.glideDuration
            if t >= 1 {
                glideStart = nil
            } else {
                style.position = displayed(now)
                animating = true
            }
        }

        guard focused else {
            style.shape = .hollow
            return Output(style: style, animating: animating, blinkOnly: false)
        }
        style.shape = cursor.requested ?? preferred

        // Entrance pop.
        if let start = entranceStart {
            let t = (now - start) / Self.entranceDuration
            if t >= 1 {
                entranceStart = nil
            } else {
                let u = 1 - t
                style.scale = 1 + 0.14 * u * u * u
                animating = true
            }
        }

        // Blink.
        var blinkOnly = false
        if blinkEnabled, cursor.blinking || cursor.requested == nil {
            let idle = now - activity - Self.blinkDelay
            if idle > 0, idle < Double(Self.blinkCycles) * Self.blinkPeriod {
                style.opacity = Self.blinkOpacity(idle.truncatingRemainder(dividingBy: Self.blinkPeriod),
                                                  hard: reduceMotion)
                blinkOnly = !animating
                animating = true
            }
        }
        return Output(style: style, animating: animating, blinkOnly: blinkOnly)
    }

    /// Opacity within one blink period: fade down, low hold, fade up, high hold.
    static func blinkOpacity(_ phase: Double, hard: Bool) -> Double {
        let low = blinkFloor
        if hard { return phase < blinkFade + blinkLowHold ? low : 1 }
        if phase < blinkFade { return 1 - (1 - low) * (phase / blinkFade) }
        if phase < blinkFade + blinkLowHold { return low }
        if phase < blinkFade * 2 + blinkLowHold { return low + (1 - low) * ((phase - blinkFade - blinkLowHold) / blinkFade) }
        return 1
    }

    private func displayed(_ now: Double) -> (x: Double, y: Double) {
        guard let t = target else { return (0, 0) }
        guard let start = glideStart else { return (Double(t.x), Double(t.y)) }
        let p = min(1, max(0, (now - start) / Self.glideDuration))
        let e = 1 - (1 - p) * (1 - p)
        return (glideFrom.x + (Double(t.x) - glideFrom.x) * e, glideFrom.y + (Double(t.y) - glideFrom.y) * e)
    }
}
