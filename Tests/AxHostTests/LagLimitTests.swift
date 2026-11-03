import AxHost
import Testing

/// How far a pane's output may fall behind on a link before the host skips to a snapshot.
@Suite("Lag limit")
struct LagLimitTests {
    let limits = PaneLimits()

    @Test func aLinkThatSaysItsRateIsAllowedATenthOfASecond() {
        #expect(limits.lagLimit(bandwidth: 5_000_000) == 500_000, "Wi-Fi at 5 MB/s: 100 ms")
        #expect(limits.lagLimit(bandwidth: 12_500_000) == 1_250_000, "100 Mbit/s")
    }

    @Test func itNeverDropsUnderTheResyncsOwnMarkNorPassesTheByteCap() {
        #expect(limits.lagLimit(bandwidth: 100_000) == 128 << 10, "a crawl still streams")
        #expect(limits.lagLimit(bandwidth: 1_000_000_000) == limits.lagBytes, "a fast path keeps the cap")
    }

    @Test func aLinkThatDoesNotSayKeepsTheByteCap() {
        #expect(limits.lagLimit(bandwidth: nil) == limits.lagBytes)
        var tight = PaneLimits()
        tight.lagBytes = 0
        #expect(tight.lagLimit(bandwidth: 5_000_000) == 0, "a cap of nothing resyncs at once, as tests ask")
    }
}
