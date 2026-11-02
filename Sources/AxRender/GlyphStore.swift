internal import AxFrame
import CoreGraphics
import CoreText
import Foundation
public import Metal

/// Glyph atlases (grayscale coverage + colour emoji) and the glyph cache that
/// fills them on demand. Shared by every pane drawn with the same font.
///
/// Confined to the render thread (the main thread on both platforms).
public final class GlyphStore {
    public let device: any MTLDevice
    public private(set) var font: TerminalFont
    private(set) var gray: any MTLTexture
    private(set) var color: any MTLTexture
    private var grayPacker: ShelfPacker
    private var colorPacker: ShelfPacker
    var cache: OpaquePointer!
    /// Bumps when the atlas was reset; frames built against an older one must rebuild.
    private(set) var epoch = 0
    private var grayCanvas: CGContext?
    private var colorCanvas: CGContext?
    private var canvasSize = (w: 0, h: 0)

    public init(device: any MTLDevice, font: TerminalFont, atlasSize: Int = 2048) throws {
        self.device = device
        self.font = font
        guard let g = Self.texture(device, .r8Unorm, atlasSize), let c = Self.texture(device, .bgra8Unorm, atlasSize / 2)
        else { throw RenderError.noTexture }
        gray = g
        color = c
        grayPacker = ShelfPacker(width: atlasSize, height: atlasSize)
        colorPacker = ShelfPacker(width: atlasSize / 2, height: atlasSize / 2)
        cache = ax_glyph_cache_new(rasterizeTrampoline, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { ax_glyph_cache_free(cache) }

    public var glyphCount: Int { ax_glyph_cache_count(cache) }

    /// New font or scale: drop every glyph.
    public func setFont(_ f: TerminalFont) {
        font = f
        reset()
    }

    func reset() {
        grayPacker.reset()
        colorPacker.reset()
        ax_glyph_cache_clear(cache)
        grayCanvas = nil
        colorCanvas = nil
        epoch += 1
    }

    private static func texture(_ device: any MTLDevice, _ format: MTLPixelFormat, _ size: Int) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return device.makeTexture(descriptor: d)
    }

    // MARK: Rasterizing

    fileprivate func rasterize(_ cps: UnsafeBufferPointer<UInt32>, flags: UInt8, into out: inout ax_glyph) -> Bool {
        let wide = flags & UInt8(AX_FONT_WIDE) != 0
        let cellW = font.cellWidth * (wide ? 2 : 1)
        let cellH = font.cellHeight
        let pad = max(2, cellH / 2)
        let w = cellW + pad * 2, h = cellH + pad * 2
        ensureCanvases(w, h)

        let scalars = cps.compactMap(Unicode.Scalar.init)
        if scalars.count == 1, BoxDrawing.handles(cps[0]) {
            guard let ctx = grayCanvas else { return false }
            clear(ctx, w, h)
            ctx.saveGState()
            // Top-left origin, cell at (pad, pad).
            ctx.translateBy(x: CGFloat(pad), y: CGFloat(h - pad))
            ctx.scaleBy(x: 1, y: -1)
            let light = max(1, (font.scale * font.pointSize / 13).rounded())
            BoxDrawing.draw(cps[0], in: ctx, w: CGFloat(cellW), h: CGFloat(cellH), light: light)
            ctx.restoreGState()
            return pack(ctx, w: w, h: h, pad: pad, colored: false, into: &out)
        }

        var text = String()
        text.unicodeScalars.append(contentsOf: scalars)
        guard !text.isEmpty else { return false }
        let base = font.face(bold: flags & UInt8(AX_FONT_BOLD) != 0, italic: flags & UInt8(AX_FONT_ITALIC) != 0)
        let scaled = CTFontCreateCopyWithAttributes(base, font.pointSize * font.scale, nil, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: scaled, kCTForegroundColorFromContextAttributeName: true]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary) else { return false }
        let line = CTLineCreateWithAttributedString(attributed)

        // Colour glyphs (emoji) go to the colour atlas.
        var colored = false
        for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            if let f = runAttrs[kCTFontAttributeName] {
                let runFont = f as! CTFont  // swiftlint:disable:this force_cast
                if CTFontGetSymbolicTraits(runFont).contains(.traitColorGlyphs) { colored = true }
            }
        }
        guard let ctx = colored ? colorCanvas : grayCanvas else { return false }
        clear(ctx, w, h)

        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        var sx: CGFloat = 1
        // Fit glyphs wider than their cells (emoji, wide fallbacks) instead of overlapping neighbours.
        if width > CGFloat(cellW) * 1.05 { sx = CGFloat(cellW) / width }
        ctx.saveGState()
        ctx.setFillColor(gray: 1, alpha: 1)
        let baselineFromBottom = CGFloat(h - pad - font.baseline)
        if sx < 1 {
            let dx = (CGFloat(cellW) - width * sx) / 2
            ctx.translateBy(x: CGFloat(pad) + dx, y: baselineFromBottom + CGFloat(font.descent) * (1 - sx))
            ctx.scaleBy(x: sx, y: sx)
            ctx.textPosition = .zero
        } else {
            // Centre narrower glyphs in wide cells (CJK in a monospace fallback).
            let dx = wide ? max(0, (CGFloat(cellW) - width) / 2) : 0
            ctx.textPosition = CGPoint(x: CGFloat(pad) + dx, y: baselineFromBottom)
        }
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return pack(ctx, w: w, h: h, pad: pad, colored: colored, into: &out)
    }

    private func ensureCanvases(_ w: Int, _ h: Int) {
        guard grayCanvas == nil || canvasSize.w < w || canvasSize.h < h else { return }
        let cw = max(w, canvasSize.w), ch = max(h, canvasSize.h)
        canvasSize = (cw, ch)
        grayCanvas = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw,
                               space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        colorCanvas = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)
        for c in [grayCanvas, colorCanvas].compactMap({ $0 }) {
            c.setShouldAntialias(true)
            c.setAllowsFontSmoothing(false)
            c.setShouldSmoothFonts(false)
            c.setAllowsFontSubpixelPositioning(true)
            c.setShouldSubpixelPositionFonts(true)
            c.interpolationQuality = .high
        }
    }

    private func clear(_ ctx: CGContext, _ w: Int, _ h: Int) {
        ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        if ctx === grayCanvas {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
    }

    /// Crops the drawn pixels, uploads them to the atlas and fills `out`.
    private func pack(_ ctx: CGContext, w: Int, h: Int, pad: Int, colored: Bool, into out: inout ax_glyph) -> Bool {
        guard let data = ctx.data else { return false }
        let bpr = ctx.bytesPerRow
        let px = data.assumingMemoryBound(to: UInt8.self)
        // The context is canvasSize; our drawing occupies its bottom-left w×h (CG origin
        // bottom-left), i.e. memory rows [ch - h, ch).
        let top = ctx.height - h
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0 ..< h {
            let row = px + (top + y) * bpr
            for x in 0 ..< w {
                let v = colored ? row[x * 4 + 3] : row[x]
                if v != 0 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            out.empty = true
            return true
        }
        let gw = maxX - minX + 1, gh = maxY - minY + 1
        guard let slot = place(gw, gh, colored: colored) else { return false }
        let tex = colored ? color : gray
        let start = px + (top + minY) * bpr + minX * (colored ? 4 : 1)
        tex.replace(region: MTLRegionMake2D(slot.x, slot.y, gw, gh), mipmapLevel: 0, withBytes: start, bytesPerRow: bpr)
        out.atlas_x = UInt16(slot.x)
        out.atlas_y = UInt16(slot.y)
        out.width = UInt16(gw)
        out.height = UInt16(gh)
        out.bearing_x = Int16(minX - pad)
        out.bearing_y = Int16(minY - pad)
        out.atlas = colored ? 1 : 0
        out.empty = false
        return true
    }

    private func place(_ w: Int, _ h: Int, colored: Bool) -> (x: Int, y: Int)? {
        if colored {
            if let p = colorPacker.place(w, h) { return p }
        } else if let p = grayPacker.place(w, h) {
            return p
        }
        // Full: start over. The current frame rebuilds against the fresh atlas.
        needsReset = true
        return nil
    }

    /// Set when an atlas filled up during a build; the renderer resets and rebuilds.
    var needsReset = false
}

private func rasterizeTrampoline(_ ctx: UnsafeMutableRawPointer?, _ cps: UnsafePointer<UInt32>?, _ n: UInt32,
                                 _ flags: UInt8, _ out: UnsafeMutablePointer<ax_glyph>?) -> Bool
{
    guard let ctx, let cps, let out else { return false }
    let store = Unmanaged<GlyphStore>.fromOpaque(ctx).takeUnretainedValue()
    return store.rasterize(UnsafeBufferPointer(start: cps, count: Int(n)), flags: flags, into: &out.pointee)
}

/// Shelf (row) packing with a 1-pixel gutter.
struct ShelfPacker {
    let width: Int, height: Int
    private var x = 0, y = 0, rowHeight = 0

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    mutating func reset() {
        x = 0
        y = 0
        rowHeight = 0
    }

    mutating func place(_ w: Int, _ h: Int) -> (x: Int, y: Int)? {
        guard w + 1 <= width, h + 1 <= height else { return nil }
        if x + w + 1 > width {
            x = 0
            y += rowHeight + 1
            rowHeight = 0
        }
        guard y + h + 1 <= height else { return nil }
        defer {
            x += w + 1
            rowHeight = max(rowHeight, h)
        }
        return (x, y)
    }
}

public enum RenderError: Error, Sendable {
    case noDevice, noTexture, shader(String), pipeline(String)
}
