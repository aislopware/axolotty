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

    @Test func openAndPbcopyPassThroughUnlessAFarPersonTakesIt() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "axshim-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }
        let bin = root.appending(path: "bin $HOME `x`"), sys = root.appending(path: "sys")
        for d in [bin, sys] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let log = root.appending(path: "log").path(percentEncoded: false)
        func exe(_ url: URL, _ text: String) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }
        // The system's commands and the CLI write down how they were called.
        try exe(sys.appending(path: "open"), "#!/bin/sh\necho \"open $*\" >> '\(log)'\n")
        try exe(sys.appending(path: "pbcopy"), "#!/bin/sh\necho \"pbcopy $* <$(cat)>\" >> '\(log)'\n")
        let cli = bin.appending(path: "axolotty")
        func run(_ name: String, _ args: [String], stdin: String = "") throws -> [String] {
            try? fm.removeItem(atPath: log)
            let shim = root.appending(path: name)
            try exe(shim, ShellEnvironment.shim(name, cli: cli.path(percentEncoded: false), system: sys.path(percentEncoded: false)))
            let p = Process()
            p.executableURL = shim
            p.arguments = args
            let input = Pipe()
            p.standardInput = input
            try p.run()
            try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
            try input.fileHandleForWriting.close()
            p.waitUntilExit()
            return ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        // No CLI (an old install): the system's own, untouched.
        #expect(try run("open", ["https://a.example"]) == ["open https://a.example"])
        #expect(try run("pbcopy", [], stdin: "hi") == ["pbcopy  <hi>"])

        // The far person takes the link (exit 0) or it is this Mac's (exit 1).
        try exe(cli, "#!/bin/sh\necho \"cli $*\" >> '\(log)'\nexit 0\n")
        #expect(try run("open", ["https://a.example"]) == ["cli open-url https://a.example"])
        try exe(cli, "#!/bin/sh\necho \"cli $*\" >> '\(log)'\nexit 1\n")
        #expect(try run("open", ["https://a.example"]) == ["cli open-url https://a.example", "open https://a.example"])
        // Only a lone web link is ever asked about.
        #expect(try run("open", ["-a", "Safari", "https://a.example"]) == ["open -a Safari https://a.example"])
        #expect(try run("open", ["."]) == ["open ."])
        #expect(try run("open", ["file:///tmp"]) == ["open file:///tmp"])

        // pbcopy goes through the CLI, which is told where the real one is.
        try exe(cli, "#!/bin/sh\necho \"cli $* via $AXOLOTTY_SYSTEM_PBCOPY\" >> '\(log)'\n")
        #expect(try run("pbcopy", ["-pboard", "find"]) == ["cli pbcopy -pboard find via \(sys.path(percentEncoded: false))/pbcopy"])
    }
}
