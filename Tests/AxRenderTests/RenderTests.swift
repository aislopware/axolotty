@testable import AxRender
import AxVT
import CoreText
import Metal
import Testing

/// Offscreen pixel tests: build a frame from a real terminal, render it with
/// Metal into a texture, and read pixels back. No window, no display.
@Suite(.serialized) struct RenderTests {
    static let font = TerminalFont(regular: CTFontCreateWithName("Menlo" as CFString, 13, nil), scale: 2)

    struct Rig {
        let renderer: TerminalRenderer
        let term: VTTerminal
        let frame: TerminalFrame
        let w: Int, h: Int

        init(cols: UInt16 = 10, rows: UInt16 = 3) throws {
            renderer = try TerminalRenderer(font: RenderTests.font)
            term = try VTTerminal(cols: cols, rows: rows)
            var palette: [(UInt8, UInt8, UInt8)] = (0 ..< 256).map { (UInt8($0), UInt8($0), UInt8($0)) }
            palette[1] = (220, 40, 40)
            palette[4] = (40, 80, 220)
            term.setDefaultColors(foreground: (230, 230, 230), background: (20, 18, 20), cursor: nil, palette: palette)
            frame = try TerminalFrame()
            w = Int(cols) * RenderTests.font.cellWidth
            h = Int(rows) * RenderTests.font.cellHeight
        }

        func render(_ text: String, cursor: CursorStyle.Shape? = nil) -> [UInt8] {
            _ = term.write(text)
            frame.update(from: term)
            renderer.prepare(frame)
            var p = DrawParams()
            p.cursor.shape = cursor
            return renderer.snapshot(frame, width: w, height: h, params: p) ?? []
        }

        /// BGRA at pixel (x, y).
        func pixel(_ px: [UInt8], _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4
            return (Int(px[i + 2]), Int(px[i + 1]), Int(px[i]))
        }

        /// Pixels in cell (col,row) whose colour differs from the background.
        func inked(_ px: [UInt8], col: Int, row: Int) -> [(r: Int, g: Int, b: Int)] {
            let cw = RenderTests.font.cellWidth, ch = RenderTests.font.cellHeight
            var out: [(r: Int, g: Int, b: Int)] = []
            for y in row * ch ..< (row + 1) * ch {
                for x in col * cw ..< (col + 1) * cw {
                    let p = pixel(px, x, y)
                    if abs(p.r - 20) + abs(p.g - 18) + abs(p.b - 20) > 30 { out.append(p) }
                }
            }
            return out
        }
    }

    @Test func instanceLayoutsMatchTheShader() {
        #expect(MemoryLayout<Uniforms>.stride == 56)
        #expect(RenderLayout.glyphInstanceSize == 24)
        #expect(RenderLayout.rectInstanceSize == 24)
    }

    @Test func metricsArePixelAligned() {
        let f = Self.font
        #expect(f.cellWidth > 0 && f.cellHeight > f.cellWidth)
        #expect(f.baseline > 0 && f.baseline < f.cellHeight)
        #expect(f.underlineY > Float(f.baseline) && f.underlineY < Float(f.cellHeight))
    }

    @Test func clearsToTheTerminalBackground() throws {
        let rig = try Rig()
        let px = rig.render("")
        let p = rig.pixel(px, 3, 3)
        #expect(p.r == 20 && p.g == 18 && p.b == 20)
    }

    @Test func drawsColouredText() throws {
        let rig = try Rig()
        let px = rig.render("\u{1B}[31mX")
        let ink = rig.inked(px, col: 0, row: 0)
        #expect(ink.count > 20, "glyph pixels exist")
        #expect(ink.contains { $0.r > 150 && $0.g < 90 }, "tinted with palette red")
        #expect(rig.inked(px, col: 1, row: 0).isEmpty, "nothing bleeds into the next cell")
    }

