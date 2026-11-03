/// One terminal pane as every client sees it.
public struct PaneInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: PaneID
    public var session: SessionID
    /// Title set by the program (OSC 0/2), already stripped of control characters.
    public var title: String
    /// Working directory from OSC 7, or the foreground process's cwd.
    public var pwd: String
    /// Basename of the foreground process (e.g. "zsh", "claude", "nvim").
    public var program: String
    public var agent: AgentKind?
    public var status: StatusBook
    /// Last OSC 9;4 progress percentage, if any; -1 while indeterminate.
    public var progress: Int?
    /// The program is reading a hidden line (a password): clients turn on
    /// Secure Keyboard Entry while the pane has focus. nil means no.
    public var readsSecret: Bool?
    /// The shell's last finished command (OSC 133 C…D), for the long-command
    /// notice and `axolotty wait --for command`.
    public var lastCommand: CommandRecord?
    /// Grid size of the authoritative terminal.
    public var cols: UInt16
    public var rows: UInt16
    /// What the pane was started with (nil: the login shell), for restart.
    public var launch: [String]?
    /// Exit status once the child is gone; the pane stays until closed.
    public var exitStatus: Int32?
    /// Unix seconds when the current activity began (for "working 2m").
    public var activitySince: Double

    public init(id: PaneID, session: SessionID, cols: UInt16 = 80, rows: UInt16 = 24) {
        self.id = id
        self.session = session
        title = ""
        pwd = ""
        program = ""
        status = StatusBook()
        self.cols = cols
        self.rows = rows
        activitySince = 0
    }

    public var activity: Activity {
        if let code = exitStatus, code != 0, status.isEmpty { return .error }
        return status.activity
    }

    /// A short label: the agent or program, then the title.
    public var displayTitle: String {
        if let headline = status.headline, !headline.title.isEmpty { return headline.title }
        if !title.isEmpty { return title }
        if let agent { return agent.displayName }
        return program.isEmpty ? "shell" : program
    }
}

/// One finished shell command, as the shell integration reported it.
public struct CommandRecord: Hashable, Codable, Sendable {
    public var command: String
    /// nil when the shell did not say.
    public var exitCode: Int32?
    public var duration: Double
    /// Unix seconds.
    public var endedAt: Double

    public init(command: String, exitCode: Int32?, duration: Double, endedAt: Double) {
        self.command = command
        self.exitCode = exitCode
        self.duration = duration
        self.endedAt = endedAt
    }
}

/// A sidebar row: one split tree of panes.
public struct SessionInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: SessionID
    public var workspace: WorkspaceID
    /// Name the person gave; nil means "derive from the focused pane".
    public var name: String?
    public var tree: SplitTree
    /// The pane last focused by any client; new clients start here.
    public var focus: PaneID
    public var zoomed: PaneID?
    /// The git worktree this session was started in (its folder), for
    /// "Remove Worktree…". nil for ordinary sessions.
    public var worktree: String?

    public init(id: SessionID, workspace: WorkspaceID, root: PaneID, name: String? = nil) {
        self.id = id
        self.workspace = workspace
        self.name = name
        tree = .leaf(root)
        focus = root
    }
}

/// A project: a directory and its sessions, in sidebar order.
public struct WorkspaceInfo: Hashable, Codable, Sendable, Identifiable {
    public var id: WorkspaceID
    public var name: String
    public var root: String
    public var sessions: [SessionID]

    public init(id: WorkspaceID, name: String, root: String, sessions: [SessionID] = []) {
        self.id = id
        self.name = name
        self.root = root
        self.sessions = sessions
    }
}

/// The complete shareable state of one host. The host owns it; clients hold a
/// replica that they update only from host deltas.
public struct HostState: Hashable, Codable, Sendable {
    public var host: HostID
    public var name: String
    public var workspaces: [WorkspaceInfo] = []
    public var sessions: [SessionID: SessionInfo] = [:]
    public var panes: [PaneID: PaneInfo] = [:]
    /// Increases with every applied delta.
    public var revision: UInt64 = 0

    public init(host: HostID, name: String) {
        self.host = host
        self.name = name
    }

    public func workspace(_ id: WorkspaceID) -> WorkspaceInfo? { workspaces.first { $0.id == id } }

    public func panes(of session: SessionID) -> [PaneInfo] {
        sessions[session]?.tree.panes.compactMap { panes[$0] } ?? []
    }

    /// Most urgent activity across a session's panes.
    public func activity(of session: SessionID) -> Activity {
        panes(of: session).map(\.activity).max() ?? .idle
    }

