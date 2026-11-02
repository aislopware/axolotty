import CoreGraphics

/// Procedural drawing for box-drawing, block and Powerline characters, so lines
/// join seamlessly across cells regardless of the font (a font's own glyphs
/// rarely fill the cell exactly).
enum BoxDrawing {
    static func handles(_ cp: UInt32) -> Bool {
        (0x2500 ... 0x259F).contains(cp) || (0xE0B0 ... 0xE0B6).contains(cp)
    }

    /// Arms: up, right, down, left. 0 none, 1 light, 2 heavy, 3 double.
    private static let lines: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = {
        var t: [UInt32: (UInt8, UInt8, UInt8, UInt8)] = [:]
        // u r d l, written as 4-digit strings for brevity, U+2500…U+254B
        let codes = [
            "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020",
            "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200",
            "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
            "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",
            "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
            "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212",
            "1222", "2122", "2221", "2222",
        ]
        for (i, c) in codes.enumerated() {
            let d = c.compactMap { $0.wholeNumberValue }.map(UInt8.init)
            t[0x2500 + UInt32(i)] = (d[0], d[1], d[2], d[3])
        }
        // Double-dash variants U+254C…U+254F.
        t[0x254C] = (0, 1, 0, 1); t[0x254D] = (0, 2, 0, 2); t[0x254E] = (1, 0, 1, 0); t[0x254F] = (2, 0, 2, 0)
        // Doubles U+2550…U+256C.
        let doubles = [
            "0303", "3030", "0310", "0130", "0330", "0013", "0031", "0033", "1300", "3100", "3300", "1003",
            "3001", "3003", "1310", "3130", "3330", "1013", "3031", "3033", "0313", "0131", "0333", "1303",
            "3101", "3303", "1313", "3131", "3333",
        ]
        for (i, c) in doubles.enumerated() {
            let d = c.compactMap { $0.wholeNumberValue }.map(UInt8.init)
            t[0x2550 + UInt32(i)] = (d[0], d[1], d[2], d[3])
        }
        // Half lines U+2574…U+257F.
        let halves = ["0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010"]
        for (i, c) in halves.enumerated() {
            let d = c.compactMap { $0.wholeNumberValue }.map(UInt8.init)
            t[0x2574 + UInt32(i)] = (d[0], d[1], d[2], d[3])
        }
        return t
    }()

    private static func dashes(_ cp: UInt32) -> Int {
        switch cp {
        case 0x2504 ... 0x2507: 3
        case 0x2508 ... 0x250B: 4
        case 0x254C ... 0x254F: 2
        default: 0
        }
    }

