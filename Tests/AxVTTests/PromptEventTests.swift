import AxVT
import Testing

@Suite struct PromptEventTests {
    @Test func cmdlineURLIsDecoded() throws {
        let t = try VTTerminal(cols: 40, rows: 4)
        let ev = t.write("\u{1b}]133;A\u{7}$ \u{1b}]133;C;cmdline_url=make%20test%3B%20echo%20ok\u{7}out\r\n\u{1b}]133;D;2\u{7}")
        let prompts = ev.compactMap { e -> VTPromptEvent? in if case let .prompt(p) = e { return p }; return nil }
        #expect(prompts.contains(.commandStart(command: "make test; echo ok")))
        #expect(prompts.contains(.commandEnd(exitCode: 2)))
    }
}

@Suite struct CommandOutputTests {
    private func prompt(_ cmd: String) -> String { "\u{1b}]133;A\u{7}$ \(cmd)\r\n\u{1b}]133;C\u{7}" }
    private let end = "\u{1b}]133;D;0\u{7}"

    @Test func lastOutputIsTheLatestCommands() throws {
        let t = try VTTerminal(cols: 40, rows: 10)
        _ = t.write(prompt("ls") + "a.txt\r\nb.txt\r\n" + end + prompt("echo hi") + "hi\r\n" + end + "\u{1b}]133;A\u{7}$ ")
        #expect(t.lastCommandOutput() == "hi")
    }

    @Test func aRunningCommandGivesItsOutputSoFar() throws {
        let t = try VTTerminal(cols: 40, rows: 10)
        _ = t.write(prompt("make") + "step 1\r\nstep 2\r\n")
        #expect(t.lastCommandOutput() == "step 1\nstep 2")
    }

    @Test func noMarksNoOutput() throws {
        let t = try VTTerminal(cols: 40, rows: 4)
        _ = t.write("plain text\r\n")
        #expect(t.lastCommandOutput() == nil)
    }

    @Test func promptJumpsMoveTheViewport() throws {
        let t = try VTTerminal(cols: 20, rows: 4)
        var s = ""
        for i in 0 ..< 6 { s += prompt("c\(i)") + "out \(i)\r\nmore\r\n" + end }
        _ = t.write(s + "\u{1b}]133;A\u{7}$ ")
        #expect(!t.isScrolledBack)
        t.scrollViewport(.prompts(-1))
        #expect(t.isScrolledBack)
        let first = t.line(atViewportRow: 0)?.text ?? ""
        #expect(first.hasPrefix("$ c"))
    }
}
