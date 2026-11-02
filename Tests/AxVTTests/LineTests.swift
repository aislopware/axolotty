import AxVT
import Foundation
import Testing

@Suite struct LineTests {
    @Test func joinsSoftWrappedRows() throws {
        let t = try VTTerminal(cols: 10, rows: 4)
        _ = t.write("0123456789abcdef\r\nnext")
        let fromSecond = try #require(t.line(atViewportRow: 1))
        #expect(fromSecond.text.hasPrefix("0123456789abcdef"))
        #expect(fromSecond.cells[10] == VTLine.Cell(row: 1, col: 0))
        let next = try #require(t.line(atViewportRow: 2))
        #expect(next.text.hasPrefix("next"))
        #expect(next.cells.first?.row == 2)
    }

    @Test func carriesOSC8Links() throws {
        let t = try VTTerminal(cols: 30, rows: 2)
        _ = t.write("go \u{1b}]8;;https://example.com\u{1b}\\here\u{1b}]8;;\u{1b}\\ now")
        let line = try #require(t.line(atViewportRow: 0))
        #expect(line.uris[2] == nil)
        #expect(line.uris[3] == "https://example.com")
        #expect(line.uris[6] == "https://example.com")
        #expect(line.uris[7] == nil)
    }

    @Test func wideCharactersTakeOneCharacter() throws {
        let t = try VTTerminal(cols: 10, rows: 1)
        _ = t.write("日本a")
        let line = try #require(t.line(atViewportRow: 0))
        #expect(line.text.hasPrefix("日本a"))
        #expect(line.cells[2] == VTLine.Cell(row: 0, col: 4))
    }
}

@Suite struct ProgramStatusKindTests {
    @Test func blockedCarriesWhatItWaitsFor() throws {
        let t = try VTTerminal(cols: 40, rows: 2)
        let msg = Array("approve Bash: ls".utf8)
        let b64 = Data(msg).base64EncodedString()
        let events = t.write("\u{1b}]7501;state=blocked:app=claude-code:kind=permission:msg=\(b64)\u{7}")
        let status = events.compactMap { e -> VTProgramStatus? in
            if case let .programStatus(s) = e { return s }
            return nil
        }
        #expect(status.first?.state == .blocked)
        #expect(status.first?.kind == .permission)
        #expect(status.first?.message == "approve Bash: ls")
    }
}
