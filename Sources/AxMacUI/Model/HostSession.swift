import AppKit
import AxClient
import AxModel
import AxProtocol
import Foundation

/// What changed on one host, in order.
enum HostChange {
    case connected
    case deltas([HostState.Delta])
    case event(HostEvent)
    case disconnected(String?)
    /// A new round-trip reading (remote hosts).
    case latency
    /// Setting Axolotty up there began, moved on a step, or ended.
    case setup
}

/// The app's link to one server: its document replica, connection phase and
/// intents. A client can hold many (local plus remote); a server can serve many.
final class HostSession: Identifiable {
    enum Phase: Equatable {
        case connecting
        case connected
        case offline(String?)
        /// Waits for the person: a login, an install, an update (see `LinkFailure`).
        case failed(LinkFailure)
    }

    let id = UUID()
    let endpoint: HostEndpoint
    let connection: HostConnection
    let isLocal: Bool
    private(set) var state: HostState?
    private(set) var phase: Phase = .connecting
    /// The last heartbeat's round trip (remote hosts).
    private(set) var rtt: Duration?
    /// The Tailscale relay region carrying the link, nil while the path is
    /// direct (or isn't a tailnet one). A relayed path is why a far Mac
    /// feels slow; Tailscale often finds a direct one a little later.
    private(set) var relay: String?
    /// The step of setting Axolotty up there over ssh (`AppModel.setUp`), nil when not.
    var settingUp: HostSetup.Step? {
        didSet { if settingUp != oldValue { changes.emit(.setup) } }
    }
    private var pathWatch: Task<Void, Never>?
    let changes = Signal<HostChange>()
    /// Reports failed intents (the app shows a toast).
    var onError: ((String) -> Void)?
    private var loop: Task<Void, Never>?
    /// Brings the server up (the local host); run again whenever the link drops.
    private var prepare: (@MainActor () async -> Void)?
    private var reviving = false

    init(endpoint: HostEndpoint, client: ClientID, clientName: String, isLocal: Bool) {
        self.endpoint = endpoint
        self.isLocal = isLocal
        connection = HostConnection(endpoint: endpoint,
                                    hello: ClientHello(client: client, name: clientName))
    }

    /// What the person called it when connecting (a tailnet machine's name),
    /// shown until the host says its own.
    var label: String?

    var name: String { state?.name ?? label ?? (isLocal ? "This Mac" : endpoint.description) }

    /// A far Mac this one can set up or update over ssh: dialled on the
    /// tailnet, and not newer than this build (an update must not go back).
    var setUpTarget: AppModel.SavedHost? {
        guard !isLocal, case let .tcp(dialled, port) = endpoint else { return nil }
        if case let .failed(.incompatible(generation)) = phase, generation > Wire.version { return nil }
        return AppModel.SavedHost(name: name, host: dialled, port: port)
    }

    /// This build has something the far Mac's server lacks: an update helps.
    var isBehind: Bool {
        if case let .failed(.incompatible(generation)) = phase { return generation < Wire.version }
        guard phase == .connected, !isLocal else { return false }
        return !Set(Wire.features).isSubset(of: connection.hostFeatures)
    }

    /// A far host, for its panes' links: nil for this Mac. ssh reaches a
    /// tailnet host by the name it was dialled as.
    var far: FarHost? {
        guard !isLocal else { return nil }
        let ssh: String? = if case let .tcp(dialled, _) = endpoint { dialled } else { nil }
        return FarHost(id: id, ssh: ssh, connection: connection)
    }

    /// Connects (after `prepare`, e.g. launching the local server) and keeps
    /// reconnecting with backoff until stopped.
    func start(prepare: (@MainActor () async -> Void)? = nil) {
        self.prepare = prepare
        loop = Task { [weak self] in
            guard let self else { return }
            let events = connection.events
            Task { [weak self] in
                await prepare?()
                await self?.connectLoop()
            }
            for await event in events { handle(event) }
        }
    }

