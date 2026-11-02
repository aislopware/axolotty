import AxVT
import Testing

@Suite struct SelectionTests {
    let geo = VTSelectionGesture.Geometry(cellWidth: 10, paddingLeft: 0, screenHeight: 100)

    @Test func dragSelectsCellsAndCopiesPlainText() throws {
        let t = try VTTerminal(cols: 40, rows: 5)
        _ = t.write("hello world\r\nsecond line")
        let g = VTSelectionGesture()
        g.press(t, col: 0, row: 0, x: 1, y: 5, timeNanos: 1_000_000)
        g.drag(t, col: 4, row: 0, x: 48, y: 5, geometry: geo)  // past the cell's midpoint
        g.release(t, col: 4, row: 0)
        #expect(t.selectionText() == "hello")
        t.clearSelection()
        #expect(t.selectionText() == nil)
    }

    @Test func doubleClickSelectsAWordAndTripleALine() throws {
        let t = try VTTerminal(cols: 40, rows: 5)
        _ = t.write("alpha beta gamma")
        let g = VTSelectionGesture()
        let base: UInt64 = 5_000_000_000
        g.press(t, col: 7, row: 0, x: 75, y: 5, timeNanos: base)
        g.release(t, col: 7, row: 0)
        g.press(t, col: 7, row: 0, x: 75, y: 5, timeNanos: base + 100_000_000)
        #expect(t.selectionText() == "beta")
        g.release(t, col: 7, row: 0)
        g.press(t, col: 7, row: 0, x: 75, y: 5, timeNanos: base + 200_000_000)
        #expect(t.selectionText() == "alpha beta gamma")
    }

    @Test func selectAllAndTrackingFlags() throws {
        let t = try VTTerminal(cols: 20, rows: 3)
        _ = t.write("one\r\ntwo")
        t.selectAll()
        #expect(t.selectionText()?.contains("two") == true)
        #expect(!t.mouseTracking)
        _ = t.write("\u{1B}[?1000h")
        #expect(t.mouseTracking)
        #expect(!t.isScrolledBack)
    }
}
