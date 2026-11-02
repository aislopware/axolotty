// The host's side of `ClaudeAgents`: which panes to watch, when to ask
// Claude Code, and how its answer becomes status records.
import AxModel
import Foundation

extension Server {
    /// A pane is watched while a tmux client is its foreground, or while
    /// Claude Code runs in it without reporting for itself.
    func retargetAgents(_ id: PaneID, program: String, agent: AgentKind?, leader: Int32, argv: [String]) {
        if agent == .claude, !claudeNative.contains(id), agentTargets[id] == nil {
            // Claude Code answers the terminal's probe within 2 s and then
            // speaks for itself; only one that hasn't by 5 s is asked about.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.watchSilentClaude(id, leader: leader)
            }
            return
        }
        let target: ClaudeAgents.Target? = program == "tmux"
            ? .tmux(client: leader, socket: ClaudeAgents.socketFlags(argv)) : nil
        if target == nil, case .direct = agentTargets[id], agent == .claude { return }  // still that Claude
        guard agentTargets[id] != target else { return }
        agentTargets[id] = target
        if target == nil { clearAgents(id) }
        ensureSessionWatch()
        if target != nil { scheduleAgentsRefresh() }
    }

    private func watchSilentClaude(_ id: PaneID, leader: Int32) {
        guard state.panes[id]?.agent == .claude, !claudeNative.contains(id), agentTargets[id] == nil else { return }
        agentTargets[id] = .direct(root: leader)
        ensureSessionWatch()
        scheduleAgentsRefresh()
    }

    func forgetAgents(_ id: PaneID) {
        agentTargets[id] = nil
        agentRoots[id] = nil
        agentShown[id] = nil
        claudeNative.remove(id)
        ensureSessionWatch()
    }

    private func clearAgents(_ id: PaneID) {
        agentRoots[id] = nil
        guard agentShown.removeValue(forKey: id) != nil else { return }
        updateStatus(id, live: false) { $0.clearAgents() }
    }

    /// The folder is watched only while some pane is.
    private func ensureSessionWatch() {
        if agentTargets.isEmpty {
            sessionWatch = nil
            return
        }
        guard sessionWatch == nil else { return }
        sessionWatch = ClaudeSessionWatch(directory: ClaudeAgents.sessionsDirectory) { [weak self] pids in
            Task { await self?.sessionsChanged(pids) }
        }
    }

    /// A session file changed: ask Claude Code only when that session is
    /// (or may be) one of ours.
    private func sessionsChanged(_ pids: [Int32]) {
        guard !agentTargets.isEmpty else { return }
        let shown = Set(agentShown.values.flatMap(\.keys))
        let roots = agentRoots.values.reduce(into: Set<Int32>()) { $0.formUnion($1) }
        let tmux = agentTargets.values.contains { if case .tmux = $0 { true } else { false } }
        let ours = pids.contains { pid in
            if shown.contains(pid) { return true }
            let chain = ClaudeAgents.ancestors(pid)
            if !roots.isDisjoint(with: chain) { return true }
            // A session in a tmux window opened since roots were read.
            return tmux && chain.contains { ClaudeAgents.isTmux($0) }
        }
        if ours { scheduleAgentsRefresh() }
    }

    /// Coalesces bursts: one call in flight, one more queued at most.
    private func scheduleAgentsRefresh() {
        if agentsRefresh != nil {
            agentsAgain = true
            return
        }
        agentsRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            await self?.refreshAgents()
        }
    }

    private func refreshAgents() async {
        let targets = agentTargets
        if !targets.isEmpty {
            let (roots, byPane) = await Task.detached(priority: .utility) {
                let roots = targets.mapValues(ClaudeAgents.roots)
                return (roots, ClaudeAgents.list().map { ClaudeAgents.assign($0, roots: roots) })
            }.value
            agentRoots = roots
            if let byPane { applyAgents(byPane) }
        }
        agentsRefresh = nil
        if agentsAgain {
            agentsAgain = false
            scheduleAgentsRefresh()
        }
    }

    private func applyAgents(_ byPane: [PaneID: [ClaudeAgents.Entry]]) {
        let prefix = StatusBook.agentsPrefix
        for (id, target) in agentTargets {
            if case .direct = target, claudeNative.contains(id) { continue }
            let entries = byPane[id] ?? []
            var shown = agentShown[id] ?? [:]
            updateStatus(id, live: true) { book in
                let live = Set(entries.map(\.pid))
                for pid in shown.keys where !live.contains(pid) {
                    book.clear(prefix + "\(pid)")
                    shown[pid] = nil
                }
                for e in entries {
                    let key = prefix + "\(e.pid)"
                    guard let (state, need) = ClaudeAgents.record(e, previous: shown[e.pid]) else {
                        if shown.removeValue(forKey: e.pid) != nil { book.clear(key) }
                        continue
                    }
                    // A finish stays as it was until seen (seeing removes it).
                    if state == .done, shown[e.pid] == .done { continue }
                    if state == shown[e.pid], book.records[key]?.need == need { continue }
                    book.report(id: key, state: state, app: "claude-code", title: e.name ?? "", need: need)
                    shown[e.pid] = state
                }
            }
            agentShown[id] = shown.isEmpty ? nil : shown
        }
    }
}
