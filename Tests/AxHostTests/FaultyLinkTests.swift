import AxClient
import AxHost
import AxModel
import AxProtocol
import AxTestSupport
import Foundation
import Synchronization
import Testing

/// A remote link through `LinkRelay`, faults injected on loopback: what
/// the person sees must be every line the program printed, once each, in
/// order, whatever the path did meanwhile. Waits are on events; the timing
/// rules are held in virtual time in `LinkLivenessTests`.
@Suite("Faulty links", .timeLimit(.minutes(1)))
struct FaultyLinkTests {
    /// Short, so an outage takes a second, not a minute; same rules.
    static let timing = LinkLiveness.Timing(beat: .milliseconds(150), silence: .milliseconds(600))
    static let lines = 300
    /// Waits for a line first, so it prints nothing before the test listens.
    static let program = ["/bin/sh", "-c", "read go; i=0; while [ $i -lt \(lines) ]; do echo L$i; i=$((i+1)); sleep 0.01; done; sleep 60"]

    final class Captured: Sendable {
        let bytes = Mutex(Data())
    }

    struct Rig {
        let fx: HostFixture
        let relay: LinkRelay
        let c: HostConnection
        let stream: Captured

        /// The numbers of the L-lines received so far, in arrival order.
        var seen: [Int] {
            let text = String(decoding: stream.bytes.withLock { $0 }, as: UTF8.self)
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return l.hasPrefix("L") ? Int(l.dropFirst()) : nil
            }
        }

        func waitFor(_ n: Int, _ timeout: Duration = .seconds(20)) async -> Bool {
            await until(timeout) { seen.count >= n }
        }

        func tearDown() async {
            c.disconnect()
            relay.close()
            await fx.tearDown()
        }
    }

    static func rig() async throws -> Rig {
        let fx = try await HostFixture()
        let relay = try LinkRelay(to: fx.paths.hostSocket.path(percentEncoded: false))
        let c = HostConnection(endpoint: .tcp(host: "127.0.0.1", port: relay.port),
                               hello: ClientHello(client: ClientID(), name: "faulty"), timing: timing)
        try await c.connect(reconnect: true)
        let (_, _, p) = try await makeSession(c, command: program)
        let stream = Captured()
        let m = c.attach(p)
        #expect(await until { m.isReady })
        m.onOutput { b in stream.bytes.withLock { $0.append(contentsOf: b) } }
        c.send(.text(p, "go\n"))
        return Rig(fx: fx, relay: relay, c: c, stream: stream)
    }

    @Test func aShortOutageKeepsTheLinkAndLosesNothing() async throws {
        let r = try await Self.rig()
        #expect(await r.waitFor(20))
        r.relay.blackout()
        try await Task.sleep(for: Self.timing.beat * 2)  // under `silence`
        r.relay.restore()
        #expect(await r.waitFor(Self.lines))
        #expect(r.seen == Array(0 ..< Self.lines))
        #expect(r.relay.accepted == 1, "a short outage must not cost a relink")
        await r.tearDown()
    }

    @Test func aLongOutageRelinksAndResumesWhereItLeftOff() async throws {
        let r = try await Self.rig()
        #expect(await r.waitFor(20))
        r.relay.blackout()
        #expect(await until(.seconds(5)) { r.c.linkState == nil }, "the link was not dropped after silence")
        try await Task.sleep(for: .milliseconds(300))  // a dial or two refused while dark
        r.relay.restore()
        #expect(await until(.seconds(10)) { r.c.isConnected })
        #expect(await r.waitFor(Self.lines))
        #expect(r.seen == Array(0 ..< Self.lines), "resumed with a gap or a repeat")
        #expect(r.relay.accepted >= 2)
        await r.tearDown()
    }

    @Test func aResetRedialsAtOnceAndLosesNothing() async throws {
        let r = try await Self.rig()
        #expect(await r.waitFor(20))
        r.relay.cut()
        #expect(await until(.seconds(5)) { r.relay.accepted >= 2 && r.c.isConnected })
        #expect(await r.waitFor(Self.lines))
        #expect(r.seen == Array(0 ..< Self.lines))
        await r.tearDown()
    }

    @Test func aSlowPathStillDeliversInOrder() async throws {
        let r = try await Self.rig()
        r.relay.delay = .milliseconds(40)
        #expect(await r.waitFor(Self.lines))
        #expect(r.seen == Array(0 ..< Self.lines))
        #expect(r.relay.accepted == 1, "40 ms each way is slow, not dead")
        await r.tearDown()
    }
}
