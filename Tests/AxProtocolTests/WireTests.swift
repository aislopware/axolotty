import AxModel
import AxProtocol
import AxTestSupport
import Foundation
import Testing

@Suite struct WireTests {
    let pane = PaneID()

    var frames: [Frame] {
        [
            .control(Data(#"{"ping":{"_0":7}}"#.utf8)),
            .output(pane: pane, offset: 0, bytes: Data("hello\u{1b}[1m".utf8)),
            .output(pane: pane, offset: 1 << 40, bytes: Data()),
            .snapshot(pane: pane, at: 99, flags: [.first, .last], bytes: Data(repeating: 0xAB, count: 5000)),
            .ack(pane: pane, offset: 12345),
        ]
    }

    @Test("frames survive any chunking of the byte stream", arguments: 1 ... 25)
    func chunking(seed: Int) throws {
        var rng = SeededRNG(seed: UInt64(seed))
        let stream = frames.map(Wire.encode).reduce(Data(), +)
        var dec = FrameDecoder()
        var out: [Frame] = []
        var i = 0
        while i < stream.count {
            let n = Int.random(in: 1 ... 97, using: &rng)
            dec.feed(stream[i ..< min(i + n, stream.count)])
            i += n
            while let f = try dec.next() { out.append(f) }
        }
        #expect(out == frames)
    }

    @Test func rejectsOversizeAndUnknownFrames() {
        var dec = FrameDecoder(limit: 64)
        dec.feed(Wire.encode(.control(Data(repeating: 1, count: 100))))
        #expect(throws: WireError.frameTooLarge(102)) { try dec.next() }

        var dec2 = FrameDecoder()
        dec2.feed(Data([2, 0, 0, 0, 0x7F, 0]))
        #expect(throws: WireError.unknownType(0x7F)) { try dec2.next() }

        var dec3 = FrameDecoder()
        dec3.feed(Data([4, 0, 0, 0, 0x02, 0, 1, 2]))
        #expect(throws: WireError.malformed("short data frame")) { try dec3.next() }
    }

    @Test func messagesRoundTrip() throws {
        let intent = Intent.split(SessionID(), target: pane, new: PaneID(), axis: .vertical, before: false,
                                  recipe: SpawnRecipe(command: ["claude"], cwd: "/tmp", env: ["A": "1"]))
        let msgs: [ClientMessage] = [
            .hello(ClientHello(client: ClientID(), name: "Mac", platform: .macOS)),
            .intent(UUID(), intent),
            .key(pane, KeyInput(key: 30, mods: KeyInput.ctrl, text: "c")),
            .report(pane, id: "", state: .blocked, app: "claude", message: "Allow?"),
            .report(pane, id: "x", state: nil, app: "", message: ""),
        ]
        for m in msgs {
            var dec = FrameDecoder()
            dec.feed(try MessageCodec.frame(m))
            guard case let .control(data)? = try dec.next() else { Issue.record("no frame"); continue }
            let back = try MessageCodec.client(data)
            #expect(try MessageCodec.frame(back) == MessageCodec.frame(m))
        }
        var state = HostState(host: HostID(), name: "studio")
        state.apply(.renamed("studio 2"))
        let welcome = HostMessage.welcome(HostHello(host: state.host, name: "studio", epoch: UUID(), state: state))
        var dec = FrameDecoder()
        dec.feed(try MessageCodec.frame(welcome))
        guard case let .control(data)? = try dec.next(), case let .welcome(h) = try MessageCodec.host(data) else {
            Issue.record("bad welcome")
            return
        }
        #expect(h.state == state)
    }
}
