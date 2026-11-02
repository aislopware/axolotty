/// A binary split layout of panes (Ghostty/Otty model).
///
/// Pure value type: every operation returns a new tree. Ratios are the share of
/// the first child, clamped to keep both children at least `minShare`.
public indirect enum SplitTree: Hashable, Codable, Sendable {
    case leaf(PaneID)
    case split(Axis, ratio: Double, SplitTree, SplitTree)

    public enum Axis: String, Hashable, Codable, Sendable {
        /// Children side by side (a vertical divider).
        case horizontal
        /// Children stacked (a horizontal divider).
        case vertical
    }

    public enum Direction: String, Hashable, Codable, Sendable, CaseIterable { case left, right, up, down }

    public static let minShare = 0.1

    // MARK: Queries

    public var panes: [PaneID] {
        switch self {
        case let .leaf(id): [id]
        case let .split(_, _, a, b): a.panes + b.panes
        }
    }

    public func contains(_ id: PaneID) -> Bool {
        switch self {
        case let .leaf(p): p == id
        case let .split(_, _, a, b): a.contains(id) || b.contains(id)
        }
    }

    public var count: Int {
        switch self {
        case .leaf: 1
        case let .split(_, _, a, b): a.count + b.count
        }
    }

    // MARK: Edits

    /// Splits `target` and puts `new` after it (right/below) or before it.
    public func splitting(_ target: PaneID, with new: PaneID, axis: Axis, before: Bool = false, ratio: Double = 0.5)
        -> SplitTree
    {
        switch self {
        case let .leaf(p) where p == target:
            let r = Self.clamp(ratio)
            return before ? .split(axis, ratio: 1 - r, .leaf(new), .leaf(p)) : .split(axis, ratio: r, .leaf(p), .leaf(new))
        case .leaf:
            return self
        case let .split(ax, r, a, b):
            return .split(
                ax, ratio: r, a.splitting(target, with: new, axis: axis, before: before, ratio: ratio),
                b.splitting(target, with: new, axis: axis, before: before, ratio: ratio))
        }
    }

    /// Removes a pane; its sibling takes the parent's place. Returns nil when the
    /// tree becomes empty.
    public func removing(_ id: PaneID) -> SplitTree? {
        switch self {
        case let .leaf(p): return p == id ? nil : self
        case let .split(ax, r, a, b):
            let na = a.removing(id), nb = b.removing(id)
            switch (na, nb) {
            case let (x?, y?): return .split(ax, ratio: r, x, y)
            case let (x?, nil): return x
            case let (nil, y?): return y
            case (nil, nil): return nil
            }
        }
    }

    /// Moves the divider nearest to `id` along `axis` by `delta` (a share of the
    /// parent, positive = towards right/down).
    public func resizing(_ id: PaneID, axis: Axis, by delta: Double) -> SplitTree {
        resizeHelper(id, axis: axis, delta: delta).tree
    }

    private func resizeHelper(_ id: PaneID, axis: Axis, delta: Double) -> (tree: SplitTree, done: Bool) {
        guard case let .split(ax, r, a, b) = self else { return (self, false) }
        let inA = a.contains(id)
        let inB = !inA && b.contains(id)
        guard inA || inB else { return (self, false) }
        let (child, done) = (inA ? a : b).resizeHelper(id, axis: axis, delta: delta)
        if done { return (inA ? .split(ax, ratio: r, child, b) : .split(ax, ratio: r, a, child), true) }
        if ax == axis { return (.split(ax, ratio: Self.clamp(r + delta), a, b), true) }
        return (self, false)
    }

    /// Sets every split to divide its space evenly by leaf count along its axis.
    public func equalized() -> SplitTree {
        switch self {
        case .leaf: return self
        case let .split(ax, _, a, b):
            let wa = Double(a.weight(along: ax)), wb = Double(b.weight(along: ax))
            return .split(ax, ratio: Self.clamp(wa / (wa + wb)), a.equalized(), b.equalized())
        }
    }

    private func weight(along axis: Axis) -> Int {
        switch self {
        case .leaf: 1
        case let .split(ax, _, a, b):
            ax == axis ? a.weight(along: axis) + b.weight(along: axis)
                : max(a.weight(along: axis), b.weight(along: axis))
        }
    }

    public func replacing(_ old: PaneID, with new: PaneID) -> SplitTree {
        switch self {
        case let .leaf(p): .leaf(p == old ? new : p)
        case let .split(ax, r, a, b): .split(ax, ratio: r, a.replacing(old, with: new), b.replacing(old, with: new))
        }
    }

    public func swapping(_ x: PaneID, _ y: PaneID) -> SplitTree {
        switch self {
        case let .leaf(p): .leaf(p == x ? y : p == y ? x : p)
        case let .split(ax, r, a, b): .split(ax, ratio: r, a.swapping(x, y), b.swapping(x, y))
        }
    }

    static func clamp(_ r: Double) -> Double { min(max(r, minShare), 1 - minShare) }

    // MARK: Geometry

    /// Lays the tree out in `rect`, leaving `gap` points between siblings.
    /// Coordinates are top-left origin (y grows down).
    public func frames(in rect: Rect, gap: Double = 0) -> [PaneID: Rect] {
        var out: [PaneID: Rect] = [:]
        layout(in: rect, gap: gap, into: &out)
        return out
    }

    private func layout(in rect: Rect, gap: Double, into out: inout [PaneID: Rect]) {
        switch self {
        case let .leaf(id):
            out[id] = rect
        case let .split(ax, r, a, b):
            switch ax {
            case .horizontal:
                let avail = max(rect.width - gap, 0)
                let wa = (avail * r).rounded()
                a.layout(in: Rect(x: rect.x, y: rect.y, width: wa, height: rect.height), gap: gap, into: &out)
                b.layout(in: Rect(x: rect.x + wa + gap, y: rect.y, width: avail - wa, height: rect.height), gap: gap, into: &out)
            case .vertical:
                let avail = max(rect.height - gap, 0)
                let ha = (avail * r).rounded()
                a.layout(in: Rect(x: rect.x, y: rect.y, width: rect.width, height: ha), gap: gap, into: &out)
                b.layout(in: Rect(x: rect.x, y: rect.y + ha + gap, width: rect.width, height: avail - ha), gap: gap, into: &out)
            }
        }
    }

    /// Dividers (for hit-testing and drawing): the line rect and the split it moves.
    public struct Divider: Hashable, Sendable {
        public var rect: Rect
        public var axis: Axis
        /// A pane in the first child; `resizing(anchor, axis:by:)` moves this divider.
        public var anchor: PaneID
        /// Size of the parent along `axis`, to turn points into a ratio delta.
        public var span: Double
        /// The split's current share for its first child.
        public var ratio: Double
    }

    public func dividers(in rect: Rect, gap: Double = 0) -> [Divider] {
        var out: [Divider] = []
        collectDividers(in: rect, gap: gap, into: &out)
        return out
    }

    private func collectDividers(in rect: Rect, gap: Double, into out: inout [Divider]) {
        guard case let .split(ax, r, a, b) = self else { return }
        let anchor = a.panes.last!
        switch ax {
        case .horizontal:
            let avail = max(rect.width - gap, 0)
            let wa = (avail * r).rounded()
            out.append(Divider(rect: Rect(x: rect.x + wa, y: rect.y, width: gap, height: rect.height), axis: ax, anchor: anchor, span: avail, ratio: r))
            a.collectDividers(in: Rect(x: rect.x, y: rect.y, width: wa, height: rect.height), gap: gap, into: &out)
            b.collectDividers(in: Rect(x: rect.x + wa + gap, y: rect.y, width: avail - wa, height: rect.height), gap: gap, into: &out)
        case .vertical:
            let avail = max(rect.height - gap, 0)
            let ha = (avail * r).rounded()
            out.append(Divider(rect: Rect(x: rect.x, y: rect.y + ha, width: rect.width, height: gap), axis: ax, anchor: anchor, span: avail, ratio: r))
            a.collectDividers(in: Rect(x: rect.x, y: rect.y, width: rect.width, height: ha), gap: gap, into: &out)
            b.collectDividers(in: Rect(x: rect.x, y: rect.y + ha + gap, width: rect.width, height: avail - ha), gap: gap, into: &out)
        }
    }

    /// The pane spatially next to `from` in `direction`: among panes whose edge
    /// touches ours on that side, the one overlapping most with our span (ties:
    /// nearest to our centre).
    public func neighbor(of from: PaneID, _ direction: Direction) -> PaneID? {
        let unit = Rect(x: 0, y: 0, width: 10_000, height: 10_000)
        let f = frames(in: unit)
        guard let me = f[from] else { return nil }
        var best: (PaneID, Double, Double)?
        for (id, r) in f where id != from {
            let gapDist: Double
            let overlap: Double
            switch direction {
            case .left: gapDist = me.minX - r.maxX; overlap = min(me.maxY, r.maxY) - max(me.minY, r.minY)
            case .right: gapDist = r.minX - me.maxX; overlap = min(me.maxY, r.maxY) - max(me.minY, r.minY)
            case .up: gapDist = me.minY - r.maxY; overlap = min(me.maxX, r.maxX) - max(me.minX, r.minX)
            case .down: gapDist = r.minY - me.maxY; overlap = min(me.maxX, r.maxX) - max(me.minX, r.minX)
            }
            guard gapDist >= -0.5, gapDist < 1.5, overlap > 0 else { continue }
            let centreDist = abs(direction == .left || direction == .right ? r.midY - me.midY : r.midX - me.midX)
            if best == nil || overlap > best!.1 + 0.5 || (abs(overlap - best!.1) <= 0.5 && centreDist < best!.2) {
                best = (id, overlap, centreDist)
            }
        }
        return best?.0
    }
}

/// Minimal geometry so the model needs neither CoreGraphics nor AppKit.
public struct Rect: Hashable, Codable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public func contains(x px: Double, y py: Double) -> Bool { px >= x && px < maxX && py >= y && py < maxY }
}
