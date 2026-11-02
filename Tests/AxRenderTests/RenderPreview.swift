import AxRender
import AxVT
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Writes a PNG of a sample screen for eyeballing (`AXOLOTTY_RENDER_PNG=/path swift test --filter preview`).
@Test(.enabled(if: ProcessInfo.processInfo.environment["AXOLOTTY_RENDER_PNG"] != nil))
func preview() throws {
    let font = TerminalFont(regular: CTFontCreateUIFontForLanguage(.userFixedPitch, 13, nil)!, scale: 2)
    let r = try TerminalRenderer(font: font)
    let t = try VTTerminal(cols: 64, rows: 14)
    let night: [(UInt8, UInt8, UInt8)] = [
        (0x39, 0x34, 0x38), (0xEF, 0x7E, 0x7C), (0x6C, 0xC5, 0x81), (0xE4, 0xC0, 0x62), (0x6F, 0xA7, 0xEE),
        (0xDF, 0x88, 0xD0), (0x5D, 0xCB, 0xD1), (0xD4, 0xCF, 0xD3), (0x85, 0x7E, 0x83), (0xFD, 0xA1, 0x9E),
        (0x8F, 0xE1, 0xA1), (0xF5, 0xD9, 0x83), (0x92, 0xC1, 0xFD), (0xF3, 0xA7, 0xE5), (0x85, 0xE3, 0xE8),
        (0xF7, 0xF4, 0xF6),
    ]
    var palette = night
    let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
    for a in steps { for b in steps { for c in steps { palette.append((a, b, c)) } } }
    for i in 0 ..< 24 { let v = UInt8(8 + i * 10); palette.append((v, v, v)) }
    t.setDefaultColors(foreground: (0xEB, 0xE6, 0xEA), background: (0x15, 0x12, 0x14), cursor: (0xDE, 0x7B, 0xCF),
                       palette: palette)
    let sample = [
        "\u{1B}[38;5;8m~/oss/axolotty\u{1B}[0m on \u{1B}[35m main\u{1B}[0m \u{1B}[32m✓\u{1B}[0m",
        "\u{1B}[35m❯\u{1B}[0m claude \u{1B}[2m--resume\u{1B}[0m",
        "\u{1B}[1m✻ Thinking…\u{1B}[0m \u{1B}[3mitalic\u{1B}[0m \u{1B}[4munder\u{1B}[0m \u{1B}[4:3mcurly\u{1B}[0m \u{1B}[9mstrike\u{1B}[0m",
        "╭──────────────┬───────────╮  ▁▂▃▄▅▆▇█  ░▒▓",
        "│ \u{1B}[31mred\u{1B}[0m \u{1B}[32mgreen\u{1B}[0m \u{1B}[33myel\u{1B}[0m │ \u{1B}[34mblue\u{1B}[0m \u{1B}[36mcyn\u{1B}[0m │  ┏━┓ ╔═╗ \u{1B}[7m inv \u{1B}[0m",
        "╰──────────────┴───────────╯  ┗━┛ ╚═╝",
        "Emoji 🙂🚀 CJK 漢字かな  Ligatures -> != ==",
        "\u{1B}[48;2;67;49;64m selection-ish \u{1B}[0m \u{1B}[38;2;245;174;57m● waiting\u{1B}[0m \u{1B}[38;2;85;201;117m● done\u{1B}[0m",
        "\u{1B}[30;45m NORMAL \u{1B}[35;49m\u{E0B0}\u{1B}[0m src/main.rs  \u{1B}[1;31merror\u{1B}[0m[E0308]",
        "$ ",
    ].joined(separator: "\r\n")
    _ = t.write(sample)
    let frame = try TerminalFrame()
    frame.update(from: t)
    r.prepare(frame)
    let pad = 16 * 2
    let w = 64 * font.cellWidth + pad * 2, h = 14 * font.cellHeight + pad * 2
    var p = DrawParams()
    p.origin = (Float(pad), Float(pad))
    p.cursor.shape = .bar
    let px = try #require(r.snapshot(frame, width: w, height: h, params: p))
    let data = Data(px)
    let provider = try #require(CGDataProvider(data: data as CFData))
    let img = try #require(CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let url = URL(filePath: ProcessInfo.processInfo.environment["AXOLOTTY_RENDER_PNG"]!)
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, img, nil)
    #expect(CGImageDestinationFinalize(dest))
}
