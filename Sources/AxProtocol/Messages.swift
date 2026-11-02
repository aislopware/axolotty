public import AxModel
public import Foundation

// MARK: - Input events (client → host). The host encodes them with libghostty's
// encoders against its own terminal's modes, so the client never needs to know
// whether the program enabled the Kitty keyboard protocol or mouse tracking.

public struct KeyInput: Codable, Hashable, Sendable {
    public enum Action: UInt8, Codable, Sendable { case release = 0, press = 1, `repeat` = 2 }
    public var action: Action
    /// A `GhosttyKey` value (W3C physical key).
    public var key: UInt16
    /// `GHOSTTY_MODS_*` bits.
    public var mods: UInt16
    public var consumedMods: UInt16
    /// Text the layout produced (without Control applied), UTF-8.
    public var text: String
    /// The key's codepoint with no modifiers (for the Kitty protocol).
    public var unshifted: UInt32
    public var composing: Bool

    public init(action: Action = .press, key: UInt16, mods: UInt16 = 0, consumedMods: UInt16 = 0, text: String = "",
                unshifted: UInt32 = 0, composing: Bool = false)
    {
        self.action = action
        self.key = key
        self.mods = mods
        self.consumedMods = consumedMods
        self.text = text
        self.unshifted = unshifted
        self.composing = composing
    }

    public static let shift: UInt16 = 1 << 0
    public static let ctrl: UInt16 = 1 << 1
    public static let alt: UInt16 = 1 << 2
    public static let `super`: UInt16 = 1 << 3
}

public struct MouseInput: Codable, Hashable, Sendable {
    public enum Action: UInt8, Codable, Sendable { case press = 0, release = 1, motion = 2 }
    public var action: Action
    /// `GhosttyMouseButton` (0 none, 1 left, 2 right, 3 middle, 4/5 wheel up/down …).
    public var button: UInt8
    public var mods: UInt16
    /// Position in fractional cells (col 0.5 = middle of the first column), top-left
    /// origin. Cells, not pixels: every client has its own cell size, so the host
    /// scales by the size-driving client's cell metrics.
    public var x: Double
    public var y: Double

    public init(action: Action, button: UInt8, mods: UInt16 = 0, x: Double, y: Double) {
        self.action = action
        self.button = button
        self.mods = mods
        self.x = x
        self.y = y
    }
}

// MARK: - Intents (client → host): edits of the shared document.

public struct SpawnRecipe: Codable, Hashable, Sendable {
    /// nil: the person's login shell.
    public var command: [String]?
    public var cwd: String?
    public var env: [String: String]
    /// Start in a git worktree for this branch of `cwd`'s repository (made,
    /// or reused, under the repository's `.worktrees/`). Sessions only.
    public var worktree: String?

    public init(command: [String]? = nil, cwd: String? = nil, env: [String: String] = [:], worktree: String? = nil) {
        self.command = command
        self.cwd = cwd
        self.env = env
        self.worktree = worktree
    }
}

/// Every edit names its targets by id and sets values (never toggles), so a
/// retried intent is harmless and conflicts resolve last-writer-wins.
public enum Intent: Codable, Hashable, Sendable {
    case createWorkspace(WorkspaceID, name: String, root: String)
    case closeWorkspace(WorkspaceID)
    case createSession(SessionID, workspace: WorkspaceID, pane: PaneID, recipe: SpawnRecipe, name: String?)
    case renameSession(SessionID, name: String?)
    case moveSession(SessionID, workspace: WorkspaceID, index: Int)
    case closeSession(SessionID)
    /// Closes a worktree session and removes its folder (the branch stays).
    /// Without `force`, a worktree with changes is refused (`.dirty`).
    case removeWorktree(SessionID, force: Bool)
    case split(SessionID, target: PaneID, new: PaneID, axis: SplitTree.Axis, before: Bool, recipe: SpawnRecipe)
    case closePane(PaneID)
    /// An ended pane's slot gets `new`, started from the same command in the
    /// same directory (the old pane goes).
    case restartPane(PaneID, new: PaneID)
    case focusPane(SessionID, PaneID)
    case setZoom(SessionID, PaneID?)
    case setTree(SessionID, SplitTree)
}

