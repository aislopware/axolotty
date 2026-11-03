#if os(macOS)
public import AxModel
public import AxProtocol
import AxVT
import Dispatch
public import Foundation

public struct ServerConfig: Sendable {
    public var paths: RuntimePaths
    /// The holder binary to launch when none is running (nil: never launch).
    public var holderExecutable: URL?
    /// The `axolotty` CLI: linked onto every pane's PATH.
    public var cliExecutable: URL?
    public var name: String
    public var limits = PaneLimits()
    /// How often to look up each pane's foreground process.
    public var foregroundPoll: Duration = .seconds(1)
    /// A shell command at least this long (seconds) that finishes becomes
    /// done/error until seen, so a build that ends while you look away tells you.
    public var longCommand: Double = 10
    /// A plain shell instead of the person's login shell (tests, safe mode):
    /// interactive panes run it bare, commands run as `shell -c line`.
    public var shellOverride: String?
    /// Base environment for children (default: this process's).
    public var environment: [String: String]?
    /// Ties a launched holder's life to this process (tests only).
    public var holderWatchesServer = false
    /// Keep the Mac from idle-sleeping while any pane is working.
    public var keepAwake = true
    /// Also listen on this Mac's tailnet addresses (`Tailnet.port`), for the
    /// person's other devices; nil serves the local socket only.
    public var tailnetPort: UInt16?
    /// Who may call on the tailnet (the same person, by default).
    public var tailnetGate = TailnetGate()
    /// Where files sent from far panes go: the user's temporary folder,
    /// whose path has no spaces to quote.
    public var drops = FileManager.default.temporaryDirectory.appending(path: "axolotty-drops", directoryHint: .isDirectory)

    public init(paths: RuntimePaths, holderExecutable: URL?, name: String = Server.defaultName) {
        self.paths = paths
        self.holderExecutable = holderExecutable
        self.name = name
    }
}

public enum ServerError: Error, Equatable, Sendable {
    case alreadyRunning
    case listen(Int32)
}

