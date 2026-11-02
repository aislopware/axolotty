/// What a pane is doing, from the person's point of view. Ordered by urgency.
public enum Activity: String, Codable, Sendable, CaseIterable, Comparable {
    /// Nothing running, or a plain shell at its prompt.
    case idle
    /// Finished; stays until a client focuses the pane.
    case done
    /// Actively working.
    case working
    /// Failed; stays until seen.
    case error
    /// Waiting on the person: permission, question, auth.
    case blocked

    public var rank: Int {
        switch self {
        case .idle: 0
        case .done: 1
        case .working: 2
        case .error: 3
        case .blocked: 4
        }
    }

    public static func < (a: Activity, b: Activity) -> Bool { a.rank < b.rank }
}

/// One OSC 7501 program-status record.
public struct StatusRecord: Hashable, Codable, Sendable {
    public enum State: String, Codable, Sendable { case idle, working, done, blocked, error }
    /// What a blocked program waits for, when it says (OSC 7501 `kind=`).
    public enum Need: String, Codable, Sendable {
        case permission, question, auth

        public var words: String {
            switch self {
            case .permission: "Needs approval"
            case .question: "Has a question"
            case .auth: "Needs sign-in"
            }
        }
    }

    public var id: String
    public var state: State
    public var app: String
    public var title: String
    public var message: String
    public var need: Need?
    /// How far along (0…100), when the program says (OSC 7501 `progress=`).
    public var progress: Int?
    /// Monotonic order of the last update; used for LRU eviction.
    public var stamp: UInt64

    public init(id: String, state: State, app: String = "", title: String = "", message: String = "",
                need: Need? = nil, progress: Int? = nil, stamp: UInt64 = 0)
    {
        self.progress = progress
        self.id = id
        self.state = state
        self.app = app
        self.title = title
        self.message = message
        self.need = need
        self.stamp = stamp
    }

    /// What a waiting program asks, as the person reads it: its own words
    /// (first letter raised: "approve Bash: …" → "Approve Bash: …"), else what
    /// it waits for, else "Needs input".
    public var ask: String {
        let m = message.drop(while: \.isWhitespace)
        if let first = m.first { return first.uppercased() + m.dropFirst() }
        return need?.words ?? "Needs input"
    }
}

/// The per-pane store of program status records, following the OSC 7501 rules
/// (spec 0.4): a report replaces its record; `clear` removes the record and every
/// record beneath it (`build` also removes `build/test`); an empty id is the
/// program itself; a record with no app inherits the nearest ancestor's;
/// `working`/`blocked` end when a new prompt starts or the program exits;
/// `done`/`error` last until seen; at most `capacity` records, LRU eviction.
public struct StatusBook: Hashable, Codable, Sendable {
    public private(set) var records: [String: StatusRecord] = [:]
    public var capacity = 256
    private var clock: UInt64 = 0

    public init() {}

    public var isEmpty: Bool { records.isEmpty }

    public mutating func report(id: String, state: StatusRecord.State?, app: String = "", title: String = "",
                                message: String = "", need: StatusRecord.Need? = nil, progress: Int? = nil)
    {
        guard let state else {
            clear(id)
            return
        }
        clock += 1
        records[id] = StatusRecord(id: id, state: state, app: app, title: title, message: message,
                                   need: state == .blocked ? need : nil,
                                   progress: state == .working || state == .blocked ? progress.map { min(max($0, 0), 100) } : nil,
                                   stamp: clock)
        while records.count > capacity, let oldest = records.values.min(by: { $0.stamp < $1.stamp }) {
            records[oldest.id] = nil
        }
    }

    /// Removes `id` and its descendants; an empty id removes everything.
    public mutating func clear(_ id: String) {
        guard !id.isEmpty else {
            records.removeAll()
            return
        }
        let prefix = id + "/"
        records = records.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
    }

    /// A new shell prompt started or the program exited.
    public mutating func programEnded() {
        records = records.filter { $0.value.state != .working && $0.value.state != .blocked }
    }

    /// The person looked at the pane: finished records have been seen.
    public mutating func markSeen() {
        records = records.filter { $0.value.state != .done && $0.value.state != .error }
    }

    /// App name with inheritance from the nearest ancestor that has one.
    public func app(of id: String) -> String {
        var cur = id
        while true {
            if let a = records[cur]?.app, !a.isEmpty { return a }
            if cur.isEmpty { return "" }
            if let slash = cur.lastIndex(of: "/") { cur = String(cur[..<slash]) } else { cur = "" }
        }
    }

