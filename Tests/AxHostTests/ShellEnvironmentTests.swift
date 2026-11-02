@testable import AxHost
import AxModel
import AxProtocol
import Foundation
import Testing

@Suite struct ShellEnvironmentTests {
    private let paths = RuntimePaths(root: FileManager.default.temporaryDirectory
        .appending(path: "ax-env-\(UUID().uuidString.prefix(8))"))

    private func env(_ base: [String: String]) -> [String: String] {
        let list = ShellEnvironment.environment(pane: PaneID(), recipe: SpawnRecipe(), paths: paths, base: base)
        return Dictionary(uniqueKeysWithValues: list.map {
            let i = $0.firstIndex(of: "=")!
            return (String($0[..<i]), String($0[$0.index(after: i)...]))
        })
    }

    @Test func aPaneIsNeverInsideTheAgentThatStartedTheServer() {
        let e = env(["PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
                     "CLAUDE_CODE_CHILD_SESSION": "x", "CLAUDE_CODE_USE_BEDROCK": "1"])
        #expect(e["CLAUDECODE"] == nil && e["CLAUDE_CODE_ENTRYPOINT"] == nil && e["CLAUDE_CODE_CHILD_SESSION"] == nil)
        #expect(e["CLAUDE_CODE_USE_BEDROCK"] == "1")  // the person's own configuration stays
        // Nor does the agent's session reach the pane's programs.
        let f = env(["CLAUDE_CODE_SESSION_ID": "s", "CLAUDE_PID": "1", "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/x",
                     "CLAUDE_CODE_MESSAGING_TOKEN": "t", "CLAUDE_CODE_DISABLE_FAST_MODE": "1"])
        #expect(f["CLAUDE_CODE_SESSION_ID"] == nil && f["CLAUDE_PID"] == nil)
        #expect(f["CLAUDE_CODE_MESSAGING_SOCKET"] == nil && f["CLAUDE_CODE_MESSAGING_TOKEN"] == nil)
        #expect(f["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
    }

    @Test func theCLIComesFirstOnPath() throws {
        let e = env(["PATH": "/usr/bin:/bin"])
        let bin = try #require(e["AXOLOTTY_BIN"])
        #expect(!bin.hasSuffix("/"))
        #expect(e["PATH"] == bin + ":/usr/bin:/bin")
    }

    @Test func installWritesEveryShellsIntegration() throws {
        try paths.prepare()
        try ShellEnvironment.install(paths)
        let fm = FileManager.default
        for rel in ["zsh/.zshenv", "bash/axolotty.bash", "fish/vendor_conf.d/axolotty.fish"] {
            #expect(fm.fileExists(atPath: paths.shellIntegration.appending(path: rel).path(percentEncoded: false)), "\(rel)")
        }
        let bash = try String(contentsOf: paths.shellIntegration.appending(path: "bash/axolotty.bash"), encoding: .utf8)
        #expect(bash.contains("133;C;cmdline_url="))
    }

    @Test func installLinksTheCLI() throws {
        try paths.prepare()
        let cli = URL(filePath: "/usr/bin/true")
        try ShellEnvironment.install(paths, cli: cli)
        try ShellEnvironment.install(paths, cli: cli)  // idempotent
        let link = paths.bin.appending(path: "axolotty").path(percentEncoded: false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "/usr/bin/true")
    }
}
