import AxProtocol
import AxTestSupport
import Foundation
import Testing

/// The send path on a simulated link, in virtual time (`LinkSim.swift`):
/// the real `SendLanes` and `BulkPacer` deciding what a host writes into a
/// TCP model over a seeded shaper. Each test runs seconds of traffic in
/// milliseconds, the same way every time.
///
/// Bounds are relative to the idle link wherever they can be, so they say
/// what the send path adds, not what the path costs. Every rule the paced
/// arm must meet is shown, in the same run, to fail for the arms without
/// the fix: a check that cannot fail tells nothing.
@Suite("Simulated link")
struct LinkSimTests {
    /// A Wi-Fi tailnet path like the Studio→MacBook one: 50 Mbit/s, 4 ms
    /// each way with a little jitter, a home router's 100 ms of buffer.
    static let wifi = LinkModel(delay: .milliseconds(4), jitter: .milliseconds(1), rate: 6_250_000, queue: .milliseconds(100))
    /// Four seeds in the gate; `AXSIM_SEEDS=200` for the long run.
    static let seeds: [UInt64] = ProcessInfo.processInfo.environment["AXSEED"].flatMap(UInt64.init).map { [$0] }
        ?? Array(1 ... UInt64(ProcessInfo.processInfo.environment["AXSIM_SEEDS"].flatMap(Int.init) ?? 4))

    /// Every seed's echoes pooled, so a bound holds across seeds, not on a lucky one.
    static func pooled(_ make: (UInt64) -> EchoRun) -> EchoResult {
        var echoes: [Duration] = [], rtts: [Duration] = []
        var lost = 0
        var rate = 0.0
        var lostIn: [UInt64] = []
        for (i, seed) in seeds.enumerated() {
            // A long run says it is alive, so a watchdog can tell slow from stuck.
            if seeds.count > 20, i % 20 == 0 { progress("sim seed \(seed) of \(seeds.count)") }
            let r = make(seed).run()
            echoes += r.echoes
            rtts += r.rtts
            lost += r.lostKeys
            if r.lostKeys > 0 { lostIn.append(seed) }
            rate += r.floodRate / Double(seeds.count)
        }
        var pooled = EchoResult(echoes: echoes, lostKeys: lost, floodRate: rate)
        pooled.lostIn = lostIn
        pooled.rtts = rtts
        return pooled
    }

    static func run(_ link: LinkModel, _ policy: SendPolicy, flood: Bool = true, halves: Bool = false) -> EchoResult {
        pooled { seed in
            var r = EchoRun(down: link, policy: policy, seed: seed)
            if !flood { r.floodRate = 0 }
            if halves { r.rateAfterWarmup = 0.5 }
            return r
        }
    }

    @Test func aSeedRepeatsItsRun() {
        let a = EchoRun(down: Self.wifi, policy: .paced, seed: 7).run()
        let b = EchoRun(down: Self.wifi, policy: .paced, seed: 7).run()
        let c = EchoRun(down: Self.wifi, policy: .paced, seed: 8).run()
        #expect(a == b)
        #expect(a.digest != c.digest)
        // The MacBook model draws stalls and aggregates from the seed too.
        let m = EchoRun(down: Self.macBookWifi, policy: .paced, seed: 7)
        #expect(m.run() == m.run())
    }

    /// The finding measured on the real tailnet, held here for good: an
    /// echo beside a flooding pane stays near the idle round trip, and the
    /// flood still gets most of the link.
    @Test func anEchoBesideAFloodStaysNearTheIdleRoundTrip() {
        let idle = Self.run(Self.wifi, .paced, flood: false)
        let paced = Self.run(Self.wifi, .paced)
        #expect(paced.lostKeys == 0, "\(paced.summary)")
        #expect(paced.quantile(0.5) <= idle.quantile(0.5) + .milliseconds(6), "\(paced.summary) vs idle \(idle.summary)")
        #expect(paced.quantile(0.99) <= idle.quantile(0.99) + .milliseconds(20), "\(paced.summary) vs idle \(idle.summary)")
        #expect(paced.floodRate >= 0.7 * Double(Self.wifi.rate), "\(paced.summary)")
    }

    /// The canaries for the rule above: without pacing the echo waits in
    /// the router's queue, and with one FIFO behind the flood's backlog
    /// too. The simulated link reproduces both failures it guards against.
    @Test func withoutTheFixTheEchoQueues() {
        let idle = Self.run(Self.wifi, .paced, flood: false)
        let lanes = Self.run(Self.wifi, .lanes)
        let fifo = Self.run(Self.wifi, .fifo)
        #expect(lanes.quantile(0.5) > idle.quantile(0.5) + .milliseconds(30), "\(lanes.summary)")
        #expect(fifo.quantile(0.5) > lanes.quantile(0.5) * 2, "fifo \(fifo.summary) lanes \(lanes.summary)")
    }

