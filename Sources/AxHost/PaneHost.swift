#if os(macOS)
import AxModel
import AxProtocol
internal import AxSys
import AxVT
import Dispatch
import Foundation

/// Something a pane reports to the host, in order.
enum PaneSignal: Sendable {
    case events(PaneID, [VTEvent], live: Bool)
    /// `leader` and `argv` are the foreground process's (a tmux client's
    /// pid and socket flags, for status from inside tmux).
    case foreground(PaneID, program: String, agent: AgentKind?, cwd: String?, leader: Int32, argv: [String])
    case readsSecret(PaneID, Bool)
}

/// Tunables (server-side only; clients need not agree).
public struct PaneLimits: Sendable {
    public var scrollbackBytes = 16 << 20
    public var continuationBytes = 64 << 10
    /// Resync a subscriber whose transport backlog exceeds this.
    public var lagBytes = 2 << 20
    /// … or whose acks trail the head by this much.
    public var ackLagBytes = 8 << 20
    /// Checkpoint after output goes quiet for this long …
    public var checkpointQuiet: Duration = .seconds(1)
    /// … or after this much output, but never more often than `checkpointMinInterval`.
    public var checkpointBytes: UInt64 = 2 << 20
    public var checkpointMinInterval: Duration = .seconds(2)

    public init() {}
}

/// The authoritative terminal of one pane.
///
/// Confined to `queue`. The read source, input, resize, subscriptions and
/// checkpoints all run there, so the terminal sees bytes in exactly journal
/// order and `terminal` always reflects `ring.head` — the invariant every
/// attach, resume and checkpoint relies on.
final class PaneHost: @unchecked Sendable {
    let id: PaneID
    /// This pane's lane on every link: its frames stay in order, and never wait behind another pane's.
    private var lane: Int { FramedConnection.lane(id) }
    let pid: Int32
    let queue: DispatchQueue
    private let master: Int32
    private let ring: JournalRing
    private var terminal: VTTerminal
    private var input: VTInputEncoder
    private let limits: PaneLimits
    private let checkpointURL: URL
    private let signals: AsyncStream<PaneSignal>.Continuation

    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?
    private var writeActive = false
    private var pendingInput: [UInt8] = []
    /// The reads that answer a person's input go ahead of every other lane.
    private var echo = EchoBurst()
    private var ended = false

    private var cellWidth: UInt32 = 8
    private var cellHeight: UInt32 = 16
    private var lastForeground: (String, String?) = ("", nil)
    private var readsSecret = false

    private final class Subscriber {
        let conn: any FrameLink
        var acked: UInt64
        var resyncing = false
        init(conn: any FrameLink, at: UInt64) {
            self.conn = conn
            acked = at
        }
    }

    private var subscribers: [ObjectIdentifier: Subscriber] = [:]
    private var resyncTimer: (any DispatchSourceTimer)?

    private var checkpointOffset: UInt64 = 0
    private var checkpointTime = ContinuousClock.now
    private var quietTimer: (any DispatchSourceTimer)?

    var head: UInt64 { ring.head }
    var masterFD: Int32 { master }
    var ringFD: Int32 { ring.fd }

