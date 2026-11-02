import GhosttyVT
import Foundation

extension VTTerminal {
    /// The output of the latest command that printed any, read from the
    /// shell's OSC 133 marks: walking up from the cursor past prompt rows to
    /// the first output row, then taking the whole output it belongs to (copy
    /// semantics: unwrapped, trimmed). While a command runs, its output so far.
    /// nil without marks or output.
    public func lastCommandOutput() -> String? {
        guard activeScreen == .primary else { return nil }
        let top = scrollbackRows
        var y = top + Int(cursor.y)
        let floor = max(0, y - 20000)
        while y >= floor {
            defer { y -= 1 }
            guard var ref = screenRef(row: y) else { continue }
            var row: GhosttyRow = 0
            guard ghostty_grid_ref_row(&ref, &row) == GHOSTTY_SUCCESS else { continue }
            var mark = GHOSTTY_ROW_SEMANTIC_NONE
            _ = ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &mark)
            if mark != GHOSTTY_ROW_SEMANTIC_NONE { continue }
            var sel = GhosttySelection()
            sel.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_output(handle, ref, &sel) == GHOSTTY_SUCCESS else { continue }
            if let text = format(sel), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    private func screenRef(row: Int) -> GhosttyGridRef? {
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        var p = GhosttyPoint()
        p.tag = GHOSTTY_POINT_TAG_SCREEN
        p.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(row))
        return ghostty_terminal_grid_ref(handle, p, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func format(_ sel: GhosttySelection) -> String? {
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        opts.unwrap = true
        opts.trim = true
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        let r = withUnsafePointer(to: sel) { s in
            opts.selection = s
            return ghostty_terminal_selection_format_alloc(handle, nil, opts, &ptr, &len)
        }
        guard r == GHOSTTY_SUCCESS else { return nil }
        guard let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }
}
