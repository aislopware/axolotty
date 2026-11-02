import GhosttyVT

/// The logical line under a viewport row: the row plus the soft-wrapped rows
/// before and after it (within the viewport), as text with each character's
/// cell, and the OSC 8 hyperlink of every cell that has one. What link
/// detection reads; one line at a time, on hover.
public struct VTLine: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public var row: Int, col: Int
        public init(row: Int, col: Int) {
            self.row = row
            self.col = col
        }
    }

    /// One Character per occupied cell (wide characters once; blanks as spaces).
    public var text: String
    /// The cell each Character of `text` starts at.
    public var cells: [Cell]
    /// The OSC 8 URI per Character, nil where the cell has none.
    public var uris: [String?]
}

extension VTTerminal {
    public func line(atViewportRow row: Int) -> VTLine? {
        let rowsCount = Int(rows), colsCount = Int(cols)
        guard row >= 0, row < rowsCount else { return nil }
        func flags(_ y: Int) -> (wrap: Bool, cont: Bool, links: Bool)? {
            var ref = GhosttyGridRef()
            ref.size = MemoryLayout<GhosttyGridRef>.size
            var p = GhosttyPoint()
            p.tag = GHOSTTY_POINT_TAG_VIEWPORT
            p.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(y))
            guard ghostty_terminal_grid_ref(handle, p, &ref) == GHOSTTY_SUCCESS else { return nil }
            var r: GhosttyRow = 0
            guard ghostty_grid_ref_row(&ref, &r) == GHOSTTY_SUCCESS else { return nil }
            var wrap = false, cont = false, links = false
            _ = ghostty_row_get(r, GHOSTTY_ROW_DATA_WRAP, &wrap)
            _ = ghostty_row_get(r, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &cont)
            _ = ghostty_row_get(r, GHOSTTY_ROW_DATA_HYPERLINK, &links)
            return (wrap, cont, links)
        }
        guard var f = flags(row) else { return nil }
        var first = row
        while f.cont, first > 0, let up = flags(first - 1), up.wrap {
            first -= 1
            f = up
        }
        var last = row
        while let cur = flags(last), cur.wrap, last + 1 < rowsCount { last += 1 }

        var line = VTLine(text: "", cells: [], uris: [])
        var cps = [UInt32](repeating: 0, count: 16)
        var uriBuf = [UInt8](repeating: 0, count: 2048)
        for y in first ... last {
            let hasLinks = flags(y)?.links ?? false
            for x in 0 ..< colsCount {
                var ref = GhosttyGridRef()
                ref.size = MemoryLayout<GhosttyGridRef>.size
                var p = GhosttyPoint()
                p.tag = GHOSTTY_POINT_TAG_VIEWPORT
                p.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                guard ghostty_terminal_grid_ref(handle, p, &ref) == GHOSTTY_SUCCESS else { continue }
                var cell: GhosttyCell = 0
                _ = ghostty_grid_ref_cell(&ref, &cell)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                _ = ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                var n = 0
                let r = cps.withUnsafeMutableBufferPointer { ghostty_grid_ref_graphemes(&ref, $0.baseAddress, $0.count, &n) }
                var s = ""
                if r == GHOSTTY_SUCCESS, n > 0 {
                    for c in cps.prefix(n) { if let u = Unicode.Scalar(c) { s.unicodeScalars.append(u) } }
                }
                // One cell is one grapheme; anything odd keeps its first.
                let ch: Character = s.count == 1 ? Character(s) : s.first ?? " "
                var uri: String?
                if hasLinks {
                    var len = 0
                    let ur = uriBuf.withUnsafeMutableBufferPointer {
                        ghostty_grid_ref_hyperlink_uri(&ref, $0.baseAddress, $0.count, &len)
                    }
                    if ur == GHOSTTY_SUCCESS, len > 0 { uri = String(decoding: uriBuf.prefix(len), as: UTF8.self) }
                }
                line.text.append(ch)
                line.cells.append(VTLine.Cell(row: y, col: x))
                line.uris.append(uri)
            }
        }
        return line
    }
}