    /// Wi-Fi halving its rate under the sender: pacing finds the new floor.
    @Test func aLinkThatHalvesUnderTheFlood() {
        let paced = Self.run(Self.wifi, .paced, halves: true)
        let lanes = Self.run(Self.wifi, .lanes, halves: true)
        #expect(paced.quantile(0.99) <= .milliseconds(50), "\(paced.summary)")
        #expect(lanes.quantile(0.99) > paced.quantile(0.99) * 2, "lanes \(lanes.summary) paced \(paced.summary)")
    }

    /// 1 % random loss: TCP's own recovery is now the floor (an echo behind
    /// a lost segment waits for it), which pacing cannot change; small
    /// frames keep what it waits behind small. This is the case Stage B
    /// (QUIC, echo datagram copies) would improve.
    @Test func aLossyLinkKeepsEchoWithinTCPsRecovery() {
        var lossy = Self.wifi
        lossy.loss = 0.01
        let paced = Self.run(lossy, .paced)
        #expect(paced.lostKeys == 0, "\(paced.summary)")
        #expect(paced.quantile(0.5) <= .milliseconds(25), "\(paced.summary)")
        #expect(paced.quantile(0.99) <= .milliseconds(90), "\(paced.summary)")
    }

    /// The Studio→MacBook path as measured over the tailnet (EchoBench,
    /// 2026-11-03: idle p50 6.7 ms, p90 9.8 ms; ssh moves 15 MB/s over it).
    /// Wi-Fi's own jitter is several milliseconds, more than the pacer's
    /// tolerance, so single round trips rise with no queue behind them.
    static let jitteryWifi = LinkModel(delay: .milliseconds(2), jitter: .milliseconds(5), rate: 20_000_000, queue: .milliseconds(100))

    /// The Studio→MacBook Wi-Fi path, fitted to what it did on 2026-11-03
    /// and held there by `theMacBookModelMatchesItsTrace`, so a pacer is
    /// chosen here, seeded and in virtual time, not on a link that is
    /// quick one minute and slow the next.
    ///
    /// Idle round trips are short with a long tail (jitter skewed by a cube).
    /// Under load they sit near 10 ms whatever the sender keeps in flight:
    /// the radio contends for the air and sends in aggregates, which a queue
    /// of one's own would not do. Now and then it stalls for tens of ms.
    static let macBookWifi = LinkModel(delay: .microseconds(1250), jitter: .milliseconds(8), jitterPower: 3,
                                       rate: 45_000_000, queue: .milliseconds(100),
                                       busyStall: (.seconds(1), .milliseconds(60)),
                                       busyExtra: .microseconds(500), aggregate: .milliseconds(3))

    /// Typing alone on the MacBook path, run once for the tests that compare with it.
    static let macBookIdle = run(macBookWifi, .paced, flood: false)

    /// The model against the measurements it stands for; a pacer tuned on a
    /// model that drifted from its path is tuned for nothing.
    ///
    /// - Idle: EchoBench over the tailnet less the pty's own 1.4 ms (its
    ///   unix-socket echo), four runs: p50 5.8, p90 9, p99 13 to 23 ms.
    /// - Loaded: the host's pacer logging `tcpi_rttcur` every 20 ms under a
    ///   64 MB tunnel transfer, 742 samples: p10 6 to 7, p50 10, p90 15 to
    ///   17 ms, the same with 32 KB in the socket as with 400 KB; 2 % of
    ///   them a stall near 100 ms.
    ///
    /// Two loads are pinned, not the pacer's, so the pacer may change and
    /// the model stays. The stalls are fitted short of the log: echo under
    /// flood, measured another time, saw them far less often (p99 22 to 37
    /// ms). Loaded echo p50 here runs about 3 ms above the real one, on the
    /// safe side for every bound on echo.
    @Test func theMacBookModelMatchesItsTrace() {
        func ms(_ d: Duration) -> Double { d / .milliseconds(1) }
        let idle = Self.macBookIdle
        var found = "idle \(idle.summary)"
        for cap in [64 << 10, 256 << 10] {
            let r = Self.pooled { seed in
                var r = EchoRun(down: Self.macBookWifi, policy: .paced, seed: seed)
                r.fixedCap = cap
                return r
            }
            let calm = EchoResult(echoes: []).with(rtts: r.rtts.filter { $0 <= .milliseconds(50) })
            let stalls = Double(r.rtts.count - calm.rtts.count) / Double(max(1, r.rtts.count))
            found += String(format: "; %dk in flight: rtt p10 %.0f p50 %.0f p90 %.0f ms, stalled %.3f", cap >> 10,
                            ms(calm.rttQuantile(0.1)), ms(calm.rttQuantile(0.5)), ms(calm.rttQuantile(0.9)), stalls)
            #expect((5 ... 8).contains(ms(calm.rttQuantile(0.1))), "\(found)")
            #expect((9 ... 12).contains(ms(calm.rttQuantile(0.5))), "\(found)")
            #expect((13 ... 18).contains(ms(calm.rttQuantile(0.9))), "\(found)")
            #expect((0.001 ... 0.04).contains(stalls), "\(found)")
        }
        #expect((4.5 ... 7.5).contains(ms(idle.quantile(0.5))), "\(found)")
        #expect((7 ... 12).contains(ms(idle.quantile(0.9))), "\(found)")
        #expect((12 ... 24).contains(ms(idle.quantile(0.99))), "\(found)")
    }

