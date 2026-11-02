import AxClient
import AxHost
import AxModel
import AxProtocol
import AxTestSupport
import AxVT
import Foundation
import Testing

/// A real server (in-process), a real holder (child process) and real shells,
/// isolated under a short /tmp root. Clients talk to it over its Unix socket.
final class HostFixture: @unchecked Sendable {
    let paths: RuntimePaths
    var config: ServerConfig
    private(set) var host: Server

    init(configure: (inout ServerConfig) -> Void = { _ in }) async throws {
        _ = sigpipeTrap
        let root = URL(filePath: "/tmp/axh-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        paths = RuntimePaths(root: root)
        var c = ServerConfig(paths: paths, holderExecutable: PtydBinary.url, name: "Test Host")
        c.shellOverride = "/bin/sh"
        c.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8",
                         "PS1": "$ "]
        c.foregroundPoll = .milliseconds(100)
        c.holderWatchesServer = true
        configure(&c)
        config = c
        host = Server(config: c)
        try await host.start()
    }

    /// Stops the server (programs keep running) and starts a new one on the same state.
    func restart() async throws {
        await host.stop()
        host = Server(config: config)
        try await host.start()
    }

    func client(_ name: String = "test") async throws -> HostConnection {
        let c = HostConnection(endpoint: .unix(path: paths.hostSocket.path(percentEncoded: false)),
                               hello: ClientHello(client: ClientID(), name: name))
        try await c.connect()
        return c
    }

    func tearDown() async {
        await host.stop()
        do {
            let c = try CustodyClient(socketPath: paths.holderSocket.path(percentEncoded: false))
            try c.shutdownHolder()
        } catch {
            print("TEARDOWN-FAIL \(paths.root.lastPathComponent): \(error)")
        }
        try? FileManager.default.removeItem(at: paths.root)
    }
}

/// A workspace with one session running /bin/sh; returns its ids.
func makeSession(_ c: HostConnection, command: [String]? = nil) async throws -> (WorkspaceID, SessionID, PaneID) {
    let w = WorkspaceID(), s = SessionID(), p = PaneID()
    try await c.perform(.createWorkspace(w, name: "test", root: "/tmp"))
    try await c.perform(.createSession(s, workspace: w, pane: p, recipe: SpawnRecipe(command: command), name: nil))
    return (w, s, p)
}

func screen(_ m: MirrorTerminal) -> String {
    m.withTerminal { $0.text(.plain, trim: true, unwrap: true) } ?? ""
}

/// Polls until `cond` holds (async-friendly; tests stay fast when things work).
func until(_ timeout: Duration = .seconds(5), _ cond: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

/// Waits for the mirror to contain `needle`.
func waitScreen(_ m: MirrorTerminal, contains needle: String, timeout: Duration = .seconds(5)) async -> Bool {
    await until(timeout) { screen(m).contains(needle) }
}
