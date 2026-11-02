import Foundation

/// What the worktree picker offers for one repository: the branch new work
/// starts from, the local branches (most recent first), and which of them
/// already have a worktree. Read on a local host only; a remote host's
/// picker offers a new branch alone (its git runs there).
nonisolated struct WorktreeSource: Sendable {
    /// The branch the main worktree has checked out ("main"); nil if detached.
    var base: String?
    var branches: [String] = []
    /// Branch → folder, for linked worktrees under `.worktrees/`.
    var worktrees: [String: String] = [:]
    /// Branches checked out anywhere (the main worktree included): git
    /// refuses a second checkout of these, except to reopen ours.
    var checkedOut: Set<String> = []

    static func read(_ dir: String) async -> WorktreeSource? {
        await Task.detached(priority: .userInitiated) { () -> WorktreeSource? in
            guard GitChangesReader.git(["rev-parse", "--git-dir"], in: dir) != nil else { return nil }
            var s = WorktreeSource()
            s.base = GitChangesReader.git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir)
            s.branches = (GitChangesReader.git(["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)",
                                                "refs/heads"], in: dir) ?? "")
                .split(separator: "\n").map(String.init)
            var path: String?
            for line in (GitChangesReader.git(["worktree", "list", "--porcelain"], in: dir) ?? "").split(separator: "\n") {
                if line.hasPrefix("worktree ") {
                    path = String(line.dropFirst("worktree ".count))
                } else if line.hasPrefix("branch refs/heads/"), let p = path {
                    let b = String(line.dropFirst("branch refs/heads/".count))
                    s.checkedOut.insert(b)
                    if URL(filePath: p).deletingLastPathComponent().lastPathComponent == ".worktrees" { s.worktrees[b] = p }
                }
            }
            return s
        }.value
    }

    /// A typed name as a branch: spaces become dashes, nothing else is
    /// rewritten (git has the last word).
    static func branchName(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}
