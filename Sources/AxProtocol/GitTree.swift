import Foundation

/// What changed in a working tree against HEAD: tracked edits (staged and
/// unstaged, from `git diff --numstat HEAD`) plus untracked files (counted as
/// all-added lines). Read for the band's diff chip and the Changes popover.
///
/// Git runs with `GIT_OPTIONAL_LOCKS=0` and `--no-optional-locks`, so reading
/// never takes the index lock an agent's own `git` may need; a read that
/// takes longer than 2 s is abandoned. Read where the tree is: this Mac for
/// its own panes, the host for a far one's (`ClientMessage.git`).
public struct GitChanges: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Equatable, Sendable { case modified, added, deleted, renamed, untracked }
        /// Relative to the repository root.
        public var path: String
        public var added: Int
        public var removed: Int
        public var kind: Kind
        /// Binary files report no line counts.
        public var binary = false

        public init(path: String, added: Int, removed: Int, kind: Kind, binary: Bool = false) {
            self.path = path
            self.added = added
            self.removed = removed
            self.kind = kind
            self.binary = binary
        }
    }

    public var root: String
    public var files: [File]
    /// Commits HEAD has that its upstream lacks, and the reverse; nil with no upstream.
    public var ahead: Int?
    public var behind: Int?
    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
    public var isEmpty: Bool { files.isEmpty }

    public init(root: String, files: [File], ahead: Int? = nil, behind: Int? = nil) {
        self.root = root
        self.files = files
        self.ahead = ahead
        self.behind = behind
    }
}

/// A working tree's branch and changes, as one answer (`HostMessage.gitTree`).
public struct GitReport: Codable, Equatable, Sendable {
    public var branch: String?
    public var changes: GitChanges?

    public init(branch: String?, changes: GitChanges?) {
        self.branch = branch
        self.changes = changes
    }

    /// Reads both for `dir`, here (blocking: call off the main thread).
    public static func read(_ dir: String) -> GitReport {
        GitReport(branch: GitTree.branch(dir), changes: GitTree.changes(dir))
    }
}


/// Git, read where the tree is (no caching here; callers cache).
public enum GitTree {
    /// A tree with more changes than this is summarised by its first ones.
    public static let maxFiles = 1000

    public static func changes(_ dir: String) -> GitChanges? {
        guard !dir.isEmpty, let top = git(["rev-parse", "--show-toplevel"], in: dir)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !top.isEmpty
        else { return nil }
        var files: [String: GitChanges.File] = [:]
        var order: [String] = []
        func put(_ f: GitChanges.File) {
            if files[f.path] == nil { order.append(f.path) }
            files[f.path] = f
        }
        // Kinds from status (porcelain v1, NUL-separated; renames carry the old path next).
        if let status = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: top) {
            var parts = status.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
            while let entry = parts.next(), order.count < maxFiles {
                guard entry.count > 3 else { continue }
                let xy = entry.prefix(2)
                let path = String(entry.dropFirst(3))
                let kind: GitChanges.File.Kind
                if xy == "??" {
                    kind = .untracked
                } else if xy.contains("R") {
                    kind = .renamed
                    _ = parts.next()  // the old path
                } else if xy.contains("A") {
                    kind = .added
                } else if xy.contains("D") {
                    kind = .deleted
                } else {
                    kind = .modified
                }
                put(GitChanges.File(path: path, added: 0, removed: 0, kind: kind))
            }
        }
        // Line counts against HEAD (staged + unstaged). A repo with no commit yet has no HEAD.
        if let numstat = git(["diff", "--numstat", "-z", "--no-renames", "HEAD"], in: top) {
            for line in numstat.split(separator: "\0", omittingEmptySubsequences: true).prefix(maxFiles) {
                let cols = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                guard cols.count == 3 else { continue }
                let path = String(cols[2])
                var f = files[path] ?? GitChanges.File(path: path, added: 0, removed: 0, kind: .modified)
                f.binary = cols[0] == "-"
                f.added = Int(cols[0]) ?? 0
                f.removed = Int(cols[1]) ?? 0
                put(f)
            }
        }
        // Untracked files count every line as added (small text files, the first 200).
        for p in order.lazy.filter({ files[$0]?.kind == .untracked }).prefix(200) {
            let url = URL(filePath: top).appending(path: p)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
                  let size = attrs[.size] as? Int, size < 1 << 20,
                  let data = try? Data(contentsOf: url)
            else { continue }
            if data.contains(0) {
                files[p]?.binary = true
            } else {
                var n = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
                if let last = data.last, last != 0x0A, !data.isEmpty { n += 1 }
                files[p]?.added = n
            }
        }
        let list = order.compactMap { files[$0] }
        var result = GitChanges(root: top, files: list)
        // Local refs only: nothing here fetches.
        if let counts = git(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: top) {
            let n = counts.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
            if n.count == 2 {
                result.ahead = n[0]
                result.behind = n[1]
            }
        }
        return result
    }

    /// Runs git with a 2 s budget; nil on failure.
    public static func git(_ args: [String], in dir: String) -> String? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks", "-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = DispatchTime.now() + .seconds(2)
        let done = DispatchSemaphore(value: 0)
        // Read on another thread so a hung git can be abandoned at the deadline;
        // the box is written once, before the signal, and read only after it.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = reader.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: box.data, as: UTF8.self)
    }

    /// The branch checked out at `dir` (walks up to `.git`, follows `gitdir:`
    /// files for worktrees); a short hash when detached.
    public static func branch(_ dir: String) -> String? {
        var url = URL(filePath: dir, directoryHint: .isDirectory)
        let fm = FileManager.default
        for _ in 0 ..< 32 {
            let git = url.appending(path: ".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path(percentEncoded: false), isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue, let s = try? String(contentsOf: git, encoding: .utf8),
                   let line = s.split(separator: "\n").first, line.hasPrefix("gitdir:")
                {
                    let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(filePath: p) : url.appending(path: p)
                }
                guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return String(h.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == url.path(percentEncoded: false) { break }
            url = parent
        }
        return nil
    }
}
