import Foundation

/// Where programs live on this Mac. The app and the server are started by
/// launchd, whose PATH is short, so the usual install folders are searched
/// after it. One list, so the "+" menu and the server agree on what is
/// installed.
public nonisolated enum Executables {
    public static let searchPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let h = "/" + home
        let env = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = [h + "/.local/bin", h + "/.claude/local", "/opt/homebrew/bin", "/usr/local/bin", h + "/.bun/bin",
                     h + "/.npm-global/bin", h + "/.cargo/bin", h + "/go/bin", h + "/.volta/bin", "/usr/bin"]
        var seen = Set<String>()
        return (env + usual).filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    /// The first `name` on the search path that can run.
    public static func find(_ name: String) -> String? {
        searchPath.lazy.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
