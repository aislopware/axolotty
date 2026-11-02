// `axolotty attach`: an Axolotty pane in this terminal (over ssh, in another
// emulator). The screen is drawn once from the host's state, then the pane's
// output passes through untouched and keystrokes go back as typed. This
// terminal drives the pane's size while attached. ^] detaches; the pane's
// program never notices.
import AxClient
import AxModel
import AxProtocol
import AxVT
import Darwin
import Foundation

enum Attach {
    static let detachKey: UInt8 = 0x1D  // ^]

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        func set() { lock.withLock { open = true } }
        var isOpen: Bool { lock.withLock { open } }
    }

    private enum End: Sendable { case detached, ended, gone }

    static func run(pane: String?) async throws(OpError) {
        guard isatty(0) == 1, isatty(1) == 1 else { throw .usage("attach needs a terminal on stdin and stdout") }
        let (c, st) = try await Ops.connect(subscribe: true)
        let p = try Ops.resolvePane(pane, in: st)
        if p == Ops.env["AXOLOTTY_PANE_ID"].flatMap(PaneID.init) { throw .usage("a pane cannot attach to itself") }
        guard st.panes[p]?.exitStatus == nil else { throw .failed("the pane's program has ended") }

        var saved = termios()
        tcgetattr(0, &saved)
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
        defer {
            var restore = saved
            tcsetattr(0, TCSANOW, &restore)
        }

        let gate = Gate()
        let mirror = c.attach(p)
        mirror.onOutput { buf in
            guard gate.isOpen, let base = buf.baseAddress else { return }
            writeAll(base, buf.count)
        }
        // One consumer of the connection's events (a stream has one): it says
        // when the snapshot is in, and later why the session ended.
        let (attached, attachedSink) = AsyncStream<Bool>.makeStream()
        let (ends, endSink) = AsyncStream<End>.makeStream()
        let watcher = Task {
            for await e in c.events {
                switch e {
                case .attached(p):
                    attachedSink.yield(true)
                case .deltas:
                    if c.replica?.panes[p]?.exitStatus != nil || c.replica?.panes[p] == nil { endSink.yield(.ended) }
                case .disconnected:
                    attachedSink.yield(false)
                    endSink.yield(.gone)
                default:
                    continue
                }
            }
            endSink.yield(.gone)
        }
        defer { watcher.cancel() }
        // The snapshot arrives first; draw the screen it holds, then let output through.
        for await ok in attached {
            guard ok else { throw OpError(message: "host went away", exit: .unreachable) }
            break
        }
        sendSize(c, p)
        mirror.withTerminal { t in
            let rows = Int(t.rows)
            let lines = t.text(.vt, trim: false, unwrap: false).split(separator: "\n", omittingEmptySubsequences: false)
            let screen = lines.suffix(rows).joined(separator: "\r\n")
            let cur = t.cursor
            let out = "\u{1B}[0m\u{1B}[H\u{1B}[2J" + screen + "\u{1B}[0m\u{1B}[\(cur.y + 1);\(cur.x + 1)H"
                + (cur.visible ? "\u{1B}[?25h" : "\u{1B}[?25l")
            out.utf8CString.withUnsafeBufferPointer { b in writeAll(b.baseAddress!, b.count - 1) }
            gate.set()
        }

        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        signal(SIGWINCH, SIG_IGN)
        winch.setEventHandler { sendSize(c, p) }
        winch.resume()
        defer { winch.cancel() }

        let end = await withTaskGroup(of: End.self) { group in
            group.addTask {
                // Keystrokes, until ^].
                let input = AsyncStream<[UInt8]> { cont in
                    let src = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .global())
                    src.setEventHandler {
                        var buf = [UInt8](repeating: 0, count: 4096)
                        let n = read(0, &buf, buf.count)
                        if n <= 0 { cont.finish() } else { cont.yield(Array(buf[0 ..< n])) }
                    }
                    src.setCancelHandler { cont.finish() }
                    cont.onTermination = { _ in src.cancel() }
                    src.resume()
                }
                for await bytes in input {
                    if let i = bytes.firstIndex(of: detachKey) {
                        if i > 0 { c.send(.text(p, String(decoding: bytes[..<i], as: UTF8.self))) }
                        return .detached
                    }
                    c.send(.text(p, String(decoding: bytes, as: UTF8.self)))
                }
                return .detached
            }
            group.addTask {
                for await e in ends { return e }
                return .gone
            }
            let first = await group.next() ?? .gone
            group.cancelAll()
            return first
        }
        c.detach(p)
        await c.ping()
        let note = switch end {
        case .detached: "detached from pane \(Ops.short(p))"
        case .ended: "pane \(Ops.short(p)) ended"
        case .gone: "host went away"
        }
        let line = "\u{1B}[0m\r\n[\(note)]\r\n"
        line.utf8CString.withUnsafeBufferPointer { b in writeAll(b.baseAddress!, b.count - 1) }
    }

    /// This terminal's size becomes the pane's.
    private static func sendSize(_ c: HostConnection, _ p: PaneID) {
        var ws = winsize()
        guard ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 else { return }
        let cw = ws.ws_xpixel > 0 ? ws.ws_xpixel / ws.ws_col : 8
        let ch = ws.ws_ypixel > 0 ? ws.ws_ypixel / ws.ws_row : 16
        c.send(.viewport(p, cols: ws.ws_col, rows: ws.ws_row, cellWidth: cw, cellHeight: ch))
        c.send(.takeSize(p))
    }

    private static func writeAll(_ base: UnsafeRawPointer, _ count: Int) {
        var off = 0
        while off < count {
            let n = write(1, base + off, count - off)
            if n < 0 { if errno == EINTR { continue }; return }
            off += n
        }
    }
}