    private func connectLoop() async {
        var delay = Duration.milliseconds(100)
        while !Task.isCancelled {
            do {
                try await connection.connect(reconnect: true)
                return
            } catch let ConnectionError.failed(f) {
                phase = .failed(f)
                changes.emit(.disconnected(nil))
                return
            } catch {
                phase = .offline("\(error)")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(3))
            }
        }
    }

    func stop() {
        loop?.cancel()
        pathWatch?.cancel()
        connection.disconnect()
    }

    /// The Mac woke or its network changed: check the link now. A host that
    /// waits for the person (a login, an install) keeps waiting.
    func nudge() {
        if case .failed = phase { return }
        connection.kick()
        if case .connected = phase { watchPath() }  // a new network, a new path
    }

    /// Tries again now (after a login, an install, a network change).
    func retry() {
        if case .failed = phase {
            phase = .connecting
            changes.emit(.disconnected(nil))
            Task { await connectLoop() }
        } else {
            connection.kick()
        }
    }

    private func handle(_ event: ConnectionEvent) {
        switch event {
        case let .connected(hello):
            state = hello.state
            phase = .connected
            changes.emit(.connected)
            watchPath()
        case let .deltas(ds):
            state?.apply(ds)
            changes.emit(.deltas(ds))
        case let .event(e):
            changes.emit(.event(e))
        case .attached, .detached:
            break
        case let .disconnected(reason):
            pathWatch?.cancel()
            relay = nil
            if case .failed = phase {} else { phase = .offline(reason) }
            changes.emit(.disconnected(reason))
            revive()
        case let .failed(f):
            phase = .failed(f)
        case let .latency(d):
            rtt = d
            changes.emit(.latency)
        }
    }

    /// Reads from Tailscale whether the link goes direct or through a relay:
    /// soon after connecting (a new path starts relayed), then now and then,
    /// more often while relayed, to see it go direct.
    private func watchPath() {
        pathWatch?.cancel()
        guard case let .tcp(dialled, _) = endpoint else { return }
        pathWatch = Task { [weak self] in
            var wait = Duration.seconds(3)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                let peers = await TailnetDirectory.scan()
                guard let self, !Task.isCancelled else { return }
                let now = TailnetDirectory.peer(dialledAs: dialled, in: peers)?.relay
                if now != relay {
                    relay = now
                    changes.emit(.latency)
                }
                wait = now == nil ? .seconds(120) : .seconds(20)
            }
        }
    }

    /// This Mac's server went away (stopped, crashed past launchd's retries,
    /// or a dev build's that nothing keeps alive): start it again rather than
    /// redial an empty socket forever. A server mid-restart answers first, and
    /// a twin started beside one loses the lock and exits.
    private func revive() {
        guard isLocal, !reviving, let prepare else { return }
        reviving = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            await prepare()
            guard let self else { return }
            reviving = false
            connection.kick()
        }
    }

    // MARK: Intents

    /// Applies an intent; failures surface as a toast.
    func perform(_ intent: Intent) {
        Task {
            do { try await connection.perform(intent) } catch let e as ConnectionError {
                onError?(Self.describe(e))
            } catch {
                onError?("\(error)")
            }
        }
    }

    func performAndWait(_ intent: Intent) async -> Bool {
        do {
            try await connection.perform(intent)
            return true
        } catch {
            onError?(Self.describe(error))
            return false
        }
    }

    static func describe(_ e: ConnectionError) -> String {
        switch e {
        case .notConnected, .closed: "Not connected to the server."
        case let .refused(why): "Connection refused: \(why)"
        case .intent(.spawnFailed): "Couldn't start the shell."
        case .intent(.targetGone): "That session or pane no longer exists."
        case .intent(.invalid): "The server rejected the change."
        case .intent(.notAllowed): "Not allowed."
        case .intent(.worktreeFailed): "Couldn't make the worktree. The branch may be checked out elsewhere."
        case .intent(.dirty): "The worktree has uncommitted changes."
        case .failed(.needsLogin(_)): "The host needs you to sign in."
        case .failed(.notInstalled): "Axolotty isn't set up on that host."
        case .failed(.incompatible(_)): "That host runs a different Axolotty version."
        case .failed(.denied): "That host doesn't accept this device."
        }
    }

    /// What a veiled session says while the link is down, nil while it is up.
    var linkStatus: (text: String, retrying: Bool)? {
        if settingUp != nil, phase != .connected { return ("Setting up Axolotty on \(name)", true) }
        return switch phase {
        case .connected: nil
        case .connecting, .offline: ("Reconnecting to \(isLocal ? "This Mac" : name)", true)
        case .failed(.needsLogin(_)): ("\(name) needs you to sign in", false)
        case .failed(.notInstalled): ("Axolotty isn't set up on \(name)", false)
        case .failed(.incompatible(_)): ("\(name) runs another Axolotty version", false)
        case .failed(.denied): ("\(name) doesn't accept this Mac", false)
        }
    }

    // MARK: Queries

    func session(_ id: SessionID) -> SessionInfo? { state?.sessions[id] }
    func pane(_ id: PaneID) -> PaneInfo? { state?.panes[id] }
}
