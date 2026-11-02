public import CoreGraphics
public import CoreText
import Foundation

/// The four faces of the terminal font and the cell grid they imply, in device pixels.
///
/// The platform layer supplies the base `CTFont` (AppKit: `NSFont.monospacedSystemFont`,
/// UIKit: `UIFont.monospacedSystemFont`, both toll-free bridged), so this module
/// stays free of AppKit and UIKit.
public struct TerminalFont: @unchecked Sendable {
    public let regular: CTFont
    public let bold: CTFont
    public let italic: CTFont
    public let boldItalic: CTFont
    /// Backing scale (2 on Retina).
    public let scale: CGFloat
    public let pointSize: CGFloat

    // Pixel metrics (integers so quads land on pixel boundaries).
    public let cellWidth: Int
    public let cellHeight: Int
    /// Baseline distance from the cell's top.
    public let baseline: Int
    public let descent: Int
    public let underlineY: Float
    public let underlineThickness: Float
    public let strikeY: Float
    public let strikeThickness: Float

    /// - Parameter cellHeightAdjust: multiplier on the font's line height (design spec: +10 %).
    public init(regular: CTFont, bold: CTFont? = nil, scale: CGFloat, cellHeightAdjust: CGFloat = 1.1) {
        self.regular = regular
        self.scale = scale
        pointSize = CTFontGetSize(regular)
        let b = bold ?? CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, .traitBold, .traitBold) ?? regular
        self.bold = b
        italic = CTFontCreateCopyWithSymbolicTraits(regular, 0, nil, .traitItalic, .traitItalic)
            ?? Self.oblique(regular)
        boldItalic = CTFontCreateCopyWithSymbolicTraits(b, 0, nil, .traitItalic, .traitItalic) ?? Self.oblique(b)

        let ascent = CTFontGetAscent(regular) * scale
        let descentPt = CTFontGetDescent(regular) * scale
        let leading = CTFontGetLeading(regular) * scale
        var glyph = CGGlyph(0)
        var ch = UniChar(("M" as Unicode.Scalar).value)
        _ = CTFontGetGlyphsForCharacters(regular, &ch, &glyph, 1)
        var advance = CGSize.zero
        _ = CTFontGetAdvancesForGlyphs(regular, .horizontal, &glyph, &advance, 1)

        cellWidth = max(1, Int((advance.width * scale).rounded()))
        let natural = ascent + descentPt + leading
        cellHeight = max(1, Int((natural * cellHeightAdjust).rounded(.up)))
        let extra = CGFloat(cellHeight) - (ascent + descentPt)
        baseline = Int((extra / 2 + ascent).rounded())
        descent = cellHeight - baseline

        let ulPos = CTFontGetUnderlinePosition(regular) * scale  // negative: below the baseline
        let ulThick = max(1, (CTFontGetUnderlineThickness(regular) * scale).rounded())
        underlineThickness = Float(ulThick)
        underlineY = Float(min(CGFloat(cellHeight) - ulThick, (CGFloat(baseline) - ulPos).rounded()))
        strikeThickness = Float(ulThick)
        strikeY = Float((CGFloat(baseline) - CTFontGetXHeight(regular) * scale / 2).rounded())
    }

    /// A synthetic italic for fonts without one (SF Mono has one; fallbacks may not).
    private static func oblique(_ font: CTFont) -> CTFont {
        var m = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), &m, nil)
    }

    func face(bold isBold: Bool, italic isItalic: Bool) -> CTFont {
        switch (isBold, isItalic) {
        case (false, false): regular
        case (true, false): bold
        case (false, true): italic
        case (true, true): boldItalic
        }
    }

    /// The same family at another size (⌘+ / ⌘−).
    public func resized(to points: CGFloat) -> TerminalFont {
        TerminalFont(regular: CTFontCreateCopyWithAttributes(regular, points, nil, nil),
                     bold: CTFontCreateCopyWithAttributes(bold, points, nil, nil), scale: scale)
    }
}
