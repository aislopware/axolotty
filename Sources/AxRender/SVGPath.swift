public import CoreGraphics
import Foundation

/// Parses SVG path data (`d="…"`) into a CGPath: every command of SVG 1.1
/// (M L H V C S Q T A Z, absolute and relative), compact number syntax
/// (`.5.5`, `1e-3`, `-1-2`), and arc flags written without separators
/// (`a6 6 0 013 4`). Arcs become cubic Béziers (≤ 90° each).
///
/// Used for brand marks that have no SF Symbol (Claude, Codex, Gemini), so
/// they draw from the vendor's own geometry at any size, crisp, tintable.
public enum SVGPath {
    public static func parse(_ d: String) -> CGPath? {
        var s = Scanner(Array(d.utf8))
        let path = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint?, lastQuad: CGPoint?
        var cmd: UInt8 = 0

        while true {
            s.skipSeparators()
            guard !s.atEnd else { break }
            if s.peekIsCommand {
                cmd = s.next()
            } else if cmd == 0 {
                return nil
            }
            let rel = cmd >= 97  // lowercase
            func pt() -> CGPoint? {
                guard let x = s.number(), let y = s.number() else { return nil }
                return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            }
            switch cmd | 0x20 {  // to lowercase
            case UInt8(ascii: "m"):
                guard let p = pt() else { return nil }
                path.move(to: p)
                cur = p
                start = p
                cmd = rel ? UInt8(ascii: "l") : UInt8(ascii: "L")  // implicit lineto
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "l"):
                guard let p = pt() else { return nil }
                path.addLine(to: p)
                cur = p
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "h"):
                guard let x = s.number() else { return nil }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y)
                path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "v"):
                guard let y = s.number() else { return nil }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y)
                path.addLine(to: cur)
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "c"):
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil
                cur = p
            case UInt8(ascii: "s"):
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let c2 = pt(), let p = pt() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastCubic = c2; lastQuad = nil
                cur = p
            case UInt8(ascii: "q"):
                guard let c = pt(), let p = pt() else { return nil }
                path.addQuadCurve(to: p, control: c)
                lastQuad = c; lastCubic = nil
                cur = p
            case UInt8(ascii: "t"):
                let c = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                guard let p = pt() else { return nil }
                path.addQuadCurve(to: p, control: c)
                lastQuad = c; lastCubic = nil
                cur = p
            case UInt8(ascii: "a"):
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(),
                      let large = s.flag(), let sweep = s.flag(), let p = pt() else { return nil }
                arc(path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = p
                lastCubic = nil; lastQuad = nil
            case UInt8(ascii: "z"):
                path.closeSubpath()
                cur = start
                lastCubic = nil; lastQuad = nil
            default:
                return nil
            }
        }
        return path
    }

    /// SVG 1.1 F.6.5 endpoint → centre parameterisation, then ≤ 90° cubic pieces.
    private static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: CGFloat, ry ry0: CGFloat,
                            rotation: CGFloat, large: Bool, sweep: Bool)
    {
        guard p0 != p1 else { return }
        var rx = abs(rx0), ry = abs(ry0)
        guard rx > 0, ry > 0 else {
            path.addLine(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cphi = cos(phi), sphi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cphi * dx + sphi * dy
        let y1 = -sphi * dx + cphi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            let r = lambda.squareRoot()
            rx *= r
            ry *= r
        }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var co = (max(0, num) / den).squareRoot()
        if large == sweep { co = -co }
        let cx1 = co * rx * y1 / ry
        let cy1 = -co * ry * x1 / rx
        let cx = cphi * cx1 - sphi * cy1 + (p0.x + p1.x) / 2
        let cy = sphi * cx1 + cphi * cy1 + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / CGFloat(pieces)
        let k = 4 / 3 * tan(step / 4)
        func point(_ t: CGFloat) -> CGPoint {
            let x = rx * cos(t), y = ry * sin(t)
            return CGPoint(x: cx + cphi * x - sphi * y, y: cy + sphi * x + cphi * y)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            let x = -rx * sin(t), y = ry * cos(t)
            return CGPoint(x: cphi * x - sphi * y, y: sphi * x + cphi * y)
        }
        var t = theta1
        for i in 0 ..< pieces {
            let t2 = t + step
            let a = point(t), b = i == pieces - 1 ? p1 : point(t2)
            let da = deriv(t), db = deriv(t2)
            path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                          control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = t2
        }
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        var atEnd: Bool { i >= b.count }

        var peekIsCommand: Bool {
            guard i < b.count else { return false }
            let c = b[i] | 0x20
            return "mlhvcsqtaz".utf8.contains(c) && b[i] != UInt8(ascii: "e") && b[i] != UInt8(ascii: "E")
        }

        mutating func next() -> UInt8 {
            defer { i += 1 }
            return b[i]
        }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x2C || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x09 { i += 1 }
        }

        /// An arc flag: a single 0 or 1, separators optional.
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count, b[i] == 0x30 || b[i] == 0x31 else { return nil }
            defer { i += 1 }
            return b[i] == 0x31
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let s = i
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            var digits = false, dot = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30, c <= 0x39 {
                    digits = true
                } else if c == 0x2E, !dot {
                    dot = true
                } else {
                    break
                }
                i += 1
            }
            if digits, i < b.count, b[i] == 0x65 || b[i] == 0x45 {
                var j = i + 1
                if j < b.count, b[j] == 0x2B || b[j] == 0x2D { j += 1 }
                if j < b.count, b[j] >= 0x30, b[j] <= 0x39 {
                    i = j
                    while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { i += 1 }
                }
            }
            guard digits, let v = Double(String(decoding: b[s ..< i], as: UTF8.self)) else {
                i = s
                return nil
            }
            return CGFloat(v)
        }
    }
}
