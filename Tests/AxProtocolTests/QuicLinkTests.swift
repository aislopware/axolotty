import AxModel
import AxProtocol
import Foundation
import Synchronization
import Testing

/// The QUIC link from Swift, over loopback UDP: what `FramedConnection` promises, kept by a link
/// whose lanes are streams of their own.
@Suite("QUIC link", .timeLimit(.minutes(1)))
struct QuicLinkTests {
    /// What one side of a link heard, and a way to wait for it without sleeping.
    final class Heard: Sendable {
        private let state = Mutex<(frames: [Frame], closed: [String?])>(([], []))
        private let changed = AsyncStream<Void>.makeStream()

        func frame(_ f: Frame) {
            state.withLock { $0.frames.append(f) }
            changed.continuation.yield()
        }

        func closed(_ e: (any Error)?) {
            state.withLock { $0.closed.append(e.map { "\($0)" }) }
            changed.continuation.yield()
        }

        var frames: [Frame] { state.withLock { $0.frames } }
        var closes: [String?] { state.withLock { $0.closed } }

        func until(_ done: () -> Bool) async {
            var it = changed.stream.makeAsyncIterator()
            while !done() { _ = await it.next() }
        }
    }

    /// A server and a client endpoint on loopback, and the link between them, both started.
    static func pair() async throws -> (server: QuicLink, client: QuicLink, s: Heard, c: Heard, ends: [QuicEndpoint]) {
        let server = try QuicEndpoint(address: "::1", port: 0, server: true)
        let client = try QuicEndpoint(address: "::1", port: 0, server: false)
        let (accepted, k) = AsyncStream<QuicLink>.makeStream()
        server.listen { link, _ in k.yield(link) }
        let c = try await client.connect(host: "::1", port: server.port)
        let s = Heard(), ch = Heard()
        c.start(onFrame: ch.frame, onClose: ch.closed)
        // The client speaks first, as its hello does: the server sees lane 0 with it.
        c.send(.control(Data("hello".utf8)))
        var it = accepted.makeAsyncIterator()
        let sl = try #require(await it.next())
        sl.start(onFrame: s.frame, onClose: s.closed)
        return (sl, c, s, ch, [server, client])
    }

    @Test func framesCrossEveryLaneInOrderBothWays() async throws {
        let (server, client, s, c, ends) = try await Self.pair()
        defer { ends.forEach { $0.close() } }
        let a = PaneID(), b = PaneID()
        // Server to client: two panes' output interleaved, one far larger, each in order.
        let chunk = Data(repeating: 7, count: 30_000)
        for i in 0 ..< 60 {
            server.send(.output(pane: a, offset: UInt64(i * chunk.count), bytes: chunk), lane: FramedConnection.lane(a))
            server.send(.output(pane: b, offset: UInt64(i), bytes: Data([UInt8(i)])), lane: FramedConnection.lane(b),
                        priority: LanePriority.echo)
        }
        server.send(.control(Data("welcome".utf8)))
        await c.until { c.frames.count == 121 }
        let byPane = Dictionary(grouping: c.frames.compactMap { f -> (PaneID, UInt64)? in
            if case let .output(p, o, _) = f { return (p, o) }
            return nil
        }, by: \.0).mapValues { $0.map(\.1) }
        #expect(byPane[a] == (0 ..< 60).map { UInt64($0 * chunk.count) }, "a lane keeps its order")
        #expect(byPane[b] == (0 ..< 60).map { UInt64($0) })
        #expect(c.frames.contains(.control(Data("welcome".utf8))))
        await s.until { !s.frames.isEmpty }
        #expect(s.frames == [.control(Data("hello".utf8))])
        #expect(server.pendingBytes < 2 << 20, "handed on, not piling up")
        #expect(client.roundTrip != nil)
    }

    @Test func aCloseIsHeardOnceOnEachSideAndNothingAfter() async throws {
        let (server, client, s, c, ends) = try await Self.pair()
        defer { ends.forEach { $0.close() } }
        client.close()
        await c.until { !c.closes.isEmpty }
        await s.until { !s.closes.isEmpty }
        #expect(c.closes == [nil] && s.closes == [nil], "closed on purpose is no error")
        #expect(client.isClosed && server.isClosed)
        server.send(.control(Data("late".utf8)))
        client.close()
        #expect(c.closes.count == 1)
    }

    @Test func aLocalErrorIsWhatTheClosingSideHears() async throws {
        let (_, client, _, c, ends) = try await Self.pair()
        defer { ends.forEach { $0.close() } }
        client.close(QuicError("bad frame"))
        await c.until { !c.closes.isEmpty }
        #expect(c.closes == ["bad frame"])
    }

    @Test func aDialToNobodyFailsInsteadOfHanging() async throws {
        let client = try QuicEndpoint(address: "::1", port: 0, server: false)
        defer { client.close() }
        let nobody = try QuicEndpoint(address: "::1", port: 0, server: false)  // bound, never accepts
        defer { nobody.close() }
        await #expect(throws: QuicError.self) {
            _ = try await client.connect(host: "::1", port: nobody.port, timeout: .milliseconds(300))
        }
    }
}
