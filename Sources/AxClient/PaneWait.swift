public import AxModel

/// What `axolotty wait` (and MCP `wait_for`) waits for, judged on every
/// change to a watched pane as it arrives, never on the latest state alone:
/// `done` lasts only until the person sees the pane (the app sees a finish
/// in front of them at once), so a waiter that read the replica late could
/// find `idle` and miss the finish for good.
public struct PaneWait: Sendable {
    public enum Goal: String, CaseIterable, Sendable {
        /// The program finished: `done`, or `idle` again after working or blocked.
        case done
        case blocked, error
        /// The program exited, or the pane closed.
        case exit
        /// The next shell command finished.
        case command
    }

    public let goal: Goal
    /// In the order the waiter gave them.
    public let panes: [PaneID]
    private var last: [PaneID: PaneInfo]
    private let lastEnded: [PaneID: Double]

    /// `state` is the document the deltas fed later follow (the welcome's).
    public init(goal: Goal, panes: [PaneID], state: HostState) {
        self.goal = goal
        self.panes = panes
        last = state.panes.filter { panes.contains($0.key) }
        lastEnded = last.mapValues { $0.lastCommand?.endedAt ?? 0 }
    }

    /// The panes already there, in order.
    public func reachedNow() -> [(PaneID, PaneInfo?)] {
        panes.compactMap { p in last[p].flatMap { reached(before: nil, after: $0) ? (p, $0) : nil } }
    }

    /// Takes one batch of changes; returns the panes that got there in it, in order.
    public mutating func feed(_ deltas: [HostState.Delta]) -> [(PaneID, PaneInfo?)] {
        var got: [PaneID: PaneInfo?] = [:]
        for d in deltas {
            switch d {
            case let .pane(info) where panes.contains(info.id):
                if got.index(forKey: info.id) == nil, reached(before: last[info.id], after: info) { got[info.id] = info }
                last[info.id] = info
            case let .paneRemoved(id) where panes.contains(id):
                if got.index(forKey: id) == nil, goal == .exit || goal == .command { got[id] = .some(nil) }
                last[id] = nil
            default:
                continue
            }
        }
        return panes.compactMap { p in got.index(forKey: p).map { (p, got[$0].value) } }
    }

    private func reached(before: PaneInfo?, after info: PaneInfo) -> Bool {
        switch goal {
        case .done:
            let was = before?.activity
            return info.activity == .done || info.activity == .idle && (was == .working || was == .blocked)
        case .blocked: return info.activity == .blocked
        case .error: return info.activity == .error
        case .exit: return info.exitStatus != nil
        case .command: return (info.lastCommand?.endedAt ?? 0) > (lastEnded[info.id] ?? 0)
        }
    }
}
