import AxClient
import AxTestSupport
import Testing

/// The liveness rules in virtual time, to the millisecond: no sleeping, no
/// real clock, every bound exact.
@Suite("Link liveness")
struct LinkLivenessTests {
    let t = LinkLiveness.Timing.standard
    let ms = Duration.milliseconds(1)

    /// Steps the machine the way `HostConnection` does: wake at each
    /// `nextCheck`, ask for the state and a ping, and hear `answer` back.
    func drive(_ l: inout LinkLiveness, until end: Duration, from start: Duration = .zero,
               answer: (Duration) -> Duration? = { _ in nil }) -> (pings: [Duration], died: Duration?, quietAt: Duration?) {
        var now = start
        var pings: [Duration] = []
        var quietAt: Duration?
        var replies: [(at: Duration, n: UInt64)] = []
        while now < end {
            var wake = l.nextCheck(after: now)
            if let r = replies.first, r.at < wake { wake = r.at }
            now = wake
            while let r = replies.first, r.at <= now {
                replies.removeFirst()
                _ = l.pong(r.n, at: r.at)
            }
            switch l.state(at: now) {
            case .dead: return (pings, now, quietAt)
            case .quiet: if quietAt == nil { quietAt = now }
            case .alive: break
            }
            if let n = l.pingIfDue(at: now) {
                pings.append(now)
                if let rtt = answer(now) { replies.append((now + rtt, n)) }
            }
        }
        return (pings, nil, quietAt)
    }

    @Test func aHealthyLinkPingsEveryBeatAndNeverTurnsQuiet() {
        var l = LinkLiveness(timing: t, now: .zero)
        let r = drive(&l, until: .seconds(20)) { _ in .milliseconds(9) }
        #expect(r.pings == (1 ... 10).map { t.beat * $0 })
        #expect(r.died == nil)
        #expect(r.quietAt == nil)
    }

    @Test func aSilentHostTurnsQuietAfterAMissedPingAndDiesAtSilence() {
        var l = LinkLiveness(timing: t, now: .zero)
        let r = drive(&l, until: .seconds(20))
        #expect(r.quietAt == t.quietAfter + ms)
        #expect(r.died == t.silence)
        #expect(r.pings == [t.beat, t.beat * 2])  // the third is due at 6 s, when it is already dead
    }

    @Test func anyFrameKeepsItAliveAndAPongGivesTheRoundTrip() {
        var l = LinkLiveness(timing: t, now: .zero)
        l.heard(at: .seconds(5))
        #expect(l.state(at: .seconds(5) + t.silence - ms) != .dead)
        #expect(l.state(at: .seconds(5) + t.silence) == .dead)
        var m = LinkLiveness(timing: t, now: .zero)
        let n = m.pingIfDue(at: t.beat)!
        #expect(m.pong(n, at: t.beat + .milliseconds(37)) == .milliseconds(37))
        #expect(m.pong(n, at: t.beat + .milliseconds(40)) == nil)  // answered once
        #expect(m.pong(5, at: t.beat + .milliseconds(41)) == nil)  // not ours
        #expect(n & (1 << 63) != 0)
    }

    /// A host that answers slower than a beat and a half is quiet but kept;
    /// slower than `silence` is dropped. Seeded round trips across that line.
    @Test func slowAnswersAreQuietNotDeadUntilSilence() {
        for seed in UInt64(1) ... 50 {
            var rng = SimRNG(seed: seed)
            let rtt = Duration.milliseconds(Int(rng.next() % 7000))
            var l = LinkLiveness(timing: t, now: .zero)
            let r = drive(&l, until: .seconds(30)) { _ in rtt }
            if rtt < t.quietAfter - t.beat {
                #expect(r.died == nil && r.quietAt == nil, "rtt \(rtt)")
            }
            if rtt + t.beat >= t.silence {
                #expect(r.died != nil, "rtt \(rtt)")
            } else {
                #expect(r.died == nil, "rtt \(rtt)")
            }
        }
    }
}
