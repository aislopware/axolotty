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
    /// The far Mac is up but refuses the link at its port: Axolotty isn't
    /// running there (not installed, or its server stopped).
    private(set) var nobodyListens = false
    /// Tailscale says the far Mac is offline (asleep, shut, off the net),
    /// with when it last heard from it; nil while it is online or unknown.
    private(set) var offline: Offline?
    struct Offline: Equatable { var lastSeen: Date? }
    private var downWatch: Task<Void, Never>?

    /// Only the machine is waited for: Tailscale says it is offline, and
    /// nothing (a setup, a login) is the person's to do.
    var waitsForTheMac: Bool {
        guard offline != nil, !nobodyListens, settingUp == nil else { return false }
        if case .failed = phase { return false }
        return phase != .connected
    }
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
        return FarHost(id: id, ssh: ssh, connection: connection, name: name)
    }

    /// Connects (after `prepare`, e.g. launching the local server) and keeps
    /// reconnecting with backoff until stopped.
    func start(prepare: (@MainActor () async -> Void)? = nil) {
        self.prepare = prepare
        watchTailnetWhileDown()
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
        downWatch?.cancel()
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
        case let .unanswered(closed):
            guard closed != nobodyListens else { return }
            nobodyListens = closed
            if phase != .connected { changes.emit(.disconnected(nil)) }
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

    /// While a far Mac's link is down, asks Tailscale every few seconds
    /// whether the machine itself is there: "offline, last seen 50 minutes
    /// ago" says more than a spinner, and needs nothing of the person.
    private func watchTailnetWhileDown() {
        guard !isLocal, case let .tcp(dialled, _) = endpoint else { return }
        downWatch = Task { [weak self] in
            while !Task.isCancelled {
                if let self, phase != .connected {
                    let peers = await TailnetDirectory.scan()
                    guard !Task.isCancelled else { return }
                    let p = TailnetDirectory.peer(dialledAs: dialled, in: peers)
                    let now = p.flatMap { $0.online ? nil : Offline(lastSeen: $0.lastSeen) }
                    if now != offline {
                        offline = now
                        if phase != .connected { changes.emit(.disconnected(nil)) }
                    }
                }
                try? await Task.sleep(for: .seconds(8))
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
        case .connecting, .offline:
            if nobodyListens, !isLocal { ("Axolotty isn't running on \(name)", false) }
            else if offline != nil { ("\(name) is offline", true) }
            // Never reached yet this run: connecting, not coming back.
            else if state == nil { ("Connecting to \(isLocal ? "This Mac" : name)", true) }
            else { ("Reconnecting to \(isLocal ? "This Mac" : name)", true) }
        case .failed(.needsLogin(_)): ("\(name) needs you to sign in", false)
        case .failed(.notInstalled): ("Axolotty isn't set up on \(name)", false)
        case .failed(.incompatible(_)): ("\(name) runs another Axolotty version", false)
        case .failed(.denied): ("\(name) doesn't accept this Mac", false)
        }
    }

    /// "50 minutes ago", "yesterday".
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(for: d, relativeTo: now)
    }

    /// The one line under the status while the link is down: what is
    /// happening and what will bring it back.
    var linkDetail: String {
        switch settingUp {
        case .checking?: return "Checking \(name) over SSH."
        case .copying?: return "Copying Axolotty there. It starts by itself after."
        case .starting?: return "Starting its server. This window opens there once it answers."
        case nil: break
        }
        switch phase {
        case .connected: return ""
        case .connecting, .offline:
            if nobodyListens, !isLocal {
                return "\(name) is reachable. Set Axolotty up there over SSH and this Mac connects by itself."
            }
            if let o = offline {
                let seen = o.lastSeen.map { "Tailscale last saw it \(Self.ago($0)). " } ?? ""
                return seen + (state == nil ? "This window opens there the moment it's back."
                    : "Your sessions keep running there; this window reattaches the moment it's back.")
            }
            if state == nil { return "This window opens there the moment it answers." }
            return "Your sessions keep running on the server. This window reattaches as soon as it answers."
        case .failed(.needsLogin(_)): return "ssh wants a password or a host key decision. Sign in there once, then try again."
        case .failed(.notInstalled): return "Set it up over SSH and this Mac connects by itself."
        case .failed(.incompatible(_)):
            return isBehind ? "Update it over SSH to the Axolotty on this Mac." : "Update Axolotty on this Mac to reach it."
        case .failed(.denied): return "It serves only Macs signed in to the same Tailscale account."
        }
    }

    /// The one thing to do while the link is down: set Axolotty up there or
    /// update it when that is what keeps the link down, else reconnect.
    /// Nil while it is being set up, or with the link up.
    var linkRemedy: (title: String, setUp: AppModel.SavedHost?)? {
        guard phase != .connected, settingUp == nil else { return nil }
        if let target = setUpTarget {
            if nobodyListens || phase == .failed(.notInstalled) { return ("Set Up over SSH", target) }
            if isBehind { return ("Update There", target) }
        }
        if case .failed = phase {} else if offline != nil { return nil }  // nothing to do but wait for it
        return (state == nil ? "Try Now" : "Reconnect Now", nil)
    }

    // MARK: Queries

    func session(_ id: SessionID) -> SessionInfo? { state?.sessions[id] }
    func pane(_ id: PaneID) -> PaneInfo? { state?.panes[id] }
}
