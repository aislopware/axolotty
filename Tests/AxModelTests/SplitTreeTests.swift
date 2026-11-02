import AxModel
import AxTestSupport
import Testing

@Suite struct SplitTreeTests {
    let a = PaneID(), b = PaneID(), c = PaneID()

    @Test func splitAndRemoveCollapseToSibling() {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        #expect(t.panes == [a, b, c])
        #expect(t.removing(b)?.panes == [a, c])
        #expect(t.removing(a)?.removing(b)?.removing(c) == nil)
        #expect(t.removing(PaneID()) == t)
    }

    @Test func splitBeforePutsNewFirst() {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal, before: true)
        #expect(t.panes == [b, a])
    }

    @Test func framesTileAndDividersSitBetween() {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        let f = t.frames(in: Rect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        #expect(f[a] == Rect(x: 0, y: 0, width: 500, height: 601))
        #expect(f[b] == Rect(x: 501, y: 0, width: 500, height: 300))
        #expect(f[c] == Rect(x: 501, y: 301, width: 500, height: 300))
        let d = t.dividers(in: Rect(x: 0, y: 0, width: 1001, height: 601), gap: 1)
        #expect(d.count == 2)
        #expect(d[0].rect == Rect(x: 500, y: 0, width: 1, height: 601))
    }

    @Test func neighborsFollowGeometry() {
        // a | (b / c)
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        // b and c overlap a equally and are equally far from its centre: either is fine.
        #expect([b, c].contains(t.neighbor(of: a, .right)))
        #expect(t.neighbor(of: b, .left) == a)
        #expect(t.neighbor(of: c, .left) == a)
        #expect(t.neighbor(of: b, .down) == c)
        #expect(t.neighbor(of: c, .up) == b)
        #expect(t.neighbor(of: a, .left) == nil)
    }

    @Test func resizeMovesNearestMatchingDividerAndClamps() {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .vertical)
        guard case let .split(_, r, _, inner) = t.resizing(c, axis: .horizontal, by: 0.2) else { Issue.record(); return }
        #expect(abs(r - 0.7) < 1e-9)
        #expect(inner == .split(.vertical, ratio: 0.5, .leaf(b), .leaf(c)))
        guard case let .split(_, r2, _, _) = t.resizing(a, axis: .horizontal, by: 5) else { Issue.record(); return }
        #expect(r2 == 1 - SplitTree.minShare)
    }

    @Test func equalizeWeighsByLeaves() {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .horizontal).splitting(b, with: c, axis: .horizontal)
        guard case let .split(_, r, _, _) = t.equalized() else { Issue.record(); return }
        #expect(abs(r - 1.0 / 3.0) < 1e-9)
    }

    /// Random edit sequences keep the tree well-formed and its frames a tiling.
    @Test("random edits keep invariants", arguments: 1 ... 40)
    func randomEdits(seed: Int) {
        var rng = SeededRNG(seed: UInt64(seed))
        var tree = SplitTree.leaf(PaneID())
        for _ in 0 ..< 60 {
            let panes = tree.panes
            let target = panes[Int.random(in: 0 ..< panes.count, using: &rng)]
            switch Int.random(in: 0 ..< 5, using: &rng) {
            case 0, 1:
                tree = tree.splitting(target, with: PaneID(), axis: Bool.random(using: &rng) ? .horizontal : .vertical,
                                      before: Bool.random(using: &rng), ratio: Double.random(in: 0 ... 1, using: &rng))
            case 2: if panes.count > 1, let t = tree.removing(target) { tree = t }
            case 3: tree = tree.resizing(target, axis: .vertical, by: Double.random(in: -0.5 ... 0.5, using: &rng))
            default: tree = tree.equalized()
            }
            let ids = tree.panes
            #expect(Set(ids).count == ids.count, "duplicate panes")
            let area = Rect(x: 0, y: 0, width: 3000, height: 2000)
            let f = tree.frames(in: area)
            let sum = f.values.reduce(0.0) { $0 + $1.width * $1.height }
            #expect(abs(sum - 3000 * 2000) < 1, "frames must tile the area")
            for id in ids {
                for dir in SplitTree.Direction.allCases {
                    if let n = tree.neighbor(of: id, dir) { #expect(n != id && tree.contains(n)) }
                }
            }
        }
    }

    @Test func codableRoundTrip() throws {
        let t = SplitTree.leaf(a).splitting(a, with: b, axis: .vertical, ratio: 0.3)
        let data = try JSONEncoderShim.encode(t)
        #expect(try JSONEncoderShim.decode(SplitTree.self, data) == t)
    }
}
