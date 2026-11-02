// A simulated link, in virtual time, for the host's send path.
//
// The real network is a bad laboratory: a path changes under you (relay or
// direct, Wi-Fi rate, a sleeping laptop) and no run can be repeated, so no
// two runs can be compared. Following Slopty's `slopty-shape`, the faults go
// in a model below the transport: a seeded shaper (delay, jitter, loss, a
// rate and the bottleneck's queue) carries the segments of a small TCP model
// (slow start and AIMD, SACK recovery, a tail-loss probe and RTO,
// in-order delivery, so head-of-line blocking is real), and the code under
// test (`SendLanes`, `BulkPacer`) decides what the host writes into it.
//
// Nothing reads a clock: time is elapsed `Duration` from the run's start and
// every draw comes from the seed, so a seed repeats its run exactly, and
// seconds of traffic pass in milliseconds.
import AxProtocol
import Foundation

// MARK: - Seeded randomness

/// xorshift64* (Slopty's), so a run repeats from its seed.
public struct SimRNG: Sendable {
    private var x: UInt64

    public init(seed: UInt64) { x = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    public mutating func next() -> UInt64 {
        x ^= x >> 12
        x ^= x << 25
        x ^= x >> 27
        return x &* 0x2545_F491_4F6C_DD1D
    }

    /// A draw in 0 ..< 1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - The link

/// One direction's faults.
public struct LinkModel: Sendable, Equatable {
    /// One-way delay added to every packet.
    public var delay: Duration
    /// Added on top of `delay`, spread over 0 ..< jitter; packets still leave in order.
    public var jitter: Duration
    /// Share of packets lost, 0 ... 1.
    public var loss: Double
    /// Bytes per second; 0 is unlimited.
    public var rate: Int
    /// How long the bottleneck's buffer holds at `rate`; a packet that would
    /// wait longer is dropped, as a router's full queue drops it.
    public var queue: Duration

    public init(delay: Duration, jitter: Duration = .zero, loss: Double = 0, rate: Int = 0, queue: Duration = .milliseconds(100)) {
        self.delay = delay
        self.jitter = jitter
        self.loss = loss
        self.rate = rate
        self.queue = queue
    }
}

/// One direction of a shaped link: when a packet arrives, or that it doesn't.
public struct Shaper: Sendable {
    public var link: LinkModel
    private var rng: SimRNG
    /// When the queue empties if nothing more arrives.
    private var drainsAt: Duration = .zero
    /// The last arrival, so jitter never reorders.
    private var lastArrival: Duration = .zero
    public private(set) var sent = 0, lost = 0, overflowed = 0

    public init(_ link: LinkModel, seed: UInt64) {
        self.link = link
        rng = SimRNG(seed: seed)
    }

    /// The standing queue a packet arriving now would wait behind.
    public func queueDelay(at now: Duration) -> Duration { max(.zero, drainsAt - now) }

    /// When a packet of `bytes` sent at `now` arrives, or nil when it is lost.
    public mutating func admit(_ bytes: Int, at now: Duration) -> Duration? {
        if link.loss > 0, rng.unit() < link.loss {
            lost += 1
            return nil
        }
        drainsAt = max(drainsAt, now)
        let leaves = drainsAt
        if link.rate > 0 {
            if leaves - now > link.queue {
                overflowed += 1
                return nil
            }
            drainsAt += .nanoseconds(Int64(bytes) * 1_000_000_000 / Int64(link.rate))
        }
        sent += 1
        let jitter: Duration = link.jitter > .zero ? link.jitter * rng.unit() : .zero
        let at = max(lastArrival, leaves + link.delay + jitter)
        lastArrival = at
        return at
    }
}

// MARK: - Events

/// A binary min-heap of timed events, ties broken by insertion order.
struct EventQueue<E> {
    private var heap: [(at: Duration, n: Int, e: E)] = []
    private var count = 0
    var isEmpty: Bool { heap.isEmpty }

    mutating func push(_ e: E, at: Duration) {
        count += 1
        heap.append((at, count, e))
        var i = heap.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard less(heap[i], heap[p]) else { break }
            heap.swapAt(i, p)
            i = p
        }
    }

    mutating func pop() -> (at: Duration, e: E)? {
        guard !heap.isEmpty else { return nil }
        heap.swapAt(0, heap.count - 1)
        let top = heap.removeLast()
        var i = 0
        while true {
            let l = 2 * i + 1, r = l + 1
            var m = i
            if l < heap.count, less(heap[l], heap[m]) { m = l }
            if r < heap.count, less(heap[r], heap[m]) { m = r }
            if m == i { break }
            heap.swapAt(i, m)
            i = m
        }
        return (top.at, top.e)
    }

    private func less(_ a: (at: Duration, n: Int, e: E), _ b: (at: Duration, n: Int, e: E)) -> Bool {
        a.at < b.at || (a.at == b.at && a.n < b.n)
    }
}

// MARK: - The run

/// How the host schedules its writes: the arms an experiment compares.
public enum SendPolicy: String, Sendable, CaseIterable {
    /// One FIFO for everything (the send path before lanes).
    case fifo
    /// A lane per pane (`SendLanes`), no pacing.
    case lanes
    /// Lanes and delay-based pacing of bulk (`BulkPacer`): what tailnet links run.
    case paced
}

/// One experiment: a pane typed into while another floods output.
public struct EchoRun: Sendable {
    public var down: LinkModel
    public var up: LinkModel
    public var policy: SendPolicy
    public var seed: UInt64
    public var keys = 200
    public var keyEvery: Duration = .milliseconds(25)
    /// How fast the flooding pane produces output (bytes/s); 0 for no flood.
    public var floodRate = 40_000_000
    /// The downlink's rate falls to this share when the typing starts (Wi-Fi, LTE), or 1.
    public var rateAfterWarmup = 1.0
    public var warmup: Duration = .seconds(1)
    /// The host's resync rule (`PaneLimits.lagBytes`).
    public var lagBytes = 2 << 20
    /// The socket's TCP_NOTSENT_LOWAT.
    public var lowat = Wire.notSentLowat
    /// The largest output frame the host cuts (`Wire.maxData`).
    public var frameBytes = Wire.maxData
    public var mss = 1228

