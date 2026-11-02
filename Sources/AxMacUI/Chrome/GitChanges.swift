import AxClient
import AxProtocol
import Foundation

@MainActor
enum GitChangesReader {
    private static var cache: [String: (value: GitChanges?, at: Date)] = [:]
    private static var inflight: [String: Task<GitChanges?, Never>] = [:]

    /// Cached for 3 s per directory; concurrent asks share one read.
    static func lookup(_ dir: String, fresh: Bool = false) async -> GitChanges? {
        if !fresh, let hit = cache[dir], Date().timeIntervalSince(hit.at) < 3 { return hit.value }
        if let t = inflight[dir] { return await t.value }
        let t = Task.detached(priority: .utility) { GitChangesReader.read(dir) }
        inflight[dir] = t
        let v = await t.value
        inflight[dir] = nil
        cache[dir] = (v, Date())
        return v
    }

    static func cached(_ dir: String) -> GitChanges?? {
        guard let hit = cache[dir] else { return nil }
        return .some(hit.value)
    }

    nonisolated static func read(_ dir: String) -> GitChanges? { GitTree.changes(dir) }
    nonisolated static func git(_ args: [String], in dir: String) -> String? { GitTree.git(args, in: dir) }
}

/// Reads the current git branch for a directory (walks up to `.git`, follows
/// `gitdir:` files for worktrees). Cached; runs off the main thread.
enum GitBranch {
    private static var cache: [String: (branch: String?, at: Date)] = [:]

    static func cached(_ dir: String) -> String?? {
        guard let hit = cache[dir], Date().timeIntervalSince(hit.at) < 5 else { return nil }
        return .some(hit.branch)
    }

    static func lookup(_ dir: String) async -> String? {
        if let hit = cached(dir) { return hit }
        let branch = await Task.detached(priority: .utility) { read(dir) }.value
        cache[dir] = (branch, Date())
        return branch
    }

    nonisolated static func read(_ dir: String) -> String? { GitTree.branch(dir) }
}

/// A pane's branch and changes wherever its tree is: read here for this
/// Mac's panes, asked of the host for a far one's (a host too old to say
/// answers nothing). Far answers are cached 3 s per host and path, and
/// concurrent asks share one.
@MainActor
enum GitFacts {
    private struct Key: Hashable {
        let host: UUID
        let dir: String
    }

    private static var cache: [Key: (report: GitReport, at: Date)] = [:]
    private static var inflight: [Key: Task<GitReport, Never>] = [:]

    /// What is known already, without asking.
    static func cached(_ host: HostSession, _ dir: String) -> GitReport? {
        if host.isLocal {
            let b = GitBranch.cached(dir), c = GitChangesReader.cached(dir)
            guard b != nil || c != nil else { return nil }
            return GitReport(branch: b ?? nil, changes: c ?? nil)
        }
        return cache[Key(host: host.id, dir: dir)]?.report
    }

    static func lookup(_ host: HostSession, _ dir: String) async -> GitReport {
        if host.isLocal {
            async let b = GitBranch.lookup(dir)
            async let c = GitChangesReader.lookup(dir)
            return await GitReport(branch: b, changes: c)
        }
        let key = Key(host: host.id, dir: dir)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3 { return hit.report }
        if let t = inflight[key] { return await t.value }
        let connection = host.connection
        let t = Task { await connection.git(dir) ?? GitReport(branch: nil, changes: nil) }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        cache[key] = (r, Date())
        return r
    }
}
