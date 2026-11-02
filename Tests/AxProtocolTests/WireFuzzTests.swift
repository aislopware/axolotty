import AxModel
import AxProtocol
import AxTestSupport
import Foundation
import Testing

/// A peer's bytes, mutated from a seed: what a remote host or a hostile
/// tailnet node can send. Structure-aware (valid frames, then flipped,
/// cut, spliced, their length fields set to the edges) and checked against
/// invariants, not just "it didn't crash". 2 000 inputs in the gate,
/// `AXFUZZ_RUNS=200000` for a long run; a failure names its seed
/// (`AXSEED=<n>` replays it). A trap kills the process before it can name
/// one: `AXFUZZ_TRACE=1` prints each seed as it starts, so the last is it.
@Suite("Wire, fuzzed")
struct WireFuzzTests {
    static let runs = Int(ProcessInfo.processInfo.environment["AXFUZZ_RUNS"] ?? "") ?? 2000
    static var seeds: [UInt64] {
        if let s = ProcessInfo.processInfo.environment["AXSEED"].flatMap(UInt64.init) { return [s] }
        return Array(1 ... UInt64(runs))
    }

    static func validFrames(_ rng: inout SimRNG) -> [Frame] {
        let pane = PaneID(raw: UUID(uuid: (UInt8(rng.next() & 0xFF), 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)))
        func bytes(_ n: Int) -> Data { Data((0 ..< n).map { _ in UInt8(rng.next() & 0xFF) }) }
        let hello = (try? MessageCodec.frame(ClientMessage.hello(ClientHello(client: ClientID(), name: "fuzz")))) ?? Data()
        let helloJSON = hello.count > 6 ? Data(hello.dropFirst(6)) : Data()
        return [
            .control(helloJSON),
            .output(pane: pane, offset: rng.next() >> 20, bytes: bytes(Int(rng.next() % 300))),
            .snapshot(pane: pane, at: rng.next() >> 30, flags: [.first], bytes: bytes(Int(rng.next() % 200))),
            .ack(pane: pane, offset: rng.next() >> 10),
            .control(Data(#"{"ping":{"_0":7}}"#.utf8)),
        ]
    }

    /// One mutation. `starts` are the frames' offsets in the unmutated
    /// stream, so a length field can be aimed at: random bytes alone almost
    /// never land a length a few bytes short of a frame's real one (a
    /// planted off-by-four in the data-frame check went unseen until this).
    static func mutate(_ d: inout Data, _ rng: inout SimRNG, starts: [Int]) {
        guard !d.isEmpty else { return }
        let i = Int(rng.next() % UInt64(d.count))
        switch rng.next() % 8 {
        case 7:
            // A frame's length nudged by a few bytes either way: a body cut short or overrun.
            let at = starts[Int(rng.next() % UInt64(starts.count))]
            guard at + 4 <= d.count else { return }
            let len = d[(d.startIndex + at) ..< (d.startIndex + at + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let nudged = Int64(UInt32(littleEndian: len)) + Int64(rng.next() % 17) - 8
            let v = UInt32(clamping: max(0, nudged)).littleEndian
            withUnsafeBytes(of: v) { d.replaceSubrange((d.startIndex + at) ..< (d.startIndex + at + 4), with: $0) }
        case 0: d[d.startIndex + i] ^= UInt8(1 << (rng.next() % 8))
        case 1: d[d.startIndex + i] = [0, 1, 0x7F, 0x80, 0xFF][Int(rng.next() % 5)]
        case 2: d = d.prefix(i)
        case 3:
            let n = min(Int(rng.next() % 64), d.count - i)
            d.insert(contentsOf: d[(d.startIndex + i) ..< (d.startIndex + i + n)], at: d.startIndex + i)
        case 4: d.insert(contentsOf: (0 ..< Int(rng.next() % 16)).map { _ in UInt8(rng.next() & 0xFF) }, at: d.startIndex + i)
        case 5:
            // A frame length at an edge.
            let edges: [UInt32] = [0, 1, 2, 3, 26, UInt32(Wire.maxFrame), UInt32(Wire.maxFrame + 1), .max]
            let v = edges[Int(rng.next() % UInt64(edges.count))].littleEndian
            let at = min(i, max(0, d.count - 4))
            withUnsafeBytes(of: v) { d.replaceSubrange((d.startIndex + at) ..< (d.startIndex + min(at + 4, d.count)), with: $0) }
        default: d.removeSubrange((d.startIndex + i) ..< (d.startIndex + min(i + Int(rng.next() % 32), d.count)))
        }
    }

    @Test func mutatedStreamsNeverCrashAndEveryFrameRoundTrips() throws {
        let trace = ProcessInfo.processInfo.environment["AXFUZZ_TRACE"] != nil
        for seed in Self.seeds {
            if trace { FileHandle.standardError.write(Data("AXSEED=\(seed)\n".utf8)) }
            var rng = SimRNG(seed: seed)
            let encoded = Self.validFrames(&rng).map(Wire.encode)
            var starts: [Int] = []
            var stream = Data()
            for e in encoded {
                starts.append(stream.count)
                stream += e
            }
            for _ in 0 ..< 1 + Int(rng.next() % 4) { Self.mutate(&stream, &rng, starts: starts) }
            var dec = FrameDecoder()
            var at = 0
            decoding: while at < stream.count {
                let n = 1 + Int(rng.next() % 200)
                dec.feed(stream[(stream.startIndex + at) ..< (stream.startIndex + min(at + n, stream.count))])
                at += n
                while true {
                    let f: Frame?
                    do { f = try dec.next() } catch { break decoding }  // a link closes on a bad frame
                    guard let f else { break }
                    // A frame the decoder accepts is one the encoder would write, and back.
                    let again = Wire.encode(f)
                    #expect(again.count <= Wire.maxFrame + 4, "seed \(seed)")
                    var d2 = FrameDecoder()
                    d2.feed(again)
                    #expect(try d2.next() == f, "seed \(seed): \(f) does not round-trip")
                    if case let .control(json) = f {
                        // Control payloads go to the JSON decoders: they may refuse, never trap.
                        _ = try? MessageCodec.client(json)
                        _ = try? MessageCodec.host(json)
                    }
                }
            }
        }
    }

    /// A length claiming more than the limit is refused from its header,
    /// before a byte of the body is buffered.
    @Test func aHugeLengthIsRefusedFromItsHeader() {
        var dec = FrameDecoder()
        withUnsafeBytes(of: UInt32.max.littleEndian) { dec.feed($0) }
        #expect(throws: WireError.frameTooLarge(Int(UInt32.max))) { try dec.next() }
    }

    /// A newer peer adds fields; an older one must still read the message.
    @Test func anUnknownFieldChangesNothing() throws {
        let hello = ClientHello(client: ClientID(), name: "Mac")
        let json = try JSONEncoder().encode(ClientMessage.hello(hello))
        var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        var inner = try #require(object["hello"] as? [String: Any])
        var payload = try #require(inner["_0"] as? [String: Any])
        payload["fromTheFuture"] = ["nested": [1, 2, 3]]
        inner["_0"] = payload
        object["hello"] = inner
        let widened = try JSONSerialization.data(withJSONObject: object)
        guard case let .hello(back) = try MessageCodec.client(widened) else {
            Issue.record("not a hello")
            return
        }
        #expect(back.name == hello.name && back.client == hello.client)
    }
}
