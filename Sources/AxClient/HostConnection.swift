public import AxModel
public import AxProtocol
public import Foundation
import Synchronization

/// Where a host listens.
public enum HostEndpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The local server's Unix socket.
    case unix(path: String)

    public var description: String {
        switch self {
        case let .unix(path): "unix:\(path)"
        }
    }
}

/// What a connection tells its owner, in order.
public enum ConnectionEvent: Sendable {
    case connected(HostHello)
    case deltas([HostState.Delta])
    case event(HostEvent)
    case attached(PaneID)
    case detached(PaneID)
    case disconnected(String?)
}

public enum ConnectionError: Error, Equatable, Sendable {
    case notConnected
    case closed
    case refused(String)
    case intent(IntentError)
}

/// One client's link to one host: the document replica, mirror terminals,
/// input, and requests. Reconnects with backoff and resumes every mirror
/// byte-exactly from its offset when the journal still has it.
public final class HostConnection: @unchecked Sendable {
    public let endpoint: HostEndpoint
    public let events: AsyncStream<ConnectionEvent>
    private let sink: AsyncStream<ConnectionEvent>.Continuation
    private var hello: ClientHello

    private struct State {
        var conn: FramedConnection?
        var replica: HostState?
        var epoch: UUID?
        var mirrors: [PaneID: MirrorTerminal] = [:]
        var welcome: CheckedContinuation<HostHello, any Error>?
        var intents: [UUID: CheckedContinuation<Result<Void, ConnectionError>, Never>] = [:]
        var captures: [UUID: CheckedContinuation<String?, Never>] = [:]
        var pongs: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var unacked: [PaneID: UInt64] = [:]
        var ackScheduled = false
        var appearance: Appearance?
        var wantConnected = false
        var backoff: Duration = .milliseconds(100)
    }

    private let state = Mutex(State())

    public init(endpoint: HostEndpoint, hello: ClientHello) {
        self.endpoint = endpoint
        self.hello = hello
        (events, sink) = AsyncStream.makeStream()
    }

    deinit { sink.finish() }

    /// The latest document replica (nil before the first welcome).
    public var replica: HostState? { state.withLock { $0.replica } }

    public var isConnected: Bool { state.withLock { $0.conn != nil && $0.replica != nil } }

    // MARK: Connecting

    /// Connects and waits for the welcome. With `reconnect`, a dropped link is re-established forever.
    @discardableResult
    public func connect(reconnect: Bool = true) async throws -> HostHello {
        state.withLock { $0.wantConnected = reconnect }
        return try await open()
    }

    public func disconnect() {
        let conn = state.withLock { s -> FramedConnection? in
            s.wantConnected = false
            return s.conn
        }
        conn?.close()
    }

    private func open() async throws -> HostHello {
        let fd: Int32
        switch endpoint {
        case let .unix(path):
            do { fd = try UnixSocket.connect(path: path) } catch {
                throw ConnectionError.refused("\(error)")
            }
        }
        let conn = FramedConnection(fd: fd, label: "host")
        return try await withCheckedThrowingContinuation { c in
            state.withLock { s in
                s.conn = conn
                s.welcome = c
            }
            conn.start(onFrame: { [weak self] in self?.receive($0, on: conn) },
                       onClose: { [weak self] e in self?.closed(conn, e) })
            conn.send(ClientMessage.hello(hello))
        }
    }

    private func closed(_ conn: FramedConnection, _ error: (any Error)?) {
        var taken = State()
        let mine = state.withLock { s -> Bool in
            guard s.conn === conn else { return false }
            s.conn = nil
            taken.welcome = s.welcome
            taken.intents = s.intents
            taken.captures = s.captures
            taken.pongs = s.pongs
            taken.wantConnected = s.wantConnected
            s.welcome = nil
            s.intents = [:]
            s.captures = [:]
            s.pongs = [:]
            return true
        }
        guard mine else { return }
        taken.welcome?.resume(throwing: ConnectionError.closed)
        taken.intents.values.forEach { $0.resume(returning: .failure(.closed)) }
        taken.captures.values.forEach { $0.resume(returning: nil) }
        taken.pongs.values.forEach { $0.resume() }
        sink.yield(.disconnected(error.map { "\($0)" }))
        if taken.wantConnected { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        let delay = state.withLock { s -> Duration in
            let d = s.backoff
            s.backoff = min(s.backoff * 2, .seconds(5))
            return d
        }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, state.withLock({ $0.wantConnected && $0.conn == nil }) else { return }
            if (try? await open()) == nil, state.withLock({ $0.conn == nil }) { scheduleReconnect() }
        }
    }

    // MARK: Receiving (connection queue)

    private func receive(_ frame: Frame, on conn: FramedConnection) {
        switch frame {
        case let .control(json):
            guard let msg = try? MessageCodec.host(json) else { return }
            handle(msg, on: conn)
        case let .output(pane, offset, bytes):
            guard let m = state.withLock({ $0.mirrors[pane] }) else { return }
            switch m.output(at: offset, bytes) {
            case let .applied(n): noteApplied(pane, n, conn: conn)
            case .duplicate: break
            case .gap: conn.send(ClientMessage.attach(pane, have: nil))
            }
        case let .snapshot(pane, at, flags, bytes):
            state.withLock { $0.mirrors[pane] }?.snapshotChunk(at: at, flags: flags, bytes: bytes)
            if flags.contains(.last) { sink.yield(.attached(pane)) }
        case .ack:
            break
        }
    }

