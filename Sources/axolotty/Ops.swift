// What the CLI and the MCP server both do: each operation opens its own
// connection to the host (a Unix socket: cheap), does one thing, and throws
// an `OpError` that the CLI turns into an exit code and MCP into a tool error.
import AxClient
import AxModel
import AxProtocol
import Foundation

enum Exit: Int32 { case ok = 0, failed = 1, usage = 2, notFound = 3, unreachable = 4, timeout = 124 }

struct OpError: Error {
    var message: String
    var exit: Exit

    static func usage(_ m: String) -> OpError { OpError(message: m, exit: .usage) }
    static func notFound(_ m: String) -> OpError { OpError(message: m, exit: .notFound) }
    static func failed(_ m: String) -> OpError { OpError(message: m, exit: .failed) }
}

enum Ops {
    static let env = ProcessInfo.processInfo.environment
    static let socketPath = env["AXOLOTTY_SOCKET"] ?? RuntimePaths.standard().hostSocket.path(percentEncoded: false)

    static func connect(subscribe: Bool = false) async throws(OpError) -> (HostConnection, HostState) {
        let c = HostConnection(endpoint: .unix(path: socketPath),
                               hello: ClientHello(client: ClientID(), name: "cli", platform: .cli, subscribe: subscribe))
        do { try await c.connect(reconnect: false) } catch {
            throw OpError(message: "host unreachable at \(socketPath)", exit: .unreachable)
        }
        guard let st = c.replica else { throw .failed("no state") }
        return (c, st)
    }

    /// A pane id or unique prefix (≥ 4); nil means this pane ($AXOLOTTY_PANE_ID).
    static func resolvePane(_ given: String?, in state: HostState) throws(OpError) -> PaneID {
        guard let raw = given ?? env["AXOLOTTY_PANE_ID"], !raw.isEmpty else {
            throw .usage("no pane: pass a pane id or run inside an Axolotty pane")
        }
        if let id = PaneID(raw), state.panes[id] != nil { return id }
        let needle = raw.lowercased()
        guard needle.count >= 4 else { throw .usage("pane prefix must be at least 4 characters") }
        let hits = state.panes.keys.filter { $0.raw.uuidString.lowercased().hasPrefix(needle) }
        if hits.count == 1 { return hits[0] }
        throw .notFound(hits.isEmpty ? "no pane \(raw)" : "pane prefix \(raw) is ambiguous")
    }

    static func short(_ p: PaneID) -> String { String(p.raw.uuidString.lowercased().prefix(8)) }

    // MARK: Sessions and panes

