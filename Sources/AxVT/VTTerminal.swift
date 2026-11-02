package import GhosttyVT

/// Events a terminal raises while it parses program output.
///
/// They are collected during `write(_:)` and handed back to the caller in one
/// batch, so no callback ever re-enters the caller while the terminal is mid-parse.
public enum VTEvent: Equatable, Sendable {
    case bell
    case titleChanged(String)
    case pwdChanged(String)
    case notification(title: String, body: String)
    case progress(VTProgress)
    case programStatus(VTProgramStatus)
    case prompt(VTPromptEvent)
    case reset
    case clipboardWrite(String)
}

public enum VTProgress: Equatable, Sendable {
    case remove
    case set(Int)
    case error(Int?)
    case indeterminate
    case paused(Int?)
}

/// One OSC 7501 program status record.
public struct VTProgramStatus: Equatable, Sendable {
    public enum State: UInt8, Sendable, Codable { case idle, working, done, blocked, error, clear }
    /// What a blocked program waits for (`kind=`); `none` when it didn't say.
    public enum Kind: UInt8, Sendable, Codable { case none, permission, question, auth }
    public var id: String
    public var state: State
    public var app: String
    public var title: String
    public var message: String
    public var kind: Kind
    /// 0…100 while working or blocked (`progress=`); nil without a percentage.
    public var progress: Int?

    public init(id: String, state: State, app: String = "", title: String = "", message: String = "", kind: Kind = .none,
                progress: Int? = nil)
    {
        self.progress = progress
        self.id = id
        self.state = state
        self.app = app
        self.title = title
        self.message = message
        self.kind = kind
    }
}

/// OSC 133 shell integration step.
public enum VTPromptEvent: Equatable, Sendable {
    case promptStart
    case inputStart
    case commandStart(command: String)
    case commandEnd(exitCode: Int32?)
}

public struct VTCursor: Equatable, Sendable {
    public var x: UInt16
    public var y: UInt16
    public var visible: Bool
}

public enum VTScreen: Sendable { case primary, alternate }

/// Swift owner of one `GhosttyTerminal`.
///
/// Not thread-safe: confine an instance to one thread or lock around it (the
/// session layer does the latter). `replies` controls whether the terminal
/// answers queries (DA, DSR, …) through `onReply`; a mirror of a remote
/// terminal must never answer, only the authoritative one does.
public final class VTTerminal {
    public private(set) var cols: UInt16
    public private(set) var rows: UInt16
    package let handle: GhosttyTerminal
    private let sink: EventSink

    /// Bytes the terminal wants to send back to the program (query replies).
    public var onReply: ((UnsafeRawBufferPointer) -> Void)? {
        get { sink.reply }
        set { sink.reply = newValue }
    }