    /// Builds the authoritative terminal for a session the holder handed over:
    /// a fresh one for a new spawn, or checkpoint + journal replay after a restart.
    init(id: PaneID, handle: CustodyHandle, cols: UInt16, rows: UInt16, fresh: Bool, appearance: Appearance?,
         checkpoints: URL, limits: PaneLimits, signals: AsyncStream<PaneSignal>.Continuation) throws
    {
        self.id = id
        pid = handle.pid
        master = handle.master
        ring = try JournalRing(fd: handle.ring)
        self.limits = limits
        self.signals = signals
        checkpointURL = checkpoints.appending(path: "\(id.raw.uuidString).ckpt")
        queue = DispatchQueue(label: "axolotty.pane.\(id)", qos: .userInteractive)

        var replayEvents: [VTEvent] = []
        if !fresh, let (term, offset) = Self.loadCheckpoint(checkpointURL, limits: limits), offset >= ring.tail,
           offset <= ring.head
        {
            terminal = term
            replayEvents = Self.replay(ring, from: offset, into: term)
            checkpointOffset = offset
        } else {
            terminal = try VTTerminal(cols: cols, rows: rows, scrollbackBytes: limits.scrollbackBytes,
                                      continuationBytes: limits.continuationBytes)
            if !fresh { replayEvents = Self.replay(ring, from: ring.tail, into: terminal) }
            checkpointOffset = ring.tail
        }
        input = VTInputEncoder(terminal: terminal)
        if let appearance {
            Self.apply(appearance, to: terminal)
            _ = terminal.setColorScheme(dark: appearance.dark)
        }
        terminal.setVersion(ShellEnvironment.termProgramVersion)
        terminal.setCellSize(width: cellWidth, height: cellHeight)
        // Replies only from now on: replayed queries were answered long ago.
        terminal.onReply = { [unowned self] bytes in writeToPTY(Array(bytes)) }
        if !replayEvents.isEmpty { signals.yield(.events(id, replayEvents, live: false)) }
    }

    deinit {
        Darwin.close(master)
    }

    func start() {
        queue.async { [self] in
            let src = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
            src.setEventHandler { [unowned self] in readAvailable() }
            readSource = src
            src.resume()
            let w = DispatchSource.makeWriteSource(fileDescriptor: master, queue: queue)
            w.setEventHandler { [unowned self] in flushInput() }
            writeSource = w
        }
    }

    /// Stops all sources. The descriptor and journal stay with the holder.
    func stop() {
        queue.sync {
            readSource?.cancel()
            readSource = nil
            if let w = writeSource {
                if !writeActive { w.resume() }
                w.cancel()
            }
            writeSource = nil
            quietTimer?.cancel()
            resyncTimer?.cancel()
            subscribers.removeAll()
        }
    }

