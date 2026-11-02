// Git worktrees for sessions: one branch per agent, side by side, under the
// repository's own `.worktrees/` (kept out of `git status` through
// `.git/info/exclude`, never the person's .gitignore). The host runs git, so a
// remote host makes its worktrees where its code is. A branch is never
// deleted here: removing a worktree only removes the folder.
import Foundation

public enum Worktrees {
    public struct Failure: Error, Sendable { public var message: String }

    /// Creates (or reuses) the worktree for `branch` of the repository that
    /// holds `dir`, checking out the branch if it exists or starting it from
    /// `dir`'s HEAD. Returns the worktree's path.
    public static func add(from dir: String, branch: String) throws(Failure) -> String {
        guard valid(branch) else { throw Failure(message: "“\(branch)” is not a branch name") }
        guard let main = mainRoot(of: dir), let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir)
        else { throw Failure(message: "\(dir) is not in a git repository") }
        let path = main + "/.worktrees/" + folder(for: branch)
        if let top = git(["rev-parse", "--show-toplevel"], in: path), top == path { return path }
        exclude(common: common)
        let exists = run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: dir).status == 0
        let r = exists ? run(["worktree", "add", path, branch], in: dir)
            : run(["worktree", "add", "-b", branch, path, "HEAD"], in: dir)
        guard r.status == 0 else { throw Failure(message: firstLine(r.err) ?? "git worktree add failed") }
        return path
    }

    /// Removes a worktree folder (its branch stays). Without `force` a tree
    /// with changes is refused and reported as nil.
    public static func remove(_ path: String, force: Bool) throws(Failure) {
        if !force, let changes = git(["status", "--porcelain"], in: path), !changes.isEmpty {
            throw Failure(message: "dirty")
        }
        guard let main = mainRoot(of: path) else { throw Failure(message: "\(path) is not a worktree") }
        let r = run(["worktree", "remove", "--force", path], in: main)
        guard r.status == 0 else { throw Failure(message: firstLine(r.err) ?? "git worktree remove failed") }
    }

    /// Whether `path` is a linked worktree Axolotty made (`…/.worktrees/x`).
    public static func isManaged(_ path: String) -> Bool {
        URL(filePath: path).deletingLastPathComponent().lastPathComponent == ".worktrees"
    }

    // MARK: Pieces

    /// The main worktree's root (where `.git` is a folder), from any worktree.
    static func mainRoot(of dir: String) -> String? {
        guard let common = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir) else { return nil }
        let url = URL(filePath: common)
        if url.lastPathComponent == ".git" { return url.deletingLastPathComponent().path(percentEncoded: false).trimmingSlash }
        return git(["rev-parse", "--show-toplevel"], in: dir)
    }

    static func valid(_ branch: String) -> Bool {
        !branch.isEmpty && !branch.hasPrefix("-") && run(["check-ref-format", "--branch", branch], in: "/").status == 0
    }

    /// One folder per branch: slashes become dashes (`feat/login` → `feat-login`).
    static func folder(for branch: String) -> String {
        branch.replacingOccurrences(of: "/", with: "-")
    }

    private static func exclude(common: String) {
        let file = URL(filePath: common).appending(path: "info/exclude")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !text.split(separator: "\n").contains(where: { $0 == ".worktrees/" || $0 == "/.worktrees/" }) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let add = (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "/.worktrees/\n"
        try? (text + add).write(to: file, atomically: true, encoding: .utf8)
    }

    private static func firstLine(_ s: String) -> String? {
        s.split(separator: "\n").first.map { String($0).replacingOccurrences(of: "fatal: ", with: "") }
    }

    /// Trimmed stdout, nil on failure.
    static func git(_ args: [String], in dir: String) -> String? {
        let r = run(args, in: dir)
        guard r.status == 0 else { return nil }
        return r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func run(_ args: [String], in dir: String) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-C", dir] + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

private extension String {
    var trimmingSlash: String { count > 1 && hasSuffix("/") ? String(dropLast()) : self }
}
