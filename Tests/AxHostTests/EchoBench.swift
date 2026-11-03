import AxClient
import AxHost
import AxModel
import AxProtocol
import Foundation
import Synchronization
import Testing

/// Key-to-echo round trips, the number Slopty tuned for. Off unless
/// AXBENCH is set; AXBENCH_TCP=host:port and AXBENCH_CMD="ssh host …"
/// add remote links next to the local socket. Prints p50/p90/p99/max.
///
///     AXBENCH=1 AXBENCH_TCP=100.64.0.2:7518 swift test -c release --filter EchoBench
@Suite("Echo bench", .enabled(if: ProcessInfo.processInfo.environment["AXBENCH"] != nil), .timeLimit(.minutes(10)))
struct EchoBench {
    static let env = ProcessInfo.processInfo.environment
    static let keys = Int(env["AXBENCH_KEYS"] ?? "") ?? 300

    @Test func echo() async throws {
        let fx = try await HostFixture()
        var links: [(String, HostEndpoint)] = [("unix", .unix(path: fx.paths.hostSocket.path(percentEncoded: false)))]
        if let t = Self.env["AXBENCH_TCP"], let colon = t.lastIndex(of: ":"), let port = UInt16(t[t.index(after: colon)...]) {
            links.append(("tcp \(t)", .tcp(host: String(t[..<colon]), port: port)))
        }
        if let cmd = Self.env["AXBENCH_CMD"] {
            links.append(("cmd", .command(argv: ["/bin/sh", "-c", cmd], label: "bench")))
        }
        for (name, endpoint) in links {
            for loaded in [false, true] {
                let c = HostConnection(endpoint: endpoint, hello: ClientHello(client: ClientID(), name: "bench"))
                try await c.connect(reconnect: false)
                let r = try await Self.run(c, loaded: loaded)
                print("ECHO \(name) \(c.transport ?? "local")\(loaded ? " +flood" : ""): \(r)")
                c.disconnect()
            }
        }
        await fx.tearDown()
    }

    static func run(_ c: HostConnection, loaded: Bool) async throws -> String {
        let (_, _, p) = try await makeSession(c, command: ["/bin/sh", "-c", "stty raw -echo; exec /bin/cat -u"])
        let m = c.attach(p)
        var flood: PaneID?
        let flooded = Atomic<Int>(0)
        let started = ContinuousClock.now
        if loaded {
            let (_, _, f) = try await makeSession(c, command: ["/bin/sh", "-c", "while :; do cat /usr/share/dict/words; done"])
            c.attach(f).onOutput { flooded.add($0.count, ordering: .relaxed) }
            flood = f
        }
        try await Task.sleep(for: .milliseconds(500))
        // The echo is timed where it lands, and the wait for it is woken by it: a sleeping
        // poll is a timer the OS may coalesce on an idle Mac, and it showed up as the tail.
        let seen = Mutex<(want: UInt8, sent: ContinuousClock.Instant, got: Duration?)>((0, .now, nil))
        let landed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        m.onOutput { buf in
            let hit = seen.withLock { s -> Bool in
                guard s.got == nil, buf.contains(s.want) else { return false }
                s.got = ContinuousClock.now - s.sent
                return true
            }
            if hit { landed.continuation.yield() }
        }
        var samples: [Duration] = []
        var lost = 0
        var it = landed.stream.makeAsyncIterator()
        for i in 0 ..< keys {
            let ch = UInt8(ascii: "a") + UInt8(i % 26)
            seen.withLock { $0 = (ch, .now, nil) }
            c.send(.text(p, String(UnicodeScalar(ch))))
            // Two seconds without the echo is a lost key: a timer wakes the wait.
            let deadline = ContinuousClock.now + .seconds(2)
            let timeout = Task {
                guard (try? await Task.sleep(until: deadline)) != nil else { return }
                landed.continuation.yield()
            }
            while seen.withLock({ $0.got }) == nil, ContinuousClock.now < deadline { _ = await it.next() }
            timeout.cancel()
            if let got = seen.withLock({ $0.got }) { samples.append(got) } else { lost += 1 }
            try await Task.sleep(for: .milliseconds(25))
        }
        m.onOutput(nil)
        let secs = Double((ContinuousClock.now - started).components.seconds)
        let rate = loaded ? String(format: " flood=%.1f MB/s", Double(flooded.load(ordering: .relaxed)) / 1e6 / max(secs, 1)) : ""
        if let flood { try? await c.perform(.closePane(flood)) }
        try? await c.perform(.closePane(p))
        samples.sort()
        func q(_ f: Double) -> String {
            guard !samples.isEmpty else { return "-" }
            let d = samples[min(samples.count - 1, Int(Double(samples.count) * f))]
            return String(format: "%.2f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
        }
        return "n=\(samples.count) lost=\(lost) p50=\(q(0.5)) p90=\(q(0.9)) p99=\(q(0.99)) max=\(q(1)) ms\(rate)"
    }
}
