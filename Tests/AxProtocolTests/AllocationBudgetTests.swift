import AxModel
import AxProtocol
import AxTestSupport
import Foundation
import Testing

/// What one frame costs the heap on its way through the wire codec, counted exactly
/// (`Allocations`). Counts, not times: the same on any Mac and under any load. Only an
/// optimised build means anything (`scripts/deep.sh budgets`).
@Suite("Allocation budgets: wire", .serialized,
       .enabled(if: Allocations.optimized && Allocations.works, "an optimised build, without sanitizers"))
struct WireAllocationBudgetTests {
    let pane = PaneID()

    @Test func theCounterSeesAnAllocationPlantedInTheLoop() {
        // The canary: a budget of zero can fail.
        let n = Allocations.each(100) {
            let p = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
            p.deallocate()
        }
        #expect(n == 1)
    }

    @Test func anEchoFrameIsDecodedWithoutTheHeap() throws {
        // A key's echo is a few bytes: `Data` holds up to 14 inline, and the decoder's own
        // buffer keeps its capacity. (As `Data`, emptying it reallocated: 2 a frame.)
        let wire = Wire.encode(.output(pane: pane, offset: 1, bytes: Data("a".utf8)))
        var d = FrameDecoder()
        let n = try Allocations.each(1000) {
            d.feed(wire)
            _ = try d.next()
        }
        #expect(n == 0)
    }

    @Test func aFullOutputFrameCostsOnlyItsPayload() throws {
        // The payload is a `Data` of its own: its storage and its bytes.
        let wire = Wire.encode(.output(pane: pane, offset: 1, bytes: Data(repeating: 65, count: Wire.maxData)))
        var d = FrameDecoder()
        let n = try Allocations.each(1000) {
            d.feed(wire)
            _ = try d.next()
        }
        #expect(n <= 2)
    }

    @Test func encodingAFrameMakesOnlyItsData() {
        for bytes in [Data("a".utf8), Data(repeating: 65, count: Wire.maxData)] {
            let f = Frame.output(pane: pane, offset: 7, bytes: bytes)
            #expect(Allocations.each(1000) { _ = Wire.encode(f) } <= 2, "\(bytes.count) bytes")
        }
    }
}
