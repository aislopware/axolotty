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
    /// The `axolotty` CLI: linked onto every pane's PATH and called by agent hooks.
    public var cliExecutable: URL?
    public var name: String
    public var limits = PaneLimits()
    /// How often to look up each pane's foreground process.
    public var foregroundPoll: Duration = .seconds(1)
    /// A shell command at least this long (seconds) that finishes becomes
    /// done/error until seen, so a build that ends while you look away tells you.
    public var longCommand: Double = 10
    /// Close a pane whose program exits with status 0.
    public var closeOnCleanExit = true
    /// A plain shell instead of the person's login shell (tests, safe mode):
    /// interactive panes run it bare, commands run as `shell -c line`.
    public var shellOverride: String?
    /// Base environment for children (default: this process's).
    public var environment: [String: String]?
    /// Ties a launched holder's life to this process (tests only).
    public var holderWatchesServer = false
    /// Keep the Mac from idle-sleeping while any pane is working.
    public var keepAwake = true

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
    private var lockFD: Int32 = -1
    private var saveTask: Task<Void, Never>?
    private var running = false

    // Claude Code status from outside the pane (`ClaudeAgents.swift`).
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
        case accepted(FramedConnection)
        case frame(ObjectIdentifier, Frame)
        case closed(ObjectIdentifier)
        case exited(PaneID, ChildStatus)
        case holderLost
    }

    /// Actor-confined per-connection state.
    final class Link {
        let conn: FramedConnection
        var hello: ClientHello?
        var attached: Set<PaneID> = []
        init(conn: FramedConnection) { self.conn = conn }
        var subscribed: Bool { hello?.subscribe ?? false }
    }

    public init(config: ServerConfig) {
        self.config = config
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
        lockFD = open(paths.run.appending(path: "d.lock").path(percentEncoded: false), O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD) }
            lockFD = -1
            throw ServerError.alreadyRunning
        }
        running = true
        let sink = inboundSink
        custody = try await Holder.connect(
            paths: paths, executable: config.holderExecutable,
            watchPID: config.holderWatchesServer ? getpid() : nil, onExit: { sink.yield(.exited($0, $1)) }, onDisconnect: { sink.yield(.holderLost) })
        try await recover()
        try listen()

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
        if listenFD >= 0 { unlink(config.paths.hostSocket.path(percentEncoded: false)) }
        for link in links.values { link.conn.close() }
        links.removeAll()
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
                let conn = FramedConnection(fd: c, label: "client")
                sink.yield(.accepted(conn))
                let key = ObjectIdentifier(conn)
                conn.start(onFrame: { sink.yield(.frame(key, $0)) }, onClose: { _ in sink.yield(.closed(key)) })
            }
        }
        src.setCancelHandler { Darwin.close(fd) }
        acceptSource = src
        src.resume()
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
        case let .closed(key):
            guard let link = links.removeValue(forKey: key) else { return }
            for p in link.attached { panes[p]?.detach(link.conn) }
            for (p, set) in focused where set.contains(key) { setFocus(p, key, false) }
            for (p, d) in drivers where d == key { drivers[p] = nil }
            if lastInput == key { lastInput = nil }
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
        case let .capture(token, id, .commands, _):
            let json = panes[id] == nil ? nil
                : (try? JSONEncoder().encode(commandHistory[id] ?? [])).map { String(decoding: $0, as: UTF8.self) }
            link.conn.send(HostMessage.captured(token, json))
        case let .capture(token, id, format, scrollback):
            link.conn.send(HostMessage.captured(token, panes[id]?.capture(format, scrollback: scrollback)))
        case let .report(id, rid, st, app, message):
            updateStatus(id, live: true) { $0.report(id: rid, state: st, app: app, message: message) }
        case let .notify(id, title, body):
            broadcastEvent(.notification(id ?? PaneID(raw: UUID(uuid: UUID_NULL)), title: title, body: body))
        case let .ping(n):
            link.conn.send(HostMessage.pong(n))
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
        case let .renameWorkspace(id, name):
            guard var w = state.workspace(id) else { return .targetGone }
            w.name = name
            commit([.workspace(w)])
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
            // Pinned sessions stay above the rest whatever the drop index.
            let pins = dest.sessions.count { state.sessions[$0]?.isPinned == true }
            let bounds = s.isPinned ? 0 ... pins : pins ... dest.sessions.count
            dest.sessions.insert(id, at: min(max(index, bounds.lowerBound), bounds.upperBound))
            s.workspace = wid
            commit(deltas + [.workspace(dest), .session(s)])
        case let .setPinned(id, on):
            guard var s = state.sessions[id], var w = state.workspace(s.workspace) else { return .targetGone }
            guard s.isPinned != on else { return nil }
            s.pinned = on ? true : nil
            // Last of the pinned, either way: a new pin goes under the older
            // ones, an unpinned session heads the rest.
            w.sessions.removeAll { $0 == id }
            let pins = w.sessions.count { state.sessions[$0]?.isPinned == true }
            w.sessions.insert(id, at: pins)
            commit([.session(s), .workspace(w)])
        case let .setUnread(id, on):
            guard var s = state.sessions[id] else { return .targetGone }
            guard s.isUnread != on else { return nil }
            s.unread = on ? true : nil
            commit([.session(s)])
        case let .closeSession(id):
            await closeSession(id)
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
        case let .closePane(id):
            await closePane(id)
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
        case let .equalize(sid):
            guard var s = state.sessions[sid] else { return .targetGone }
            s.tree = s.tree.equalized()
            commit([.session(s)])
        }
        return nil
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
    private func closePane(_ id: PaneID) async {
        await discardPane(id)
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
    }

    private func closeSession(_ id: SessionID) async {
        guard let s = state.sessions[id] else { return }
        for p in s.tree.panes { await discardPane(p) }
        var deltas: [HostState.Delta] = s.tree.panes.map { .paneRemoved($0) } + [.sessionRemoved(id)]
        if var w = state.workspace(s.workspace) {
            w.sessions.removeAll { $0 == id }
            deltas.insert(.workspace(w), at: 0)
        }
        commit(deltas)
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
        commandHistory[id] = nil
        for link in links.values where link.attached.remove(id) != nil { link.conn.send(HostMessage.detached(id)) }
        try? await custody?.close(id: id)
    }

    private func paneExited(_ id: PaneID, _ status: ChildStatus) {
        guard var info = state.panes[id] else { return }
        let code = status.exitCode ?? 0
        if code == 0, config.closeOnCleanExit {
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
            retargetAgents(id, program: program, agent: agent, leader: leader, argv: argv)
        case let .readsSecret(id, on):
            guard var info = state.panes[id] else { return }
            info.readsSecret = on ? true : nil
            if info != state.panes[id] { commit([.pane(info)]) }
        case let .ports(id, ports):
            guard var info = state.panes[id] else { return }
            info.ports = ports.isEmpty ? nil : ports
            if info != state.panes[id] { commit([.pane(info)]) }
        case let .ended(id):
            // The terminal closed; the exit status follows from the holder.
            _ = id
        }
    }

    private var hasOSC7: Set<PaneID> = []
    /// When each pane's running command started, and its command line.
    private var commandStarts: [PaneID: (Double, String)] = [:]
    /// Each pane's finished commands this host has seen, oldest first
    /// (`axolotty commands`). Kept in memory only.
    private var commandHistory: [PaneID: [CommandRecord]] = [:]
    static let historyLimit = 200
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
                    if case .direct = agentTargets[id] { agentTargets[id] = nil }
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
                // A new command supersedes the last one's receipt.
                info.status.clear(Self.commandRecordID)
            case let .prompt(.commandEnd(code)):
                guard let (start, command) = commandStarts.removeValue(forKey: id) else { break }
                let now = Date().timeIntervalSince1970
                let record = CommandRecord(command: command, exitCode: code, duration: now - start, endedAt: now)
                info.lastCommand = record
                if live {
                    commandHistory[id, default: []].append(record)
                    if commandHistory[id]!.count > Self.historyLimit { commandHistory[id]!.removeFirst() }
                }
                if live, record.duration >= config.longCommand, !Self.isInteractive(command) {
                    let took = Self.duration(record.duration)
                    info.status.report(id: Self.commandRecordID, state: record.failed ? .error : .done, app: "",
                                       title: Self.firstLine(command),
                                       message: record.failed ? "Exit \(code ?? 1) after \(took)" : "Finished in \(took)")
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
        if before == .working, info.activitySince > 0 { info.lastRun = now - info.activitySince }
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

    /// Forces a checkpoint of every pane (tests, graceful shutdown).
    public func checkpointAll() {
        for p in panes.values { p.checkpointNow() }
    }

    public var paneCount: Int { panes.count }
}
#endif
