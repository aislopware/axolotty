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
        var gits: [UUID: CheckedContinuation<GitReport?, Never>] = [:]
        /// What the host said it can do in its welcome.
        var hostFeatures: Set<String> = []
        /// A kick's ping, until its pong comes.
        var kickPing: UInt64?
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
        /// The open link's liveness (remote links; see `LinkLiveness`).
        var liveness: LinkLiveness?
        /// When the link up now was dialled.
        var dialedAt: Duration?
        /// The dial under way: every caller meanwhile waits on this one, so
        /// two dials never race to be the link (and strand each other's welcome).
        var dialing: Task<HostHello, any Error>?
        /// Bumped by each scheduled redial; an older one finds it moved and stands down.
        var redialTicket = 0
        var heartbeat: Task<Void, Never>?
        var rtt: Duration?
    }

    /// How a remote link is judged alive (`LinkLiveness.Timing.standard`
    /// unless a test shortens it).
    public let timing: LinkLiveness.Timing
    private let epoch = ContinuousClock.now
    private var now: Duration { ContinuousClock.now - epoch }

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

    public init(endpoint: HostEndpoint, hello: ClientHello, timing: LinkLiveness.Timing = .standard) {
        self.endpoint = endpoint
        self.hello = hello
        self.timing = timing
        (events, sink) = AsyncStream.makeStream()
    }

    deinit { sink.finish() }

    /// The latest document replica (nil before the first welcome).
    public var replica: HostState? { state.withLock { $0.replica } }

    /// A link is up and the host has said welcome on it (not mid-handshake).
    public var isConnected: Bool { state.withLock { $0.conn != nil && $0.welcome == nil && $0.replica != nil } }

    /// The last heartbeat's round trip (remote links).
    public var rtt: Duration? { state.withLock { $0.rtt } }

    /// Whether the open remote link is alive, quiet (a ping went
    /// unanswered) or dead; nil with no link or on a local one.
    public var linkState: LinkLiveness.State? {
        let t = now
        return state.withLock { $0.conn == nil ? nil : $0.liveness?.state(at: t) }
    }

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
        let dial = state.withLock { s -> Task<HostHello, any Error> in
            if let d = s.dialing { return d }
            let d = Task { [weak self] () throws -> HostHello in
                guard let self else { throw ConnectionError.closed }
                defer { state.withLock { $0.dialing = nil } }
                return try await dialOnce()
            }
            s.dialing = d
            return d
        }
        return try await dial.value
    }

    private func dialOnce() async throws -> HostHello {
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
        let t = now
        return try await withCheckedThrowingContinuation { c in
            state.withLock { s in
                s.conn = conn
                s.welcome = c
                s.refusal = nil
                s.liveness = nil
                s.dialedAt = t
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
            taken.gits = s.gits
            taken.wantConnected = s.wantConnected
            taken.refusal = s.refusal
            #if os(macOS)
            taken.child = s.child
            s.child = nil
            #endif
            s.heartbeat?.cancel()
            s.heartbeat = nil
            s.liveness = nil
            s.welcome = nil
            s.intents = [:]
            s.captures = [:]
            s.pongs = [:]
            s.gits = [:]
            s.kickPing = nil
            return true
        }
        guard mine else { return }
        taken.intents.values.forEach { $0.resume(returning: .failure(.closed)) }
        taken.captures.values.forEach { $0.resume(returning: nil) }
        taken.pongs.values.forEach { $0.resume() }
        taken.gits.values.forEach { $0.resume(returning: nil) }
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
    /// A link up is asked first, and dropped unless a beat brings the answer
    /// or output sent after the question. Bytes that arrive at once prove
    /// nothing: they were on their way before the network changed. A link
    /// busy a moment ago is asked too, since a change can end it mid-stream.
    /// A handshake under way for over a beat rides the old path too and is
    /// dialled again; a younger one was most likely dialled for this very
    /// change (path updates come in bursts) and is left to finish.
    public func kick() {
        let t = now
        let n = UInt64.random(in: 1 ..< 1 << 63)  // below the liveness pings' range
        let (conn, asked, shaking, idle) = state.withLock { s -> (FramedConnection?, Bool, Bool, Bool) in
            s.redials = 0
            s.downSince = nil
            let shaking = s.welcome != nil && s.dialedAt.map { t - $0 >= timing.beat } ?? false
            let asked = s.liveness != nil
            if asked { s.kickPing = n }
            return (s.conn, asked, shaking, s.conn == nil && s.wantConnected)
        }
        if let conn, shaking, endpoint.isRemote {
            conn.close(ConnectionError.refused("dialled before the network changed"))
        } else if let conn, asked, endpoint.isRemote {
            conn.send(ClientMessage.ping(n))
            let beat = timing.beat
            conn.queue.asyncAfter(deadline: .now() + .nanoseconds(Int(beat / .nanoseconds(1)))) { [weak self, weak conn] in
                guard let self, let conn else { return }
                let silent = state.withLock { s -> Bool in
                    guard s.conn === conn, s.kickPing == n else { return false }
                    s.kickPing = nil
                    return (s.liveness?.lastHeard ?? t) < t + beat / 2
                }
                if silent { conn.close(ConnectionError.refused("silent")) }
            }
        } else if idle {
            scheduleReconnect(after: .zero)
        }
    }

    /// Drives `LinkLiveness`: sleeps until it next has something to say,
    /// sends the pings it asks for, and closes the link (to be redialled)
    /// when it calls it dead.
    private func startHeartbeat(_ conn: FramedConnection) {
        let (epoch, timing) = (epoch, timing)
        let task = Task { [weak self, weak conn] in
            while !Task.isCancelled {
                guard let wake = self?.state.withLock({ s -> Duration? in
                    s.conn === conn ? s.liveness?.nextCheck(after: ContinuousClock.now - epoch) : nil
                }) else { return }
                try? await Task.sleep(until: epoch + wake, tolerance: timing.beat / 100, clock: .continuous)
                guard let self, let conn, !Task.isCancelled else { return }
                let t = ContinuousClock.now - epoch
                let verdict = state.withLock { s -> (LinkLiveness.State, UInt64?)? in
                    guard s.conn === conn, s.liveness != nil else { return nil }
                    return (s.liveness!.state(at: t), s.liveness!.pingIfDue(at: t))
                }
                guard let (alive, ping) = verdict else { return }
                if alive == .dead {
                    conn.close(ConnectionError.refused("host silent"))
                    return
                }
                if let ping { conn.send(ClientMessage.ping(ping)) }
            }
        }
        state.withLock { $0.heartbeat = task }
    }

    /// Redials after the ladder's next step (or `delay`). Only the latest
    /// schedule stands: a link that closed mid-handshake is rescheduled both
    /// by its close and by its failed dial, and those must be one redial.
    private func scheduleReconnect(after delay: Duration? = nil) {
        let remote = endpoint.isRemote
        let (wait, ticket) = state.withLock { s -> (Duration, Int) in
            s.redialTicket &+= 1
            if let delay { return (delay, s.redialTicket) }
            let now = ContinuousClock.now
            let since = s.downSince ?? now
            s.downSince = since
            let step = Self.redialDelay(after: s.redials == 0 ? nil : s.backoff, downFor: now - since, remote: remote)
            s.backoff = step
            s.redials += 1
            return (step * Double.random(in: 0.8 ... 1.2), s.redialTicket)
        }
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, redialStands(ticket) else { return }
            if (try? await open()) == nil, redialStands(ticket) { scheduleReconnect() }
        }
    }

    /// Still wanted, still down, and no later redial scheduled.
    private func redialStands(_ ticket: Int) -> Bool {
        state.withLock { $0.wantConnected && $0.conn == nil && $0.redialTicket == ticket }
    }

    // MARK: Receiving (connection queue)

    private func receive(_ frame: Frame, on conn: FramedConnection) {
        let t = now
        state.withLock { $0.liveness?.heard(at: t) }
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
                s.hostFeatures = Set(h.features ?? [])
                s.epoch = h.epoch
                s.backoff = .milliseconds(100)
                s.redials = 0
                s.downSince = nil
                defer { s.welcome = nil }
                return (s.welcome, s.mirrors, s.appearance)
            }
            if let appearance { conn.send(ClientMessage.appearance(appearance)) }
            if endpoint.isRemote {
                let t = now
                state.withLock { $0.liveness = LinkLiveness(timing: timing, now: t) }
                startHeartbeat(conn)
            }
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
        case let .gitTree(token, report):
            state.withLock { $0.gits.removeValue(forKey: token) }?.resume(returning: report)
        case let .pong(n):
            let t = now
            let (waiter, rtt) = state.withLock { s in
                if s.kickPing == n { s.kickPing = nil }
                return (s.pongs.removeValue(forKey: n), s.liveness?.pong(n, at: t))
            }
            waiter?.resume()
            if let rtt {
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

    /// The branch and changes of the working tree at `path` on the host; nil
    /// with no link, or from a host too old to say.
    public func git(_ path: String) async -> GitReport? {
        let token = UUID()
        return await withCheckedContinuation { c in
            let conn = state.withLock { s -> FramedConnection? in
                guard let conn = s.conn, s.welcome == nil, s.hostFeatures.contains("git") else { return nil }
                s.gits[token] = c
                return conn
            }
            if let conn { conn.send(ClientMessage.git(token, path: path)) } else { c.resume(returning: nil) }
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