    /// What a waiting session waits for, when its program says (the first
    /// blocked pane's `kind=`).
    public func need(of session: SessionID) -> StatusRecord.Need? {
        panes(of: session).lazy.compactMap(\.status.headline).first(where: { $0.state == .blocked })?.need
    }

    /// A session's known progress, 0…1: OSC 9;4 first, else the agent's own
    /// OSC 7501 `progress=`. Indeterminate (-1) is no number.
    public func progress(of session: SessionID) -> Double? {
        let panes = panes(of: session)
        return (panes.compactMap(\.progress).first(where: { $0 >= 0 })
            ?? panes.compactMap { $0.status.headline?.progress }.first).map { Double($0) / 100 }
    }

    public func activity(ofWorkspace id: WorkspaceID) -> Activity {
        workspace(id)?.sessions.map { activity(of: $0) }.max() ?? .idle
    }

    public func sessionTitle(_ id: SessionID) -> String {
        guard let s = sessions[id] else { return "" }
        if let n = s.name, !n.isEmpty { return n }
        return panes[s.focus]?.displayTitle ?? "session"
    }

    /// The pane whose program reopening a closed session brings back: the
    /// focused pane when Claude Code is in front of it, else the first such
    /// pane in tree order. The app takes its folder; the server reads its
    /// conversation, so both pick the same pane.
    public func claudePane(of session: SessionID) -> PaneID? {
        guard let s = sessions[session] else { return nil }
        if panes[s.focus]?.agent == .claude { return s.focus }
        return s.tree.panes.first { panes[$0]?.agent == .claude }
    }

    /// Sessions in sidebar order across all workspaces.
    public var orderedSessions: [SessionID] { workspaces.flatMap(\.sessions) }

    /// Counts for the status bar roll-up and the Dock badge.
    public var attention: (blocked: Int, error: Int, working: Int, done: Int) {
        var r = (blocked: 0, error: 0, working: 0, done: 0)
        for p in panes.values {
            switch p.activity {
            case .blocked: r.blocked += 1
            case .error: r.error += 1
            case .working: r.working += 1
            case .done: r.done += 1
            case .idle: break
            }
        }
        return r
    }

    // MARK: Deltas

    /// An idempotent change. Applying the same delta twice is harmless, which
    /// makes resync after reconnect trivial.
    public enum Delta: Hashable, Codable, Sendable {
        case workspace(WorkspaceInfo)
        case workspaceRemoved(WorkspaceID)
        case session(SessionInfo)
        case sessionRemoved(SessionID)
        case pane(PaneInfo)
        case paneRemoved(PaneID)
    }

    public mutating func apply(_ delta: Delta) {
        switch delta {
        case let .workspace(w):
            if let i = workspaces.firstIndex(where: { $0.id == w.id }) { workspaces[i] = w } else { workspaces.append(w) }
        case let .workspaceRemoved(id):
            workspaces.removeAll { $0.id == id }
        case let .session(s):
            sessions[s.id] = s
        case let .sessionRemoved(id):
            sessions[id] = nil
        case let .pane(p):
            panes[p.id] = p
        case let .paneRemoved(id):
            panes[id] = nil
        }
        revision &+= 1
    }

    public mutating func apply(_ deltas: some Sequence<Delta>) { for d in deltas { apply(d) } }

    /// Problems that should never exist; tests and debug builds check these.
    public var invariantViolations: [String] {
        var out: [String] = []
        var seenSessions = Set<SessionID>()
        for w in workspaces {
            for s in w.sessions {
                if !seenSessions.insert(s).inserted { out.append("session \(s) listed twice") }
                guard let info = sessions[s] else {
                    out.append("workspace \(w.id) lists missing session \(s)")
                    continue
                }
                if info.workspace != w.id { out.append("session \(s) points at \(info.workspace), listed in \(w.id)") }
            }
        }
        for (id, s) in sessions {
            if !seenSessions.contains(id) { out.append("session \(id) not in any workspace") }
            if !s.tree.contains(s.focus) { out.append("session \(id) focus \(s.focus) not in tree") }
            if let z = s.zoomed, !s.tree.contains(z) { out.append("session \(id) zoom not in tree") }
            for p in s.tree.panes {
                guard let pane = panes[p] else {
                    out.append("session \(id) has missing pane \(p)")
                    continue
                }
                if pane.session != id { out.append("pane \(p) belongs to \(pane.session), found in \(id)") }
            }
        }
        let inTrees = Set(sessions.values.flatMap(\.tree.panes))
        for p in panes.keys where !inTrees.contains(p) { out.append("pane \(p) not in any tree") }
        return out
    }
}