    private func handle(_ msg: HostMessage, on conn: FramedConnection) {
        switch msg {
        case let .welcome(h):
            let (c, mirrors, appearance) = state.withLock { s in
                s.replica = h.state
                s.epoch = h.epoch
                s.backoff = .milliseconds(100)
                defer { s.welcome = nil }
                return (s.welcome, s.mirrors, s.appearance)
            }
            if let appearance { conn.send(ClientMessage.appearance(appearance)) }
            // Resume every mirror where it left off (byte-exact when the journal still holds it).
            for (id, m) in mirrors {
                conn.send(ClientMessage.attach(id, have: m.isReady ? m.offset : nil))
            }
            sink.yield(.connected(h))
            c?.resume(returning: h)
        case let .deltas(ds, _):
            state.withLock { $0.replica?.apply(ds) }
            sink.yield(.deltas(ds))
        case let .intentResult(token, error):
            state.withLock { $0.intents.removeValue(forKey: token) }?.resume(returning: error.map { .failure(.intent($0)) } ?? .success(()))
        case let .attached(id, cols, rows, at, resume):
            state.withLock { $0.mirrors[id] }?.attached(cols: cols, rows: rows, at: at, resume: resume)
            if resume { sink.yield(.attached(id)) }
        case let .detached(id):
            state.withLock { $0.mirrors[id] = nil }
            sink.yield(.detached(id))
        case let .resized(id, cols, rows, _):
            state.withLock { $0.mirrors[id] }?.resized(cols: cols, rows: rows)
        case let .event(e):
            sink.yield(.event(e))
        case let .captured(token, text):
            state.withLock { $0.captures.removeValue(forKey: token) }?.resume(returning: text)
        case let .pong(n):
            state.withLock { $0.pongs.removeValue(forKey: n) }?.resume()
        case .error:
            break
        }
    }

    /// Acks after applying: at least every 32 KiB, otherwise within 50 ms.
    private func noteApplied(_ pane: PaneID, _ n: Int, conn: FramedConnection) {
        let (flushNow, schedule) = state.withLock { s -> (Bool, Bool) in
            s.unacked[pane, default: 0] += UInt64(n)
            if s.unacked[pane, default: 0] >= 32 << 10 { return (true, false) }
            if s.ackScheduled { return (false, false) }
            s.ackScheduled = true
            return (false, true)
        }
        if flushNow { flushAcks(conn) }
        if schedule { conn.queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in self?.flushAcks(conn) } }
    }

    private func flushAcks(_ conn: FramedConnection) {
        let mirrors = state.withLock { s -> [MirrorTerminal] in
            defer {
                s.unacked = [:]
                s.ackScheduled = false
            }
            return s.unacked.keys.compactMap { s.mirrors[$0] }
        }
        for m in mirrors { conn.send(Frame.ack(pane: m.pane, offset: m.offset)) }
    }

    // MARK: Sending

    public func send(_ message: ClientMessage) {
        state.withLock { $0.conn }?.send(message)
    }

    /// Applies an intent on the host; returns when the host has (deltas arrive first).
    public func perform(_ intent: Intent) async throws(ConnectionError) {
        let token = UUID()
        let result: Result<Void, ConnectionError> = await withCheckedContinuation { c in
            let conn = state.withLock { s -> FramedConnection? in
                guard let conn = s.conn else { return nil }
                s.intents[token] = c
                return conn
            }
            if let conn { conn.send(ClientMessage.intent(token, intent)) } else { c.resume(returning: .failure(.notConnected)) }
        }
        try result.get()
    }

    public func capture(_ pane: PaneID, format: CaptureFormat = .plain, scrollback: Bool = false) async -> String? {
        let token = UUID()
        return await withCheckedContinuation { c in
            let conn = state.withLock { s -> FramedConnection? in
                guard let conn = s.conn else { return nil }
                s.captures[token] = c
                return conn
            }
            if let conn {
                conn.send(ClientMessage.capture(token, pane, format, scrollback: scrollback))
            } else {
                c.resume(returning: nil)
            }
        }
    }

    /// Round trip: everything sent before it has been handled by the host.
    public func ping() async {
        let n = UInt64.random(in: 1 ... .max)
        await withCheckedContinuation { c in
            let conn = state.withLock { s -> FramedConnection? in
                guard let conn = s.conn else { return nil }
                s.pongs[n] = c
                return conn
            }
            if let conn { conn.send(ClientMessage.ping(n)) } else { c.resume() }
        }
    }

    public func setAppearance(_ a: Appearance) {
        let (conn, mirrors) = state.withLock { s in
            s.appearance = a
            return (s.conn, Array(s.mirrors.values))
        }
        mirrors.forEach { $0.setAppearance(a) }
        conn?.send(ClientMessage.appearance(a))
    }

    // MARK: Mirrors

    /// Starts mirroring `pane` (idempotent).
    @discardableResult
    public func attach(_ pane: PaneID) -> MirrorTerminal {
        let (m, isNew, conn) = state.withLock { s -> (MirrorTerminal, Bool, FramedConnection?) in
            if let m = s.mirrors[pane] { return (m, false, s.conn) }
            let m = MirrorTerminal(pane: pane, appearance: s.appearance)
            s.mirrors[pane] = m
            return (m, true, s.conn)
        }
        if isNew { conn?.send(ClientMessage.attach(pane, have: nil)) }
        return m
    }

    public func detach(_ pane: PaneID) {
        let conn = state.withLock { s -> FramedConnection? in
            s.mirrors[pane] = nil
            return s.conn
        }
        conn?.send(ClientMessage.detach(pane))
    }

    public func mirror(_ pane: PaneID) -> MirrorTerminal? { state.withLock { $0.mirrors[pane] } }
}