    public init(down: LinkModel, up: LinkModel? = nil, policy: SendPolicy, seed: UInt64) {
        self.down = down
        self.up = up ?? LinkModel(delay: down.delay, jitter: down.jitter, loss: down.loss)
        self.policy = policy
        self.seed = seed
    }
}

/// What a run measured.
public struct EchoResult: Sendable, Equatable {
    /// Key to echo, per key that came back, in key order.
    public var echoes: [Duration]
    public var lostKeys: Int
    /// Flood bytes delivered per second of typing.
    public var floodRate: Double
    public var resyncs: Int
    public var retransmits: Int
    /// Retransmission timeouts and tail-loss probes that fired.
    public var timeouts: Int
    public var probes: Int
    /// A digest of every echo time: two runs of one seed must agree.
    public var digest: UInt64
    /// Pooled results: the seeds that lost a key, to replay with `AXSEED`.
    public var lostIn: [UInt64] = []

    public init(echoes: [Duration], lostKeys: Int = 0, floodRate: Double = 0, resyncs: Int = 0, retransmits: Int = 0,
                timeouts: Int = 0, probes: Int = 0, digest: UInt64 = 0) {
        self.echoes = echoes
        self.lostKeys = lostKeys
        self.floodRate = floodRate
        self.resyncs = resyncs
        self.retransmits = retransmits
        self.timeouts = timeouts
        self.probes = probes
        self.digest = digest
    }

    public func quantile(_ q: Double) -> Duration {
        let s = echoes.sorted()
        guard !s.isEmpty else { return .seconds(999) }
        return s[min(s.count - 1, Int(Double(s.count) * q))]
    }

    public var summary: String {
        func ms(_ d: Duration) -> String { String(format: "%.1f", Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000) }
        return "p50=\(ms(quantile(0.5))) p90=\(ms(quantile(0.9))) p99=\(ms(quantile(0.99))) max=\(ms(quantile(1))) ms"
            + " lost=\(lostKeys) flood=\(String(format: "%.2f", floodRate / 1e6)) MB/s resyncs=\(resyncs) retx=\(retransmits) rto=\(timeouts) tlp=\(probes)"
            + (lostIn.isEmpty ? "" : " lost in seeds \(lostIn)")
    }
}

extension EchoRun {
    private enum Event {
        case segment(seq: Int, len: Int)
        /// A cumulative ack and the segments held past it (SACK, idealised: every block).
        case ack(Int, sacked: [Int])
        case keyAtHost(Int)
        case echoReady(Int)
        case hostWake
        case floodTick
        case keySend(Int)
        case probe(Int)
        case retransmitTimeout(Int)
        case rackCheck
        case rateDrop
    }

