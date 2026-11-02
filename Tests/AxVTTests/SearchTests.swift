import AxVT
import Testing

@Suite struct SearchTests {
    @Test func findsAcrossScrollbackAndWalksNewestFirst() throws {
        let t = try VTTerminal(cols: 40, rows: 5)
        for i in 0 ..< 30 { _ = t.write("line \(i)\(i % 10 == 0 ? " ERROR here" : "")\r\n") }
        let s = try #require(VTSearch(t))
        defer { s.close() }
        s.setNeedle("error")  // ASCII ignores case
        s.update()
        #expect(s.total == 3)
        #expect(s.selectedIndex == nil)
        s.select(older: true)
        #expect(s.selectedIndex == 0)
        s.select(older: true)
        #expect(s.selectedIndex == 1)
        s.select(older: false)
        s.select(older: false)
        #expect(s.selectedIndex == 2)  // wraps past the newest
    }

    @Test func visibleRunsLandOnTheirCells() throws {
        let t = try VTTerminal(cols: 20, rows: 4)
        _ = t.write("abc needle xyz\r\nnothing\r\nneedle")
        let s = try #require(VTSearch(t))
        defer { s.close() }
        s.setNeedle("needle")
        s.update()
        s.select(older: true)  // the newest: row 2
        let runs = s.visibleRuns(rows: 4, cols: 20).sorted { $0.row < $1.row }
        #expect(runs == [VTSearch.Run(row: 0, from: 4, to: 9, selected: false),
                         VTSearch.Run(row: 2, from: 0, to: 5, selected: true)])
    }

    @Test func aMatchAcrossASoftWrapSplitsByRow() throws {
        let t = try VTTerminal(cols: 10, rows: 3)
        _ = t.write("12345678needle")
        let s = try #require(VTSearch(t))
        defer { s.close() }
        s.setNeedle("needle")
        s.update()
        #expect(s.total == 1)
        #expect(s.visibleRuns(rows: 3, cols: 10) == [VTSearch.Run(row: 0, from: 8, to: 9, selected: false),
                                                      VTSearch.Run(row: 1, from: 0, to: 3, selected: false)])
    }

    @Test func clearingTheNeedleEmptiesResults() throws {
        let t = try VTTerminal(cols: 20, rows: 3)
        _ = t.write("find me")
        let s = try #require(VTSearch(t))
        defer { s.close() }
        s.setNeedle("me")
        s.update()
        #expect(s.total == 1)
        s.setNeedle("")
        s.update()
        #expect(s.total == 0 && s.visibleRuns(rows: 3, cols: 20).isEmpty)
    }
}
