public import Foundation

/// A path a pane printed, as the host that ran the pane finds it: absolute,
/// and a file or a folder. A far pane's ⌘-click underlines only what exists
/// there (`ClientMessage.paths`), as a near pane's does here.
public struct HostPath: Codable, Hashable, Sendable {
    public var path: String
    public var isFolder: Bool

    public init(path: String, isFolder: Bool) {
        self.path = path
        self.isFolder = isFolder
    }

    /// At most this many candidates are looked up per ask (a screenful).
    public static let maxBatch = 256

    /// Each candidate resolved where this runs: `~` to this user's home, a
    /// relative path against `cwd`; nil for what doesn't exist.
    public static func resolve(_ candidates: [String], cwd: String,
                               home: String = NSHomeDirectory()) -> [HostPath?] {
        candidates.prefix(maxBatch).map { c in
            var p = c
            if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
            if !p.hasPrefix("/") {
                guard cwd.hasPrefix("/") else { return nil }
                p = (cwd as NSString).appendingPathComponent(p)
            }
            p = (p as NSString).standardizingPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else { return nil }
            return HostPath(path: p, isFolder: isDir.boolValue)
        }
    }
}
