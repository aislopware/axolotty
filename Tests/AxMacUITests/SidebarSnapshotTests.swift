import AppKit
import AxClient
@testable import AxMacUI
import AxModel
import AxProtocol
import Foundation
import Testing

/// The sidebar as a person sees it mid-afternoon: two projects, agents working, waiting,
/// done and failed, and a plain shell, drawn from a host shown without connecting
/// (`HostSession.show`). Same rules as `SnapshotTests`.
@Suite("Sidebar snapshots", .serialized)
struct SidebarSnapshotTests {
    static func pane(_ s: SessionID, title: String, program: String, agent: AgentKind?, state: StatusRecord.State?,
                     need: StatusRecord.Need? = nil, message: String = "", ago: Double) -> PaneInfo
    {
        var p = PaneInfo(id: PaneID(), session: s)
        p.title = title
        p.program = program
        p.agent = agent
        p.status.report(id: "s", state: state, app: agent?.rawValue ?? "", message: message, need: need)
        p.activitySince = Date().timeIntervalSince1970 - ago
        return p
    }

    static func state() -> HostState {
        var st = HostState(host: HostID(), name: "Mac Studio")
        func project(_ name: String, _ panes: [(SessionID) -> PaneInfo]) {
            let w = WorkspaceInfo(id: WorkspaceID(), name: name, root: "/Users/me/Workspace/\(name)")
            st.workspaces.append(w)
            for make in panes {
                let sid = SessionID()
                let p = make(sid)
                st.sessions[sid] = SessionInfo(id: sid, workspace: w.id, root: p.id)
                st.panes[p.id] = p
                st.workspaces[st.workspaces.count - 1].sessions.append(sid)
            }
        }
        project("axolotty", [
            { pane($0, title: "Snapshot tests", program: "claude", agent: .claude, state: .working, ago: 95) },
            { pane($0, title: "QUIC send window", program: "codex", agent: .codex, state: .blocked, need: .permission,
                   message: "Allow Bash: cargo test", ago: 40) },
            { pane($0, title: "", program: "zsh", agent: nil, state: nil, ago: 1500) },
        ])
        project("slopty", [
            { pane($0, title: "Pacer trace", program: "claude", agent: .claude, state: .done, ago: 300) },
            { pane($0, title: "Release build", program: "make", agent: nil, state: .error, ago: 600) },
        ])
        return st
    }

    @Test func aHostWithTwoProjects() throws {
        let suite = "axolotty.snapshots.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!)
        let host = HostSession(endpoint: .unix(path: "/nonexistent"), client: ClientID(), clientName: "test", isLocal: true)
        model.add(host, connect: false)
        host.show(Self.state())
        let sidebar = SidebarViewController(model: model)
        let size = NSSize(width: Axo.Metric.sidebarWidth, height: 420)
        sidebar.view.frame = NSRect(origin: .zero, size: size)
        sidebar.reload()
        for scale: CGFloat in [1, 2] {
            try Snapshot.expect(Snapshot.render(sidebar.view, size: size, scale: scale, margin: 0, on: Axo.Color.sidebar),
                                named: "sidebar@\(Int(scale))x")
        }
    }
}