    /// Records other than the program's own (id "") that are working: Claude
    /// Code reports each subagent it runs this way, one record per agent id,
    /// gone when that subagent finishes.
    public var subagentsWorking: Int {
        records.values.count { !$0.id.isEmpty && !$0.id.hasPrefix(Self.agentsPrefix) && $0.state == .working }
    }

    /// Ids of records the host makes from `claude agents` for panes Claude
    /// Code can't report to (inside tmux): `agents:<pid>`.
    public static let agentsPrefix = "agents:"

    /// Removes every `agents:` record.
    public mutating func clearAgents() {
        records = records.filter { !$0.key.hasPrefix(Self.agentsPrefix) }
    }

    /// The most urgent record, newest first among equals.
    public var headline: StatusRecord? {
        records.values.max { (Self.activity($0.state), $0.stamp) < (Self.activity($1.state), $1.stamp) }
    }

    public var activity: Activity { headline.map { Self.activity($0.state) } ?? .idle }

    static func activity(_ s: StatusRecord.State) -> Activity {
        switch s {
        case .idle: .idle
        case .working: .working
        case .done: .done
        case .blocked: .blocked
        case .error: .error
        }
    }
}

/// Coding agents Axolotty recognises from the foreground process, for an icon and
/// a name when the agent does not report itself. Detection of *state* never comes
/// from here.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude, codex, gemini, opencode, amp, cursor, copilot, aider, goose, pi, qwen, crush, droid, kimi, kiro, auggie

    /// The agent an OSC 7501 `app=` names ("claude-code", "codex", "gemini-cli"…).
    public init?(statusApp app: String) {
        let a = app.lowercased()
        let aliases: [String: AgentKind] = ["claude-code": .claude, "gemini-cli": .gemini, "cursor-agent": .cursor,
                                            "github-copilot": .copilot, "copilot-cli": .copilot, "qwen-code": .qwen]
        guard let k = aliases[a] ?? AgentKind(rawValue: a) else { return nil }
        self = k
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "opencode"
        case .amp: "Amp"
        case .cursor: "Cursor Agent"
        case .copilot: "Copilot"
        case .aider: "Aider"
        case .goose: "Goose"
        case .pi: "Pi"
        case .qwen: "Qwen Code"
        case .crush: "Crush"
        case .droid: "Droid"
        case .kimi: "Kimi"
        case .kiro: "Kiro"
        case .auggie: "Auggie"
        }
    }

    /// The name where room is tight (a launch tile): the vendor's word alone.
    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .qwen: "Qwen"
        default: displayName
        }
    }

    /// Exact executable basenames per agent.
    static let names: [String: AgentKind] = [
        "claude": .claude, "codex": .codex, "gemini": .gemini, "opencode": .opencode, "amp": .amp,
        "cursor-agent": .cursor, "copilot": .copilot, "aider": .aider, "goose": .goose, "pi": .pi,
        "qwen": .qwen, "crush": .crush, "droid": .droid, "kimi": .kimi, "kiro-cli": .kiro, "auggie": .auggie,
    ]

    /// The command that starts this agent.
    public var executable: String { Self.names.first { $0.value == self }?.key ?? rawValue }

    static let launchers: Set<String> = ["node", "bun", "deno", "python", "python3", "uv", "uvx", "npx", "bunx", "pnpx"]

    /// Identifies an agent from a process name and (for script launchers such as
    /// node/python) its argv. Wrappers like `npx` are only a match through argv.
    public static func identify(processName: String, argv: [String] = []) -> AgentKind? {
        let base = processName.split(separator: "/").last.map(String.init) ?? processName
        if let k = names[base] { return k }
        guard launchers.contains(base) || base.hasPrefix("python") else { return nil }
        for arg in argv.dropFirst() where !arg.hasPrefix("-") {
            let leaf = arg.split(separator: "/").last.map(String.init) ?? arg
            let trimmed = leaf.hasSuffix(".mjs") ? String(leaf.dropLast(4)) : leaf.hasSuffix(".js") ? String(leaf.dropLast(3)) : leaf
            if let k = names[trimmed] { return k }
            // Package paths: .../@anthropic-ai/claude-code/cli.js, .../@openai/codex/bin/codex.js
            if arg.contains("claude-code") { return .claude }
            if arg.contains("@openai/codex") { return .codex }
            if arg.contains("@google/gemini-cli") { return .gemini }
            if arg.contains("opencode") { return .opencode }
            if arg.contains("@sourcegraph/amp") { return .amp }
        }
        return nil
    }
}
