public import AxModel
public import AxProtocol
public import Foundation
import Synchronization

/// Where a host listens.
public enum HostEndpoint: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The local server's Unix socket.
    case unix(path: String)
    /// A server on the tailnet (its MagicDNS name or address). Tailscale
    /// carries, encrypts and authenticates; frames go bare.
    case tcp(host: String, port: UInt16)
    /// A command whose standard input and output reach a server's socket:
    /// `ssh host axolotty bridge`. Everything before the bridge preamble is skipped.
    case command(argv: [String], label: String)

    public var description: String {
        switch self {
        case let .unix(path): "unix:\(path)"
        case let .tcp(host, port): "\(host):\(port)"
        case let .command(_, label): label
        }
    }

    /// Reached over a network (its latency is worth showing).
    public var isRemote: Bool {
        if case .unix = self { return false }
        return true
    }
}

/// Why a link can't come up by itself. Reconnecting stops until the person acts.
public enum LinkFailure: Error, Equatable, Sendable {
    /// ssh wants a password, a key passphrase, a host key decision (exit 255).
    case needsLogin(String)
    /// The host has no Axolotty, or one too old to bridge.
    case notInstalled
    /// The host speaks another wire generation.
    case incompatible(generation: Int)
    /// The host refused this device (not the same tailnet user).
    case denied
}

/// What a connection tells its owner, in order.
public enum ConnectionEvent: Sendable {
    case connected(HostHello)
    case deltas([HostState.Delta])
    case event(HostEvent)
    case attached(PaneID)
    case detached(PaneID)
    case disconnected(String?)
    /// The link can't come back by itself (see `LinkFailure`).
    case failed(LinkFailure)
    /// A heartbeat's round trip (remote links, every few seconds).
    case latency(Duration)
}