    /// Draws into `ctx` whose coordinate system is top-left origin, cell at (0,0,w,h).
    /// `light` is the light stroke width in pixels.
    static func draw(_ cp: UInt32, in ctx: CGContext, w: CGFloat, h: CGFloat, light: CGFloat) {
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setStrokeColor(gray: 1, alpha: 1)
        let heavy = light * 2
        let cx = (w / 2 - light / 2).rounded(.down) + light / 2
        let cy = (h / 2 - light / 2).rounded(.down) + light / 2

        if let arms = lines[cp] {
            let n = dashes(cp)
            if n > 0 {
                drawDashed(ctx, horizontal: arms.1 != 0, n: n, weight: max(arms.0, arms.1) == 2 ? heavy : light,
                           w: w, h: h, cx: cx, cy: cy)
                return
            }
            drawArms(ctx, arms, w: w, h: h, cx: cx, cy: cy, light: light, heavy: heavy)
            return
        }
        switch cp {
        case 0x256D ... 0x2570: drawArc(ctx, cp, w: w, h: h, cx: cx, cy: cy, light: light)
        case 0x2571 ... 0x2573:
            ctx.setLineWidth(light)
            ctx.setLineCap(.square)
            if cp != 0x2572 {
                ctx.move(to: CGPoint(x: 0, y: h))
                ctx.addLine(to: CGPoint(x: w, y: 0))
            }
            if cp != 0x2571 {
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: h))
            }
            ctx.strokePath()
        case 0x2580 ... 0x259F: drawBlock(ctx, cp, w: w, h: h)
        case 0xE0B0 ... 0xE0B6: drawPowerline(ctx, cp, w: w, h: h, light: light)
        default: break
        }
    }

    private static func drawArms(_ ctx: CGContext, _ a: (UInt8, UInt8, UInt8, UInt8), w: CGFloat, h: CGFloat,
                                 cx: CGFloat, cy: CGFloat, light: CGFloat, heavy: CGFloat)
    {
        func width(_ k: UInt8) -> CGFloat { k == 2 ? heavy : light }
        // How far a vertical arm must reach so it meets the thickest horizontal arm (and vice versa).
        let hMax = max(a.1 == 3 ? light * 3 : width(a.1), a.3 == 3 ? light * 3 : width(a.3))
        let vMax = max(a.0 == 3 ? light * 3 : width(a.0), a.2 == 3 ? light * 3 : width(a.2))
        let gap = light  // double-line gap

        func vertical(_ k: UInt8, from y0: CGFloat, to y1: CGFloat) {
            guard k != 0 else { return }
            if k == 3 {
                for dx in [-gap, gap] { ctx.fill(CGRect(x: cx + dx - light / 2, y: y0, width: light, height: y1 - y0)) }
            } else {
                let t = width(k)
                ctx.fill(CGRect(x: cx - t / 2, y: y0, width: t, height: y1 - y0))
            }
        }
        func horizontal(_ k: UInt8, from x0: CGFloat, to x1: CGFloat) {
            guard k != 0 else { return }
            if k == 3 {
                for dy in [-gap, gap] { ctx.fill(CGRect(x: x0, y: cy + dy - light / 2, width: x1 - x0, height: light)) }
            } else {
                let t = width(k)
                ctx.fill(CGRect(x: x0, y: cy - t / 2, width: x1 - x0, height: t))
            }
        }
        vertical(a.0, from: 0, to: cy + hMax / 2)
        vertical(a.2, from: cy - hMax / 2, to: h)
        horizontal(a.3, from: 0, to: cx + vMax / 2)
        horizontal(a.1, from: cx - vMax / 2, to: w)
    }

    private static func drawDashed(_ ctx: CGContext, horizontal: Bool, n: Int, weight t: CGFloat, w: CGFloat,
                                   h: CGFloat, cx: CGFloat, cy: CGFloat)
    {
        let len = horizontal ? w : h
        let seg = len / CGFloat(n)
        let dash = (seg * 0.6).rounded()
        for i in 0 ..< n {
            let start = (CGFloat(i) * seg + (seg - dash) / 2).rounded()
            if horizontal {
                ctx.fill(CGRect(x: start, y: cy - t / 2, width: dash, height: t))
            } else {
                ctx.fill(CGRect(x: cx - t / 2, y: start, width: t, height: dash))
            }
        }
    }

    private static func drawArc(_ ctx: CGContext, _ cp: UInt32, w: CGFloat, h: CGFloat, cx: CGFloat, cy: CGFloat,
                                light: CGFloat)
    {
        let r = min(w, h) / 2
        ctx.setLineWidth(light)
        // (end point on the cell edge, corner direction)
        let goesRight = cp == 0x256D || cp == 0x2570
        let goesDown = cp == 0x256D || cp == 0x256E
        let ex = goesRight ? w : 0
        let ey = goesDown ? h : 0
        ctx.move(to: CGPoint(x: cx, y: ey))
        ctx.addLine(to: CGPoint(x: cx, y: goesDown ? cy + r : cy - r))
        ctx.addArc(tangent1End: CGPoint(x: cx, y: cy), tangent2End: CGPoint(x: goesRight ? cx + r : cx - r, y: cy),
                   radius: r)
        ctx.addLine(to: CGPoint(x: ex, y: cy))
        ctx.strokePath()
    }

    private static func drawBlock(_ ctx: CGContext, _ cp: UInt32, w: CGFloat, h: CGFloat) {
        func eighthsH(_ n: Int) -> CGFloat { (h * CGFloat(n) / 8).rounded() }
        func eighthsW(_ n: Int) -> CGFloat { (w * CGFloat(n) / 8).rounded() }
        let hw = (w / 2).rounded(), hh = (h / 2).rounded()
        switch cp {
        case 0x2580: ctx.fill(CGRect(x: 0, y: 0, width: w, height: hh))
        case 0x2581 ... 0x2588:
            let n = Int(cp - 0x2580)
            ctx.fill(CGRect(x: 0, y: h - eighthsH(n), width: w, height: eighthsH(n)))
        case 0x2589 ... 0x258F:
            let n = 8 - Int(cp - 0x2588)
            ctx.fill(CGRect(x: 0, y: 0, width: eighthsW(n), height: h))
        case 0x2590: ctx.fill(CGRect(x: hw, y: 0, width: w - hw, height: h))
        case 0x2591 ... 0x2593:
            let alpha: CGFloat = [0.25, 0.5, 0.75][Int(cp - 0x2591)]
            ctx.setFillColor(gray: 1, alpha: alpha)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        case 0x2594: ctx.fill(CGRect(x: 0, y: 0, width: w, height: eighthsH(1)))
        case 0x2595: ctx.fill(CGRect(x: w - eighthsW(1), y: 0, width: eighthsW(1), height: h))
        default:
            // Quadrants U+2596…U+259F: bits UL, UR, LL, LR.
            let quads: [UInt32: (Bool, Bool, Bool, Bool)] = [
                0x2596: (false, false, true, false), 0x2597: (false, false, false, true),
                0x2598: (true, false, false, false), 0x2599: (true, false, true, true),
                0x259A: (true, false, false, true), 0x259B: (true, true, true, false),
                0x259C: (true, true, false, true), 0x259D: (false, true, false, false),
                0x259E: (false, true, true, false), 0x259F: (false, true, true, true),
            ]
            guard let q = quads[cp] else { return }
            if q.0 { ctx.fill(CGRect(x: 0, y: 0, width: hw, height: hh)) }
            if q.1 { ctx.fill(CGRect(x: hw, y: 0, width: w - hw, height: hh)) }
            if q.2 { ctx.fill(CGRect(x: 0, y: hh, width: hw, height: h - hh)) }
            if q.3 { ctx.fill(CGRect(x: hw, y: hh, width: w - hw, height: h - hh)) }
        }
    }

    private static func drawPowerline(_ ctx: CGContext, _ cp: UInt32, w: CGFloat, h: CGFloat, light: CGFloat) {
        switch cp {
        case 0xE0B0, 0xE0B2:  // solid triangles
            let right = cp == 0xE0B0
            ctx.move(to: CGPoint(x: right ? 0 : w, y: 0))
            ctx.addLine(to: CGPoint(x: right ? w : 0, y: h / 2))
            ctx.addLine(to: CGPoint(x: right ? 0 : w, y: h))
            ctx.closePath()
            ctx.fillPath()
        case 0xE0B1, 0xE0B3:  // chevrons
            let right = cp == 0xE0B1
            ctx.setLineWidth(light)
            ctx.move(to: CGPoint(x: right ? 0 : w, y: 0))
            ctx.addLine(to: CGPoint(x: right ? w - light : light, y: h / 2))
            ctx.addLine(to: CGPoint(x: right ? 0 : w, y: h))
            ctx.strokePath()
        case 0xE0B4, 0xE0B6:  // half circles
            let right = cp == 0xE0B4
            ctx.addEllipse(in: CGRect(x: right ? -w : 0, y: 0, width: w * 2, height: h))
            ctx.fillPath()
        default:
            break
        }
    }
}
