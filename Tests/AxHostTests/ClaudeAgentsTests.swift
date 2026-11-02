@testable import AxHost
import AxModel
import Foundation
import Testing

/// Status read from `claude agents --json` for panes Claude Code can't
/// report to (tmux): parsing, the state each session becomes, and which pane
/// it belongs to.
@Suite struct ClaudeAgentsTests {
    @Test func parsesLiveSessionsAndSkipsBackgroundOnes() {
        let json = """
        [{"cwd":"/a","kind":"background","id":"x1","state":"done","startedAt":1},
         {"cwd":"/b","kind":"interactive","pid":4242,"status":"waiting","waitingFor":"permission prompt","name":"fix login"},
         {"cwd":"/c","kind":"interactive","pid":77,"status":"busy"}]
        """
        let e = ClaudeAgents.parse(Data(json.utf8))
        #expect(e == [
            .init(pid: 4242, status: "waiting", waitingFor: "permission prompt", name: "fix login"),
            .init(pid: 77, status: "busy", waitingFor: nil, name: nil),
        ])
        #expect(ClaudeAgents.parse(Data("not json".utf8)).isEmpty)
    }

    @Test func statesFollowWhatTheHostLastShowed() {
        func r(_ status: String, _ waiting: String? = nil, _ prev: StatusRecord.State? = nil) -> StatusRecord.State? {
            ClaudeAgents.record(.init(pid: 1, status: status, waitingFor: waiting), previous: prev)?.0
        }
        #expect(r("busy") == .working)
        #expect(r("waiting", "permission prompt") == .blocked)
        #expect(ClaudeAgents.record(.init(pid: 1, status: "waiting", waitingFor: "input needed"), previous: nil)?.1 == .question)
        #expect(ClaudeAgents.record(.init(pid: 1, status: "waiting", waitingFor: "sandbox request"), previous: nil)?.1 == .permission)
        #expect(r("idle") == nil)  // quiet from the start: nothing to say
        #expect(r("idle", nil, .working) == .done)  // quiet after working: finished
        #expect(r("idle", nil, .blocked) == .done)
        #expect(r("shell", nil, .working) == .done)
    }

    @Test func aSessionBelongsToThePaneItsParentsReach() {
        let a = PaneID(), b = PaneID()
        let parents: [Int32: [Int32]] = [500: [500, 400, 300], 600: [600, 410, 300], 700: [700, 1]]
        let byPane = ClaudeAgents.assign(
            [.init(pid: 500, status: "busy"), .init(pid: 600, status: "idle"), .init(pid: 700, status: "busy")],
            roots: [a: [400], b: [410, 411]], ancestors: { parents[$0] ?? [$0] })
        #expect(byPane[a]?.map(\.pid) == [500])
        #expect(byPane[b]?.map(\.pid) == [600])
        #expect(byPane.values.flatMap { $0 }.contains { $0.pid == 700 } == false)  // not under any pane
    }

    @Test func tmuxSocketFlagsComeFromTheClient() {
        #expect(ClaudeAgents.socketFlags(["tmux", "-L", "work", "attach"]) == ["-L", "work"])
        #expect(ClaudeAgents.socketFlags(["tmux", "-S", "/tmp/s", "new", "-s", "x"]) == ["-S", "/tmp/s"])
        #expect(ClaudeAgents.socketFlags(["tmux"]).isEmpty)
    }

    @Test func hostRecordsNeverPassForSubagents() {
        var b = StatusBook()
        b.report(id: StatusBook.agentsPrefix + "4242", state: .working, app: "claude-code")
        #expect(b.subagentsWorking == 0)
        #expect(b.activity == .working)
        b.clearAgents()
        #expect(b.isEmpty)
    }

    @Test func ancestorsWalkUpToLaunchd() {
        let chain = ClaudeAgents.ancestors(getpid())
        #expect(chain.first == getpid())
        #expect(chain.contains(getppid()))
    }
}
