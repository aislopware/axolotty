import AxClient
import AxHost
import AxModel
import AxProtocol
import Foundation
import Testing

/// Links to a host through a command (the ssh path) and over TCP (the tailnet path).
@Suite("Remote links", .timeLimit(.minutes(1)))
struct RemoteLinkTests {
    /// A command that prints an ssh-style banner, then the bridge preamble,
    /// then splices the server's socket (nc -U stands in for `axolotty bridge`).
    @Test func aCommandLinkSkipsTheBannerAndStreams() async throws {
        let fx = try await HostFixture()
        let sock = fx.paths.hostSocket.path(percentEncoded: false)
        let script = "printf 'Last login: today\\nWelcome to the host\\n\\000AXOLOTTY-BRIDGE\\000\(Wire.version)\\n'; exec /usr/bin/nc -U '\(sock)'"
        let c = HostConnection(endpoint: .command(argv: ["/bin/sh", "-c", script], label: "test-host"),
                               hello: ClientHello(client: ClientID(), name: "remote"))
        try await c.connect(reconnect: false)
        let (_, _, p) = try await makeSession(c)
        let m = c.attach(p)
        c.send(.text(p, "echo over-the-bridge\n"))
        #expect(await waitScreen(m, contains: "over-the-bridge"))
        c.disconnect()
        await fx.tearDown()
    }

    @Test func sshExitCodesSayWhatThePersonMustDo() {
        #expect(HostConnection.classify(exit: 255, stderr: "Permission denied (publickey).", banner: "")
            == .needsLogin("Permission denied (publickey)."))
        #expect(HostConnection.classify(exit: 255, stderr: "Host key verification failed.", banner: "") != nil)
        // A network that is down is retried, not handed to the person.
        #expect(HostConnection.classify(exit: 255, stderr: "ssh: connect to host x port 22: Operation timed out", banner: "") == nil)
        #expect(HostConnection.classify(exit: 87, stderr: "", banner: "") == .notInstalled)
        #expect(HostConnection.classify(exit: 1, stderr: "", banner: "") == nil)
    }

    @Test func aCommandThatNeedsALoginStopsRetrying() async throws {
        let c = HostConnection(endpoint: .command(argv: ["/bin/sh", "-c", "echo 'Permission denied (publickey).' >&2; exit 255"],
                                                  label: "locked"),
                               hello: ClientHello(client: ClientID(), name: "remote"))
        await #expect(throws: ConnectionError.failed(.needsLogin("Permission denied (publickey)."))) {
            try await c.connect(reconnect: true)
        }
    }
}
