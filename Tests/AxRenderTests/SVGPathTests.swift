import AxFrame
import AxRender
import Foundation
import CoreGraphics
import Testing

@Suite("SVG path")
struct SVGPathTests {
    @Test func compactNumbersAndImplicitLineto() throws {
        // "M1.5.5" is (1.5, 0.5); after M, bare pairs are linetos; "-1-2" is two numbers.
        let p = try #require(SVGPath.parse("M1.5.5 3 .5l-1-2z"))
        let b = p.boundingBoxOfPath
        #expect(abs(b.minX - 1.5) < 1e-6 && abs(b.maxX - 3) < 1e-6)
        #expect(abs(b.minY - -1.5) < 1e-6 && abs(b.maxY - 0.5) < 1e-6)
    }

    @Test func arcFlagsWithoutSeparators() throws {
        // A half circle of radius 5 from (0,0) to (10,0), flags packed: "0 01" + "10 0".
        let p = try #require(SVGPath.parse("M0 0a5 5 0 0110 0"))
        let b = p.boundingBoxOfPath
        #expect(abs(b.width - 10) < 0.01)
        #expect(abs(b.height - 5) < 0.05)  // bulges 5 to one side only
    }

    @Test func undersizedArcRadiusIsScaledUp() throws {
        // Radius 1 cannot span 10: SVG scales it to 5.
        let p = try #require(SVGPath.parse("M0 0A1 1 0 0 1 10 0"))
        #expect(abs(p.boundingBoxOfPath.height - 5) < 0.05)
    }

    @Test func exponentsAndSmoothCurves() throws {
        // The second T pair is "1e1 0" = (10, 0): the path must end there.
        let p = try #require(SVGPath.parse("M0 0C0 10 10 10 10 0S20-10 20 0Q25 5 30 0T40 0 1e1 0"))
        #expect(abs(p.currentPoint.x - 10) < 1e-9 && abs(p.currentPoint.y) < 1e-9)
    }

    @Test func rejectsGarbage() {
        #expect(SVGPath.parse("12 34") == nil)
        #expect(SVGPath.parse("M0 0 L") == nil)
    }

    @Test(arguments: [BrandMark.claude, .codex, .gemini].map(\.name))
    func brandMarksFillTheirBox(_ name: String) throws {
        let mark = try #require([BrandMark.claude, .codex, .gemini].first { $0.name == name })
        let b = try #require(mark.path).boundingBoxOfPath
        // Each mark spans (nearly) its 24-unit box and never leaves it.
        #expect(b.minX >= -0.01 && b.minY >= -0.01 && b.maxX <= 24.01 && b.maxY <= 24.01)
        #expect(b.width > 20 && b.height > 20)
    }
}

@Suite("Minimum contrast")
struct MinimumContrastTests {
    private func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000
    }

    private func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func l(_ v: UInt32) -> Double {
                let s = Double(v & 0xFF) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * l(c) + 0.7152 * l(c >> 8) + 0.0722 * l(c >> 16)
        }
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func leavesReadablePairsAlone() {
        let fg = pack(0x2A, 0x24, 0x29), bg = pack(0xFC, 0xF9, 0xFB)
        #expect(ax_min_contrast(fg, bg, 3) == fg)
    }

    @Test func darkensPaleTextOnLightGround() {
        // Starship's bright cyan prompt on Axolotty Day.
        let fg = pack(0x8B, 0xE9, 0xFD), bg = pack(0xFC, 0xF9, 0xFB)
        let out = ax_min_contrast(fg, bg, 3)
        #expect(ratio(out, bg) >= 2.98)
        #expect(ratio(out, bg) < 3.3)  // the least change, not black
        #expect(out & 0xFF00_0000 == 0xFF00_0000)
    }

    @Test func lightensDimTextOnDarkGround() {
        let fg = pack(0x30, 0x2C, 0x2F), bg = pack(0x15, 0x12, 0x14)
        let out = ax_min_contrast(fg, bg, 3)
        #expect(ratio(out, bg) >= 2.98)
        #expect(lum8(out) > lum8(fg))
    }

    @Test func offWhenRatioIsOne() {
        let fg = pack(0xFF, 0xFF, 0xF0), bg = pack(0xFF, 0xFF, 0xFF)
        #expect(ax_min_contrast(fg, bg, 1) == fg)
    }

    private func lum8(_ c: UInt32) -> UInt32 { (c & 0xFF) + (c >> 8 & 0xFF) + (c >> 16 & 0xFF) }
}
