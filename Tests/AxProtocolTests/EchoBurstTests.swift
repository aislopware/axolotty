import AxModel
import AxProtocol
import Foundation
import Testing

/// What goes ahead of everything on a QUIC link: a key, and the output that answers it.
@Suite("Echo lift")
struct EchoBurstTests {
    let t0 = ContinuousClock.now

    @Test func outputNobodyAskedForKeepsItsPlace() {
        var burst = EchoBurst()
        #expect(burst.priority(t0) == LanePriority.normal)
        #expect(burst.priority(t0 + .seconds(5)) == LanePriority.normal)
    }

    @Test func aKeysEchoAndItsRepaintGoFirstThenTheRestWaits() {
        var burst = EchoBurst()
        burst.arm(t0)
        let reads = (0 ..< 4).map { burst.priority(t0 + .milliseconds(1 + $0)) }
        #expect(reads == [LanePriority.echo, LanePriority.echo, LanePriority.normal, LanePriority.normal],
                "two reads, so a flood beside the typing stays where it was")
        burst.arm(t0 + .milliseconds(10))
        #expect(burst.priority(t0 + .milliseconds(11)) == LanePriority.echo, "every key buys its own")
    }

    @Test func outputLongAfterTheKeyIsNotItsEcho() {
        var burst = EchoBurst()
        burst.arm(t0)
        #expect(burst.priority(t0 + EchoBurst.window) == LanePriority.echo, "the window's edge still counts")
        burst.arm(t0)
        #expect(burst.priority(t0 + EchoBurst.window + .microseconds(1)) == LanePriority.normal)
    }

    @Test func aPersonsInputLeavesAheadOfAFileAndTheRestDoesNot() {
        let pane = PaneID()
        let typed: [ClientMessage] = [
            .key(pane, KeyInput(key: 0, text: "a")),
            .paste(pane, "ls"), .text(pane, "ls\n"),
        ]
        for m in typed { #expect(m.priority == LanePriority.echo, "\(m)") }
        for m in [ClientMessage.ping(1), .detach(pane), .seen(pane)] {
            #expect(m.priority == LanePriority.normal, "\(m)")
        }
        #expect(LanePriority.bulk < LanePriority.tunnel && LanePriority.tunnel < LanePriority.normal
            && LanePriority.normal < LanePriority.echo, "files, then tunnels, then panes, then an echo")
    }
}
