import Foundation

/// The byte streams one link carries to TCP ports on the host's loopback
/// (feature "tunnel"): a dev server a far pane started at `localhost:5173`
/// answers a browser on this Mac at `localhost:5173`, as if it ran here.
///
///     browser ─ 127.0.0.1:5173 ─┐ client                host ┌─ localhost:5173 ─ vite
///                               └─ open · stream · ack ─────┘
///
/// Both ends are this one type: the client hands it each connection its
/// listener accepts (`open`), the host dials the port it is asked for
/// (`dial`). Each stream rides a lane of its own, so it queues behind no key
/// and no pane, and the bulk pacer keeps it from filling the path ahead of
/// an echo. A sender keeps at most `window` bytes past the receiver's last
/// ack, and the receiver acks what it wrote into its local socket: a
/// browser that stops reading stops the dev server's side, nothing piles up.
///
/// Every stream lives on one serial queue; frames come in by `receive`.
public final class Tunnels: @unchecked Sendable {
    /// Bytes in flight past the receiver's last ack (a few round trips of a
    /// fast path; a page's bundle streams without waiting on each ack).
    public static let window = 1 << 20
    /// The receiver acks at least every this many bytes, and when it drains.
    static let ackEvery = 64 << 10
    /// Streams one link carries at once (a browser opens six per origin).
    /// Past it a new one is refused: a host that is this very Mac would
    /// otherwise dial the client's own listener, and that one again.
    public static let maxStreams = 128

    private let conn: FramedConnection
    private let dial: (@Sendable (UInt16) -> Int32?)?
    private let queue = DispatchQueue(label: "axolotty.tunnels", qos: .userInitiated)
    private var streams: [UUID: Stream] = [:]
    private var closed = false
    private var buffer = [UInt8](repeating: 0, count: Wire.maxData)

    /// `dial`: the host's side, which connects a stream to its port (nil
    /// when nothing listens there); the client's side passes nil.
    public init(conn: FramedConnection, dial: (@Sendable (UInt16) -> Int32?)? = nil) {
        self.conn = conn
        self.dial = dial
    }

    /// The client's side: carries `fd` (a connection to the local listener)
    /// to `port` on the host. Takes ownership of `fd`.
    public func open(_ fd: Int32, port: UInt16) {
        let id = UUID()
        queue.async { [self] in
            guard !closed, streams.count < Self.maxStreams else { return abort(fd) }
            // On the stream's own lane, so it goes before the stream's bytes.
            conn.send(.open(stream: id, port: port), lane: FramedConnection.lane(id))
            start(id, fd)
        }
    }

    /// A tunnel frame from the peer (any other frame is ignored).
    public func receive(_ frame: Frame) {
        queue.async { [self] in
            guard !closed else { return }
            switch frame {
            case let .open(id, port):
                guard streams[id] == nil else { return }
                guard streams.count < Self.maxStreams, let dial, let fd = dial(port) else { return conn.send(.reset(stream: id), lane: FramedConnection.lane(id)) }
                start(id, fd)
            case let .stream(id, offset, bytes, end):
                guard let s = streams[id] else { return conn.send(.reset(stream: id), lane: FramedConnection.lane(id)) }
                guard offset == s.received, !s.peerEnded else { return reset(s, tell: true) }
                s.received += UInt64(bytes.count)
                if !bytes.isEmpty { s.outbox.append(bytes) }
                if end { s.peerEnded = true }
                flush(s)
            case let .streamAck(id, offset):
                guard let s = streams[id] else { return }
                s.acked = max(s.acked, min(offset, s.sent))
                if s.readerHeld, s.sent - s.acked < UInt64(Self.window) {
                    s.readerHeld = false
                    s.reader?.resume()
                }
            case let .reset(id):
                if let s = streams[id] { reset(s, tell: false) }
            default:
                break
            }
        }
    }

    /// The link is gone: every stream ends, abruptly (the browser sees a
    /// reset, and its next request opens a new one on the next link).
    public func closeAll() {
        queue.async { [self] in
            closed = true
            for s in streams.values { reset(s, tell: false) }
        }
    }

    /// Streams open now (tests).
    public var count: Int { queue.sync { streams.count } }

    // MARK: One stream