    private struct Sent {
        var len: Int
        var at: Duration
        var retransmitted: Bool
    }

    /// Runs the experiment to its end. Deterministic in `seed`.
    /// `AXSIM_TRACE=1` prints the sender's state every 250 ms and the events by kind.
    public func run() -> EchoResult {
        let tracing = ProcessInfo.processInfo.environment["AXSIM_TRACE"] != nil
        var events = EventQueue<Event>()
        var downShaper = Shaper(down, seed: seed &* 2 &+ 1)
        var upShaper = Shaper(up, seed: seed &* 2 &+ 2)
        let lanesOn = policy != .fifo
        var lanes = SendLanes()
        var pacer: BulkPacer? = policy == .paced ? BulkPacer() : nil
        let echoLane = 1, floodLane = 2

        // Sender (the host's TCP).
        var written = 0, sndNxt = 0, sndUna = 0
        var inflight: [Int: Sent] = [:]
        var order: [Int] = []  // seqs in flight, ascending (head at orderHead)
        var orderHead = 0
        var cwnd = 10 * mss, ssthresh = Int.max
        var recovering = false, recoverAt = 0
        // The SACK scoreboard and RACK's clock (RFC 8985): a segment is lost
        // once one sent after it has arrived and a reordering window passed.
        var sacked = Set<Int>(), sackedBytes = 0, topSacked = -1
        var rackSent: Duration = .seconds(-1), rackRTT: Duration = .zero, rackCheckArmed = false
        var srtt: Duration?, rttvar: Duration = .zero, rttcur: Duration?
        var timerGen = 0, rto: Duration = .milliseconds(200), probed = false
        var retransmits = 0, timeouts = 0, probes = 0

        // Receiver (the client).
        var rcvNxt = 0
        var outOfOrder: [Int: Int] = [:]
        var frames: [(start: Int, end: Int, key: Int)] = []  // key -1: flood
        var frameHead = 0
        var keySent: [Duration] = Array(repeating: .zero, count: keys)
        var echoes: [Duration?] = Array(repeating: nil, count: keys)
        var floodDelivered = 0

        // Host application.
        var wakeArmed = false, resyncing = false, resyncs = 0
        let typingStarts = warmup
        let typingEnds = warmup + keyEvery * keys
        let end = warmup + keyEvery * keys + .seconds(2)

        func frame(key: Int, size: Int) -> Data {
            var d = Data(count: size)
            withUnsafeBytes(of: Int64(key).littleEndian) { d.replaceSubrange(0 ..< 8, with: $0) }
            return d
        }
        func keyOf(_ d: Data) -> Int { Int(d.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }) }

        func armTimers(_ now: Duration) {
            timerGen += 1
            probed = false
            guard sndNxt > sndUna else { return }
            let pto = max(.milliseconds(10), (srtt ?? .milliseconds(100)) * 2)
            events.push(.probe(timerGen), at: now + pto)
        }

        func transmit(_ seq: Int, _ len: Int, retx: Bool, _ now: Duration) {
            inflight[seq] = Sent(len: len, at: now, retransmitted: retx || inflight[seq]?.retransmitted == true)
            if retx { retransmits += 1 }
            if let at = downShaper.admit(len + 40, at: now) { events.push(.segment(seq: seq, len: len), at: at) }
        }

        func sendNew(_ now: Duration) {
            var sentAny = false
            while sndNxt < written, sndNxt - sndUna - sackedBytes < cwnd {
                let len = min(mss, written - sndNxt)
                order.append(sndNxt)
                transmit(sndNxt, len, retx: false, now)
                sndNxt += len
                sentAny = true
            }
            if sentAny { armTimers(now) }
        }

        func wakeHost(_ now: Duration) { events.push(.hostWake, at: now) }

        func hostFlush(_ now: Duration) {
            while written - sndNxt < lowat {
                let hold = pacer?.holdsBulk(now: now, rtt: rttcur.map { .milliseconds(Int(($0 / .milliseconds(1)).rounded())) },
                                            socketBytes: written - sndUna) ?? false
                guard let f = lanes.next(holdBulk: hold) else {
                    if hold, lanes.choose() != nil, !wakeArmed {
                        wakeArmed = true
                        events.push(.hostWake, at: now + .milliseconds(2))
                    }
                    break
                }
                let n = f.count - lanes.head
                if lanes.head == 0 { frames.append((written, written + f.count, keyOf(f))) }
                written += n
                lanes.wrote(n)
                sendNew(now)
            }
        }