    static func newSession(cwd: String?, name: String?, workspace: String?, command: [String],
                           worktree: String? = nil) async throws(OpError) -> PaneID {
        let (c, st) = try await connect()
        let dir = cwd.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path(percentEncoded: false) }
            ?? FileManager.default.currentDirectoryPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw .notFound("no directory \(dir)")
        }
        let wsName = workspace ?? URL(filePath: dir).lastPathComponent
        let ws = st.workspaces.first { $0.name == wsName || $0.id.raw.uuidString.lowercased().hasPrefix(wsName.lowercased()) }
            ?? st.workspaces.first { $0.root == dir }
        let wid = ws?.id ?? WorkspaceID()
        do {
            if ws == nil { try await c.perform(.createWorkspace(wid, name: wsName, root: dir)) }
            let pane = PaneID()
            try await c.perform(.createSession(SessionID(), workspace: wid, pane: pane,
                                               recipe: SpawnRecipe(command: command.isEmpty ? nil : command, cwd: dir,
                                                                   worktree: worktree),
                                               name: name ?? worktree))
            return pane
        } catch ConnectionError.intent(.worktreeFailed) {
            throw .failed("could not make a worktree for \(worktree ?? "") in \(dir): not a repository, a bad name, or the branch is checked out elsewhere")
        } catch { throw .failed("\(error)") }
    }

    static func split(pane: String?, down: Bool, before: Bool, command: [String]) async throws(OpError) -> PaneID {
        let (c, st) = try await connect()
        let target = try resolvePane(pane, in: st)
        guard let sid = st.panes[target]?.session else { throw .notFound("pane has no session") }
        let new = PaneID()
        do {
            try await c.perform(.split(sid, target: target, new: new, axis: down ? .vertical : .horizontal, before: before,
                                       recipe: SpawnRecipe(command: command.isEmpty ? nil : command)))
        } catch { throw .failed("\(error)") }
        return new
    }

    static func close(pane: String?) async throws(OpError) {
        let (c, st) = try await connect()
        do { try await c.perform(.closePane(try resolvePane(pane, in: st))) } catch let e as OpError { throw e } catch {
            throw .failed("\(error)")
        }
    }

    // MARK: Input

    /// Types `text` (`paste`: bracketed, then Enter on its own ≥ 200 ms later
    /// unless `enter` is false), then presses `keys`. Refuses a pane whose
    /// agent waits for its person: typing could answer its question.
    static func send(pane: String?, text: String, paste: Bool, enter: Bool, keys: [KeyInput], force: Bool) async throws(OpError) {
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        if let info = st.panes[p], info.activity == .blocked, !force {
            throw .failed("pane is waiting for its person (\(info.status.headline?.ask ?? "needs input")); force to send anyway")
        }
        if paste {
            // Ink-based TUIs read an Enter that arrives with the paste as part of
            // it: Enter goes on its own, after the paste has landed.
            c.send(.paste(p, text))
            await c.ping()
            if enter {
                try? await Task.sleep(for: .milliseconds(250))
                c.send(.key(p, NamedKeys.parse("enter")!))
            }
        } else if !text.isEmpty {
            c.send(.text(p, text))
        }
        for k in keys {
            c.send(.key(p, k))
            var up = k
            up.action = .release
            c.send(.key(p, up))
        }
        await c.ping()
    }

    static func keys(_ list: String?) throws(OpError) -> [KeyInput] {
        guard let list, !list.isEmpty else { return [] }
        switch NamedKeys.parseList(list) {
        case let .success(k): return k
        case let .failure(bad): throw .usage("unknown key \(bad.chord)")
        }
    }

    // MARK: Output

    static func capture(pane: String?, format: CaptureFormat, scrollback: Bool) async throws(OpError) -> String {
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        guard let text = await c.capture(p, format: format, scrollback: scrollback) else { throw .failed("capture failed") }
        return text
    }

    /// The pane's finished shell commands this host saw, oldest first.
    static func commands(pane: String?) async throws(OpError) -> [CommandRecord] {
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        guard let json = await c.capture(p, format: .commands, scrollback: false),
              let list = try? JSONDecoder().decode([CommandRecord].self, from: Data(json.utf8))
        else { throw .failed("the host did not answer (restart axolottyd after an update)") }
        return list
    }

    static func describe(_ r: CommandRecord) -> String {
        let code = r.exitCode.map(String.init) ?? "?"
        return "exit \(code) · \(String(format: "%.1f", r.duration))s · \(r.command)"
    }

    // MARK: Events

    /// What changed, one line each, until the host goes away: activity
    /// changes, finished commands, notifications and bells. `pane` narrows
    /// to one pane.
    static func events(pane: String?, emit: @Sendable (Event) -> Void) async throws(OpError) {
        let (c, st) = try await connect(subscribe: true)
        let only = try pane.map { p throws(OpError) in try resolvePane(p, in: st) }
        var last = st.panes
        for await e in c.events {
            switch e {
            case let .deltas(ds):
                for d in ds {
                    switch d {
                    case let .pane(info):
                        guard only == nil || only == info.id else { continue }
                        let before = last[info.id]
                        last[info.id] = info
                        if before?.activity != info.activity {
                            emit(Event(kind: "activity", pane: info.id, activity: info.activity.rawValue,
                                       message: info.status.headline.map { $0.state == .blocked ? $0.ask : $0.message }))
                        }
                        if let r = info.lastCommand, r != before?.lastCommand {
                            emit(Event(kind: "command", pane: info.id, command: r))
                        }
                        if info.exitStatus != nil, before?.exitStatus == nil {
                            emit(Event(kind: "exit", pane: info.id, exitCode: info.exitStatus))
                        }
                    case let .paneRemoved(id):
                        guard only == nil || only == id else { continue }
                        last[id] = nil
                        emit(Event(kind: "closed", pane: id))
                    default:
                        continue
                    }
                }
            case let .event(.notification(id, title, body)):
                guard only == nil || only == id else { continue }
                emit(Event(kind: "notification", pane: id, message: [title, body].filter { !$0.isEmpty }.joined(separator: ": ")))
            case let .event(.bell(id)):
                guard only == nil || only == id else { continue }
                emit(Event(kind: "bell", pane: id))
            case .disconnected:
                throw OpError(message: "host went away", exit: .unreachable)
            default:
                continue
            }
        }
    }

    struct Event: Encodable, Sendable {
        var kind: String
        var pane: String
        var activity: String?
        var message: String?
        var command: CommandRecord?
        var exitCode: Int32?
        var at = Date().timeIntervalSince1970

        init(kind: String, pane: PaneID, activity: String? = nil, message: String? = nil,
             command: CommandRecord? = nil, exitCode: Int32? = nil) {
            self.kind = kind
            self.pane = pane.raw.uuidString.lowercased()
            self.activity = activity
            self.message = message
            self.command = command
            self.exitCode = exitCode
        }

        var line: String {
            let head = "\(pane.prefix(8))  \(kind)"
            switch kind {
            case "activity": return head + "  \(activity ?? "")" + (message.map { "  \($0)" } ?? "")
            case "command": return head + "  " + (command.map(Ops.describe) ?? "")
            case "exit": return head + "  \(exitCode.map(String.init) ?? "?")"
            default: return head + (message.map { "  \($0)" } ?? "")
            }
        }
    }

    // MARK: Status

    static func report(pane: String?, state word: String, id: String, app: String, message: String) async throws(OpError) {
        let state: StatusRecord.State?
        if word == "clear" {
            state = nil
        } else {
            guard let s = StatusRecord.State(rawValue: word) else { throw .usage("unknown state \(word)") }
            state = s
        }
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        c.send(.report(p, id: id, state: state, app: app, message: message))
        await c.ping()
    }

    static func notify(pane: String?, title: String, body: String) async throws(OpError) {
        let (c, _) = try await connect()
        c.send(.notify((pane ?? env["AXOLOTTY_PANE_ID"]).flatMap { PaneID($0) }, title: title, body: body))
        await c.ping()
    }

    static func markSeen(pane: String?) async throws(OpError) {
        let (c, st) = try await connect()
        c.send(.seen(try resolvePane(pane, in: st)))
        await c.ping()
    }

    // MARK: Waiting

    static let waitGoals = ["done", "idle", "blocked", "error", "working", "exit", "command"]

    /// Waits until the pane reaches `goal` (an activity, `exit`, or
    /// `command`: the next shell command to finish, returned). Throws a
    /// timeout after `timeout` seconds (0 waits forever).
    static func wait(pane: String?, goal: String, timeout: Double) async throws(OpError) -> PaneInfo? {
        try await wait(panes: [pane], all: false, goal: goal, timeout: timeout).first?.1
    }

    /// Waits on several panes: until any of them reaches `goal` (or, with
    /// `all`, every one has). Returns the panes that have, in the order given.
    /// An agent that started others waits on them this way.
    static func wait(panes: [String?], all: Bool, goal: String, timeout: Double) async throws(OpError)
        -> [(PaneID, PaneInfo?)]
    {
        guard waitGoals.contains(goal) else { throw .usage("unknown wait goal \(goal)") }
        let (c, st) = try await connect(subscribe: true)
        var ids: [PaneID] = []
        for pane in panes {
            let p = try resolvePane(pane, in: st)
            if !ids.contains(p) { ids.append(p) }
        }
        let watched = ids
        let lastEnded = Dictionary(uniqueKeysWithValues: watched.map { ($0, st.panes[$0]?.lastCommand?.endedAt ?? 0) })
        @Sendable func done(_ p: PaneID, _ s: HostState) -> Bool {
            guard let info = s.panes[p] else { return goal == "exit" || goal == "command" }
            switch goal {
            case "exit": return info.exitStatus != nil
            case "command": return (info.lastCommand?.endedAt ?? 0) > (lastEnded[p] ?? 0)
            default: return info.activity.rawValue == goal
            }
        }
        @Sendable func reached(_ s: HostState) -> Bool {
            all ? watched.allSatisfy { done($0, s) } : watched.contains { done($0, s) }
        }
        func result(_ s: HostState) -> [(PaneID, PaneInfo?)] { watched.filter { done($0, s) }.map { ($0, s.panes[$0]) } }
        if reached(st) { return result(st) }
        enum Outcome: Sendable { case reached, gone, timedOut }
        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await e in c.events {
                    if case .deltas = e, let s = c.replica, reached(s) { return .reached }
                    if case .disconnected = e { return .gone }
                }
                return .gone
            }
            if timeout > 0 {
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    return .timedOut
                }
            }
            let first = await group.next() ?? .gone
            group.cancelAll()
            return first
        }
        switch outcome {
        case .reached: return c.replica.map(result) ?? []
        case .timedOut: throw OpError(message: "timed out waiting for \(goal)", exit: .timeout)
        case .gone: throw OpError(message: "host went away", exit: .unreachable)
        }
    }

    /// Every pane's listening ports, or one pane's.
    static func ports(pane: String?) async throws(OpError) -> [PaneInfo] {
        let (_, st) = try await connect()
        if let pane { return [st.panes[try resolvePane(pane, in: st)]].compactMap { $0 } }
        return st.panes.values.filter { $0.ports != nil }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }
}