    private final class Stream {
        let id: UUID
        let fd: Int32
        let lane: Int
        var reader: (any DispatchSourceRead)?
        var writer: (any DispatchSourceWrite)?
        /// The reader is suspended: the window is full.
        var readerHeld = false
        /// The writer is resumed: the socket took less than was queued.
        var writerArmed = false
        var sent: UInt64 = 0
        var acked: UInt64 = 0
        /// The local socket read EOF and the peer was told.
        var readDone = false
        var received: UInt64 = 0
        var written: UInt64 = 0
        var ackSent: UInt64 = 0
        var outbox: [Data] = []
        var head = 0
        var peerEnded = false
        var writeDone = false
        var released = 0

        init(id: UUID, fd: Int32) {
            self.id = id
            self.fd = fd
            lane = FramedConnection.lane(id)
        }
    }

    private func start(_ id: UUID, _ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        noSIGPIPE(fd)
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let s = Stream(id: id, fd: fd)
        streams[id] = s
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let writer = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self, weak s] in if let self, let s { pump(s) } }
        writer.setEventHandler { [weak self, weak s] in if let self, let s { flush(s) } }
        // The descriptor closes once both sources let go of it.
        let release = { [s] in
            s.released += 1
            if s.released == 2 { _ = Darwin.close(s.fd) }
        }
        reader.setCancelHandler(handler: release)
        writer.setCancelHandler(handler: release)
        s.reader = reader
        s.writer = writer
        reader.resume()
    }

    /// Reads what the local socket has, as far as the window allows.
    private func pump(_ s: Stream) {
        while !s.readDone {
            guard s.sent - s.acked < UInt64(Self.window) else {
                if !s.readerHeld {
                    s.readerHeld = true
                    s.reader?.suspend()
                }
                return
            }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(s.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                conn.send(.stream(stream: s.id, offset: s.sent, bytes: Data(buffer[0 ..< n]), end: false), lane: s.lane)
                s.sent += UInt64(n)
            } else if n == 0 {
                s.readDone = true
                conn.send(.stream(stream: s.id, offset: s.sent, bytes: Data(), end: true), lane: s.lane)
                s.reader?.cancel()
                s.reader = nil
                finishIfDone(s)
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN {
                return
            } else {
                return reset(s, tell: true)
            }
        }
    }

    /// Writes what the peer sent into the local socket; acks what it took.
    private func flush(_ s: Stream) {
        while let first = s.outbox.first {
            let n = first.withUnsafeBytes { p in
                Darwin.write(s.fd, p.baseAddress!.advanced(by: s.head), p.count - s.head)
            }
            if n > 0 {
                s.head += n
                s.written += UInt64(n)
                if s.head == first.count {
                    s.outbox.removeFirst()
                    s.head = 0
                }
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                if !s.writerArmed {
                    s.writerArmed = true
                    s.writer?.resume()
                }
                break
            } else {
                return reset(s, tell: true)
            }
        }
        let drained = s.outbox.isEmpty
        if drained, s.writerArmed {
            s.writerArmed = false
            s.writer?.suspend()
        }
        if s.written - s.ackSent >= UInt64(Self.ackEvery) || (drained && s.written > s.ackSent) {
            s.ackSent = s.written
            conn.send(.streamAck(stream: s.id, offset: s.written))
        }
        if drained, s.peerEnded, !s.writeDone {
            s.writeDone = true
            _ = shutdown(s.fd, SHUT_WR)
            finishIfDone(s)
        }
    }

    private func finishIfDone(_ s: Stream) {
        if s.readDone, s.writeDone { end(s) }
    }

    /// Ends a stream at once: the local peer sees a reset, not an orderly
    /// close (its request did not complete).
    private func reset(_ s: Stream, tell: Bool) {
        guard streams[s.id] === s else { return }
        if tell { conn.send(.reset(stream: s.id), lane: s.lane) }
        var hard = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(s.fd, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
        end(s)
    }

    private func end(_ s: Stream) {
        guard streams.removeValue(forKey: s.id) != nil else { return }
        // A suspended source must be resumed to be cancelled; each one's
        // cancel handler lets go of the descriptor (the reader's already
        // ran, or will, when it went at EOF).
        if let r = s.reader {
            if s.readerHeld { r.resume() }
            r.cancel()
        }
        if let w = s.writer {
            if !s.writerArmed { w.resume() }
            w.cancel()
        }
        s.reader = nil
        s.writer = nil
    }

    private func abort(_ fd: Int32) {
        var hard = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
        _ = Darwin.close(fd)
    }
}
