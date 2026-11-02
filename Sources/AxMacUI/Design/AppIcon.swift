import AppKit
import AxModel

/// The app icon, drawn from the mark's geometry (no artwork to keep in
/// step): Axolotty Night's ground as a continuous-corner plate on Apple's
/// grid (824 of 1024, radius 185), lit a little from the top, and the mark in
/// the brand pink, its smile cut in the plate's colour. Rendered into an
/// `.iconset` by `scripts/package-app.sh` through `--write-iconset DIR`.
enum AppIcon {
    static func draw(in ctx: CGContext, side: CGFloat) {
        let unit = side / 1024
        let plate = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
        let path = CGPath(roundedRect: plate, cornerWidth: 185 * unit, cornerHeight: 185 * unit, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func cg(_ hex: String, _ a: CGFloat = 1) -> CGColor {
            let c = RGB(hex: hex)!
            return CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: a)
        }

        // Plate: a soft shadow, the ground lit from the top, a hairline rim.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * unit), blur: 28 * unit, color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(path)
        ctx.setFillColor(cg("#17161D"))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let ground = CGGradient(colorsSpace: space, colors: [cg("#2E2B3B"), cg("#17161D")] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(cg("#FFFFFF", 0.08))
        ctx.setLineWidth(2 * unit)
        ctx.strokePath()
        ctx.restoreGState()

        // Mark: 86% of the plate's width, centred on its own extent (gill tips to chin).
        let s = plate.width * 0.86
        let markTop: CGFloat = 0.285, markBottom: CGFloat = 0.78
        let ox = plate.midX - s / 2
        let oy = plate.midY - (markTop + markBottom) / 2 * s
        ctx.saveGState()
        // The geometry is y-down: flip into it.
        ctx.translateBy(x: ox, y: side - oy)
        ctx.scaleBy(x: 1, y: -1)
        let ink = CGGradient(colorsSpace: space, colors: [cg("#FFB3D9"), cg("#FF80BF"), cg("#E0609F")] as CFArray,
                             locations: [0, 0.55, 1])!
        // Gills (strokes turned into fills) and head painted with one
        // gradient, each part clipped on its own so overlaps stay solid.
        let gills = AxoMarkGeometry.gills(s).copy(strokingWithWidth: AxoMarkGeometry.gillWidth * s, lineCap: .round,
                                                  lineJoin: .round, miterLimit: 4)
        for (part, rule) in [(gills, CGPathFillRule.winding), (AxoMarkGeometry.head(s), .evenOdd)] {
            ctx.saveGState()
            ctx.addPath(part)
            ctx.clip(using: rule)
            ctx.drawLinearGradient(ink, start: CGPoint(x: 0, y: 0.28 * s), end: CGPoint(x: 0, y: 0.8 * s),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        }
        ctx.restoreGState()
        // The smile, cut in the ground.
        ctx.saveGState()
        ctx.translateBy(x: ox, y: side - oy)
        ctx.scaleBy(x: 1, y: -1)
        ctx.addPath(AxoMarkGeometry.smile(s))
        ctx.setStrokeColor(cg("#1F1E28"))
        ctx.setLineWidth(AxoMarkGeometry.smileWidth * s)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Writes `icon_16x16.png` … `icon_512x512@2x.png` into `dir`.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                ctx.setShouldAntialias(true)
                ctx.interpolationQuality = .high
                draw(in: ctx, side: CGFloat(px))
                guard let img = ctx.makeImage() else { continue }
                let rep = NSBitmapImageRep(cgImage: img)
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try rep.representation(using: .png, properties: [:])?.write(to: dir.appending(path: name))
            }
        }
    }
}