public enum IntentError: String, Codable, Sendable, Error {
    case targetGone, invalid, spawnFailed, notAllowed
    /// git could not make the worktree (not a repository, bad name, branch in use).
    case worktreeFailed
    /// The worktree has uncommitted changes.
    case dirty
}

// MARK: - Messages

public struct ClientHello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var client: ClientID
    public var name: String
    /// When true, the host also sends state and attention events (apps); the CLI
    /// sends false and gets only replies.
    public var subscribe: Bool

    public init(client: ClientID, name: String, subscribe: Bool = true) {
        protocolVersion = Wire.version
        self.client = client
        self.name = name
        self.subscribe = subscribe
    }
}

public struct Appearance: Codable, Hashable, Sendable {
    public var foreground: RGB
    public var background: RGB
    public var cursor: RGB
    public var palette: [RGB]
    public var dark: Bool

    public init(theme: TerminalTheme) {
        foreground = theme.foreground
        background = theme.background
        cursor = theme.cursor
        palette = theme.palette256
        dark = theme.isDark
    }
}

public enum ClientMessage: Codable, Sendable {
    case hello(ClientHello)
    case intent(UUID, Intent)
    /// Start mirroring a pane. `have` is the journal offset the client already
    /// applied (warm resume), nil for a fresh snapshot.
    case attach(PaneID, have: UInt64?)
    case detach(PaneID)
    /// This client's grid for the pane. Applied only if it drives the size.
    case viewport(PaneID, cols: UInt16, rows: UInt16, cellWidth: UInt16, cellHeight: UInt16)
    /// Make this client the size driver for the pane.
    case takeSize(PaneID)
    case appearance(Appearance)
    case key(PaneID, KeyInput)
    case mouse(PaneID, MouseInput)
    case paste(PaneID, String)
    /// Raw text typed as if from a keyboard (CLI `send`), no paste brackets.
    case text(PaneID, String)
    case focus(PaneID, Bool)
    case signal(PaneID, Int32)
    /// Erase the pane's scrollback and screen (⌘K).
    case clear(PaneID)
    case seen(PaneID)
    /// The pane's text, plain (CLI, agents).
    case capture(UUID, PaneID, scrollback: Bool)
    case ping(UInt64)
}

public enum HostEvent: Codable, Hashable, Sendable {
    case notification(PaneID, title: String, body: String)
    case bell(PaneID)
    /// The pane entered a state the person should hear about (blocked/done/error).
    case attention(PaneID, Activity, message: String)
    case clipboard(PaneID, String)
}

public struct HostHello: Codable, Hashable, Sendable {
    public var protocolVersion: Int
    public var host: HostID
    public var name: String
    /// Unique per server start; a new epoch means "drop your replica".
    public var epoch: UUID
    public var state: HostState

    public init(host: HostID, name: String, epoch: UUID, state: HostState) {
        protocolVersion = Wire.version
        self.host = host
        self.name = name
        self.epoch = epoch
        self.state = state
    }
}

public enum HostMessage: Codable, Sendable {
    case welcome(HostHello)
    case deltas([HostState.Delta], revision: UInt64)
    case intentResult(UUID, IntentError?)
    /// The pane's stream starts: a snapshot at `at` follows (unless resuming),
    /// then output from `at` (or from the client's `have`).
    case attached(PaneID, cols: UInt16, rows: UInt16, at: UInt64, resume: Bool)
    case detached(PaneID)
    /// The authoritative grid changed at journal offset `at`; mirrors resize there.
    case resized(PaneID, cols: UInt16, rows: UInt16, at: UInt64)
    case event(HostEvent)
    case captured(UUID, String?)
    case pong(UInt64)
    case error(String)
}

// MARK: - Codec

public enum MessageCodec {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    public static func frame(_ m: ClientMessage) throws -> Data { Wire.encode(.control(try encoder.encode(m))) }
    public static func frame(_ m: HostMessage) throws -> Data { Wire.encode(.control(try encoder.encode(m))) }

    public static func client(_ data: Data) throws -> ClientMessage { try JSONDecoder().decode(ClientMessage.self, from: data) }
    public static func host(_ data: Data) throws -> HostMessage { try JSONDecoder().decode(HostMessage.self, from: data) }
}
