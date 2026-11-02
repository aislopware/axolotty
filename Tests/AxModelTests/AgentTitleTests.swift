import AxModel
import Testing

@Suite struct AgentTitleTests {
    private let claude = ["claude code", "claude"]

    @Test(arguments: [
        ("✳ Fix login redirect", "Fix login redirect"),
        ("⠂ Fix login redirect", "Fix login redirect"),
        ("Claude Code · Fix login", "Fix login"),
        ("claude: refactor parser", "refactor parser"),
        ("Claude — tests", "tests"),
        ("Claude docs", "Claude docs"),
        ("Claude Code", "Claude Code"),
        ("✳ Claude Code", "Claude Code"),
        ("  ", ""),
        ("Fix login", "Fix login"),
    ])
    func trims(_ input: String, _ expected: String) {
        #expect(AgentTitle.trimmed(input, names: claude) == expected)
    }

    @Test func codexPrefix() {
        #expect(AgentTitle.trimmed("Codex | release notes", names: ["openai codex", "codex"]) == "release notes")
    }
}
