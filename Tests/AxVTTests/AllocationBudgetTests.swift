import AxTestSupport
import AxVT
import Testing

/// What the terminal costs the heap per write and per frame drawn, counted exactly
/// (`Allocations`); only an optimised build means anything (`scripts/deep.sh budgets`).
// Whether this target is optimised is asked here: `AxTestSupport` is always built `-O`.
@Suite("Allocation budgets: terminal", .serialized,
       .enabled(if: !_isDebugAssertConfiguration() && Allocations.works, "an optimised build, without sanitizers"))
struct VTAllocationBudgetTests {
    static let line = Array("\u{1b}[32mok\u{1b}[0m src/main.swift:12: compiled in 3 ms, nothing more to do\r\n".utf8)

    /// A terminal whose scrollback has already grown its pages.
    static func warm() throws -> VTTerminal {
        let t = try VTTerminal(cols: 120, rows: 40)
        for _ in 0 ..< 2000 { line.withUnsafeBytes { _ = t.write($0) } }
        return t
    }

    @Test func aWriteThatRaisesNothingCostsOneAllocation() throws {
        // libghostty makes one per write; the Swift side adds none.
        let t = try Self.warm()
        #expect(Allocations.each(1000) { Self.line.withUnsafeBytes { _ = t.write($0) } } <= 1)
        let echo: [UInt8] = [0x61]
        #expect(Allocations.each(1000) { echo.withUnsafeBytes { _ = t.write($0) } } <= 1)
    }

    @Test func aFramesCopyOfTheScreenCostsOneAllocation() throws {
        let t = try Self.warm()
        let rs = try VTRenderState()
        rs.update(from: t)
        let n = Allocations.each(200) {
            Self.line.withUnsafeBytes { _ = t.write($0) }
            rs.update(from: t)
        }
        #expect(n <= 2)
    }
}
