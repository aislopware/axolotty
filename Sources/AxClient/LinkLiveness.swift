/// Whether a remote link is alive, from what it has said and when: Slopty's
/// third-generation liveness. A ping goes every `beat`; any frame counts as
/// hearing from the host; a link quiet for more than a beat and a half has
/// missed a ping and shows as quiet; one quiet for `silence` is dead and is
/// relinked.
///
/// Pure: time comes in as elapsed `Duration` from any fixed epoch, so the
/// rules are tested to the millisecond in virtual time, and `HostConnection`
/// only sleeps until `nextCheck` and does what it is told.
public struct LinkLiveness: Sendable {
    public struct Timing: Sendable, Equatable {
        public var beat: Duration
        public var silence: Duration

        public init(beat: Duration, silence: Duration) {
            self.beat = beat
            self.silence = silence
        }

        /// Slopty's numbers: a ping every 2 s, relink after 6 s of silence.
        public static let standard = Timing(beat: .seconds(2), silence: .seconds(6))

        /// Past this much quiet, a ping has gone unanswered.
        public var quietAfter: Duration { beat + beat / 2 }
    }

    public enum State: Sendable, Equatable {
        case alive
        /// A ping went unanswered: say so, but keep the link.
        case quiet
        /// Silent for `silence`: drop the link and redial.
        case dead
    }

    public let timing: Timing
    public private(set) var lastHeard: Duration
    private var lastPing: Duration
    private var pings: [UInt64: Duration] = [:]
    private var counter: UInt64 = 0

    /// A link that has just been heard from (its welcome).
    public init(timing: Timing = .standard, now: Duration) {
        self.timing = timing
        lastHeard = now
        lastPing = now
    }

    /// Any frame from the host.
    public mutating func heard(at now: Duration) { lastHeard = max(lastHeard, now) }

    /// The number of a ping to send now, when one is due. Numbers have the
    /// top bit set, so they never meet the explicit pings of `ping()`.
    public mutating func pingIfDue(at now: Duration) -> UInt64? {
        guard now - lastPing >= timing.beat else { return nil }
        lastPing = now
        counter += 1
        let n = (1 << 63) | counter
        pings = pings.filter { now - $0.value < timing.silence }
        pings[n] = now
        return n
    }

    /// A pong: the host was heard, and the round trip when it answers one of ours.
    public mutating func pong(_ n: UInt64, at now: Duration) -> Duration? {
        heard(at: now)
        return pings.removeValue(forKey: n).map { now - $0 }
    }

    public func state(at now: Duration) -> State {
        let quiet = now - lastHeard
        if quiet >= timing.silence { return .dead }
        if quiet > timing.quietAfter { return .quiet }
        return .alive
    }

    /// When something next changes if nothing is heard: a ping falls due,
    /// the link turns quiet, or it dies.
    public func nextCheck(after now: Duration) -> Duration {
        let marks = [lastPing + timing.beat, lastHeard + timing.quietAfter + .milliseconds(1), lastHeard + timing.silence]
        return marks.filter { $0 > now }.min() ?? now + timing.beat
    }
}
