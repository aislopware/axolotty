import AxModel
import Foundation
import Testing

enum JSONEncoderShim {
    static func encode<T: Encodable>(_ v: T) throws -> Data { try JSONEncoder().encode(v) }
    static func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T { try JSONDecoder().decode(t, from: d) }
}

@Suite struct HostStateTests {
    func sample() -> (HostState, WorkspaceID, SessionID, PaneID, PaneID) {
        var s = HostState(host: HostID(), name: "mac")
        let w = WorkspaceID(), sid = SessionID(), p1 = PaneID(), p2 = PaneID()
        var session = SessionInfo(id: sid, workspace: w, root: p1)
        session.tree = session.tree.splitting(p1, with: p2, axis: .horizontal)
        s.apply([
            .workspace(WorkspaceInfo(id: w, name: "axolotty", root: "/tmp", sessions: [sid])),
            .session(session), .pane(PaneInfo(id: p1, session: sid)), .pane(PaneInfo(id: p2, session: sid)),
        ])
        return (s, w, sid, p1, p2)
    }

    @Test func deltasAreIdempotentAndCountRevisions() {
        var (s, w, _, _, _) = sample()
        let before = s
        s.apply(.workspace(s.workspace(w)!))
        #expect(s.workspaces == before.workspaces && s.sessions == before.sessions && s.panes == before.panes)
        #expect(s.revision == before.revision + 1)
        #expect(s.invariantViolations.isEmpty)
    }

    /// Reopening brings back the focused pane's Claude Code if it has one,
    /// else the first in tree order: the app and the server must agree.
    @Test func claudePanePrefersTheFocusedOne() {
        var (s, _, sid, p1, p2) = sample()
        #expect(s.claudePane(of: sid) == nil)
        s.panes[p2]!.agent = .claude
        s.sessions[sid]!.focus = p1
        #expect(s.claudePane(of: sid) == p2)
        s.panes[p1]!.agent = .claude
        #expect(s.claudePane(of: sid) == p1)
        s.sessions[sid]!.focus = p2
        #expect(s.claudePane(of: sid) == p2)
    }

    @Test func activityRollsUpByUrgency() {
        var (s, w, sid, p1, p2) = sample()
        s.panes[p1]!.status.report(id: "", state: .working)
        s.panes[p2]!.status.report(id: "", state: .done)
        #expect(s.activity(of: sid) == .working)
        s.panes[p2]!.status.report(id: "", state: .blocked)
        #expect(s.activity(ofWorkspace: w) == .blocked)
        #expect(s.attention.blocked == 1 && s.attention.working == 1)
    }

    /// What the status circle holds: the blocked pane's own need, wherever
    /// it sits in the split, and nothing once no pane waits.
    @Test func aSessionWaitsForWhatItsBlockedPaneSays() {
        var (s, _, sid, p1, p2) = sample()
        s.panes[p1]!.status.report(id: "", state: .working)
        s.panes[p2]!.status.report(id: "", state: .blocked, need: .permission)
        #expect(s.need(of: sid) == .permission)
        s.panes[p2]!.status.report(id: "", state: .working)
        #expect(s.need(of: sid) == nil)
    }

    /// The wedge's number: the terminal's OSC 9;4 wins over the agent's
    /// own, and indeterminate (-1) is no number.
    @Test func progressPrefersTheTerminalsOwnNumber() {
        var (s, _, sid, p1, p2) = sample()
        #expect(s.progress(of: sid) == nil)
        s.panes[p2]!.status.report(id: "", state: .working, progress: 40)
        #expect(s.progress(of: sid) == 0.4)
        s.panes[p1]!.progress = -1
        #expect(s.progress(of: sid) == 0.4)
        s.panes[p1]!.progress = 75
        #expect(s.progress(of: sid) == 0.75)
    }

    @Test func nonZeroExitWithoutReportsIsAnError() {
        var (s, _, _, p1, _) = sample()
        s.panes[p1]!.exitStatus = 1
        #expect(s.panes[p1]!.activity == .error)
    }

    @Test func invariantsCatchDanglingReferences() {
        var (s, _, sid, p1, _) = sample()
        s.apply(.paneRemoved(p1))
        #expect(!s.invariantViolations.isEmpty)
        s.apply(.sessionRemoved(sid))
        #expect(s.invariantViolations.contains { $0.contains("missing session") })
    }

    @Test func codableRoundTrip() throws {
        var (s, _, _, p1, _) = sample()
        s.panes[p1]!.status.report(id: "x", state: .blocked, app: "claude", message: "Allow edit?")
        let back = try JSONEncoderShim.decode(HostState.self, try JSONEncoderShim.encode(s))
        #expect(back == s)
    }
}
