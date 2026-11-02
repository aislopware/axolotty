import AxClient
import AxHost
import AxModel
import AxProtocol
import AxVT
import Foundation
import Testing

/// End-to-end: server + holder + shells + clients over the real socket.
@Suite("Host end to end", .timeLimit(.minutes(1)))
struct HostTests {
    @Test func sessionStreamsIntoAMirror() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, s, p) = try await makeSession(c)
        let replica = try #require(c.replica)
        #expect(replica.sessions[s]?.tree == .leaf(p))
        #expect(replica.invariantViolations.isEmpty)

        let m = c.attach(p)
        c.send(.text(p, "echo axo-$((40+2))\n"))
        #expect(await waitScreen(m, contains: "axo-42"))
        let captured = await c.capture(p)
        #expect(captured?.contains("axo-42") == true)
        await fx.tearDown()
    }

    @Test func lateJoinerSeesTheSameScreen() async throws {
        let fx = try await HostFixture()
        let a = try await fx.client("a")
        let (_, _, p) = try await makeSession(a)
        let ma = a.attach(p)
        a.send(.text(p, "printf 'late-%s\\n' joiner\n"))
        #expect(await waitScreen(ma, contains: "late-joiner"))

        let b = try await fx.client("b")
        let mb = b.attach(p)
        #expect(await waitScreen(mb, contains: "late-joiner"), "snapshot carries the screen")
        b.send(.text(p, "echo from-b\n"))
        #expect(await waitScreen(ma, contains: "from-b"), "input from any client reaches every mirror")
        #expect(await waitScreen(mb, contains: "from-b"))
        await fx.tearDown()
    }

    /// The point of the three-process design: restart the server, keep the program.
    @Test func serverRestartKeepsProgramsAndScreen() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, s, p) = try await makeSession(c)
        let m = c.attach(p)
        // Wait for the output line itself: the echoed command line contains the marker first.
        func output(_ m: MirrorTerminal, _ marker: String) -> String? {
            screen(m).split(separator: "\n").last { $0.hasPrefix("pid=") && $0.contains(marker) }.map(String.init)
        }
        c.send(.text(p, "echo pid=$$ marker-before\n"))
        #expect(await until { output(m, "marker-before") != nil })
        let pidLine = output(m, "marker-before")

        try await fx.restart()
        #expect(await until { c.isConnected }, "the client reconnects by itself")
        #expect(c.replica?.sessions[s] != nil)
        #expect(await fx.host.paneCount == 1)

        let fresh = try await fx.client("fresh")
        let m2 = fresh.attach(p)
        #expect(await waitScreen(m2, contains: "marker-before"), "screen restored from checkpoint + journal")
        fresh.send(.text(p, "echo pid=$$ marker-after\n"))
        #expect(await until { output(m2, "marker-after") != nil })
        let after = output(m2, "marker-after")
        #expect(pidLine?.replacingOccurrences(of: "marker-before", with: "")
            == after?.replacingOccurrences(of: "marker-after", with: ""), "same shell process")
        #expect(await waitScreen(m, contains: "marker-after"), "the old client's mirror resumed too")
        await fx.tearDown()
    }

    /// The holder itself crashes: the server still has every master and journal,
    /// launches a new holder and hands the live programs over.
    @Test func holderCrashIsSurvived() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        let m = c.attach(p)
        c.send(.text(p, "echo pre-crash\n"))
        #expect(await waitScreen(m, contains: "pre-crash"))

        let socket = fx.paths.holderSocket.path(percentEncoded: false)
        let old = try CustodyClient(socketPath: socket).holderPid
        kill(old, SIGKILL)
        let adopted = await until {
            guard let probe = try? CustodyClient(socketPath: socket), probe.holderPid != old else { return false }
            return (try? await probe.list().map(\.id)) == [p]
        }
        #expect(adopted, "a new holder took custody of the running shell")
        c.send(.text(p, "echo post-crash\n"))
        #expect(await waitScreen(m, contains: "post-crash"))
        await fx.tearDown()
    }

    @Test func cleanExitClosesThePaneAndSession() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (w, s, p) = try await makeSession(c)
        c.send(.text(p, "exit\n"))
        #expect(await until { c.replica?.sessions[s] == nil })
        #expect(c.replica?.panes[p] == nil)
        #expect(c.replica?.workspace(w)?.sessions.isEmpty == true)
        #expect(c.replica?.invariantViolations.isEmpty == true)
        await fx.tearDown()
    }

    @Test func failedExitKeepsThePaneWithItsStatus() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        c.send(.text(p, "exit 7\n"))
        #expect(await until { c.replica?.panes[p]?.exitStatus == 7 })
        #expect(c.replica?.panes[p]?.activity == .error)
        await fx.tearDown()
    }

    @Test func aWorktreeSessionLivesAndGoesWithItsFolder() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "axwt-\(UUID().uuidString.prefix(8))")
            .path(percentEncoded: false).replacingOccurrences(of: "//", with: "/")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func sh(_ line: String) {
            let p = Process()
            p.executableURL = URL(filePath: "/bin/sh")
            p.arguments = ["-c", line]
            p.currentDirectoryURL = URL(filePath: repo)
            try? p.run()
            p.waitUntilExit()
        }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        sh("git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init")

        let fx = try await HostFixture()
        let c = try await fx.client()
        let w = WorkspaceID(), sid = SessionID(), p = PaneID()
        try await c.perform(.createWorkspace(w, name: "repo", root: repo))
        try await c.perform(.createSession(sid, workspace: w, pane: p, recipe: SpawnRecipe(worktree: "feat/login"), name: "feat/login"))
        let real = URL(filePath: repo).resolvingSymlinksInPath().path(percentEncoded: false)
        let path = try #require(c.replica?.sessions[sid]?.worktree)
        #expect(path.hasSuffix("/.worktrees/feat-login"))
        #expect(FileManager.default.fileExists(atPath: path + "/.git"))
        #expect(await until { c.replica?.panes[p]?.pwd.hasSuffix("/.worktrees/feat-login") == true })
        let exclude = try String(contentsOfFile: real + "/.git/info/exclude", encoding: .utf8)
        #expect(exclude.contains("/.worktrees/"))

        // A second session on the same branch reuses the folder.
        let sid2 = SessionID()
        try await c.perform(.createSession(sid2, workspace: w, pane: PaneID(), recipe: SpawnRecipe(worktree: "feat/login"), name: nil))
        #expect(c.replica?.sessions[sid2]?.worktree == path)

        // Changes make removal ask; forced, the folder goes and the branch stays.
        try "x".write(toFile: path + "/new.txt", atomically: true, encoding: .utf8)
        await #expect(throws: ConnectionError.intent(.dirty)) { try await c.perform(.removeWorktree(sid, force: false)) }
        try await c.perform(.removeWorktree(sid, force: true))
        #expect(c.replica?.sessions[sid] == nil)
        #expect(c.replica?.sessions[sid2]?.worktree == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        sh("git show-ref --verify --quiet refs/heads/feat/login && touch kept")
        #expect(FileManager.default.fileExists(atPath: repo + "/kept"))

        // Not a repository: refused, nothing created.
        await #expect(throws: ConnectionError.intent(.worktreeFailed)) {
            try await c.perform(.createSession(SessionID(), workspace: w, pane: PaneID(),
                                               recipe: SpawnRecipe(cwd: "/tmp", worktree: "x"), name: nil))
        }
        await fx.tearDown()
    }

    @Test func anEndedPaneRestartsInItsSlot() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, sid, p) = try await makeSession(c, command: ["echo started; read x; exit 3"])
        c.send(.text(p, "\n"))
        #expect(await until { c.replica?.panes[p]?.exitStatus == 3 })
        // A running pane is not restarted.
        let q = PaneID()
        let running = try await makeSession(c).2
        await #expect(throws: (any Error).self) { try await c.perform(.restartPane(running, new: q)) }
        try await c.perform(.restartPane(p, new: q))
        #expect(c.replica?.panes[p] == nil)
        #expect(c.replica?.sessions[sid]?.tree.panes == [q])
        #expect(c.replica?.sessions[sid]?.focus == q)
        #expect(c.replica?.panes[q]?.launch == ["echo started; read x; exit 3"])
        c.send(.text(q, "\n"))
        #expect(await until { c.replica?.panes[q]?.exitStatus == 3 })  // the same command ran again
        await fx.tearDown()
    }

    @Test func programStatusBecomesSharedStateAndAttention() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        var attention: [(PaneID, Activity)] = []
        let listen = Task { () -> (PaneID, Activity)? in
            for await e in c.events {
                if case let .event(.attention(id, a, _)) = e { return (id, a) }
            }
            return nil
        }
        c.send(.text(p, "printf '\\033]7501;state=blocked:kind=permission:app=claude-code:id=t\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .blocked })
        if let got = await listen.value { attention.append(got) }
        #expect(attention.first?.0 == p)
        #expect(attention.first?.1 == .blocked)

        c.send(.seen(p))  // seen does not clear blocked …
        await c.ping()
        #expect(c.replica?.panes[p]?.activity == .blocked)
        c.send(.text(p, "printf '\\033]7501;state=done:id=t\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .done })
        c.send(.seen(p))  // … but clears done
        #expect(await until { c.replica?.panes[p]?.activity == .idle })
        await fx.tearDown()
    }

    /// `wait --for done` sees a finish the person saw (and so cleared) before
    /// the waiter looked: by then the replica says idle, the changes say done.
    @Test func aWaiterCatchesAFinishSeenBeforeItLooked() async throws {
        let fx = try await HostFixture()
        let app = try await fx.client("app")
        let (_, _, p) = try await makeSession(app)
        app.send(.text(p, "printf '\\033]7501;state=working:app=claude-code\\033\\\\'\n"))
        #expect(await until { app.replica?.panes[p]?.activity == .working })

        let waiter = try await fx.client("waiter")
        let watch = PaneWait(goal: .done, panes: [p], state: try #require(waiter.replica))
        #expect(watch.reachedNow().isEmpty)
        app.send(.text(p, "printf '\\033]7501;state=done\\033\\\\'\n"))
        #expect(await until { app.replica?.panes[p]?.activity == .done })
        app.send(.seen(p))  // what the app does for a finish in front of the person
        #expect(await until { waiter.replica?.panes[p]?.activity == .idle })

        let reader = Task {
            var watch = watch
            for await e in waiter.events {
                if case let .deltas(ds) = e, !watch.feed(ds).isEmpty { return true }
            }
            return false
        }
        let timer = Task {
            try? await Task.sleep(for: .seconds(5))
            reader.cancel()
        }
        #expect(await reader.value)
        timer.cancel()
        await fx.tearDown()
    }

    @Test func aFinishedRunLeavesItsLengthAsAReceipt() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        #expect(c.replica?.panes[p]?.lastRun == nil)
        c.send(.text(p, "printf '\\033]7501;state=working:app=claude-code\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .working })
        try await Task.sleep(for: .milliseconds(300))
        c.send(.text(p, "printf '\\033]7501;state=done\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .done })
        let run = try #require(c.replica?.panes[p]?.lastRun)
        #expect(run >= 0.25 && run < 5)
        // Seeing it keeps the receipt; the next run replaces it only when it ends.
        c.send(.seen(p))
        #expect(await until { c.replica?.panes[p]?.activity == .idle })
        #expect(c.replica?.panes[p]?.lastRun == run)
        await fx.tearDown()
    }

    @Test func theMacStaysAwakeOnlyWhileSomethingWorks() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        #expect(await fx.host.holdsWake == false)
        c.send(.text(p, "printf '\\033]7501;state=working:app=claude-code\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .working })
        #expect(await fx.host.holdsWake)
        c.send(.text(p, "printf '\\033]7501;state=done\\033\\\\'\n"))
        #expect(await until { c.replica?.panes[p]?.activity == .done })
        #expect(await fx.host.holdsWake == false)
        await fx.tearDown()
    }

    @Test func aHiddenLineIsReported() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        c.send(.text(p, "stty -echo; printf 'Password:'; read x; stty echo; echo done\n"))
        #expect(await until { c.replica?.panes[p]?.readsSecret == true })
        c.send(.text(p, "hunter2\n"))
        #expect(await until { c.replica?.panes[p]?.readsSecret == nil })
        await fx.tearDown()
    }

    @Test func aListeningPortIsReported() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        // In the background, so the shell stays in front: ports count anywhere in the tree.
        c.send(.text(p, "python3 -c 'import socket,time;s=socket.socket();s.bind((\"127.0.0.1\",0));s.listen();time.sleep(30)' & echo started\n"))
        #expect(await until { (c.replica?.panes[p]?.ports?.count ?? 0) == 1 })
        c.send(.text(p, "kill %1\n"))
        #expect(await until { c.replica?.panes[p]?.ports == nil })
        await fx.tearDown()
    }

    @Test func progressKeepsItsTone() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        c.send(.text(p, "printf '\\033]9;4;1;40\\007'\n"))
        #expect(await until { c.replica?.panes[p]?.progress == 40 })
        #expect(c.replica?.panes[p]?.progressTone == .normal)
        c.send(.text(p, "printf '\\033]9;4;2\\007'\n"))
        #expect(await until { c.replica?.panes[p]?.progressTone == .error })
        #expect(c.replica?.panes[p]?.progress == 40)  // an error without a value keeps the bar where it stopped
        c.send(.text(p, "printf '\\033]9;4;3\\007'\n"))
        #expect(await until { c.replica?.panes[p]?.progress == -1 })
        c.send(.text(p, "printf '\\033]9;4;0\\007'\n"))
        #expect(await until { c.replica?.panes[p]?.progress == nil })
        #expect(c.replica?.panes[p]?.progressTone == nil)
        await fx.tearDown()
    }

    @Test func splitsCloseAndTreeEditsKeepInvariants() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (_, s, p) = try await makeSession(c)
        let q = PaneID(), r = PaneID()
        try await c.perform(.split(s, target: p, new: q, axis: .horizontal, before: false, recipe: SpawnRecipe()))
        try await c.perform(.split(s, target: q, new: r, axis: .vertical, before: true, recipe: SpawnRecipe()))
        var tree = try #require(c.replica?.sessions[s]?.tree)
        #expect(Set(tree.panes) == [p, q, r])
        #expect(c.replica?.sessions[s]?.focus == r)

        await #expect(throws: ConnectionError.intent(.invalid)) {
            try await c.perform(.setTree(s, .leaf(p)))
        }
        try await c.perform(.setTree(s, tree.swapping(p, r)))
        tree = try #require(c.replica?.sessions[s]?.tree)
        #expect(tree.panes.first == r)

        try await c.perform(.closePane(r))
        #expect(c.replica?.sessions[s]?.tree.panes.count == 2)
        #expect(c.replica?.panes[r] == nil)
        #expect(c.replica?.invariantViolations.isEmpty == true)
        // Retried intents are harmless.
        try await c.perform(.split(s, target: p, new: q, axis: .horizontal, before: false, recipe: SpawnRecipe()))
        #expect(c.replica?.sessions[s]?.tree.panes.count == 2)
        await fx.tearDown()
    }

    @Test func driverResizesThePTYAndEveryMirror() async throws {
        let fx = try await HostFixture()
        let a = try await fx.client("driver")
        let (_, _, p) = try await makeSession(a)
        let ma = a.attach(p)
        let b = try await fx.client("watcher")
        let mb = b.attach(p)
        #expect(await until { mb.isReady })

        a.send(.viewport(p, cols: 100, rows: 30, cellWidth: 8, cellHeight: 16))
        b.send(.viewport(p, cols: 40, rows: 10, cellWidth: 8, cellHeight: 16))  // not the driver: ignored
        a.send(.text(p, "stty size\n"))
        #expect(await waitScreen(ma, contains: "30 100"))
        #expect(await until { mb.withTerminal { $0.cols } == 100 })
        #expect(a.replica?.panes[p]?.cols == 100)

        b.send(.takeSize(p))
        b.send(.viewport(p, cols: 40, rows: 10, cellWidth: 8, cellHeight: 16))
        b.send(.text(p, "stty size\n"))
        #expect(await waitScreen(mb, contains: "10 40"))
        await fx.tearDown()
    }

    /// A client whose transport backs up is resynced with a snapshot instead of
    /// being fed an unbounded backlog; it still converges.
    @Test func laggingClientConvergesThroughResync() async throws {
        let fx = try await HostFixture { $0.limits.lagBytes = 0 }
        let c = try await fx.client()
        let (_, _, p) = try await makeSession(c)
        let m = c.attach(p)
        c.send(.text(p, "i=0; while [ $i -lt 300 ]; do echo line-$i; i=$((i+1)); done; echo done-marker\n"))
        #expect(await waitScreen(m, contains: "done-marker", timeout: .seconds(10)))
        await fx.tearDown()
    }

    @Test func workspacesMoveAndCloseSessions() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (w1, s, _) = try await makeSession(c)
        let w2 = WorkspaceID()
        try await c.perform(.createWorkspace(w2, name: "two", root: "/tmp"))
        try await c.perform(.moveSession(s, workspace: w2, index: 0))
        #expect(c.replica?.workspace(w1)?.sessions.isEmpty == true)
        #expect(c.replica?.workspace(w2)?.sessions == [s])
        try await c.perform(.closeWorkspace(w2))
        #expect(c.replica?.workspace(w2) == nil)
        #expect(c.replica?.panes.isEmpty == true)
        #expect(await fx.host.paneCount == 0)
        await fx.tearDown()
    }

    @Test func pinnedSessionsLeadTheirProjectAndUnreadIsAMark() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let (w, a, pa) = try await makeSession(c)
        let b = SessionID(), cc = SessionID()
        try await c.perform(.createSession(b, workspace: w, pane: PaneID(), recipe: SpawnRecipe(), name: nil))
        try await c.perform(.createSession(cc, workspace: w, pane: PaneID(), recipe: SpawnRecipe(), name: nil))
        #expect(c.replica?.workspace(w)?.sessions == [a, b, cc])
        try await c.perform(.setPinned(cc, true))
        try await c.perform(.setPinned(b, true))
        #expect(c.replica?.workspace(w)?.sessions == [cc, b, a])  // in the order pinned
        try await c.perform(.moveSession(a, workspace: w, index: 0))  // can't jump the pins
        #expect(c.replica?.workspace(w)?.sessions == [cc, b, a])
        try await c.perform(.setPinned(cc, false))
        #expect(c.replica?.workspace(w)?.sessions == [b, cc, a])
        #expect(c.replica?.sessions[cc]?.isPinned == false)

        try await c.perform(.setUnread(a, true))
        #expect(c.replica?.sessions[a]?.isUnread == true)
        c.send(.seen(pa))  // seeing a pane is not reading the mark; switching to it is (the client's call)
        await c.ping()
        #expect(c.replica?.sessions[a]?.isUnread == true)
        try await c.perform(.setUnread(a, false))
        #expect(c.replica?.sessions[a]?.isUnread == false)
        await fx.tearDown()
    }

    @Test func onlyOneServerPerRuntimeDirectory() async throws {
        let fx = try await HostFixture()
        let second = Server(config: fx.config)
        await #expect(throws: ServerError.alreadyRunning) { try await second.start() }
        await fx.tearDown()
    }
}
