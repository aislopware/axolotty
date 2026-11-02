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
    let changes = Signal<HostChange>()
    /// Reports failed intents (the app shows a toast).
    var onError: ((String) -> Void)?
    private var loop: Task<Void, Never>?

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

    /// Connects (after `prepare`, e.g. launching the local server) and keeps
    /// reconnecting with backoff until stopped.
    func start(prepare: (@MainActor () async -> Void)? = nil) {
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
        connection.disconnect()
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
        case let .deltas(ds):
            state?.apply(ds)
            changes.emit(.deltas(ds))
        case let .event(e):
            changes.emit(.event(e))
        case .attached, .detached:
            break
        case let .disconnected(reason):
            if case .failed = phase {} else { phase = .offline(reason) }
            changes.emit(.disconnected(reason))
        case let .failed(f):
            phase = .failed(f)
        case let .latency(d):
            rtt = d
            changes.emit(.latency)
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
        switch phase {
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