public enum ConnectionError: Error, Equatable, Sendable {
    case notConnected
    case closed
    case refused(String)
    case intent(IntentError)
    case failed(LinkFailure)
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
        /// When the link last went down (nil while up): the redial ladder
        /// slows once a host has been gone a minute.
        var downSince: ContinuousClock.Instant?
        var redials = 0
        #if os(macOS)
        var child: CommandChild?
        #endif
        /// Set when the host says why it closed (incompatible, denied).
        var refusal: LinkFailure?
        var lastHeard = ContinuousClock.now
        var pings: [UInt64: ContinuousClock.Instant] = [:]
        var heartbeat: Task<Void, Never>?
        var rtt: Duration?
    }

    /// Heartbeats, Slopty's third-generation numbers: a ping every `beat`
    /// on remote links; a link that has said nothing for `silence` (three
    /// beats) is dead and is redialled at once.
    static let beat: Duration = .seconds(2)
    static let silence: Duration = .seconds(6)

    /// The redial ladder. Remote: 250 ms doubling to 2 s; once the host has
    /// been gone a minute, 4 s doubling to 30 s. Local: 100 ms to 5 s.
    /// Every step is jittered ±20 % so clients don't redial a woken host in step.
    public static func redialDelay(after previous: Duration?, downFor: Duration, remote: Bool) -> Duration {
        guard remote else {
            return previous.map { min($0 * 2, .seconds(5)) } ?? .milliseconds(100)
        }
        if downFor < .seconds(60) {
            return previous.map { min($0 * 2, .seconds(2)) } ?? .milliseconds(250)
        }
        guard let previous, previous >= .seconds(4) else { return .seconds(4) }
        return min(previous * 2, .seconds(30))
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

    /// The last heartbeat's round trip (remote links).
    public var rtt: Duration? { state.withLock { $0.rtt } }

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
        let conn: FramedConnection
        switch endpoint {
        case let .unix(path):
            do { conn = FramedConnection(fd: try UnixSocket.connect(path: path), label: "host") } catch {
                throw ConnectionError.refused("\(error)")
            }
        case let .tcp(host, port):
            let fd: Int32
            do {
                fd = try await Task.detached { try TCPSocket.connect(host: host, port: port, timeout: 6) }.value
            } catch {
                throw ConnectionError.refused("\(error)")
            }
            conn = FramedConnection(fd: fd, label: "host")
        case let .command(argv, _):
            #if os(macOS)
            let child: CommandChild
            do { child = try CommandChild.spawn(argv) } catch {
                throw ConnectionError.refused("can't run \(argv.first ?? ""): \(error)")
            }
            conn = FramedConnection(fd: child.fd, label: "host", preamble: Wire.bridgePreamble)
            state.withLock { $0.child = child }
            #else
            throw ConnectionError.refused("commands need macOS")
            #endif
        }
        // A remote link that never says welcome (a hung ssh, a black hole) is given up.
        if endpoint.isRemote {
            Task { [weak self, weak conn] in
                try? await Task.sleep(for: .seconds(25))
                guard let self, let conn, state.withLock({ $0.conn === conn && $0.welcome != nil }) else { return }
                conn.close(ConnectionError.refused("timed out"))
            }
        }
        return try await withCheckedThrowingContinuation { c in
            state.withLock { s in
                s.conn = conn
                s.welcome = c
                s.refusal = nil
                s.lastHeard = .now
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
            taken.refusal = s.refusal
            #if os(macOS)
            taken.child = s.child
            s.child = nil
            #endif
            s.heartbeat?.cancel()
            s.heartbeat = nil
            s.pings = [:]
            s.welcome = nil
            s.intents = [:]
            s.captures = [:]
            s.pongs = [:]
            return true
        }
        guard mine else { return }
        taken.intents.values.forEach { $0.resume(returning: .failure(.closed)) }
        taken.captures.values.forEach { $0.resume(returning: nil) }
        taken.pongs.values.forEach { $0.resume() }
        let banner = conn.bannerText
        Task { [weak self] in
            var failure = taken.refusal
            var reason = error.map { "\($0)" }
            #if os(macOS)
            if let child = taken.child {
                // The command ends with the link (ssh exits when its pipe closes).
                let code = await child.finish(grace: 0.5)
                let said = child.stderrTail
                if failure == nil, taken.welcome != nil {
                    failure = Self.classify(exit: code, stderr: said, banner: banner)
                }
                if !said.isEmpty { reason = said }
            }
            #endif
            guard let self else { return }
            if let failure {
                state.withLock { $0.wantConnected = false }
                taken.welcome?.resume(throwing: ConnectionError.failed(failure))
                sink.yield(.failed(failure))
                sink.yield(.disconnected(reason))
                return
            }
            taken.welcome?.resume(throwing: ConnectionError.closed)
            sink.yield(.disconnected(reason))
            if taken.wantConnected { scheduleReconnect() }
        }
    }

    /// What a remote command's exit before the welcome means.
    public static func classify(exit code: Int32, stderr: String, banner: String) -> LinkFailure? {
        switch code {
        // ssh's own failure: authentication, host key, an unknown host. A
        // network that is merely down says so in words and is retried.
        case 255:
            let s = stderr.lowercased()
            let transient = ["timed out", "no route", "network is unreachable", "connection refused",
                             "could not resolve", "connection reset", "broken pipe"]
            return transient.contains { s.contains($0) } ? nil : .needsLogin(stderr)
        // Our bridge script: no Axolotty there (or the shell can't find it).
        case 87, 126, 127: return .notInstalled
        default: return nil
        }
    }

    /// Redials now: the network changed, the Mac woke, the person asked.
    /// A live link that has gone quiet is dropped first, so it is replaced
    /// rather than waited on.
    public func kick() {
        let (conn, stale, idle) = state.withLock { s -> (FramedConnection?, Bool, Bool) in
            s.redials = 0
            s.downSince = nil
            let quiet = ContinuousClock.now - s.lastHeard
            return (s.conn, quiet > Self.beat, s.conn == nil && s.wantConnected)
        }
        if let conn, stale, endpoint.isRemote {
            // Ask; an answer within a second keeps the link.
            conn.send(ClientMessage.ping(0))
            conn.queue.asyncAfter(deadline: .now() + 1) { [weak self, weak conn] in
                guard let self, let conn else { return }
                if ContinuousClock.now - state.withLock({ $0.lastHeard }) > .milliseconds(1500) {
                    conn.close(ConnectionError.refused("silent"))
                }
            }
        } else if idle {
            Task { [weak self] in
                guard let self, state.withLock({ $0.conn == nil }) else { return }
                if (try? await open()) == nil, state.withLock({ $0.conn == nil && $0.wantConnected }) {
                    scheduleReconnect()
                }
            }
        }
    }

    /// Pings every `beat`; a link silent for `silence` is closed (and redialled).
    private func startHeartbeat(_ conn: FramedConnection) {
        let task = Task { [weak self, weak conn] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.beat)
                guard let self, let conn, !Task.isCancelled else { return }
                let (live, silent) = state.withLock { s -> (Bool, Bool) in
                    (s.conn === conn, ContinuousClock.now - s.lastHeard > Self.silence)
                }
                guard live else { return }
                if silent {
                    conn.close(ConnectionError.refused("host silent"))
                    return
                }
                let n = UInt64.random(in: 1 ... .max)
                state.withLock { $0.pings[n] = .now }
                conn.send(ClientMessage.ping(n))
            }
        }
        state.withLock { $0.heartbeat = task }
    }

    private func scheduleReconnect() {
        let remote = endpoint.isRemote
        let delay = state.withLock { s -> Duration in
            let now = ContinuousClock.now
            let since = s.downSince ?? now
            s.downSince = since
            let step = Self.redialDelay(after: s.redials == 0 ? nil : s.backoff, downFor: now - since, remote: remote)
            s.backoff = step
            s.redials += 1
            return step * Double.random(in: 0.8 ... 1.2)
        }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, state.withLock({ $0.wantConnected && $0.conn == nil }) else { return }
            if (try? await open()) == nil, state.withLock({ $0.conn == nil && $0.wantConnected }) { scheduleReconnect() }
        }
    }

    // MARK: Receiving (connection queue)

    private func receive(_ frame: Frame, on conn: FramedConnection) {
        state.withLock { $0.lastHeard = .now }
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
                s.redials = 0
                s.downSince = nil
                defer { s.welcome = nil }
                return (s.welcome, s.mirrors, s.appearance)
            }
            if let appearance { conn.send(ClientMessage.appearance(appearance)) }
            if endpoint.isRemote { startHeartbeat(conn) }
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
            let (waiter, sent) = state.withLock { s in (s.pongs.removeValue(forKey: n), s.pings.removeValue(forKey: n)) }
            waiter?.resume()
            if let sent {
                let rtt = ContinuousClock.now - sent
                state.withLock { $0.rtt = rtt }
                sink.yield(.latency(rtt))
            }
        case let .incompatible(generation):
            state.withLock { $0.refusal = .incompatible(generation: generation) }
        case let .error(text):
            if text == "denied" { state.withLock { $0.refusal = .denied } }
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

    public func capture(_ pane: PaneID, scrollback: Bool = false) async -> String? {
        let token = UUID()
        return await withCheckedContinuation { c in
            let conn = state.withLock { s -> FramedConnection? in
                guard let conn = s.conn else { return nil }
                s.captures[token] = c
                return conn
            }
            if let conn {
                conn.send(ClientMessage.capture(token, pane, scrollback: scrollback))
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