    /// - Parameters:
    ///   - continuationBytes: when non-zero, the terminal keeps the bytes of an
    ///     unfinished escape sequence so `snapshot()` can be taken at any byte
    ///     boundary and the stream resumed on the restored copy. Hosts enable it.
    public init(
        cols: UInt16, rows: UInt16, scrollbackBytes: Int = 10 << 20, replies: Bool = true, continuationBytes: Int = 0
    ) throws(VTError) {
        var term: GhosttyTerminal?
        try check(ghostty_terminal_new(nil, &term, cols, rows))
        guard let term else { throw .outOfMemory }
        handle = term
        self.cols = cols
        self.rows = rows
        sink = EventSink()

        let ud = Unmanaged.passUnretained(sink).toOpaque()
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, ud)
        var limit = scrollbackBytes
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit)
        if continuationBytes > 0 {
            var cont = continuationBytes
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &cont)
        }
        installCallbacks(replies: replies)
    }

    /// Wraps a terminal restored from a snapshot; takes ownership.
    init(adopting term: GhosttyTerminal, replies: Bool) {
        handle = term
        sink = EventSink()
        var c: UInt16 = 0
        var r: UInt16 = 0
        _ = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &c)
        _ = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        cols = c
        rows = r
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(sink).toOpaque())
        installCallbacks(replies: replies)
    }

    deinit { ghostty_terminal_free(handle) }

    private func installCallbacks(replies: Bool) {
        let set = { (opt: GhosttyTerminalOption, fn: UnsafeRawPointer?) in
            _ = ghostty_terminal_set(self.handle, opt, fn)
        }
        if replies {
            let writePty: GhosttyTerminalWritePtyFn = { _, ud, data, len in
                guard let ud, let data, len > 0 else { return }
                EventSink.from(ud).reply?(UnsafeRawBufferPointer(start: data, count: len))
            }
            set(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self))
            installQueryAnswers()
        }
        let bell: GhosttyTerminalBellFn = { _, ud in EventSink.from(ud).events.append(.bell) }
        set(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))

        let title: GhosttyTerminalTitleChangedFn = { term, ud in
            var s = GhosttyString()
            guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS else { return }
            EventSink.from(ud).events.append(.titleChanged(String(s)))
        }
        set(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))

        let pwd: GhosttyTerminalPwdChangedFn = { term, ud in
            var s = GhosttyString()
            guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS else { return }
            EventSink.from(ud).events.append(.pwdChanged(String(s)))
        }
        set(GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwd, to: UnsafeRawPointer.self))

        let notify: GhosttyTerminalDesktopNotificationFn = { _, ud, n in
            guard let n else { return }
            EventSink.from(ud).events.append(.notification(title: String(n.pointee.title), body: String(n.pointee.body)))
        }
        set(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notify, to: UnsafeRawPointer.self))

        let progress: GhosttyTerminalProgressReportFn = { _, ud, r in
            guard let r else { return }
            let pct = r.pointee.progress >= 0 ? Int(r.pointee.progress) : nil
            let p: VTProgress = switch r.pointee.state {
            case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: .set(pct ?? 0)
            case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: .error(pct)
            case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: .indeterminate
            case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: .paused(pct)
            default: .remove
            }
            EventSink.from(ud).events.append(.progress(p))
        }
        set(GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(progress, to: UnsafeRawPointer.self))

        let status: GhosttyTerminalProgramStatusFn = { _, ud, r in
            guard let r else { return }
            let s = r.pointee
            let state = VTProgramStatus.State(rawValue: UInt8(truncatingIfNeeded: s.state.rawValue)) ?? .idle
            let kind = VTProgramStatus.Kind(rawValue: UInt8(truncatingIfNeeded: s.kind.rawValue)) ?? .none
            EventSink.from(ud).events.append(.programStatus(VTProgramStatus(
                id: String(s.id), state: state, app: String(s.app), title: String(s.title), message: String(s.message),
                kind: kind, progress: s.progress >= 0 ? Int(s.progress) : nil)))
        }
        set(GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(status, to: UnsafeRawPointer.self))

        let prompt: GhosttyTerminalSemanticPromptFn = { _, ud, e in
            guard let e else { return }
            let ev = e.pointee
            let mapped: VTPromptEvent? = switch ev.kind {
            case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START:
                ev.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY ? .promptStart : nil
            case GHOSTTY_SEMANTIC_PROMPT_INPUT_START: .inputStart
            case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START: .commandStart(command: String(ev.command))
            case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END: .commandEnd(exitCode: ev.has_exit_code ? ev.exit_code : nil)
            default: nil
            }
            if let mapped { EventSink.from(ud).events.append(.prompt(mapped)) }
        }
        set(GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(prompt, to: UnsafeRawPointer.self))

        let reset: GhosttyTerminalResetFn = { _, ud in EventSink.from(ud).events.append(.reset) }
        set(GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(reset, to: UnsafeRawPointer.self))

        let clip: GhosttyTerminalClipboardWriteFn = { _, ud, w in
            guard let w else { return }
            let write = w.pointee
            var text = ""
            for i in 0 ..< write.contents_len {
                let c = write.contents[i]
                let mime = String(c.mime)
                if mime.isEmpty || mime.hasPrefix("text/plain") {
                    text = String(c.data)
                    break
                }
            }
            // The embedder decides; we accept and surface it so the UI can apply policy.
            var reply = GhosttyClipboardWriteReply()
            reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
            reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            write.reply(w, &reply)
            EventSink.from(ud).events.append(.clipboardWrite(text))
        }
        set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clip, to: UnsafeRawPointer.self))
    }

    /// Answers for what programs ask the terminal (only the authoritative
    /// terminal answers; a mirror stays silent):
    /// - DA1 `?62;22;52c` (VT220-level, ANSI colour, clipboard writes), DA2
    ///   `>1;10;0c` (what Ghostty answers, so programs that sniff it treat
    ///   us alike), DA3 unanswered;
    /// - XTVERSION "Axolotty <version>"; XTGETTCAP TN "xterm-256color";
    /// - XTWINOPS 14/16/18/19 t and mode 2048 from the size driver's cells;
    /// - CSI ?996n from the appearance (mode 2031 reports go out on change).
    private func installQueryAnswers() {
        let set = { (opt: GhosttyTerminalOption, fn: UnsafeRawPointer?) in
            _ = ghostty_terminal_set(self.handle, opt, fn)
        }
        let da: GhosttyTerminalDeviceAttributesFn = { _, ud, out in
            guard let out else { return false }
            let sink = EventSink.from(ud)
            var a = GhosttyDeviceAttributes()
            a.primary.conformance_level = 62
            a.primary.features.0 = 22
            a.primary.num_features = 1
            if sink.clipboardWrites {
                a.primary.features.1 = 52
                a.primary.num_features = 2
            }
            a.secondary.device_type = 1
            a.secondary.firmware_version = 10
            a.secondary.rom_cartridge = 0
            a.tertiary.unit_id = 0
            out.pointee = a
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(da, to: UnsafeRawPointer.self))

        let version: GhosttyTerminalXtversionFn = { _, ud in
            let sink = EventSink.from(ud)
            return sink.version.withUnsafeBufferPointer { GhosttyString(ptr: $0.baseAddress, len: $0.count) }
        }
        set(GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(version, to: UnsafeRawPointer.self))

        let size: GhosttyTerminalSizeFn = { term, ud, out in
            guard let out else { return false }
            let sink = EventSink.from(ud)
            var c: UInt16 = 0, r: UInt16 = 0
            _ = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_COLS, &c)
            _ = ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_ROWS, &r)
            out.pointee = GhosttySizeReportSize(rows: r, columns: c, cell_width: max(1, sink.cellWidth),
                                                cell_height: max(1, sink.cellHeight))
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))

        let scheme: GhosttyTerminalColorSchemeFn = { _, ud, out in
            guard let out else { return false }
            out.pointee = EventSink.from(ud).dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            return true
        }
        set(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(scheme, to: UnsafeRawPointer.self))

        var name = Array("xterm-256color".utf8)
        name.withUnsafeMutableBufferPointer { b in
            var str = GhosttyString(ptr: b.baseAddress, len: b.count)
            _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &str)
        }
    }

    /// What XTVERSION reports after "Axolotty ".
    public func setVersion(_ v: String) { sink.version = Array("Axolotty \(v)".utf8) }

    /// The size driver's cell, in pixels (for XTWINOPS and mode 2048).
    public func setCellSize(width: UInt32, height: UInt32) {
        sink.cellWidth = width
        sink.cellHeight = height
    }

    /// Records the appearance; returns the report to send the program when it
    /// asked to hear about changes (mode 2031) and the scheme flipped.
    public func setColorScheme(dark: Bool) -> [UInt8]? {
        let changed = sink.dark != dark
        sink.dark = dark
        guard changed, mode(2031) else { return nil }
        var buf = [CChar](repeating: 0, count: 16)
        var n = 0
        guard ghostty_color_scheme_report_encode(dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT,
                                                 &buf, buf.count, &n) == GHOSTTY_SUCCESS else { return nil }
        return buf.prefix(n).map { UInt8(bitPattern: $0) }
    }

    // MARK: - Feeding

    /// Parses program output. Returns the events it raised, in order.
    @discardableResult
    public func write(_ bytes: UnsafeRawBufferPointer) -> [VTEvent] {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return [] }
        ghostty_terminal_vt_write(handle, base.assumingMemoryBound(to: UInt8.self), bytes.count)
        return sink.drain()
    }

    @discardableResult
    public func write(_ bytes: some Sequence<UInt8>) -> [VTEvent] {
        let array = Array(bytes)
        return array.withUnsafeBytes { write($0) }
    }

    @discardableResult
    public func write(_ string: String) -> [VTEvent] { write(Array(string.utf8)) }

    public func resize(cols: UInt16, rows: UInt16, cellWidth: UInt32 = 0, cellHeight: UInt32 = 0) {
        guard cols > 0, rows > 0 else { return }
        _ = ghostty_terminal_resize(handle, cols, rows, cellWidth, cellHeight)
        self.cols = cols
        self.rows = rows
    }

    /// Re-applies limits (a terminal restored from a snapshot starts with defaults).
    public func setLimits(scrollbackBytes: Int, continuationBytes: Int) {
        var limit = scrollbackBytes
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit)
        var cont = continuationBytes
        _ = ghostty_terminal_set(handle, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &cont)
    }

    // MARK: - Queries

    public var cursor: VTCursor {
        var x: UInt16 = 0, y: UInt16 = 0
        var visible = true
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        return VTCursor(x: x, y: y, visible: visible)
    }

    public var title: String { stringData(GHOSTTY_TERMINAL_DATA_TITLE) }
    public var pwd: String { stringData(GHOSTTY_TERMINAL_DATA_PWD) }

    public var activeScreen: VTScreen {
        var s = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &s)
        return s == GHOSTTY_TERMINAL_SCREEN_ALTERNATE ? .alternate : .primary
    }

    /// The cursor sits at a shell prompt or its input line (needs OSC 133 marks).
    public var cursorAtPrompt: Bool {
        var v = false
        _ = ghostty_terminal_get(handle, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &v)
        return v
    }

    private func stringData(_ key: GhosttyTerminalData) -> String {
        var s = GhosttyString()
        guard ghostty_terminal_get(handle, key, &s) == GHOSTTY_SUCCESS else { return "" }
        return String(s)
    }

    // MARK: - Viewport

    /// `prompts(n)`: n shell prompts down (negative: up), from the viewport top
    /// (needs OSC 133 marks; a no-op without them).
    public enum Scroll: Sendable { case top, bottom, delta(Int), prompts(Int) }

    public func scrollViewport(_ scroll: Scroll) {
        var behavior = GhosttyTerminalScrollViewport()
        switch scroll {
        case .top: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        case .bottom: behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        case let .delta(d):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = d
        case let .prompts(n):
            behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA_PROMPT
            behavior.value.delta_prompt = n
        }
        ghostty_terminal_scroll_viewport(handle, behavior)
    }

    // MARK: - Formatting

    public enum TextFormat: Sendable { case plain, vt, html }

    /// The whole screen (including scrollback) as text.
    public func text(_ format: TextFormat = .plain, trim: Bool = true, unwrap: Bool = false) -> String {
        var opts = GhosttyFormatterTerminalOptions()
        opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
        opts.emit = switch format {
        case .plain: GHOSTTY_FORMATTER_FORMAT_PLAIN
        case .vt: GHOSTTY_FORMATTER_FORMAT_VT
        case .html: GHOSTTY_FORMATTER_FORMAT_HTML
        }
        opts.trim = trim
        opts.unwrap = unwrap
        opts.extra.size = MemoryLayout<GhosttyFormatterTerminalExtra>.size
        opts.extra.screen.size = MemoryLayout<GhosttyFormatterScreenExtra>.size
        var fmt: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &fmt, handle, opts) == GHOSTTY_SUCCESS, let fmt else { return "" }
        defer { ghostty_formatter_free(fmt) }
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        guard ghostty_formatter_format_alloc(fmt, nil, &ptr, &len) == GHOSTTY_SUCCESS, let ptr else { return "" }
        defer { ghostty_free(nil, ptr, len) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    // MARK: - Snapshots

    /// Encodes the complete terminal state (screens, scrollback, modes, unfinished
    /// parser input) in libghostty's CRC-protected snapshot format.
    public func snapshot() throws(VTError) -> [UInt8] {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len = 0
        try check(ghostty_snapshot_encode_alloc(handle, nil, &ptr, &len))
        guard let ptr else { return [] }
        defer { ghostty_free(nil, ptr, len) }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    /// Restores a terminal from `snapshot()` output.
    public static func restore(_ bytes: [UInt8], replies: Bool = false) throws(VTError) -> VTTerminal {
        var term: GhosttyTerminal?
        let result: GhosttyResult = bytes.withUnsafeBufferPointer { buf in
            var dec: GhosttySnapshotDecoder?
            let r = ghostty_snapshot_decoder_new_buf(nil, &dec, buf.baseAddress, buf.count)
            guard r == GHOSTTY_SUCCESS, let dec else { return r }
            defer { ghostty_snapshot_decoder_free(dec) }
            return ghostty_snapshot_decoder_decode(dec, &term)
        }
        try check(result)
        guard let term else { throw .invalidValue }
        return VTTerminal(adopting: term, replies: replies)
    }
}

// MARK: - Plumbing

public enum VTError: Error, Equatable, Sendable {
    case outOfMemory, invalidValue, outOfSpace, noValue, io, limitExceeded, rejected, unknown(Int32)
}

@inline(__always)
func check(_ r: GhosttyResult) throws(VTError) {
    switch r {
    case GHOSTTY_SUCCESS: return
    case GHOSTTY_OUT_OF_MEMORY: throw .outOfMemory
    case GHOSTTY_INVALID_VALUE: throw .invalidValue
    case GHOSTTY_OUT_OF_SPACE: throw .outOfSpace
    case GHOSTTY_NO_VALUE: throw .noValue
    case GHOSTTY_IO_ERROR: throw .io
    case GHOSTTY_LIMIT_EXCEEDED: throw .limitExceeded
    case GHOSTTY_REJECTED: throw .rejected
    default: throw .unknown(r.rawValue)
    }
}

/// Collects callback output; owned by the terminal, passed to C as userdata.
final class EventSink {
    var events: [VTEvent] = []
    var reply: ((UnsafeRawBufferPointer) -> Void)?
    /// What XTVERSION answers ("Axolotty 0.1.0"), kept alive for the C side.
    var version: [UInt8] = Array("Axolotty".utf8)
    var dark = true
    var cellWidth: UInt32 = 0
    var cellHeight: UInt32 = 0
    /// OSC 52 writes are honoured (DA1 then advertises 52).
    var clipboardWrites = true

    static func from(_ ud: UnsafeMutableRawPointer?) -> EventSink {
        Unmanaged<EventSink>.fromOpaque(ud!).takeUnretainedValue()
    }

    func drain() -> [VTEvent] {
        guard !events.isEmpty else { return [] }
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

extension String {
    init(_ s: GhosttyString) {
        guard let p = s.ptr, s.len > 0 else {
            self = ""
            return
        }
        self = String(decoding: UnsafeBufferPointer(start: p, count: s.len), as: UTF8.self)
    }
}