        /// RACK: resend every segment sent before the latest one delivered,
        /// once a round trip and a reordering window have passed since it went.
        func detectLosses(_ now: Duration) {
            // Only a segment below one already delivered can be judged lost.
            guard rackSent >= .zero, topSacked >= sndUna else { return }
            let window = max(.milliseconds(1), (srtt ?? .milliseconds(10)) / 4)
            var lostAny = false
            var nextCheck: Duration?
            var i = orderHead
            while i < order.count, order[i] < topSacked {
                let seq = order[i]
                i += 1
                guard !sacked.contains(seq), let seg = inflight[seq], seg.at < rackSent else { continue }
                let due = seg.at + rackRTT + window
                if now >= due {
                    transmit(seq, seg.len, retx: true, now)
                    lostAny = true
                } else {
                    nextCheck = min(nextCheck ?? due, due)
                }
            }
            if lostAny, !recovering {
                recovering = true
                recoverAt = sndNxt
                ssthresh = max(2 * mss, (sndNxt - sndUna - sackedBytes) / 2)
                cwnd = ssthresh
            }
            if let nextCheck, !rackCheckArmed {
                rackCheckArmed = true
                events.push(.rackCheck, at: nextCheck)
            }
        }

        func deliver(_ now: Duration) {
            while frameHead < frames.count, frames[frameHead].end <= rcvNxt {
                let f = frames[frameHead]
                frameHead += 1
                if f.key >= 0 {
                    if echoes[f.key] == nil { echoes[f.key] = now - keySent[f.key] }
                } else if now >= typingStarts, now < typingEnds {
                    floodDelivered += f.end - f.start
                }
            }
        }

        events.push(.floodTick, at: .zero)
        for k in 0 ..< keys { events.push(.keySend(k), at: warmup + keyEvery * k) }
        if rateAfterWarmup != 1 { events.push(.rateDrop, at: warmup) }