    // MARK: Output

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        var events: [VTEvent] = []
        var total = 0
        // Bounded so one chatty pane cannot starve the queue's other work.
        for _ in 0 ..< 8 {
            let n = buf.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
            if n > 0 {
                let chunk = buf.withUnsafeBytes { UnsafeRawBufferPointer(rebasing: $0[0 ..< n]) }
                let offset = ring.head
                ring.append(chunk)
                events += terminal.write(chunk)
                fanOut(Data(chunk), at: offset, priority: echo.priority(.now))
                total += n
                if n < buf.count { break }
            } else if n < 0, errno == EAGAIN || errno == EINTR {
                break
            } else {
                // EOF / EIO: the child closed the terminal.
                endOfOutput()
                break
            }
        }
        if !events.isEmpty { signals.yield(.events(id, events, live: true)) }
        if total > 0 {
            scheduleCheckpoint()
            // A password prompt turns echo off, then prints itself: checking
            // after output catches it before the first key.
            checkSecret()
        }
    }

    /// Reports when the program starts or stops reading a hidden line. On `queue`.
    private func checkSecret() {
        let now = ax_pty_reads_secret(master) != 0
        guard now != readsSecret else { return }
        readsSecret = now
        signals.yield(.readsSecret(id, now))
    }

    /// ⌘K: erase scrollback (and the screen, outside full-screen programs) by
    /// writing the erase sequences into the journal like program output, so every
    /// mirror and every later replay sees exactly the same bytes. At a shell
    /// prompt, ^L then makes the shell redraw its prompt at the top.
    func clear() {
        queue.async { [self] in
            guard !ended else { return }
            let alternate = terminal.activeScreen == .alternate
            let atPrompt = terminal.cursorAtPrompt
            let seq = Array((alternate ? "\u{1b}[3J" : "\u{1b}[H\u{1b}[2J\u{1b}[3J").utf8)
            let offset = ring.head
            let events = seq.withUnsafeBytes { raw in
                ring.append(raw)
                return terminal.write(raw)
            }
            fanOut(Data(seq), at: offset)
            if !events.isEmpty { signals.yield(.events(id, events, live: true)) }
            scheduleCheckpoint()
            if atPrompt { writeToPTY([0x0C]) }
        }
    }

    private func endOfOutput() {
        guard !ended else { return }
        ended = true
        readSource?.cancel()
        readSource = nil
        checkpoint()
    }

    private func fanOut(_ bytes: Data, at offset: UInt64, priority: Int32 = LanePriority.normal) {
        guard !subscribers.isEmpty else { return }
        let frames = Self.outputFrames(id, bytes, at: offset)
        let head = offset + UInt64(bytes.count)
        for sub in subscribers.values where !sub.resyncing {
            if sub.conn.pendingBytes(lane: lane) > limits.lagBytes || head &- sub.acked > UInt64(limits.ackLagBytes) {
                sub.resyncing = true
                armResync()
                continue
            }
            for f in frames { sub.conn.send(f, lane: lane, priority: priority) }
        }
    }

    private static func outputFrames(_ id: PaneID, _ bytes: Data, at offset: UInt64) -> [Data] {
        var out: [Data] = []
        var at = 0
        while at < bytes.count {
            let n = min(Wire.maxData, bytes.count - at)
            let slice = bytes.subdata(in: bytes.startIndex + at ..< bytes.startIndex + at + n)
            out.append(Wire.encode(.output(pane: id, offset: offset + UInt64(at), bytes: slice)))
            at += n
        }
        return out
    }

    // MARK: Subscriptions

    /// Starts streaming to `conn`: a byte-exact resume from `have` when the
    /// journal still holds it, otherwise a snapshot at the head.
    func attach(_ conn: any FrameLink, have: UInt64?) {
        queue.async { [self] in
            let head = ring.head
            if let have, have >= ring.tail, have <= head, let tail = ring.read(from: have) {
                conn.send(HostMessage.attached(id, cols: terminal.cols, rows: terminal.rows, at: have, resume: true), lane: lane)
                for f in Self.outputFrames(id, tail, at: have) { conn.send(f, lane: lane) }
            } else {
                sendSnapshot(to: conn)
            }
            subscribers[ObjectIdentifier(conn)] = Subscriber(conn: conn, at: have ?? head)
        }
    }

    func detach(_ conn: any FrameLink) {
        queue.async { [self] in subscribers[ObjectIdentifier(conn)] = nil }
    }

    func ack(_ conn: any FrameLink, offset: UInt64) {
        queue.async { [self] in
            if let s = subscribers[ObjectIdentifier(conn)], offset > s.acked { s.acked = offset }
        }
    }

    private func sendSnapshot(to conn: any FrameLink) {
        let head = ring.head
        guard let snap = try? terminal.snapshot() else {
            conn.send(HostMessage.error("snapshot failed for \(id)"), lane: lane)
            return
        }
        conn.send(HostMessage.attached(id, cols: terminal.cols, rows: terminal.rows, at: head, resume: false), lane: lane)
        var at = 0
        repeat {
            let n = min(Wire.maxData, snap.count - at)
            var flags: FrameFlags = []
            if at == 0 { flags.insert(.first) }
            if at + n == snap.count { flags.insert(.last) }
            conn.send(Wire.encode(.snapshot(pane: id, at: head, flags: flags, bytes: Data(snap[at ..< at + n]))), lane: lane)
            at += n
        } while at < snap.count
    }

    private func armResync() {
        guard resyncTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(10))
        t.setEventHandler { [unowned self] in
            var waiting = false
            for sub in subscribers.values where sub.resyncing {
                if sub.conn.isClosed {
                    subscribers[ObjectIdentifier(sub.conn)] = nil
                } else if sub.conn.pendingBytes(lane: lane) < 64 << 10 {
                    // Skip the backlog: a fresh snapshot at the current head.
                    sendSnapshot(to: sub.conn)
                    sub.acked = ring.head
                    sub.resyncing = false
                } else {
                    waiting = true
                }
            }
            if !waiting {
                resyncTimer?.cancel()
                resyncTimer = nil
            }
        }
        resyncTimer = t
        t.resume()
    }

    // MARK: Input

    func key(_ k: KeyInput) {
        queue.async { [self] in
            let action = VTInputEncoder.KeyAction(rawValue: k.action.rawValue) ?? .press
            let bytes = input.key(action: action, key: k.key, mods: k.mods, consumedMods: k.consumedMods, text: k.text,
                                  unshifted: k.unshifted, composing: k.composing)
            if !bytes.isEmpty {
                terminal.scrollViewport(.bottom)
                echo.arm(.now)
                writeToPTY(bytes)
            }
        }
    }

    func mouse(_ m: MouseInput) {
        queue.async { [self] in
            let action = VTInputEncoder.MouseAction(rawValue: m.action.rawValue) ?? .press
            echo.arm(.now)
            writeToPTY(input.mouse(action: action, button: m.button, mods: m.mods,
                                   x: m.x * Double(cellWidth), y: m.y * Double(cellHeight),
                                   cellWidth: cellWidth, cellHeight: cellHeight))
        }
    }

    func paste(_ text: String) {
        queue.async { [self] in
            echo.arm(.now)
            writeToPTY(input.paste(text))
        }
    }

    /// Raw text as if typed (CLI `send`): no bracketing, newlines as CR.
    func type(_ text: String) {
        queue.async { [self] in
            echo.arm(.now)
            writeToPTY(Array(text.utf8).map { $0 == 0x0A ? 0x0D : $0 })
        }
    }

    func focus(_ gained: Bool) {
        queue.async { [self] in writeToPTY(input.focus(gained)) }
    }

    /// Called on `queue`.
    private func writeToPTY(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !ended || pendingInput.isEmpty else { return }
        pendingInput += bytes
        flushInput()
    }

    private func flushInput() {
        while !pendingInput.isEmpty {
            let n = pendingInput.withUnsafeBytes { ax_write_some(master, $0.baseAddress, $0.count) }
            if n > 0 {
                pendingInput.removeFirst(n)
            } else if n == 0 || errno == EAGAIN {
                if !writeActive, let w = writeSource {
                    w.resume()
                    writeActive = true
                }
                return
            } else {
                pendingInput.removeAll()  // EIO: the child is gone
                break
            }
        }
        if writeActive, let w = writeSource {
            w.suspend()
            writeActive = false
        }
    }

    // MARK: Size, appearance, capture

    /// The one TIOCSWINSZ writer. Mirrors resize at the same journal offset.
    func resize(cols: UInt16, rows: UInt16, cellWidth cw: UInt16, cellHeight ch: UInt16) {
        queue.async { [self] in
            if cw > 0 { cellWidth = UInt32(cw) }
            if ch > 0 { cellHeight = UInt32(ch) }
            terminal.setCellSize(width: cellWidth, height: cellHeight)
            guard cols >= 2, rows >= 1, cols != terminal.cols || rows != terminal.rows else { return }
            let ws = ax_winsize(cols: cols, rows: rows, width_px: cols &* UInt16(clamping: cellWidth),
                                height_px: rows &* UInt16(clamping: cellHeight))
            _ = ax_pty_resize(master, ws)
            terminal.resize(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
            let msg = HostMessage.resized(id, cols: cols, rows: rows, at: ring.head)
            for sub in subscribers.values where !sub.resyncing { sub.conn.send(msg, lane: lane) }
        }
    }

    var size: (cols: UInt16, rows: UInt16) { queue.sync { (terminal.cols, terminal.rows) } }

    func setAppearance(_ a: Appearance) {
        queue.async { [self] in
            Self.apply(a, to: terminal)
            if let report = terminal.setColorScheme(dark: a.dark), !ended { writeToPTY(report) }
        }
    }

    private static func apply(_ a: Appearance, to t: VTTerminal) {
        t.setDefaultColors(foreground: (a.foreground.r, a.foreground.g, a.foreground.b),
                           background: (a.background.r, a.background.g, a.background.b),
                           cursor: (a.cursor.r, a.cursor.g, a.cursor.b),
                           palette: a.palette.map { ($0.r, $0.g, $0.b) })
    }

    /// The pane's text, plain; the visible screen unless `scrollback`.
    func capture(scrollback: Bool) -> String {
        queue.sync {
            let full = terminal.text(.plain, trim: true, unwrap: true)
            guard !scrollback else { return full }
            // Visible screen only: the last `rows` lines.
            let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(Int(terminal.rows)).joined(separator: "\n")
        }
    }

    // MARK: Foreground process

    /// Looks up the tty's foreground process; reports when it changed.
    func pollForeground() {
        queue.async { [self] in
            guard !ended else { return }
            checkSecret()  // also catches echo coming back on with no output
            let pgid = ax_pty_foreground_pgid(master)
            let leader = pgid > 0 ? pgid : pid
            var name = [CChar](repeating: 0, count: 64)
            guard ax_proc_name(leader, &name, name.count) > 0 else { return }
            let program = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            var cmd = [CChar](repeating: 0, count: 2048)
            let argv = ax_proc_cmdline(leader, &cmd, cmd.count) > 0
                ? String(decoding: cmd.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    .split(separator: " ").map(String.init)
                : []
            var cwdBuf = [CChar](repeating: 0, count: 1024)
            let cwd = ax_proc_cwd(leader, &cwdBuf, cwdBuf.count) > 0
                ? String(decoding: cwdBuf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            let key = (program + "\u{0}" + argv.joined(separator: " ") + "\u{0}\(leader)", cwd)
            guard key != lastForeground else { return }
            lastForeground = key
            signals.yield(.foreground(id, program: program,
                                      agent: AgentKind.identify(processName: program, argv: argv), cwd: cwd,
                                      leader: leader, argv: argv))
        }
    }

    // MARK: Checkpoints

    private func scheduleCheckpoint() {
        let since = ring.head &- checkpointOffset
        let elapsed = ContinuousClock.now - checkpointTime
        if since >= limits.checkpointBytes && elapsed >= limits.checkpointMinInterval
            || since >= UInt64(ring.capacity / 2)
        {
            checkpoint()
            return
        }
        quietTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        let ms = Int(limits.checkpointQuiet.components.seconds * 1000
            + limits.checkpointQuiet.components.attoseconds / 1_000_000_000_000_000)
        t.schedule(deadline: .now() + .milliseconds(ms), leeway: .milliseconds(100))
        t.setEventHandler { [unowned self] in
            quietTimer?.cancel()
            quietTimer = nil
            checkpoint()
        }
        quietTimer = t
        t.resume()
    }

    /// Snapshot at the head (on `queue`), written to disk off it.
    func checkpoint() {
        dispatchPrecondition(condition: .onQueue(queue))
        let offset = ring.head
        guard offset != checkpointOffset || !FileManager.default.fileExists(atPath: checkpointURL.path),
              let snap = try? terminal.snapshot() else { return }
        checkpointOffset = offset
        checkpointTime = .now
        var data = Data("AXCK".utf8)
        withUnsafeBytes(of: UInt32(1).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: offset.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: snap)
        let url = checkpointURL, payload = data
        DispatchQueue.global(qos: .utility).async { try? payload.write(to: url, options: .atomic) }
    }

    func checkpointNow() { queue.sync { checkpoint() } }

    func removeCheckpoint() { try? FileManager.default.removeItem(at: checkpointURL) }

    private static func loadCheckpoint(_ url: URL, limits: PaneLimits) -> (VTTerminal, UInt64)? {
        guard let data = try? Data(contentsOf: url), data.count > 16, data.prefix(4) == Data("AXCK".utf8) else {
            return nil
        }
        let bytes = [UInt8](data)
        var offset: UInt64 = 0
        for i in 0 ..< 8 { offset |= UInt64(bytes[8 + i]) << (8 * i) }
        guard let term = try? VTTerminal.restore(Array(bytes[16...]), replies: true) else { return nil }
        term.setLimits(scrollbackBytes: limits.scrollbackBytes, continuationBytes: limits.continuationBytes)
        return (term, offset)
    }

    private static func replay(_ ring: JournalRing, from offset: UInt64, into term: VTTerminal) -> [VTEvent] {
        var at = offset
        var events: [VTEvent] = []
        while at < ring.head, let chunk = ring.read(from: at, limit: 1 << 20), !chunk.isEmpty {
            events += chunk.withUnsafeBytes { term.write($0) }
            at += UInt64(chunk.count)
        }
        return events
    }
}
#endif
