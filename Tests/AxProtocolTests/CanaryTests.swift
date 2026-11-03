import Foundation
import Synchronization
import Testing

/// Planted faults that `scripts/deep.sh canaries` runs each long step against: a step that
/// passes its canary can't see what it is there to see. Never in the gate (`AXCANARY` unset).
@Suite("Canaries", .enabled(if: ProcessInfo.processInfo.environment["AXCANARY"] != nil), .serialized)
struct CanaryTests {
    static let which = ProcessInfo.processInfo.environment["AXCANARY"] ?? ""

    final class Box: @unchecked Sendable { var n = 0 }

    /// Two threads write one plain Int: TSan must call it a data race.
    @Test(.enabled(if: which == "tsan")) func aDataRace() {
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0 ..< 1000 { box.n += 1 }
        }
        #expect(box.n > 0)
    }

    /// One byte past an allocation: ASan must call it a heap-buffer-overflow.
    @Test(.enabled(if: which == "asan")) func aWritePastTheEnd() {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 8)
        defer { p.deallocate() }
        (p + Int(ProcessInfo.processInfo.processIdentifier & 0) + 8).pointee = 1
    }

    /// Passes twice, then fails: repeating until a failure must find it.
    static let runs = Atomic<Int>(0)
    @Test(.enabled(if: which == "flakes")) func aFlakeOnTheThirdRun() {
        let n = Self.runs.add(1, ordering: .relaxed).newValue
        #expect(n < 3, "AXCANARY flake on run \(n)")
    }
}
