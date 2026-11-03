@testable import AxHost
import AxModel
import AxProtocol
import Foundation
import Testing

/// A key may arrive twice, once on the stream and once as a datagram copy: it is typed once,
/// in order, from whichever came first.
@Suite("Input copies")
struct InputCopiesTests {
    final class NoLink: FrameLink, @unchecked Sendable {
        let queue = DispatchQueue(label: "nolink")
        var isClosed: Bool { false }
        var pendingBytes: Int { 0 }
        func pendingBytes(lane _: Int) -> Int { 0 }
        func start(onFrame _: @escaping (Frame) -> Void, onClose _: @escaping ((any Error)?) -> Void) {}
        func send(_: Data, lane _: Int, priority _: Int32) {}
        func close(_: (any Error)?) {}
        var bannerText: String { "" }
    }

    @Test func eachNumberIsAppliedOnceFromWhicheverComesFirst() {
        let link = Server.Link(conn: NoLink())
        var typed: [UInt64] = []
        func arrive(_ seq: UInt64, copy: Bool) { if link.admits(seq, copy: copy) { typed.append(seq) } }
        arrive(0, copy: false)
        arrive(1, copy: true)  // the copy won the race
        arrive(0, copy: true)  // late copy
        arrive(1, copy: false)  // the stream's, after its copy
        arrive(3, copy: true)  // 2 was lost and is on its way again: not typed out of turn
        arrive(2, copy: false)
        arrive(3, copy: false)
        arrive(3, copy: true)
        #expect(typed == [0, 1, 2, 3])
    }

    @Test func numberedInputCrossesTheWireAndOnlyInputIsNumbered() throws {
        let pane = PaneID()
        let m = ClientMessage.numbered(7, .key(pane, KeyInput(key: 0, text: "a")))
        guard case let .control(json) = try #require(try FrameDecoder.one(MessageCodec.frame(m))),
              case let .numbered(seq, .key(p, k)) = try MessageCodec.client(json) else {
            Issue.record("not a numbered key")
            return
        }
        #expect(seq == 7 && p == pane && k.text == "a")
        #expect(m.priority == LanePriority.echo, "a numbered key still goes first")
        #expect(!ClientMessage.numbered(1, .numbered(2, .text(pane, "x"))).isInput)
        #expect(!ClientMessage.ping(1).isInput)
    }
}

extension FrameDecoder {
    static func one(_ data: Data) throws -> Frame? {
        var d = FrameDecoder()
        d.feed(data)
        return try d.next()
    }
}
