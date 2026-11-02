import GhosttyVT

/// Find in a terminal's screen and scrollback, on libghostty's incremental
/// search (it follows the live screens, alternate-screen switches, reflow and
/// scrollback pruning). Matching is literal; ASCII letters ignore case.
///
/// Not thread-safe, and bound to one terminal: call everything while holding
/// that terminal (`MirrorTerminal.withTerminal`), and `close()` the same way
/// before dropping it.
public final class VTSearch {
    /// One match's cells on one viewport row (`to` inclusive).
    public struct Run: Equatable, Sendable {
        public var row: Int, from: Int, to: Int
        public var selected: Bool
        public init(row: Int, from: Int, to: Int, selected: Bool) {
            self.row = row
            self.from = from
            self.to = to
            self.selected = selected
        }
    }

    private var handle: GhosttySearch?
    private weak var terminal: VTTerminal?

    /// Whether this search belongs to `t` (a mirror replaces its terminal on a snapshot).
    public func isBound(to t: VTTerminal) -> Bool { terminal === t && handle != nil }

    public init?(_ terminal: VTTerminal) {
        var s: GhosttySearch?
        guard ghostty_search_new(nil, &s, terminal.handle) == GHOSTTY_SUCCESS, let s else { return nil }
        handle = s
        self.terminal = terminal
    }

    /// Releases the search's state in the terminal. Hold the terminal.
    public func close() {
        if let handle { ghostty_search_free(handle) }
        handle = nil
    }

    deinit { assert(handle == nil, "VTSearch dropped without close() while holding its terminal") }

    /// Sets what to look for; the same text again keeps the results. Empty clears.
    public func setNeedle(_ text: String) {
        guard let handle else { return }
        if text.isEmpty {
            _ = ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            return
        }
        var bytes = Array(text.utf8)
        bytes.withUnsafeMutableBufferPointer { buf in
            var s = GhosttyString(ptr: buf.baseAddress, len: buf.count)
            _ = ghostty_search_set(handle, GHOSTTY_SEARCH_OPT_NEEDLE, &s)
        }
    }

    /// Reads the terminal and searches until caught up with it.
    public func update() {
        guard let handle else { return }
        _ = ghostty_search_run(handle)
    }

    public var total: Int { value(GHOSTTY_SEARCH_DATA_TOTAL_MATCHES) ?? 0 }

    /// 0 is the newest match (nearest the bottom), as the find card counts.
    public var selectedIndex: Int? { value(GHOSTTY_SEARCH_DATA_SELECTED_INDEX) }

    /// Selects the next older match (`older`) or newer one, wrapping, and
    /// scrolls the viewport to it when it is off screen.
    public func select(older: Bool) {
        guard let handle else { return }
        _ = ghostty_search_set(handle, older ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV, nil)
    }

    /// The matches on screen, split into one run per row, clipped to `rows`.
    public func visibleRuns(rows: Int, cols: Int) -> [Run] {
        guard let handle else { return [] }
        var buf = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        let first = ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buf)
        guard first == GHOSTTY_SUCCESS || first == GHOSTTY_OUT_OF_SPACE, buf.len > 0 else { return [] }
        var matches = [GhosttySelection](repeating: GhosttySelection(), count: buf.len)
        let ok = matches.withUnsafeMutableBufferPointer { p -> Bool in
            for i in p.indices { p[i].size = MemoryLayout<GhosttySelection>.size }
            var b = GhosttySelectionBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
            let r = ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &b)
            return r == GHOSTTY_SUCCESS && b.len == p.count
        }
        guard ok else { return [] }
        let chosen = selectedSpan()
        var runs: [Run] = []
        for m in matches {
            guard let span = viewportSpan(m) else { continue }
            let sel = chosen.map { $0 == span } ?? false
            runs += Self.split(span, rows: rows, cols: cols, selected: sel)
        }
        return runs
    }

    // MARK: Private

    private struct Span: Equatable { var start: GhosttyPointCoordinate, end: GhosttyPointCoordinate
        static func == (a: Span, b: Span) -> Bool {
            a.start.x == b.start.x && a.start.y == b.start.y && a.end.x == b.end.x && a.end.y == b.end.y
        }
    }

    private func selectedSpan() -> Span? {
        guard let handle else { return nil }
        var m = GhosttySelection()
        m.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_search_get(handle, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &m) == GHOSTTY_SUCCESS else { return nil }
        return viewportSpan(m)
    }

    /// The match in viewport coordinates, start before end; nil when an end is off screen
    /// (a match straddling the top edge is drawn from the first visible row).
    private func viewportSpan(_ m: GhosttySelection) -> Span? {
        var a = GhosttyPointCoordinate(), b = GhosttyPointCoordinate()
        guard let terminal else { return nil }
        var sref = m.start, eref = m.end
        let ra = ghostty_terminal_point_from_grid_ref(terminal.handle, &sref, GHOSTTY_POINT_TAG_VIEWPORT, &a)
        let rb = ghostty_terminal_point_from_grid_ref(terminal.handle, &eref, GHOSTTY_POINT_TAG_VIEWPORT, &b)
        switch (ra == GHOSTTY_SUCCESS, rb == GHOSTTY_SUCCESS) {
        case (true, true): break
        case (false, true): a = GhosttyPointCoordinate(x: 0, y: 0)  // starts above the viewport
        default: return nil
        }
        if (a.y, a.x) > (b.y, b.x) { swap(&a, &b) }
        return Span(start: a, end: b)
    }

    private static func split(_ s: Span, rows: Int, cols: Int, selected: Bool) -> [Run] {
        var out: [Run] = []
        let last = min(Int(s.end.y), rows - 1)
        guard Int(s.start.y) <= last else { return [] }
        for y in Int(s.start.y) ... last {
            let from = y == Int(s.start.y) ? Int(s.start.x) : 0
            let to = y == Int(s.end.y) ? Int(s.end.x) : cols - 1
            if from <= to { out.append(Run(row: y, from: from, to: to, selected: selected)) }
        }
        return out
    }

    private func value(_ key: GhosttySearchData) -> Int? {
        guard let handle else { return nil }
        var v = 0
        return ghostty_search_get(handle, key, &v) == GHOSTTY_SUCCESS ? v : nil
    }
}
