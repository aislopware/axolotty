import AxModel
import Testing

@Suite struct StatusBookTests {
    /// As Claude Code 2.1.316 reports them: its own record (id "") and one
    /// per subagent (a flat agent id), each gone when that subagent ends.
    @Test func subagentsAreTheOtherWorkingRecords() {
        var b = StatusBook()
        b.report(id: "", state: .working, app: "claude-code")
        #expect(b.subagentsWorking == 0)
        b.report(id: "ab89c272635bed8ac", state: .working)
        b.report(id: "a0c9a00a8a37d67d0", state: .working)
        #expect(b.subagentsWorking == 2)
        b.clear("ab89c272635bed8ac")
        #expect(b.subagentsWorking == 1)
        #expect(b.activity == .working)
    }

    @Test func reportReplacesWholeRecord() {
        var b = StatusBook()
        b.report(id: "", state: .working, app: "claude", message: "Reading files")
        b.report(id: "", state: .working)
        #expect(b.records[""]?.message == "")
        #expect(b.records[""]?.app == "")
    }

    @Test func clearRemovesSubtreeAndEmptyClearsAll() {
        var b = StatusBook()
        b.report(id: "build", state: .working)
        b.report(id: "build/test", state: .working)
        b.report(id: "builder", state: .working)
        b.clear("build")
        #expect(Set(b.records.keys) == ["builder"])
        b.clear("")
        #expect(b.isEmpty)
    }

    @Test func appInheritsFromNearestAncestor() {
        var b = StatusBook()
        b.report(id: "", state: .working, app: "deploy")
        b.report(id: "us-east", state: .working)
        b.report(id: "us-east/db", state: .working, app: "psql")
        #expect(b.app(of: "us-east") == "deploy")
        #expect(b.app(of: "us-east/db") == "psql")
        #expect(b.app(of: "us-east/db/x") == "psql")
    }

    @Test func promptEndsWorkAndBlockedButKeepsDoneUntilSeen() {
        var b = StatusBook()
        b.report(id: "a", state: .working)
        b.report(id: "b", state: .blocked)
        b.report(id: "c", state: .done)
        b.report(id: "d", state: .error)
        b.programEnded()
        #expect(Set(b.records.keys) == ["c", "d"])
        #expect(b.activity == .error)
        b.markSeen()
        #expect(b.isEmpty && b.activity == .idle)
    }

    @Test func headlineIsMostUrgentThenNewest() {
        var b = StatusBook()
        b.report(id: "x", state: .working, message: "old")
        b.report(id: "y", state: .working, message: "new")
        #expect(b.headline?.message == "new")
        b.report(id: "z", state: .blocked, message: "permission")
        #expect(b.activity == .blocked)
        #expect(b.headline?.message == "permission")
    }

    @Test func capacityEvictsLeastRecentlyUpdated() {
        var b = StatusBook()
        b.capacity = 3
        for i in 0 ..< 3 { b.report(id: "\(i)", state: .working) }
        b.report(id: "0", state: .working)  // refresh 0
        b.report(id: "3", state: .working)
        #expect(Set(b.records.keys) == ["0", "2", "3"])
    }

    @Test func activityOrderIsUrgency() {
        #expect(Activity.allCases.sorted() == [.idle, .done, .working, .error, .blocked])
    }
}

@Suite struct AgentKindTests {
    @Test("identifies agents from process name and argv", arguments: [
        ("claude", [String](), AgentKind?.some(.claude)),
        ("/usr/local/bin/codex", [], .codex),
        ("node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"], .claude),
        ("node", ["node", "/x/@openai/codex/bin/codex.js", "--yolo"], .codex),
        ("bun", ["bun", "run", "opencode"], .opencode),
        ("cursor-agent", [], .cursor),
        ("zsh", [], nil),
        ("node", ["node", "server.js"], nil),
        ("npx", ["npx", "vite"], nil),
    ])
    func identify(name: String, argv: [String], expected: AgentKind?) {
        #expect(AgentKind.identify(processName: name, argv: argv) == expected)
    }
}

@Suite struct FuzzyTests {
    @Test func matchesSubsequenceAndRejectsMissing() {
        #expect(Fuzzy.match("spl", in: "Split Right") != nil)
        #expect(Fuzzy.match("xyz", in: "Split Right") == nil)
        #expect(Fuzzy.match("", in: "anything")?.score == 0)
    }

    @Test func prefersWordStartsAndContiguity() {
        let ranked = Fuzzy.rank("sr", ["Close Session Rightmost", "Split Right", "sidebar"]) { $0 }.map(\.item)
        #expect(ranked.first == "Split Right")
        let r2 = Fuzzy.rank("term", ["Determine", "Terminal: Clear", "t e r m"]) { $0 }.map(\.item)
        #expect(r2.first == "Terminal: Clear")
    }

    @Test func positionsHighlightMatchedCharacters() {
        #expect(Fuzzy.match("nw", in: "New Window")?.positions == [0, 4])
    }
}

@Suite struct AskTests {
    @Test func wordsTheNeed() {
        #expect(StatusRecord(id: "", state: .blocked, message: "approve Bash: ls").ask == "Approve Bash: ls")
        #expect(StatusRecord(id: "", state: .blocked, need: .question).ask == "Has a question")
        #expect(StatusRecord(id: "", state: .blocked).ask == "Needs input")
        var book = StatusBook()
        book.report(id: "a", state: .working, need: .auth)
        #expect(book.records["a"]?.need == nil)  // only a blocked record waits for something
    }
}