/// `axolottyd`'s core: the shared document, the authoritative panes, and every
/// client connection. One actor serialises the document and intents; each pane
/// runs on its own queue (see `PaneHost`).
public actor Server {
    /// The computer name from Sharing settings ("Mac Studio"), else the host name.
    public static var defaultName: String {
        Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    public let config: ServerConfig
    public private(set) var state: HostState
    public nonisolated let epoch = UUID()

    private var custody: CustodyClient?
    private var panes: [PaneID: PaneHost] = [:]
    private var links: [ObjectIdentifier: Link] = [:]
    /// The client whose grid sizes each pane (one TIOCSWINSZ writer).
    private var drivers: [PaneID: ObjectIdentifier] = [:]
    private var focused: [PaneID: Set<ObjectIdentifier>] = [:]
    private var lastInput: ObjectIdentifier?
    private var appearance: Appearance?

    private let paneSignals: AsyncStream<PaneSignal>
    private let paneSink: AsyncStream<PaneSignal>.Continuation
    private let inbound: AsyncStream<Inbound>
    private let inboundSink: AsyncStream<Inbound>.Continuation
    private var tasks: [Task<Void, Never>] = []
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    /// One listener per tailnet address, kept in step with the interfaces.
    private var tailnetSources: [String: any DispatchSourceRead] = [:]
    /// The QUIC listener on each tailnet address (UDP, the same port as TCP's).
    private var tailnetQuic: [String: QuicEndpoint] = [:]
    private var lockFD: Int32 = -1
    private var saveTask: Task<Void, Never>?
    private var drops: Drops
    private var running = false

    // Claude Code status from outside, for panes running tmux (`ClaudeAgents.swift`).
    var agentTargets: [PaneID: ClaudeAgents.Target] = [:]
    var agentRoots: [PaneID: Set<Int32>] = [:]
    /// What the host last showed for each watched session, by pid.
    var agentShown: [PaneID: [Int32: StatusRecord.State]] = [:]
    /// Panes whose Claude Code reports for itself (OSC 7501) this program.
    var claudeNative: Set<PaneID> = []
    var sessionWatch: ClaudeSessionWatch?
    var agentsRefresh: Task<Void, Never>?
    var agentsAgain = false

    enum Inbound: Sendable {
        case accepted(any FrameLink)
        case frame(ObjectIdentifier, Frame)
        /// A datagram copy of a frame the peer also sent on its stream (feature "copies").
        case copy(ObjectIdentifier, Frame)
        case closed(ObjectIdentifier)
        case exited(PaneID, ChildStatus)
        case holderLost
    }

    /// Actor-confined per-connection state.
    final class Link {
        let conn: any FrameLink
        var hello: ClientHello?
        var attached: Set<PaneID> = []
        /// The number of the next input to apply (`ClientMessage.numbered`).
        var nextInput: UInt64 = 0
        init(conn: any FrameLink) { self.conn = conn }

        /// Whether numbered input `seq` is applied: from the stream, unless its copy already
        /// was; from a copy, only in its turn (an earlier one is still on its way).
        func admits(_ seq: UInt64, copy: Bool) -> Bool {
            guard copy ? seq == nextInput : seq >= nextInput else { return false }
            nextInput = seq + 1
            return true
        }
        var subscribed: Bool { hello?.subscribe ?? false }
    }

    public init(config: ServerConfig) {
        self.config = config
        drops = Drops(root: config.drops)
        let identity = Self.loadIdentity(config.paths)
        state = Self.loadDocument(config.paths) ?? HostState(host: identity, name: config.name)
        state.host = identity
        state.name = config.name
        (paneSignals, paneSink) = AsyncStream.makeStream()
        (inbound, inboundSink) = AsyncStream.makeStream()
    }

    // MARK: Lifecycle

    /// Takes the server lock, connects to (or launches) the holder, recovers
    /// every pane, and starts listening.
    public func start() async throws {
        let paths = config.paths
        try paths.prepare()
        try ShellEnvironment.install(paths, cli: config.cliExecutable)
        // Only a lock held elsewhere means another server: any other failure
        // (no descriptors left, no permission) is said as itself, or the
        // daemon would exit quietly believing it has a twin.
        let fd = open(paths.run.appending(path: "d.lock").path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        // A twin holds the lock for good. A process another thread is spawning
        // holds it for an instant: Foundation's Process carries every open
        // description, close-on-exec ones too, until its exec (71 of 20 000
        // tries refused beside a spawn loop), so a restart that met the old
        // server's last `git` would take itself for a twin. Waited out, by
        // the clock: on a Mac under load that instant can stretch past
        // half a second (seen with a test suite spawning in parallel).
        var rc: Int32 = -1
        let giveUp = ContinuousClock.now + .milliseconds(1500)
        while true {
            repeat { rc = flock(fd, LOCK_EX | LOCK_NB) } while rc != 0 && errno == EINTR
            if rc == 0 || errno != EWOULDBLOCK || ContinuousClock.now >= giveUp { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            if e == EWOULDBLOCK { throw ServerError.alreadyRunning }
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        lockFD = fd
        running = true
        let sink = inboundSink
        custody = try await Holder.connect(
            paths: paths, executable: config.holderExecutable,
            watchPID: config.holderWatchesServer ? getpid() : nil, onExit: { sink.yield(.exited($0, $1)) }, onDisconnect: { sink.yield(.holderLost) })
        try await recover()
        try listen()
        if let port = config.tailnetPort {
            tasks.append(Task { [weak self] in
                // Tailscale can come up, go down or change address at any time.
                while !Task.isCancelled {
                    await self?.listenOnTailnet(port: port)
                    try? await Task.sleep(for: .seconds(5))
                }
            })
        }

        tasks.append(Task { [weak self, paneSignals] in
            for await s in paneSignals { await self?.handle(s) }
        })
        tasks.append(Task { [weak self, inbound] in
            for await m in inbound { await self?.handle(m) }
        })
        let poll = config.foregroundPoll
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: poll)
                await self?.pollForeground()
            }
        })
    }

    /// Stops serving. Programs keep running in the holder; a later `start()`
    /// (this process or a new one) picks them up again.
    public func stop() async {
        guard running else { return }
        running = false
        acceptSource?.cancel()
        acceptSource = nil
        for src in tailnetSources.values { src.cancel() }
        tailnetSources.removeAll()
        for q in tailnetQuic.values { q.close() }
        tailnetQuic.removeAll()
        if listenFD >= 0 { unlink(config.paths.hostSocket.path(percentEncoded: false)) }
        for link in links.values { link.conn.close() }
        links.removeAll()
        // Panes a person closed don't outlive the server.
        for p in closing { await discardPane(p) }
        closing.removeAll()
        for pane in panes.values {
            pane.checkpointNow()
            pane.stop()
        }
        panes.removeAll()
        if let w = wake { ProcessInfo.processInfo.endActivity(w) }
        wake = nil
        saveTask?.cancel()
        saveNow()
        custody?.disconnect()
        custody = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        paneSink.finish()
        inboundSink.finish()
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    private func recover() async throws {
        guard let custody else { return }
        let held = try await custody.list()
        let heldByID = Dictionary(held.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        repairDocument()

        for (id, info) in state.panes {
            if heldByID[id] != nil, let handle = try? await custody.attach(id: id) {
                do {
                    let pane = try PaneHost(
                        id: id, handle: handle, cols: info.cols, rows: info.rows, fresh: false,
                        appearance: appearance, checkpoints: config.paths.checkpoints, limits: config.limits,
                        signals: paneSink)
                    panes[id] = pane
                    pane.start()
                    if let code = handle.status.exitCode { state.panes[id]?.exitStatus = code }
                    continue
                } catch {
                    try? await custody.close(id: id)
                }
            }
            // The program is gone (reboot, holder crash): start a fresh shell where it was.
            let cwd = info.pwd.isEmpty ? nil : info.pwd
            var fresh = info
            fresh.status = StatusBook()
            fresh.exitStatus = nil
            fresh.agent = nil
            fresh.program = ""
            state.panes[id] = fresh
            if (try? await spawn(id, recipe: SpawnRecipe(cwd: cwd), cols: info.cols, rows: info.rows)) == nil {
                state.panes[id]?.exitStatus = -1
            }
        }
        // Sessions the document no longer knows about.
        for h in held where state.panes[h.id] == nil {
            try? await custody.close(id: h.id)
        }
        scheduleSave()
    }

    /// Drops dangling references so the document always satisfies its invariants.
    private func repairDocument() {
        for (sid, s) in state.sessions {
            let live = s.tree.panes.filter { state.panes[$0] != nil }
            if live.isEmpty {
                state.sessions[sid] = nil
                continue
            }
            var tree: SplitTree? = s.tree
            for p in s.tree.panes where state.panes[p] == nil { tree = tree?.removing(p) }
            guard let tree else {
                state.sessions[sid] = nil
                continue
            }
            var fixed = s
            fixed.tree = tree
            if !tree.contains(fixed.focus) { fixed.focus = tree.panes[0] }
            if let z = fixed.zoomed, !tree.contains(z) { fixed.zoomed = nil }
            state.sessions[sid] = fixed
        }
        let sessions = state.sessions
        for i in state.workspaces.indices {
            state.workspaces[i].sessions.removeAll { sessions[$0] == nil }
        }
        let listed = Set(state.workspaces.flatMap(\.sessions))
        for (sid, s) in state.sessions where !listed.contains(sid) {
            if let w = state.workspaces.firstIndex(where: { $0.id == s.workspace }) {
                state.workspaces[w].sessions.append(sid)
            } else {
                state.sessions[sid] = nil
            }
        }
        let inTrees = Set(state.sessions.values.flatMap(\.tree.panes))
        for p in state.panes.keys where !inTrees.contains(p) { state.panes[p] = nil }
        for p in state.panes.keys {
            if let s = state.sessions.first(where: { $0.value.tree.contains(p) })?.key { state.panes[p]?.session = s }
        }
    }

    // MARK: Listening

    private func listen() throws {
        let path = config.paths.hostSocket.path(percentEncoded: false)
        let fd: Int32
        do { fd = try UnixSocket.listen(path: path) } catch let e as POSIXError {
            throw ServerError.listen(e.code.rawValue)
        }
        listenFD = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "axolotty.accept"))
        let sink = inboundSink
        src.setEventHandler {
            while true {
                let c = accept(fd, nil, nil)
                guard c >= 0 else { return }
                guard UnixSocket.peerIsSameUser(c) else {
                    Darwin.close(c)
                    continue
                }
                Self.serve(FramedConnection(fd: c, label: "client"), sink: sink)
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.resume()
    }

    private nonisolated static func serve(_ conn: any FrameLink, sink: AsyncStream<Inbound>.Continuation) {
        sink.yield(.accepted(conn))
        let key = ObjectIdentifier(conn)
        // Tunnelled streams (feature "tunnel") go straight to their sockets,
        // never through the actor: a page loading must not wait on a pane.
        let tunnels = Tunnels(conn: conn) { port in try? TCPSocket.connect(host: "localhost", port: port, timeout: 2) }
        conn.onCopies { frame in sink.yield(.copy(key, frame)) }
        conn.start(onFrame: { frame in
            switch frame {
            case .open, .stream, .streamAck, .reset: tunnels.receive(frame)
            default: sink.yield(.frame(key, frame))
            }
        }, onClose: { _ in
            tunnels.closeAll()
            sink.yield(.closed(key))
        })
    }

    /// Listens on every tailnet address this Mac has now and stops on the
    /// ones it lost. A caller is served only when Tailscale says it is the
    /// same person (`TailnetGate`); anyone else hears "denied".
    /// Serves a tailnet caller Tailscale says is the same person; tells anyone else "denied".
    private nonisolated static func admit(_ conn: any FrameLink, peer: String, gate: TailnetGate,
                                          sink: AsyncStream<Inbound>.Continuation) {
        if gate.admits(peer) {
            serve(conn, sink: sink)
        } else {
            conn.start(onFrame: { _ in }, onClose: { _ in })
            conn.send(HostMessage.error("denied"))
            conn.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { conn.close() }
        }
    }

    private func listenOnTailnet(port: UInt16) {
        let now = Set(Tailnet.localAddresses())
        for (address, src) in tailnetSources where !now.contains(address) {
            src.cancel()
            tailnetSources[address] = nil
        }
        for (address, q) in tailnetQuic where !now.contains(address) {
            q.close()
            tailnetQuic[address] = nil
        }
        // QUIC first for every client that speaks it (`QuicLink`); TCP beside it for older
        // clients and paths that drop UDP.
        for address in now where tailnetQuic[address] == nil {
            guard let q = try? QuicEndpoint(address: address, port: port, server: true) else { continue }
            let sink = inboundSink
            let gate = config.tailnetGate
            let admission = DispatchQueue(label: "axolotty.admission.quic", attributes: .concurrent)
            q.listen { link, peer in
                admission.async { Self.admit(link, peer: peer, gate: gate, sink: sink) }
            }
            tailnetQuic[address] = q
        }
        for address in now where tailnetSources[address] == nil {
            guard let fd = try? TCPSocket.listen(address: address, port: port) else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "axolotty.accept.tailnet"))
            let sink = inboundSink
            let gate = config.tailnetGate
            let admission = DispatchQueue(label: "axolotty.admission", attributes: .concurrent)
            src.setEventHandler {
                while true {
                    let c = accept(fd, nil, nil)
                    guard c >= 0 else { return }
                    _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
                    _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                    TCPSocket.tune(c)  // no SIGPIPE: inherited from the listener
                    let peer = TCPSocket.peerAddress(c) ?? ""
                    admission.async {
                        let conn = FramedConnection(fd: c, label: "tailnet \(peer)")
                        conn.pace()
                        Server.admit(conn, peer: peer, gate: gate, sink: sink)
                    }
                }
            }
            src.setCancelHandler { Darwin.close(fd) }
            tailnetSources[address] = src
            src.resume()
        }
    }

    // MARK: Inbound

    private func handle(_ m: Inbound) async {
        switch m {
        case let .accepted(conn):
            links[ObjectIdentifier(conn)] = Link(conn: conn)
        case let .frame(key, frame):
            guard let link = links[key] else { return }
            switch frame {
            case let .control(json):
                do {
                    try await handle(try MessageCodec.client(json), from: link)
                } catch {
                    link.conn.send(HostMessage.error("bad message: \(error)"))
                }
            case let .ack(pane, offset):
                panes[pane]?.ack(link.conn, offset: offset)
            default:
                link.conn.send(HostMessage.error("unexpected frame"))
            }
        case let .copy(key, frame):
            // A key's copy, applied if it is the next input; anything else a copy carries is
            // left to the stream.
            guard let link = links[key], case let .control(json) = frame,
                  case let .numbered(seq, input) = try? MessageCodec.client(json), input.isInput,
                  link.admits(seq, copy: true) else { return }
            try? await handle(input, from: link)
        case let .closed(key):
            guard let link = links.removeValue(forKey: key) else { return }
            for p in link.attached { panes[p]?.detach(link.conn) }
            for (p, set) in focused where set.contains(key) { setFocus(p, key, false) }
            for (p, d) in drivers where d == key { drivers[p] = nil }
            if lastInput == key { lastInput = nil }
            drops.drop(owner: key)
        case let .exited(id, status):
            paneExited(id, status)
        case .holderLost:
            // Running programs are still alive (the server keeps every master
            // descriptor); a fresh holder adopts them.
            await relaunchHolder()
        }
    }

    private func handle(_ msg: ClientMessage, from link: Link) async throws {
        if case let .hello(h) = msg {
            guard h.protocolVersion == Wire.version else {
                link.conn.send(HostMessage.incompatible(generation: Wire.version))
                let conn = link.conn
                conn.queue.asyncAfter(deadline: .now() + .milliseconds(200)) { conn.close() }
                return
            }
            link.hello = h
            link.conn.send(HostMessage.welcome(HostHello(host: state.host, name: state.name, epoch: epoch, state: state)))
            return
        }
        guard link.hello != nil else {
            link.conn.send(HostMessage.error("hello first"))
            return
        }
        let key = ObjectIdentifier(link.conn)
        switch msg {
        case let .numbered(seq, input):
            // Input only, one level deep; skipped when its copy came first.
            guard input.isInput, link.admits(seq, copy: false) else { return }
            try await handle(input, from: link)
        case .hello:
            break
        case let .intent(token, intent):
            let error = await apply(intent, from: link)
            link.conn.send(HostMessage.intentResult(token, error))
        case let .attach(id, have):
            guard let pane = panes[id] else {
                link.conn.send(HostMessage.detached(id))
                return
            }
            link.attached.insert(id)
            pane.attach(link.conn, have: have)
        case let .detach(id):
            link.attached.remove(id)
            panes[id]?.detach(link.conn)
            setFocus(id, key, false)
            link.conn.send(HostMessage.detached(id))
        case let .viewport(id, cols, rows, cw, ch):
            guard let pane = panes[id] else { return }
            if drivers[id] == nil || links[drivers[id]!] == nil { drivers[id] = key }
            guard drivers[id] == key else { return }
            pane.resize(cols: cols, rows: rows, cellWidth: cw, cellHeight: ch)
            if var info = state.panes[id], info.cols != cols || info.rows != rows, cols >= 2, rows >= 1 {
                info.cols = cols
                info.rows = rows
                commit([.pane(info)])
            }
        case let .takeSize(id):
            drivers[id] = key
        case let .appearance(a):
            appearance = a
            for p in panes.values { p.setAppearance(a) }
        case let .key(id, k):
            lastInput = key
            panes[id]?.key(k)
            if k.action == .press { markSeen(id) }
        case let .mouse(id, m):
            lastInput = key
            panes[id]?.mouse(m)
        case let .paste(id, text):
            lastInput = key
            panes[id]?.paste(text)
        case let .text(id, text):
            panes[id]?.type(text)
        case let .focus(id, on):
            setFocus(id, key, on)
            if on { markSeen(id) }
        case let .signal(id, signo):
            try? await custody?.signal(id: id, signo, foreground: true)
        case let .clear(id):
            panes[id]?.clear()
        case let .seen(id):
            markSeen(id)
        case let .capture(token, id, scrollback):
            link.conn.send(HostMessage.captured(token, panes[id]?.capture(scrollback: scrollback)))
        case let .ping(n):
            link.conn.send(HostMessage.pong(n))
        case let .git(token, path):
            // Git may take a while (2 s at most): off the server's own work.
            let conn = link.conn
            Task.detached(priority: .utility) { conn.send(HostMessage.gitTree(token, GitReport.read(path))) }
        case let .paths(token, cwd, candidates):
            let conn = link.conn
            Task.detached(priority: .utility) {
                conn.send(HostMessage.pathsFound(token, HostPath.resolve(candidates, cwd: cwd)))
            }
        case let .file(token, name, bytes, last):
            if let saved = drops.put(token, name: name, bytes: bytes, last: last, from: ObjectIdentifier(link.conn)) {
                link.conn.send(HostMessage.fileSaved(token, path: saved))
            }
        }
    }

    private func setFocus(_ id: PaneID, _ key: ObjectIdentifier, _ on: Bool) {
        var set = focused[id] ?? []
        let before = !set.isEmpty
        if on { set.insert(key) } else { set.remove(key) }
        focused[id] = set.isEmpty ? nil : set
        if before != !set.isEmpty { panes[id]?.focus(!set.isEmpty) }
    }

    // MARK: Intents

    private func apply(_ intent: Intent, from link: Link) async -> IntentError? {
        let key = ObjectIdentifier(link.conn)
        switch intent {
        case let .createWorkspace(id, name, root):
            if var w = state.workspace(id) {
                w.name = name
                w.root = root
                commit([.workspace(w)])
            } else {
                commit([.workspace(WorkspaceInfo(id: id, name: name, root: root))])
            }
        case let .closeWorkspace(id):
            guard let w = state.workspace(id) else { return nil }
            for s in w.sessions { await closeSession(s) }
            commit([.workspaceRemoved(id)])
        case let .createSession(sid, wid, pid, recipe, name):
            if state.sessions[sid] != nil { return nil }  // retried intent
            guard let w = state.workspace(wid) else { return .targetGone }
            var recipe = recipe
            if recipe.cwd == nil, !w.root.isEmpty { recipe.cwd = w.root }
            var worktree: String?
            if let branch = recipe.worktree {
                let from = recipe.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
                let made = await Task.detached { () -> Result<String, Worktrees.Failure> in
                    do throws(Worktrees.Failure) { return .success(try Worktrees.add(from: from, branch: branch)) } catch {
                        return .failure(error)
                    }
                }.value
                guard case let .success(path) = made else { return .worktreeFailed }
                recipe.cwd = path
                recipe.worktree = nil
                worktree = path
            }
            state.panes[pid] = PaneInfo(id: pid, session: sid)
            do {
                try await spawn(pid, recipe: recipe, cols: 80, rows: 24)
            } catch {
                state.panes[pid] = nil
                return .spawnFailed
            }
            drivers[pid] = key
            guard var w2 = state.workspace(wid), let info = state.panes[pid] else {
                await discardPane(pid)
                return .targetGone
            }
            w2.sessions.append(sid)
            var s = SessionInfo(id: sid, workspace: wid, root: pid, name: name)
            s.worktree = worktree
            commit([.pane(info), .session(s), .workspace(w2)])
        case let .renameSession(id, name):
            guard var s = state.sessions[id] else { return .targetGone }
            s.name = name
            commit([.session(s)])
        case let .moveSession(id, wid, index):
            guard var s = state.sessions[id], var dest = state.workspace(wid) else { return .targetGone }
            var deltas: [HostState.Delta] = []
            if var src = state.workspace(s.workspace), src.id != wid {
                src.sessions.removeAll { $0 == id }
                deltas.append(.workspace(src))
            }
            dest.sessions.removeAll { $0 == id }
            dest.sessions.insert(id, at: min(max(index, 0), dest.sessions.count))
            s.workspace = wid
            commit(deltas + [.workspace(dest), .session(s)])
        case let .closeSession(id, reopenable):
            await closeSession(id, remember: reopenable)
        case let .removeWorktree(id, force):
            guard let path = state.sessions[id]?.worktree else { return .notAllowed }
            if !force {
                let dirty = await Task.detached {
                    !(Worktrees.git(["status", "--porcelain"], in: path) ?? "").isEmpty
                }.value
                if dirty { return .dirty }
            }
            await closeSession(id)
            // Other sessions in the same folder lose their worktree mark.
            let others = state.sessions.values.filter { $0.worktree == path }
            if !others.isEmpty {
                commit(others.map { var s = $0; s.worktree = nil; return .session(s) })
            }
            let removed = await Task.detached { () -> Bool in
                do throws(Worktrees.Failure) { try Worktrees.remove(path, force: true); return true } catch { return false }
            }.value
            if !removed { return .worktreeFailed }
        case let .split(sid, target, new, axis, before, recipe):
            if state.panes[new] != nil { return nil }
            guard let s = state.sessions[sid], s.tree.contains(target) else { return .targetGone }
            var recipe = recipe
            if recipe.cwd == nil, let pwd = state.panes[target]?.pwd, !pwd.isEmpty { recipe.cwd = pwd }
            let t = state.panes[target]
            let cols = axis == .horizontal ? max(2, (t?.cols ?? 80) / 2) : t?.cols ?? 80
            let rows = axis == .vertical ? max(1, (t?.rows ?? 24) / 2) : t?.rows ?? 24
            state.panes[new] = PaneInfo(id: new, session: sid, cols: cols, rows: rows)
            do {
                try await spawn(new, recipe: recipe, cols: cols, rows: rows)
            } catch {
                state.panes[new] = nil
                return .spawnFailed
            }
            drivers[new] = key
            guard var s2 = state.sessions[sid], s2.tree.contains(target), let info = state.panes[new] else {
                await discardPane(new)
                return .targetGone
            }
            s2.tree = s2.tree.splitting(target, with: new, axis: axis, before: before)
            s2.focus = new
            s2.zoomed = nil
            commit([.pane(info), .session(s2)])
        case let .closePane(id, reopenable):
            await closePane(id, remember: reopenable)
        case let .restartPane(old, new):
            if state.panes[new] != nil { return nil }  // retried intent
            guard let o = state.panes[old], let s = state.sessions[o.session], s.tree.contains(old) else { return .targetGone }
            guard o.exitStatus != nil else { return .notAllowed }  // only an ended pane
            state.panes[new] = PaneInfo(id: new, session: o.session, cols: o.cols, rows: o.rows)
            do {
                try await spawn(new, recipe: SpawnRecipe(command: o.launch, cwd: o.pwd.isEmpty ? nil : o.pwd),
                                cols: o.cols, rows: o.rows)
            } catch {
                state.panes[new] = nil
                return .spawnFailed
            }
            drivers[new] = key
            await discardPane(old)
            guard var s2 = state.sessions[o.session], s2.tree.contains(old), let info = state.panes[new] else {
                await discardPane(new)
                return .targetGone
            }
            s2.tree = s2.tree.replacing(old, with: new)
            if s2.focus == old { s2.focus = new }
            if s2.zoomed == old { s2.zoomed = new }
            commit([.pane(info), .session(s2), .paneRemoved(old)])
        case let .focusPane(sid, pid):
            guard var s = state.sessions[sid], s.tree.contains(pid) else { return .targetGone }
            guard s.focus != pid else { return nil }
            s.focus = pid
            commit([.session(s)])
        case let .setZoom(sid, pid):
            guard var s = state.sessions[sid] else { return .targetGone }
            if let pid, !s.tree.contains(pid) { return .targetGone }
            s.zoomed = pid
            commit([.session(s)])
        case let .setTree(sid, tree):
            guard var s = state.sessions[sid] else { return .targetGone }
            guard Set(tree.panes) == Set(s.tree.panes), tree.panes.count == s.tree.panes.count else { return .invalid }
            s.tree = tree
            commit([.session(s)])
        case let .openURL(text):
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let far = personFar() else { return .notAllowed }
            far.conn.send(HostMessage.event(.openURL(text)))
        case let .copy(pane, text):
            guard let far = personFar() else { return .notAllowed }
            far.conn.send(HostMessage.event(.clipboard(pane, text)))
        }
        return nil
    }

    /// The link the person last typed or clicked through, when it comes
    /// from another Mac that can take links and copies: where they are.
    private func personFar() -> Link? {
        guard let key = lastInput, let l = links[key], l.hello?.remote == true,
              l.hello?.features?.contains("open") == true else { return nil }
        return l
    }

    private func spawn(_ id: PaneID, recipe: SpawnRecipe, cols: UInt16, rows: UInt16) async throws {
        guard let custody else { throw CustodyError.disconnected }
        let (path, argv) = ShellEnvironment.command(recipe, shell: config.shellOverride, integration: config.paths.shellIntegration)
        var cwd = recipe.cwd.map { $0.hasPrefix("~") ? ShellEnvironment.home + $0.dropFirst() : $0 }
        var isDir: ObjCBool = false
        if let c = cwd, !FileManager.default.fileExists(atPath: c, isDirectory: &isDir) || !isDir.boolValue {
            cwd = nil
        }
        let env = ShellEnvironment.environment(pane: id, recipe: recipe, paths: config.paths,
                                               base: config.environment ?? ProcessInfo.processInfo.environment)
        let handle = try await custody.spawn(
            id: id, SpawnSpec(path: path, argv: argv, env: env, cwd: cwd ?? ShellEnvironment.home, cols: cols, rows: rows))
        let pane: PaneHost
        do {
            pane = try PaneHost(id: id, handle: handle, cols: cols, rows: rows, fresh: true, appearance: appearance,
                                checkpoints: config.paths.checkpoints, limits: config.limits, signals: paneSink)
        } catch {
            Darwin.close(handle.master)
            try? await custody.close(id: id)
            throw error
        }
        panes[id] = pane
        state.panes[id]?.pwd = cwd ?? ShellEnvironment.home
        state.panes[id]?.launch = recipe.command
        state.panes[id]?.activitySince = Date().timeIntervalSince1970
        pane.start()
    }

    /// Ends a pane's program and removes it from its session.
    /// `remember`: the app keeps the session for reopening, so when it goes
    /// with this pane, its Claude Code conversation is looked up (`closeLater`).
    private func closePane(_ id: PaneID, remember: Bool = false) async {
        let session = state.panes[id]?.session
        let last = session.flatMap { state.sessions[$0] }.map { $0.tree.count == 1 } ?? false
        let claude = remember && last ? session.flatMap(claudeRoot) : nil
        if claude == nil { await discardPane(id) }
        guard let info = state.panes[id] else { return }
        var deltas: [HostState.Delta] = [.paneRemoved(id)]
        if var s = state.sessions[info.session] {
            if let tree = s.tree.removing(id) {
                s.tree = tree
                if s.focus == id { s.focus = tree.panes[0] }
                if s.zoomed == id { s.zoomed = nil }
                deltas.insert(.session(s), at: 0)
            } else {
                deltas.insert(.sessionRemoved(s.id), at: 0)
                if var w = state.workspace(s.workspace) {
                    w.sessions.removeAll { $0 == s.id }
                    deltas.insert(.workspace(w), at: 0)
                }
            }
        }
        commit(deltas)
        if let claude { closeLater(info.session, [id], claude) }
    }

    private func closeSession(_ id: SessionID, remember: Bool = false) async {
        guard let s = state.sessions[id] else { return }
        let claude = remember ? claudeRoot(id) : nil
        if claude == nil { for p in s.tree.panes { await discardPane(p) } }
        var deltas: [HostState.Delta] = s.tree.panes.map { .paneRemoved($0) } + [.sessionRemoved(id)]
        if var w = state.workspace(s.workspace) {
            w.sessions.removeAll { $0 == id }
            deltas.insert(.workspace(w), at: 0)
        }
        commit(deltas)
        if let claude { closeLater(id, s.tree.panes, claude) }
    }

    /// The pane `HostState.claudePane` picks and its shell's pid, while that
    /// pane still runs here and Claude Code can be asked.
    private func claudeRoot(_ session: SessionID) -> (pane: PaneID, shell: Int32)? {
        guard ClaudeAgents.claude != nil, let p = state.claudePane(of: session), let host = panes[p] else { return nil }
        return (p, host.pid)
    }

    /// Panes already gone from the state whose processes wait for
    /// `closeLater`'s question; `stop()` ends them rather than keep them.
    private var closing = Set<PaneID>()

    /// Finishes closing a session the app will offer to reopen: asks Claude
    /// Code which conversation the pane's process holds, while it still runs
    /// (`claude agents --json`, its documented outside view, lists
    /// `sessionId` for live processes only), then ends the panes. It runs on
    /// its own: the state already changed, and the server keeps serving
    /// every client while the question is out (≤ 3 s).
    private func closeLater(_ session: SessionID, _ ids: [PaneID], _ claude: (pane: PaneID, shell: Int32)) {
        closing.formUnion(ids)
        Task {
            let roots = [claude.pane: Set([claude.shell])]
            let byPane = await Task.detached(priority: .userInitiated) {
                ClaudeAgents.list(timeout: 3).map { ClaudeAgents.assign($0, roots: roots) } ?? [:]
            }.value
            if running, let id = byPane[claude.pane]?.compactMap(\.sessionId).first(where: { UUID(uuidString: $0) != nil }) {
                broadcastEvent(.claudeConversation(session, id: id))
            }
            for p in ids where closing.remove(p) != nil { await discardPane(p) }
        }
    }

    /// Stops serving a pane and tells the holder to hang it up.
    private func discardPane(_ id: PaneID) async {
        if let pane = panes.removeValue(forKey: id) {
            pane.stop()
            pane.removeCheckpoint()
        }
        drivers[id] = nil
        focused[id] = nil
        forgetAgents(id)
        commandStarts[id] = nil
        for link in links.values where link.attached.remove(id) != nil { link.conn.send(HostMessage.detached(id)) }
        try? await custody?.close(id: id)
    }

    private func paneExited(_ id: PaneID, _ status: ChildStatus) {
        guard var info = state.panes[id] else { return }
        let code = status.exitCode ?? 0
        // A clean exit closes the pane; a failed one stays to show why.
        if code == 0 {
            Task { await closePane(id) }
            return
        }
        info.exitStatus = code
        info.status.programEnded()
        info.status.clearAgents()
        forgetAgents(id)
        commit([.pane(info)])
    }

    private func relaunchHolder() async {
        guard running else { return }
        custody = nil
        let sink = inboundSink
        guard let fresh = try? await Holder.connect(
            paths: config.paths, executable: config.holderExecutable,
            watchPID: config.holderWatchesServer ? getpid() : nil, onExit: { sink.yield(.exited($0, $1)) }, onDisconnect: { sink.yield(.holderLost) })
        else { return }
        custody = fresh
        for (id, pane) in panes {
            try? await fresh.adopt(id: id, pid: pane.pid, master: pane.masterFD, ring: pane.ringFD)
        }
    }

    // MARK: Pane signals

    private func handle(_ s: PaneSignal) {
        switch s {
        case let .events(id, events, live):
            apply(events, to: id, live: live)
        case let .foreground(id, program, agent, cwd, leader, argv):
            guard var info = state.panes[id] else { return }
            let hadAgent = info.agent != nil
            info.program = program
            info.agent = agent
            if let cwd, !hasOSC7.contains(id) { info.pwd = cwd }
            if hadAgent, agent == nil {
                info.status.programEnded()
                claudeNative.remove(id)
            }
            if info != state.panes[id] { commit([.pane(info)]) }
            retargetAgents(id, program: program, leader: leader, argv: argv)
        case let .readsSecret(id, on):
            guard var info = state.panes[id] else { return }
            info.readsSecret = on ? true : nil
            if info != state.panes[id] { commit([.pane(info)]) }
        }
    }

    private var hasOSC7: Set<PaneID> = []
    /// When each pane's running command started, and its command line.
    private var commandStarts: [PaneID: (Double, String)] = [:]

    static let commandRecordID = "axolotty.command"

    /// Programs a person sits in rather than waits for: their end is no news.
    static func isInteractive(_ command: String) -> Bool {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard var first = words.first.map(String.init) else { return true }
        var rest = words.dropFirst()
        while first == "sudo" || first == "exec" || first == "command" || first == "nocorrect", let n = rest.first {
            first = String(n)
            rest = rest.dropFirst()
        }
        first = String(first.split(separator: "/").last ?? Substring(first))
        let args = rest.map(String.init)
        if AgentKind.identify(processName: first, argv: [first] + args) != nil { return true }
        let operand = args.contains { !$0.hasPrefix("-") }
        let tty = args.contains { $0 == "-it" || $0 == "-ti" || $0 == "-i" || $0 == "--interactive" || $0 == "-t" }
        switch first {
        case "python", "python3", "node", "bun", "deno", "irb", "ghci", "lua", "julia", "R":
            return !operand  // the REPL, not a script
        case "docker", "podman", "kubectl", "oc":
            return tty || args.contains("port-forward") || args.contains("-f") && args.contains("logs")
        case "tail", "journalctl":
            return args.contains { $0 == "-f" || $0 == "-F" || $0 == "--follow" }
        default:
            return interactive.contains(first)
        }
    }

    private static let interactive: Set<String> = [
        "vi", "vim", "nvim", "nano", "emacs", "hx", "helix", "micro", "kak", "less", "more", "man", "most",
        "ssh", "mosh", "et", "telnet", "tmux", "screen", "zellij", "top", "htop", "btop", "btm", "glances",
        "psql", "mysql", "sqlite3", "redis-cli", "mongosh", "lazygit", "lazydocker", "tig", "gitui", "yazi",
        "ranger", "nnn", "lf", "fzf", "watch", "zsh", "bash", "fish", "sh", "su", "login", "k9s", "ncdu",
    ]

    static func firstLine(_ s: String) -> String {
        let line = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        return line.count > 80 ? String(line.prefix(79)) + "…" : line
    }

    /// "12s", "4m 12s", "1h 24m".
    static func duration(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        if t < 60 { return "\(t)s" }
        if t < 3600 { return t % 60 == 0 ? "\(t / 60)m" : "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \(t / 60 % 60)m"
    }

    private func apply(_ events: [VTEvent], to id: PaneID, live: Bool) {
        guard var info = state.panes[id] else { return }
        let before = info.activity
        for e in events {
            switch e {
            case let .titleChanged(t):
                info.title = String(t.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(256))
            case let .pwdChanged(p):
                hasOSC7.insert(id)
                info.pwd = Self.path(fromOSC7: p)
            case .bell:
                if live { broadcastEvent(.bell(id)) }
            case let .notification(title, body):
                if live { broadcastEvent(.notification(id, title: title, body: body)) }
            case let .progress(p):
                switch p {
                case .remove: info.progress = nil
                case let .set(v): info.progress = v
                case let .error(v): info.progress = v ?? info.progress ?? 100
                case let .paused(v): info.progress = v ?? info.progress ?? -1
                case .indeterminate: info.progress = -1
                }
            case let .programStatus(ps):
                if ps.app == "claude-code", !claudeNative.contains(id) {
                    // It speaks for itself: what the host read from outside goes.
                    claudeNative.insert(id)
                    info.status.clearAgents()
                    agentShown[id] = nil
                }
                if ps.state == .clear {
                    info.status.clear(ps.id)
                } else {
                    let st: StatusRecord.State = switch ps.state {
                    case .idle: .idle
                    case .working: .working
                    case .done: .done
                    case .blocked: .blocked
                    case .error, .clear: .error
                    }
                    let need: StatusRecord.Need? = switch ps.kind {
                    case .permission: .permission
                    case .question: .question
                    case .auth: .auth
                    case .none: nil
                    }
                    info.status.report(id: ps.id, state: st, app: ps.app, title: ps.title, message: ps.message, need: need,
                                       progress: ps.progress)
                }
            case .prompt(.promptStart):
                info.status.programEnded()
                claudeNative.remove(id)
            case let .prompt(.commandStart(command)):
                commandStarts[id] = (Date().timeIntervalSince1970, command)
                // A new command supersedes the last one's notice.
                info.status.clear(Self.commandRecordID)
            case let .prompt(.commandEnd(code)):
                guard let (start, command) = commandStarts.removeValue(forKey: id) else { break }
                let now = Date().timeIntervalSince1970
                let record = CommandRecord(command: command, exitCode: code, duration: now - start, endedAt: now)
                info.lastCommand = record
                if live, record.duration >= config.longCommand, !Self.isInteractive(command) {
                    let took = Self.duration(record.duration)
                    let failed = (code ?? 0) != 0
                    info.status.report(id: Self.commandRecordID, state: failed ? .error : .done, app: "",
                                       title: Self.firstLine(command),
                                       message: failed ? "Exit \(code ?? 1) after \(took)" : "Finished in \(took)")
                }
            case .prompt:
                break
            case let .clipboardWrite(text):
                if live, let k = lastInput, let link = links[k] { link.conn.send(HostMessage.event(.clipboard(id, text))) }
            case .reset:
                break
            }
        }
        finishStatusChange(&info, before: before, live: live)
        if info != state.panes[id] { commit([.pane(info)]) }
    }

    func updateStatus(_ id: PaneID, live: Bool, _ body: (inout StatusBook) -> Void) {
        guard var info = state.panes[id] else { return }
        let before = info.activity
        body(&info.status)
        finishStatusChange(&info, before: before, live: live)
        if info != state.panes[id] { commit([.pane(info)]) }
    }

    private func finishStatusChange(_ info: inout PaneInfo, before: Activity, live: Bool) {
        let after = info.activity
        guard after != before else { return }
        let now = Date().timeIntervalSince1970
        info.activitySince = now
        guard live, after == .blocked || after == .done || after == .error else { return }
        let message = after == .blocked ? info.status.headline?.ask : info.status.headline?.message
        broadcastEvent(.attention(info.id, after, message: message ?? info.displayTitle))
    }

    private func markSeen(_ id: PaneID) {
        guard var info = state.panes[id] else { return }
        info.status.markSeen()
        if info.exitStatus == nil, info != state.panes[id] { commit([.pane(info)]) }
    }

    static func path(fromOSC7 s: String) -> String {
        guard s.hasPrefix("file://") else { return s }
        let rest = s.dropFirst(7)
        let path = rest.firstIndex(of: "/").map { rest[$0...] } ?? rest
        return String(path).removingPercentEncoding ?? String(path)
    }

    private func pollForeground() {
        for p in panes.values { p.pollForeground() }
    }

    // MARK: Fan-out and persistence

    private func commit(_ deltas: [HostState.Delta]) {
        guard !deltas.isEmpty else { return }
        state.apply(deltas)
        let msg = HostMessage.deltas(deltas, revision: state.revision)
        guard let frame = try? MessageCodec.frame(msg) else { return }
        for link in links.values where link.subscribed { link.conn.send(frame) }
        scheduleSave()
        updateWake()
    }

    // MARK: Keep awake

    /// Held while any pane is working, so a Mac left alone does not idle-sleep
    /// under a running agent (the display may still sleep). Lives in the host,
    /// so it holds with no client attached.
    private var wake: (any NSObjectProtocol)?

    private func updateWake() {
        let working = config.keepAwake && state.panes.values.contains { $0.activity == .working }
        if working, wake == nil {
            wake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                         reason: "An agent is working in Axolotty")
        } else if !working, let w = wake {
            ProcessInfo.processInfo.endActivity(w)
            wake = nil
        }
    }

    /// Whether the host currently holds the keep-awake assertion (tests).
    public var holdsWake: Bool { wake != nil }

    private func broadcastEvent(_ e: HostEvent) {
        guard let frame = try? MessageCodec.frame(HostMessage.event(e)) else { return }
        for link in links.values where link.subscribed { link.conn.send(frame) }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.saveNow()
        }
    }

    private func saveNow() {
        saveTask = nil
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(state) else { return }
        try? data.write(to: config.paths.document, options: .atomic)
    }

    private static func loadDocument(_ paths: RuntimePaths) -> HostState? {
        guard let data = try? Data(contentsOf: paths.document) else { return nil }
        if let s = try? JSONDecoder().decode(HostState.self, from: data) { return s }
        // Corrupt: keep it for inspection, start empty.
        let aside = paths.document.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
        try? FileManager.default.moveItem(at: paths.document, to: aside)
        return nil
    }

    private static func loadIdentity(_ paths: RuntimePaths) -> HostID {
        if let data = try? Data(contentsOf: paths.identity), let id = try? JSONDecoder().decode(HostID.self, from: data) {
            return id
        }
        let id = HostID()
        try? paths.prepare()
        if let data = try? JSONEncoder().encode(id) { try? data.write(to: paths.identity, options: .atomic) }
        return id
    }

    // MARK: Test and tooling hooks

    public var paneCount: Int { panes.count }
}
#endif