        var counts: [String: Int] = [:]
        defer { if tracing { print("EVENTS", counts.sorted { $0.key < $1.key }) } }
        while let (now, e) = events.pop(), now <= end {
            if tracing { counts["\(e)".prefix { $0 != "(" }.description, default: 0] += 1 }
            switch e {
            case .rateDrop:
                downShaper.link.rate = Int(Double(down.rate) * rateAfterWarmup)

            case .floodTick:
                guard floodRate > 0 else { break }
                if tracing, (now / .milliseconds(1)).truncatingRemainder(dividingBy: 250) < 0.5 {
                    print("T \(now) cwnd=\(cwnd) flight=\(sndNxt - sndUna) unsent=\(written - sndNxt) una=\(sndUna) rcv=\(rcvNxt) rec=\(recovering) q=\(downShaper.queueDelay(at: now)) lanes=\(lanes.pending) ooo=\(outOfOrder.count) sacked=\(sacked.count) rto=\(rto)")
                }
                if resyncing {
                    if lanes.pending(lane: lanesOn ? floodLane : 0) < 64 << 10 {
                        // Skip the backlog: a snapshot at the head.
                        lanes.push(frame(key: -1, size: 40 << 10), lane: lanesOn ? floodLane : 0)
                        resyncing = false
                    }
                } else {
                    var budget = floodRate / 1000
                    while budget > 0 {
                        if lanes.pending(lane: lanesOn ? floodLane : 0) > lagBytes {
                            resyncing = true
                            resyncs += 1
                            break
                        }
                        let n = min(frameBytes, budget)
                        lanes.push(frame(key: -1, size: max(n, 8)), lane: lanesOn ? floodLane : 0)
                        budget -= n
                    }
                }
                hostFlush(now)
                events.push(.floodTick, at: now + .milliseconds(1))

            case let .keySend(k):
                keySent[k] = now
                // A lost key is resent: by the client's tail-loss probe two round
                // trips on, then on its retransmission timer, doubling from 200 ms.
                // It is late, never lost (one resend alone lost 2 keys in 200 seeds).
                var send = now, wait = (down.delay + up.delay) * 4
                while true {
                    if let at = upShaper.admit(60, at: send) {
                        events.push(.keyAtHost(k), at: at)
                        break
                    }
                    send += wait
                    wait = max(wait * 2, .milliseconds(200))
                }

            case let .keyAtHost(k):
                // The program's echo through the PTY.
                events.push(.echoReady(k), at: now + .microseconds(200))

            case let .echoReady(k):
                lanes.push(frame(key: k, size: 64), lane: lanesOn ? echoLane : 0)
                hostFlush(now)

            case .hostWake:
                wakeArmed = false
                hostFlush(now)

            case let .segment(seq, len):
                if seq == rcvNxt {
                    rcvNxt += len
                    while let l = outOfOrder.removeValue(forKey: rcvNxt) { rcvNxt += l }
                    deliver(now)
                } else if seq > rcvNxt {
                    outOfOrder[seq] = len
                }
                if let at = upShaper.admit(40, at: now) { events.push(.ack(rcvNxt, sacked: Array(outOfOrder.keys)), at: at) }

            case let .ack(a, blocks):
                let before = written - sndNxt
                var progressed = false
                /// RACK: remember the latest send among segments known delivered.
                func delivered(_ seg: Sent) {
                    if seg.at > rackSent {
                        rackSent = seg.at
                        rackRTT = now - seg.at
                    }
                }
                for seq in blocks where !sacked.contains(seq) {
                    guard seq >= sndUna, let seg = inflight[seq] else { continue }
                    sacked.insert(seq)
                    sackedBytes += seg.len
                    topSacked = max(topSacked, seq)
                    delivered(seg)
                }
                if a > sndUna {
                    progressed = true
                    var acked = 0
                    var sample: Duration?
                    while orderHead < order.count, order[orderHead] < a {
                        let seq = order[orderHead]
                        orderHead += 1
                        if let seg = inflight.removeValue(forKey: seq) {
                            if sacked.remove(seq) != nil { sackedBytes -= seg.len } else { acked += seg.len }
                            delivered(seg)
                            if !seg.retransmitted { sample = now - seg.at }
                        }
                    }
                    if orderHead > 4096 {
                        order.removeFirst(orderHead)
                        orderHead = 0
                    }
                    sndUna = a
                    if let r = sample {
                        rttcur = r
                        if let s = srtt {
                            let gap: Duration = s > r ? s - r : r - s
                            let v3: Duration = rttvar * 3
                            rttvar = (v3 + gap) / 4
                            let s7: Duration = s * 7
                            srtt = (s7 + r) / 8
                        } else {
                            srtt = r
                            rttvar = r / 2
                        }
                    }
                    if let s = srtt { rto = max(.milliseconds(200), s + rttvar * 4) }
                    if recovering, a >= recoverAt { recovering = false }
                    if !recovering {
                        if cwnd < ssthresh { cwnd += acked } else { cwnd += max(1, mss * acked / cwnd) }
                    }
                }
                detectLosses(now)
                if progressed { armTimers(now) }
                sendNew(now)
                if before >= lowat, written - sndNxt < lowat { wakeHost(now) }

            case .rackCheck:
                rackCheckArmed = false
                detectLosses(now)

            case let .probe(gen):
                guard gen == timerGen, sndNxt > sndUna else { break }
                if !probed {
                    // Tail-loss probe: resend the newest unacknowledged segment, so a lone loss is heard of.
                    probed = true
                    probes += 1
                    if let last = order.last, !sacked.contains(last), let seg = inflight[last] { transmit(last, seg.len, retx: true, now) }
                    events.push(.retransmitTimeout(gen), at: now + rto)
                }

            case let .retransmitTimeout(gen):
                guard gen == timerGen, sndNxt > sndUna, let seg = inflight[sndUna] else { break }
                timeouts += 1
                ssthresh = max(2 * mss, (sndNxt - sndUna - sackedBytes) / 2)
                cwnd = mss
                recovering = true
                recoverAt = sndNxt
                transmit(sndUna, seg.len, retx: true, now)
                rto = min(rto * 2, .seconds(60))
                timerGen += 1
                events.push(.retransmitTimeout(timerGen), at: now + rto)
            }
        }

        var digest: UInt64 = 0xCBF2_9CE4_8422_2325
        for e in echoes {
            let v = UInt64(bitPattern: (e ?? .seconds(-1)).components.attoseconds / 1000)
            digest = (digest ^ v) &* 0x100_0000_01B3
        }
        let typed = Double((keyEvery * keys) / .seconds(1))
        return EchoResult(echoes: echoes.compactMap { $0 }, lostKeys: echoes.filter { $0 == nil }.count,
                          floodRate: Double(floodDelivered) / max(typed, 0.001), resyncs: resyncs,
                          retransmits: retransmits, timeouts: timeouts, probes: probes, digest: digest)
    }
}
