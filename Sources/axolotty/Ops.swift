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
                               hello: ClientHello(client: ClientID(), name: "cli", subscribe: subscribe))
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

    /// A session in `cwd` (default: here), in the workspace rooted there
    /// (made, named after the folder, when there is none).
    static func newSession(cwd: String?, name: String?, command: [String], worktree: String? = nil) async throws(OpError)
        -> PaneID
    {
        let (c, st) = try await connect()
        let dir = cwd.map { URL(filePath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path(percentEncoded: false) }
            ?? FileManager.default.currentDirectoryPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw .notFound("no directory \(dir)")
        }
        let ws = st.workspaces.first { $0.root == dir }
        let wid = ws?.id ?? WorkspaceID()
        do {
            if ws == nil { try await c.perform(.createWorkspace(wid, name: URL(filePath: dir).lastPathComponent, root: dir)) }
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

    static func close(pane: String?) async throws(OpError) {
        let (c, st) = try await connect()
        do { try await c.perform(.closePane(try resolvePane(pane, in: st))) } catch let e as OpError { throw e } catch {
            throw .failed("\(error)")
        }
    }

    // MARK: Input

    /// Pastes `text` (bracketed, then Enter on its own ≥ 200 ms later unless
    /// `enter` is false), then presses `keys`. Refuses a pane whose agent
    /// waits for its person: typing could answer its question.
    static func send(pane: String?, text: String, enter: Bool, keys: [KeyInput], force: Bool) async throws(OpError) {
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        if let info = st.panes[p], info.activity == .blocked, !force {
            throw .failed("pane is waiting for its person (\(info.status.headline?.ask ?? "needs input")); force to send anyway")
        }
        if !text.isEmpty {
            // Ink-based TUIs read an Enter that arrives with the paste as part of
            // it: Enter goes on its own, after the paste has landed.
            c.send(.paste(p, text))
            await c.ping()
            if enter {
                try? await Task.sleep(for: .milliseconds(250))
                c.send(.key(p, NamedKeys.parse("enter")!))
            }
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

    static func capture(pane: String?, scrollback: Bool) async throws(OpError) -> String {
        let (c, st) = try await connect()
        let p = try resolvePane(pane, in: st)
        guard let text = await c.capture(p, scrollback: scrollback) else { throw .failed("capture failed") }
        return text
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
}