    /// A guess replaces what its cell shows: a character ⌫ takes back is
    /// gone before the host's echo says so, and its neighbours stay.
    @Test func aGuessedBlankHidesTheCharacterUnderIt() throws {
        let rig = try Rig()
        let before = rig.render("ab")
        #expect(!rig.inked(before, col: 1, row: 0).isEmpty)
        rig.frame.setOverlay([(row: 0, col: 1, character: " ")], marked: false, cursor: (x: 1, y: 0))
        let after = rig.render("")
        #expect(rig.inked(after, col: 1, row: 0).isEmpty, "b is taken back")
        #expect(!rig.inked(after, col: 0, row: 0).isEmpty, "a stays")
        rig.frame.setOverlay([(row: 0, col: 1, character: "_")], marked: false, cursor: (x: 2, y: 0))
        let retyped = rig.inked(rig.render(""), col: 1, row: 0)
        #expect(!retyped.isEmpty && retyped.count < rig.inked(before, col: 1, row: 0).count, "_ in place of b, not over it")
    }

    @Test func paintsCellBackgrounds() throws {
        let rig = try Rig()
        let px = rig.render("\u{1B}[44m  \u{1B}[0m")
        let cw = Self.font.cellWidth, ch = Self.font.cellHeight
        let p = rig.pixel(px, cw + cw / 2, ch / 2)
        #expect(p.b > 180 && p.r < 80, "second cell is blue")
        let q = rig.pixel(px, cw * 2 + cw / 2, ch / 2)
        #expect(q.b < 40, "third cell keeps the default background")
    }

    @Test func boxDrawingJoinsAcrossCells() throws {
        let rig = try Rig()
        let px = rig.render("───")
        let cw = Self.font.cellWidth, ch = Self.font.cellHeight
        // The horizontal line touches both edges of the middle cell.
        let lit = (0 ..< ch).contains { y in
            rig.pixel(px, cw, y).r > 150 && rig.pixel(px, cw * 2 - 1, y).r > 150
        }
        #expect(lit)
    }

    @Test func emojiUseTheColourAtlas() throws {
        let rig = try Rig()
        let px = rig.render("🙂")
        let ink = rig.inked(px, col: 0, row: 0) + rig.inked(px, col: 1, row: 0)
        #expect(ink.contains { abs($0.r - $0.g) > 40 || abs($0.g - $0.b) > 40 }, "emoji keep their own colours")
    }

    @Test func blockCursorInvertsItsCell() throws {
        let rig = try Rig()
        let px = rig.render("A\u{1B}[1;1H", cursor: .block)
        let corner = rig.pixel(px, 1, 1)
        #expect(corner.r > 150 && corner.b > 150, "cursor block drawn in the accent")
    }

    @Test func incrementalBuildsOnlyRedrawWhatChanged() throws {
        let rig = try Rig()
        _ = rig.render("hello")
        rig.frame.update(from: rig.term)
        #expect(!rig.renderer.prepare(rig.frame), "no change, no dirty rows")
        _ = rig.term.write("!")
        rig.frame.update(from: rig.term)
        #expect(rig.renderer.prepare(rig.frame))
        // What a shell sends around each prompt besides the prompt itself
        // changes nothing on screen: no rows to draw (the view skips the frame).
        for quiet in ["\u{1B}]0;title\u{07}", "\u{1B}]7;file://h/tmp\u{07}", "\u{07}", "\u{1B}[6n"] {
            _ = rig.term.write(quiet)
            rig.frame.update(from: rig.term)
            #expect(!rig.renderer.prepare(rig.frame), "\(quiet.debugDescription) draws nothing")
        }
        // A selection is drawn in the rows: selecting and clearing redraw them.
        rig.term.selectAll()
        rig.frame.update(from: rig.term)
        #expect(rig.renderer.prepare(rig.frame), "selected")
        rig.term.clearSelection()
        rig.frame.update(from: rig.term)
        #expect(rig.renderer.prepare(rig.frame), "cleared")
    }
}