    /// The MacBook path with a flood beside typing, as the pacer meets it:
    /// the flood keeps about the 8 MB/s it moved over the real path (8 to 15
    /// there; the model runs pessimistic), and the echo stays near idle.
    /// Judging every raw round trip (the pacer before 982768a) halves the
    /// flood. Unpaced is no canary here: the link outruns the flood's
    /// 40 MB/s, so no queue builds; the slow `wifi` link shows what pacing
    /// is for.
    @Test func theMacBookPathCarriesAFloodBesideAnEcho() {
        let idle = Self.macBookIdle
        let paced = Self.run(Self.macBookWifi, .paced)
        let raw = Self.pooled { seed in
            var r = EchoRun(down: Self.macBookWifi, policy: .paced, seed: seed)
            r.pacerWindow = .zero
            return r
        }
        #expect(paced.lostKeys == 0, "\(paced.summary)")
        #expect(paced.floodRate >= 6_000_000, "\(paced.summary)")
        #expect(paced.quantile(0.5) <= idle.quantile(0.5) + .milliseconds(6), "\(paced.summary) vs idle \(idle.summary)")
        #expect(paced.quantile(0.9) <= idle.quantile(0.9) + .milliseconds(8), "\(paced.summary) vs idle \(idle.summary)")
        #expect(raw.floodRate < 0.7 * paced.floodRate, "raw \(raw.summary)")
    }

    /// Bulk on a jittery link: judged on each raw round trip, the pacer took
    /// jitter for a queue and held a flood to a sixth of the link (3.5 of
    /// 19 MB/s here; 6 MB/s against ssh's 15 on the real path). Cutting only
    /// when the least round trip over the window is up sees a real queue
    /// alone (13 MB/s over 16 seeds), and the echo still stays near the idle
    /// link.
    @Test func aJitteryLinkStillCarriesTheFlood() {
        let idle = Self.run(Self.jitteryWifi, .paced, flood: false)
        let paced = Self.run(Self.jitteryWifi, .paced)
        let raw = Self.pooled { seed in
            var r = EchoRun(down: Self.jitteryWifi, policy: .paced, seed: seed)
            r.pacerWindow = .zero
            return r
        }
        #expect(paced.lostKeys == 0, "\(paced.summary)")
        #expect(paced.floodRate >= 0.6 * Double(Self.jitteryWifi.rate), "\(paced.summary)")
        #expect(raw.floodRate < 0.3 * Double(Self.jitteryWifi.rate), "raw \(raw.summary)")
        #expect(paced.quantile(0.5) <= idle.quantile(0.5) + .milliseconds(6), "\(paced.summary) vs idle \(idle.summary)")
        #expect(paced.quantile(0.99) <= idle.quantile(0.99) + .milliseconds(12), "\(paced.summary) vs idle \(idle.summary)")
    }

    /// `AXSIM_REPORT=1 swift test --filter LinkSimTests/report`: every arm on
    /// every link. `AXSIM_ONLY=wifi,jittery` picks links by name prefix,
    /// `AXSIM_PACED=1` the paced arm alone.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["AXSIM_REPORT"] != nil))
    func report() {
        var lossy = Self.wifi
        lossy.loss = 0.01
        for (name, link, halves) in [("wifi", Self.wifi, false), ("wifi 1% loss", lossy, false), ("wifi halves", Self.wifi, true),
                                     ("jittery wifi", Self.jitteryWifi, false), ("macbook wifi", Self.macBookWifi, false)] {
            if let only = ProcessInfo.processInfo.environment["AXSIM_ONLY"], !only.split(separator: ",").contains(where: { name.hasPrefix($0) }) { continue }
            for policy in SendPolicy.allCases where ProcessInfo.processInfo.environment["AXSIM_PACED"] == nil || policy == .paced {
                print("SIM \(name) \(policy): \(Self.run(link, policy, halves: halves).summary)")
            }
            if ProcessInfo.processInfo.environment["AXSIM_PACED"] == nil { print("SIM \(name) idle: \(Self.run(link, .paced, flood: false, halves: halves).summary)") }
        }
    }
}
