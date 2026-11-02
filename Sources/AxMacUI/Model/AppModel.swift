import AppKit
import AxClient
import AxModel
import AxProtocol
import Foundation

/// App-wide state: preferences, the resolved theme, and every host this client
/// is connected to.
final class AppModel {
    static let shared = AppModel()

    let prefs = Preferences()
    let paths = RuntimePaths.standard()
    let clientID: ClientID
    private(set) var hosts: [HostSession] = []
    let hostsChanged = Signal<Void>()
    /// Any host's document or connection changed.
    let anyChange = Signal<(HostSession, HostChange)>()
    let themeChanged = Signal<Void>()
    let fontChanged = Signal<Void>()
    /// Shown as a toast in the key window.
    let errors = Signal<String>()
    /// Something the person asked for can't happen here, said plainly (a
    /// title and a detail), not as a failure.
    let notices = Signal<(String, String)>()
    private var tokens: [SignalToken] = []

    private(set) var systemDark = true
    private(set) var theme: TerminalTheme = .night

    /// Recently closed sessions (for ⌘⇧T): where they ran, what they were
    /// called, and the Claude Code conversation in them, if any (the host
    /// says which one just after the close).
    struct ClosedSession {
        var host: UUID
        var session: SessionID
        var workspace: WorkspaceID
        var cwd: String
        var name: String?
        var claude = false
        var conversation: String?
    }

    var closed: [ClosedSession] = []
    private var bootstrapped = Set<UUID>()

    /// True once per host per launch: the caller may create the first session.
    func bootstrap(_ host: HostSession) -> Bool { bootstrapped.insert(host.id).inserted }

    private init() {
        let defaults = UserDefaults.standard
        if let s = defaults.string(forKey: "clientID"), let id = ClientID(s) {
            clientID = id
        } else {
            clientID = ClientID()
            defaults.set(clientID.raw.uuidString, forKey: "clientID")
        }
    }

    var local: HostSession? { hosts.first { $0.isLocal } }

    func startLocal() {
        guard local == nil else { return }
        let paths = paths
        let host = HostSession(endpoint: .unix(path: paths.hostSocket.path(percentEncoded: false)), client: clientID,
                               clientName: Host.current().localizedName ?? "Mac", isLocal: true)
        add(host) { [weak self] in
            if let e = await ServerLauncher.ensureRunning(paths) { self?.errors.emit(e) }
        }
    }

    // MARK: Remote hosts

    /// A host this Mac connects to over the tailnet, kept across launches.
    struct SavedHost: Codable, Equatable {
        var name: String
        var host: String
        var port: UInt16 = TailnetDirectory.port
        var endpoint: HostEndpoint { .tcp(host: host, port: port) }
    }

