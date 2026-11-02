public import Foundation

/// Where the processes of one user meet. All under a 0700 directory.
public struct RuntimePaths: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/Axolotty`, or `$AXOLOTTY_HOME` (tests, side-by-side dev builds).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> RuntimePaths {
        if let home = environment["AXOLOTTY_HOME"], !home.isEmpty {
            return RuntimePaths(root: URL(filePath: home, directoryHint: .isDirectory))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return RuntimePaths(root: base.appending(path: "Axolotty", directoryHint: .isDirectory))
    }

    public var run: URL { root.appending(path: "run", directoryHint: .isDirectory) }
    public var hostSocket: URL { run.appending(path: "d.sock") }
    public var holderSocket: URL { run.appending(path: "ptyd.sock") }
    public var holderLock: URL { run.appending(path: "ptyd.lock") }
    public var state: URL { root.appending(path: "state", directoryHint: .isDirectory) }
    public var document: URL { state.appending(path: "workspace.json") }
    public var checkpoints: URL { state.appending(path: "checkpoints", directoryHint: .isDirectory) }
    public var shellIntegration: URL { root.appending(path: "shell", directoryHint: .isDirectory) }
    public var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    /// An MCP config naming `axolotty mcp`, for `claude --mcp-config "$AXOLOTTY_MCP"`.
    public var mcpConfig: URL { root.appending(path: "mcp.json") }
    public var identity: URL { state.appending(path: "host.json") }

    /// Creates the private directories (0700).
    public func prepare() throws {
        for dir in [root, run, state, checkpoints, shellIntegration, bin] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }
}
