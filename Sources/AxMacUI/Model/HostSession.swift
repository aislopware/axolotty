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
}

/// The app's link to one server: its document replica, connection phase and
/// intents. A client can hold many (local plus remote); a server can serve many.
final class HostSession: Identifiable {
    enum Phase: Equatable {
        case connecting
        case connected
        case offline(String?)
    }

    let id = UUID()
    let endpoint: HostEndpoint
    let connection: HostConnection
    let isLocal: Bool
    private(set) var state: HostState?
    private(set) var phase: Phase = .connecting
    let changes = Signal<HostChange>()
    /// Reports failed intents (the app shows a toast).
    var onError: ((String) -> Void)?
    private var loop: Task<Void, Never>?

    init(endpoint: HostEndpoint, client: ClientID, clientName: String, isLocal: Bool) {
        self.endpoint = endpoint
        self.isLocal = isLocal
        connection = HostConnection(endpoint: endpoint,
                                    hello: ClientHello(client: client, name: clientName, platform: .macOS))
    }

    var name: String { state?.name ?? (isLocal ? "This Mac" : endpoint.description) }

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
            phase = .offline(reason)
            changes.emit(.disconnected(reason))
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
        }
    }

    // MARK: Queries

    func session(_ id: SessionID) -> SessionInfo? { state?.sessions[id] }
    func pane(_ id: PaneID) -> PaneInfo? { state?.panes[id] }
}
