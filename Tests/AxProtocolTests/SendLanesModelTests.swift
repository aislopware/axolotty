import AxProtocol
import AxTestSupport
import Foundation
import Testing

/// `SendLanes` and `BulkPacer` against a model, through seeded random
/// sequences of operations. A failure prints its seed and the shortest
/// prefix of its operations that still fails; `AXSEED=<n>` replays one.
@Suite("Send lanes, modelled")
struct SendLanesModelTests {
    static var seeds: [UInt64] {
        if let s = ProcessInfo.processInfo.environment["AXSEED"].flatMap(UInt64.init) { return [s] }
        return Array(1 ... 300)
    }

    enum Op: CustomStringConvertible {
        case push(lane: Int, bytes: Int)
        case write(max: Int, holdBulk: Bool)

        var description: String {
            switch self {
            case let .push(l, b): "push(\(l), \(b))"
            case let .write(m, h): "write(\(m)\(h ? ", hold" : ""))"
            }
        }
    }

    static func ops(_ seed: UInt64, count: Int = 120) -> [Op] {
        var rng = SimRNG(seed: seed)
        return (0 ..< count).map { _ in
            if rng.unit() < 0.55 {
                // Sizes lean to the edges: tiny echoes, the interactive bound, whole frames.
                let sizes = [1, 64, SendLanes.interactiveBytes, SendLanes.interactiveBytes + 1, Wire.maxData]
                let bytes = rng.unit() < 0.5 ? sizes[Int(rng.next() % UInt64(sizes.count))] : 1 + Int(rng.next() % 9000)
                return .push(lane: Int(rng.next() % 4), bytes: bytes)
            }
            return .write(max: 1 + Int(rng.next() % 12000), holdBulk: rng.unit() < 0.3)
        }
    }

    /// Runs `ops` against the model; returns the first broken rule.
    static func check(_ ops: [Op]) -> String? {
        var lanes = SendLanes()
        var model: [Int: [(id: Int, bytes: Int)]] = [:]  // per lane, oldest first
        var nextID = 0
        var writing: (lane: Int, id: Int, left: Int)?
        func total() -> Int { model.values.flatMap { $0 }.reduce(0) { $0 + $1.bytes } + (writing?.left ?? 0) }

        for (i, op) in ops.enumerated() {
            switch op {
            case let .push(lane, bytes):
                var d = Data(count: max(bytes, 8))
                withUnsafeBytes(of: Int64(nextID)) { d.replaceSubrange(0 ..< 8, with: $0) }
                lanes.push(d, lane: lane)
                model[lane, default: []].append((nextID, d.count))
                nextID += 1

            case let .write(maxBytes, hold):
                let starting = writing == nil
                var expected: Int?
                if let w = writing {
                    expected = w.lane
                } else if !(model[SendLanes.control] ?? []).isEmpty {
                    expected = SendLanes.control
                } else {
                    var best: (lane: Int, bytes: Int)?
                    for lane in model.keys.sorted() {
                        let queued = model[lane]!.reduce(0) { $0 + $1.bytes }
                        guard queued > 0 else { continue }
                        if best == nil || queued < best!.bytes { best = (lane, queued) }
                    }
                    if let best, !(hold && best.bytes > SendLanes.interactiveBytes) { expected = best.lane }
                }
                guard let f = lanes.next(holdBulk: hold) else {
                    if expected != nil { return "op \(i) \(op): nothing to write, expected lane \(expected!)" }
                    continue
                }
                guard let lane = expected else { return "op \(i) \(op): wrote from lane \(lanes.currentLane), expected nothing" }
                if lanes.currentLane != lane { return "op \(i) \(op): lane \(lanes.currentLane), expected \(lane)" }
                let id = Int(f.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })
                if starting {
                    let head = model[lane]!.removeFirst()
                    if head.id != id { return "op \(i) \(op): frame \(id) out of order in lane \(lane), expected \(head.id)" }
                    writing = (lane, id, head.bytes)
                } else if id != writing!.id {
                    return "op \(i) \(op): frame \(id) interleaved into frame \(writing!.id)"
                }
                let n = min(maxBytes, f.count - lanes.head)
                lanes.wrote(n)
                writing!.left -= n
                if writing!.left == 0 { writing = nil }
            }
            if lanes.pending != total() { return "op \(i) \(op): pending \(lanes.pending), model \(total())" }
            for l in 0 ..< 4 {
                let m = (model[l] ?? []).reduce(0) { $0 + $1.bytes } + (writing?.lane == l ? writing!.left : 0)
                if lanes.pending(lane: l) != m { return "op \(i) \(op): lane \(l) pending \(lanes.pending(lane: l)), model \(m)" }
            }
        }
        return nil
    }

    /// The smallest failing case: cut the tail, then drop single operations
    /// while it still fails (delta debugging, one at a time).
    static func shrink(_ ops: [Op]) -> [Op] {
        var ops = ops
        while ops.count > 1, check(Array(ops.dropLast())) != nil { ops.removeLast() }
        var i = 0
        while i < ops.count {
            var fewer = ops
            fewer.remove(at: i)
            if check(fewer) != nil { ops = fewer } else { i += 1 }
        }
        return ops
    }

    @Test func lanesKeepOrderPriorityAndCount() {
        for seed in Self.seeds {
            let ops = Self.ops(seed)
            guard let failure = Self.check(ops) else { continue }
            let short = Self.shrink(ops)
            Issue.record("seed \(seed) (AXSEED=\(seed)): \(Self.check(short) ?? failure)\n  \(short.map(\.description).joined(separator: "; "))")
            return
        }
    }

    /// The pacer, over seeded round trips: the cap stays in bounds, never
    /// shrinks while the path is at its floor, and shrinks once delay builds.
    @Test func thePacerFollowsTheDelay() {
        for seed in Self.seeds.prefix(100) {
            var rng = SimRNG(seed: seed)
            var p = BulkPacer()
            var now: Duration = .zero
            let base = Duration.milliseconds(5 + Int(rng.next() % 40))
            for _ in 0 ..< 400 {
                now += .milliseconds(1 + Int(rng.next() % 9))
                let extra = rng.unit() < 0.5 ? Duration.zero : .milliseconds(Int(rng.next() % 60))
                let before = p.cap
                _ = p.holdsBulk(now: now, rtt: base + extra, socketBytes: Int(rng.next() % (4 << 20)))
                #expect(p.cap >= BulkPacer.minCap && p.cap <= BulkPacer.maxCap, "seed \(seed)")
                if extra <= BulkPacer.tolerance { #expect(p.cap >= before, "seed \(seed): shrank at the floor") }
                #expect(p.floor! <= base + extra, "seed \(seed)")
            }
            // A standing queue: the cap falls to its least within a second.
            for _ in 0 ..< 200 {
                now += .milliseconds(6)
                _ = p.holdsBulk(now: now, rtt: base + .milliseconds(40), socketBytes: 0)
            }
            #expect(p.cap == BulkPacer.minCap, "seed \(seed)")
            let holds = p.holdsBulk(now: now + .milliseconds(6), rtt: base + .milliseconds(40), socketBytes: BulkPacer.minCap)
            #expect(holds, "seed \(seed)")
        }
    }
}
