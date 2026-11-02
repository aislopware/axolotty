public import Foundation

/// The frames waiting to go out on one link, by lane, and which goes next.
///
/// Lane 0 (control) always goes first; then the lane with the least queued,
/// a whole frame at a time. Each pane has a lane of its own, so its frames
/// keep their order but never wait behind another pane's: a pane pouring out
/// a build log cannot hold back the echo of a key typed into another (Slopty
/// gets the same from a QUIC stream per session; here it is one TCP stream).
///
/// Pure: no I/O and no clock, so the simulated link in the tests drives the
/// very scheduler a socket does.
public struct SendLanes: Sendable {
    public static let control = 0
    /// A lane with no more than this queued is interactive (an echo, a
    /// prompt) and is never held back by pacing.
    public static let interactiveBytes = 4 << 10

    private struct Lane {
        var chunks: [Data] = []
        var first = 0
        var bytes = 0
        var isEmpty: Bool { first == chunks.count }

        mutating func push(_ d: Data) {
            chunks.append(d)
            bytes += d.count
        }

        mutating func pop() -> Data {
            let d = chunks[first]
            first += 1
            bytes -= d.count
            if first == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                first = 0
            } else if first >= 256 {
                chunks.removeFirst(first)
                first = 0
            }
            return d
        }
    }

    private var lanes: [Int: Lane] = [:]
    /// The frame being written: a frame is never interleaved with another.
    public private(set) var current: Data?
    public private(set) var currentLane = 0
    /// Bytes of `current` already written.
    public private(set) var head = 0
    /// Everything queued, the unwritten rest of `current` included.
    public private(set) var pending = 0

    public init() {}

    /// The lane for a stream of frames that must stay in order (one pane's).
    public static func lane<K: Hashable>(_ key: K) -> Int {
        let h = key.hashValue
        return h == control ? 1 : h
    }

    public var isEmpty: Bool { pending == 0 }

    public mutating func push(_ frame: Data, lane: Int = control) {
        guard !frame.isEmpty else { return }
        lanes[lane, default: Lane()].push(frame)
        pending += frame.count
    }

    /// What one lane still has to send, the rest of `current` included.
    public func pending(lane: Int) -> Int {
        (lanes[lane]?.bytes ?? 0) + (current != nil && currentLane == lane ? current!.count - head : 0)
    }

    /// The lane that goes next, and whether it is bulk: when even the least
    /// queued lane has a backlog, every lane waiting is pouring.
    public func choose() -> (lane: Int, bulk: Bool)? {
        if let c = lanes[Self.control], !c.isEmpty { return (Self.control, false) }
        var pick: Int?
        var least = Int.max
        for (k, l) in lanes where !l.isEmpty && (l.bytes < least || (l.bytes == least && k < pick!)) {
            least = l.bytes
            pick = k
        }
        return pick.map { ($0, least > Self.interactiveBytes) }
    }

    /// The frame to write now: the one under way, else the next one chosen.
    /// With `holdBulk`, nothing new starts when only bulk lanes wait.
    public mutating func next(holdBulk: Bool = false) -> Data? {
        if let current { return current }
        guard let (pick, bulk) = choose(), !(holdBulk && bulk) else { return nil }
        current = lanes[pick]!.pop()
        currentLane = pick
        if lanes[pick]!.isEmpty, pick != Self.control { lanes[pick] = nil }
        head = 0
        return current
    }

    /// Records that `n` more bytes of `current` were written.
    public mutating func wrote(_ n: Int) {
        guard let c = current, n > 0 else { return }
        head += n
        pending -= n
        if head >= c.count {
            current = nil
            head = 0
        }
    }

    public mutating func removeAll() {
        lanes.removeAll()
        current = nil
        head = 0
        pending = 0
    }
}

/// Delay-based pacing for bulk lanes, after LEDBAT. While the path's round
/// trip sits at its floor, bulk may keep up to `cap` bytes in the socket (in
/// flight plus unsent) and the cap grows; once queueing shows up as extra
/// delay, it shrinks. TCP alone fills every buffer on the path (a Wi-Fi
/// driver's especially), and a key's echo then queues behind output already
/// on the wire.
///
/// Pure: the time, the round trip and the socket's bytes come in, so the
/// simulated link drives it in virtual time.
public struct BulkPacer: Sendable {
    public var cap = 256 << 10
    public static let minCap = 32 << 10
    public static let maxCap = 8 << 20
    /// Extra delay over the floor that counts as a queue building.
    public static let tolerance: Duration = .milliseconds(3)
    public static let adjustEvery: Duration = .milliseconds(5)
    /// How long a floor is trusted before a higher sample may replace it
    /// (the path may have changed).
    public static let floorLife: Duration = .seconds(10)

    public private(set) var floor: Duration?
    private var floorAt: Duration = .zero
    private var adjustedAt: Duration?

    public init() {}

    /// Whether bulk output should wait now. `now` is time since any fixed
    /// epoch; `rtt` the latest round trip (nil if unknown); `socketBytes`
    /// what the socket holds, in flight and unsent.
    public mutating func holdsBulk(now: Duration, rtt: Duration?, socketBytes: Int) -> Bool {
        if let rtt, rtt > .zero {
            if floor == nil || rtt <= floor! || now - floorAt > Self.floorLife {
                floor = rtt
                floorAt = now
            }
            if let floor, adjustedAt.map({ now - $0 > Self.adjustEvery }) ?? true {
                adjustedAt = now
                if rtt > floor + Self.tolerance {
                    cap = max(Self.minCap, cap * 3 / 4)
                } else {
                    cap = min(Self.maxCap, cap + Self.minCap)
                }
            }
        }
        return socketBytes >= cap
    }
}