    private(set) var saved: [SavedHost] {
        get {
            (UserDefaults.standard.data(forKey: "remoteHosts")).flatMap { try? JSONDecoder().decode([SavedHost].self, from: $0) } ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "remoteHosts") }
    }

    /// Connects every host kept from the last launch, in the background,
    /// and checks every remote link when the Mac wakes or changes network.
    func startRemotes() {
        for s in saved where host(at: s.endpoint) == nil { addRemote(s) }
        if nudge == nil {
            nudge = LinkNudge { [weak self] in
                for h in self?.hosts ?? [] where !h.isLocal { h.nudge() }
            }
        }
    }

    private var nudge: LinkNudge?

    func host(at endpoint: HostEndpoint) -> HostSession? { hosts.first { $0.endpoint == endpoint } }

    /// Connects to a host and keeps it; one already here is tried again now.
    @discardableResult
    func connect(to s: SavedHost) -> HostSession {
        if let h = host(at: s.endpoint) {
            h.retry()
            return h
        }
        saved = saved.filter { $0.endpoint != s.endpoint } + [s]
        return addRemote(s)
    }

    @discardableResult
    private func addRemote(_ s: SavedHost) -> HostSession {
        let h = HostSession(endpoint: s.endpoint, client: clientID, clientName: Host.current().localizedName ?? "Mac",
                            isLocal: false)
        h.label = s.name
        add(h)
        return h
    }

    /// Puts Axolotty on a far Mac over ssh (this build's server, holder and
    /// CLI, kept running by a LaunchAgent there), then connects. Run on a host
    /// that has it, it updates it in place; its shells keep running.
    func setUp(_ s: SavedHost) {
        let h = connect(to: s)
        guard h.settingUp == nil else { return }
        guard let from = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent(),
              HostSetup.binaries.allSatisfy({
                  FileManager.default.isExecutableFile(atPath: from.appending(path: $0).path(percentEncoded: false))
              })
        else {
            errors.emit("This build of Axolotty has no server to copy.")
            return
        }
        h.settingUp = .checking
        Task { @MainActor [weak self] in
            do {
                try await HostSetup(ssh: s.host, from: from).install { step in
                    Task { @MainActor in if h.settingUp != nil { h.settingUp = step } }
                }
                // The server takes a moment to listen on the tailnet.
                for _ in 0 ..< 40 {
                    if await TailnetDirectory.probe(s.host, port: s.port, timeout: 1) != nil { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                h.settingUp = nil
                h.retry()
            } catch let f as HostSetup.Failure {
                h.settingUp = nil
                switch f {
                case .signIn:
                    self?.notices.emit(("\(s.name) wants you to sign in", "Run ssh \(s.host) in a session once, then set it up again. A key or Tailscale SSH lets Axolotty in without asking."))
                case let .unsupported(why):
                    self?.notices.emit(("Axolotty can't run on \(s.name)", why))
                case let .failed(why):
                    self?.errors.emit("Couldn't set up \(s.name): \(why)")
                }
            } catch {
                h.settingUp = nil
                self?.errors.emit("Couldn't set up \(s.name): \(error.localizedDescription)")
            }
        }
    }

    /// Disconnects and forgets a remote host. Its sessions keep running there.
    func forget(_ h: HostSession) {
        guard !h.isLocal else { return }
        h.stop()
        hosts.removeAll { $0 === h }
        saved = saved.filter { $0.endpoint != h.endpoint }
        hostsChanged.emit()
    }

    func add(_ host: HostSession, prepare: (@MainActor () async -> Void)? = nil) {
        hosts.append(host)
        host.onError = { [weak self] in self?.errors.emit($0) }
        tokens.append(host.changes.observe { [weak self, weak host] change in
            guard let self, let host else { return }
            if case .connected = change { host.connection.setAppearance(Appearance(theme: theme)) }
            if case let .event(.claudeConversation(sid, id)) = change, UUID(uuidString: id) != nil,
               let i = closed.lastIndex(where: { $0.host == host.id && $0.session == sid }) {
                closed[i].conversation = id
            }
            anyChange.emit((host, change))
        })
        host.start(prepare: prepare)
        hostsChanged.emit()
    }

    func host(_ id: UUID) -> HostSession? { hosts.first { $0.id == id } }

    // MARK: Appearance

    func updateSystemAppearance(dark: Bool) {
        systemDark = dark
        applyTheme()
    }

    func applyTheme() {
        let t = prefs.theme(systemDark: systemDark)
        guard t != theme else { return }
        theme = t
        for h in hosts { h.connection.setAppearance(Appearance(theme: t)) }
        themeChanged.emit()
    }

    func setFontSize(_ size: CGFloat) {
        let s = min(max(size.rounded(), Axo.Font.terminalRange.lowerBound), Axo.Font.terminalRange.upperBound)
        guard s != prefs.fontSize else { return }
        prefs.fontSize = s
        fontChanged.emit()
    }

    // MARK: Attention

    /// Every pane in a state the person should look at, most urgent first.
    func attentionPanes() -> [(HostSession, PaneInfo)] {
        var out: [(HostSession, PaneInfo)] = []
        for h in hosts {
            guard let s = h.state else { continue }
            for sid in s.orderedSessions {
                for p in s.panes(of: sid) where p.activity == .blocked || p.activity == .error || p.activity == .done {
                    out.append((h, p))
                }
            }
        }
        return out.sorted { $0.1.activity > $1.1.activity }
    }

    /// Every session in sidebar (document) order across hosts.
    var sidebarOrder: [(HostSession, SessionID)] {
        hosts.flatMap { h in (h.state?.orderedSessions ?? []).map { (h, $0) } }
    }

    /// Panes that want the person: waiting for input, or failed and unseen.
    var waitingCount: Int {
        hosts.reduce(0) { n, h in n + (h.state.map { $0.attention.blocked + $0.attention.error } ?? 0) }
    }
}
