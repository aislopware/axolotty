import GhosttyVT

/// Click/drag text selection (cell, double-click word, triple-click line) on a
/// terminal, installed as its active selection so the renderer highlights it.
/// Selection is local to each client's mirror; it never reaches the host.
public final class VTSelectionGesture {
    private var gesture: GhosttySelectionGesture?
    private weak var lastTerminal: VTTerminal?

    public init() { _ = ghostty_selection_gesture_new(nil, &gesture) }

    /// Repeat-click window (the platform's double-click interval) and slop in pixels.
    public var repeatInterval: UInt64 = 500_000_000
    public var repeatDistance: Double = 8

    deinit { ghostty_selection_gesture_free(gesture, lastTerminal?.handle) }

    public struct Geometry: Sendable {
        public var cellWidth: UInt32
        public var paddingLeft: UInt32
        public var screenHeight: UInt32
        public init(cellWidth: UInt32, paddingLeft: UInt32, screenHeight: UInt32) {
            self.cellWidth = cellWidth
            self.paddingLeft = paddingLeft
            self.screenHeight = screenHeight
        }
    }

    /// Pointer down at viewport cell (col,row), surface position (x,y) in pixels.
    public func press(_ t: VTTerminal, col: Int, row: Int, x: Double, y: Double, timeNanos: UInt64) {
        apply(t, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS, col: col, row: row, x: x, y: y, time: timeNanos)
    }

    public func drag(_ t: VTTerminal, col: Int, row: Int, x: Double, y: Double, geometry: Geometry,
                     rectangle: Bool = false)
    {
        apply(t, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG, col: col, row: row, x: x, y: y, geometry: geometry,
              rectangle: rectangle)
    }

    public func release(_ t: VTTerminal, col: Int, row: Int) {
        apply(t, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE, col: col, row: row, x: 0, y: 0, install: false)
    }

    /// Click count of the current gesture (1 single, 2 word, 3 line), 0 when idle.
    public func clickCount(_ t: VTTerminal) -> Int {
        var n: UInt8 = 0
        _ = ghostty_selection_gesture_get(gesture, t.handle, GHOSTTY_SELECTION_GESTURE_DATA_CLICK_COUNT, &n)
        return Int(n)
    }

    public func dragged(_ t: VTTerminal) -> Bool {
        var d = false
        _ = ghostty_selection_gesture_get(gesture, t.handle, GHOSTTY_SELECTION_GESTURE_DATA_DRAGGED, &d)
        return d
    }

    public func reset(_ t: VTTerminal) { ghostty_selection_gesture_reset(gesture, t.handle) }

    private func apply(_ t: VTTerminal, _ type: GhosttySelectionGestureEventType, col: Int, row: Int, x: Double,
                       y: Double, time: UInt64? = nil, geometry: Geometry? = nil, rectangle: Bool = false,
                       install: Bool = true)
    {
        lastTerminal = t
        var ev: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_event_new(nil, &ev, type) == GHOSTTY_SUCCESS, let ev else { return }
        defer { ghostty_selection_gesture_event_free(ev) }
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        let clampedRow = max(0, min(row, Int(t.rows) - 1)), clampedCol = max(0, min(col, Int(t.cols) - 1))
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clampedCol), y: UInt32(clampedRow))
        let haveRef = ghostty_terminal_grid_ref(t.handle, point, &ref) == GHOSTTY_SUCCESS
        if haveRef { _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref) }
        var pos = GhosttySurfacePosition(x: x, y: y)
        if type != GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE {
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos)
        }
        if var time {
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time)
            var interval = repeatInterval
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
            var distance = repeatDistance
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
        }
        if let geometry {
            var g = GhosttySelectionGestureGeometry(columns: UInt32(t.cols), cell_width: geometry.cellWidth,
                                                    padding_left: geometry.paddingLeft,
                                                    screen_height: geometry.screenHeight)
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &g)
            var rect = rectangle
            _ = ghostty_selection_gesture_event_set(ev, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rect)
        }
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        let r = ghostty_selection_gesture_event(gesture, t.handle, ev, &sel)
        guard install else { return }
        if r == GHOSTTY_SUCCESS {
            _ = ghostty_terminal_set(t.handle, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
        } else if type == GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS {
            t.clearSelection()
        }
    }
}

extension VTTerminal {
    public func clearSelection() {
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
    }

    public func selectAll() {
        var sel = GhosttySelection()
        sel.size = MemoryLayout<GhosttySelection>.size
        if ghostty_terminal_select_all(handle, &sel) == GHOSTTY_SUCCESS {
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)
        }
    }

    public var hasSelection: Bool { selectionText(.plain) != nil }

    /// The selected text (copy semantics: unwrapped, trimmed), nil without a selection.
    public func selectionText(_ format: TextFormat = .plain) -> String? {
        var opts = GhosttyTerminalSelectionFormatOptions()
        opts.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        opts.emit = switch format {
        case .plain: GHOSTTY_FORMATTER_FORMAT_PLAIN
        case .vt: GHOSTTY_FORMATTER_FORMAT_VT
        case .html: GHOSTTY_FORMATTER_FORMAT_HTML
        }
        opts.unwrap = true
        opts.trim = true
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_terminal_selection_format_alloc(handle, nil, opts, &ptr, &len) == GHOSTTY_SUCCESS else {
            return nil
        }
        guard let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// Mouse tracking the program asked for (any mode means clicks go to it).
    public var mouseTracking: Bool {
        var mode = GHOSTTY_MOUSE_TRACKING_NONE
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &mode)
        return mode != GHOSTTY_MOUSE_TRACKING_NONE
    }

    /// Scrolled back from the bottom.
    public var isScrolledBack: Bool {
        var active = true
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active)
        return !active
    }
}
