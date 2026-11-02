import Darwin
import Foundation

/// A Claude Code conversation that can be resumed: what it was first asked,
/// where, and when it was last spoken to.
nonisolated struct PastSession: Sendable, Hashable {
    var id: String
    var project: String
    var title: String
    var lastAt: Double
}

/// Past Claude Code sessions, read from Claude Code's own files and never
/// written: `history.jsonl` (each prompt with its project and session id),
/// `projects/*/<id>.jsonl` (a transcript must still exist to resume) and
/// `sessions/<pid>.json` (a session a live process holds is left out: two
/// processes appending to one transcript corrupt it).
nonisolated enum ClaudeHistory {
    static var root: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty { return URL(filePath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    }

    /// Newest first, at most `limit`.
    static func read(limit: Int = 400) async -> [PastSession] {
        await Task.detached(priority: .userInitiated) { scan(limit: limit) }.value
    }

    private static func scan(limit: Int) -> [PastSession] {
        guard let data = try? Data(contentsOf: root.appending(path: "history.jsonl")) else { return [] }
        var byID: [String: PastSession] = [:]
        for line in data.split(separator: 0x0A) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = obj["sessionId"] as? String, let project = obj["project"] as? String
            else { continue }
            let at = (obj["timestamp"] as? Double ?? 0) / 1000
            if var s = byID[id] {
                s.lastAt = max(s.lastAt, at)
                if s.title.isEmpty, let t = title(obj["display"] as? String ?? "") { s.title = t }
                byID[id] = s
            } else {
                byID[id] = PastSession(id: id, project: project, title: title(obj["display"] as? String ?? "") ?? "", lastAt: at)
            }
        }
        let resumable = transcripts()
        let held = live()
        let fm = FileManager.default
        var projectExists: [String: Bool] = [:]
        var out: [PastSession] = []
        for s in byID.values.sorted(by: { $0.lastAt > $1.lastAt }) {
            guard resumable.contains(s.id), !held.contains(s.id), !s.title.isEmpty else { continue }
            let exists = projectExists[s.project] ?? fm.fileExists(atPath: s.project)
            projectExists[s.project] = exists
            guard exists else { continue }
            out.append(s)
            if out.count >= limit { break }
        }
        return out
    }

    /// Session ids with a transcript on disk.
    private static func transcripts() -> Set<String> {
        let fm = FileManager.default
        let projects = root.appending(path: "projects")
        var ids = Set<String>()
        for dir in (try? fm.contentsOfDirectory(atPath: projects.path(percentEncoded: false))) ?? [] {
            for f in (try? fm.contentsOfDirectory(atPath: projects.appending(path: dir).path(percentEncoded: false))) ?? []
            where f.hasSuffix(".jsonl") {
                ids.insert(String(f.dropLast(6)))
            }
        }
        return ids
    }

    /// Session ids a running Claude Code process holds.
    private static func live() -> Set<String> {
        let dir = root.appending(path: "sessions")
        var ids = Set<String>()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appending(path: f)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["sessionId"] as? String, let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// The conversation a Claude Code process in `pane` holds: its
    /// `sessions/<pid>.json` says which, and the process's environment says
    /// where it runs (`AXOLOTTY_PANE_ID`, inherited from the pane's shell).
    static func held(byPane pane: String) -> String? {
        let dir = root.appending(path: "sessions")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
        where f.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appending(path: f)),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["sessionId"] as? String, let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  environment(of: pid)?["AXOLOTTY_PANE_ID"] == pane
            else { continue }
            return id
        }
        return nil
    }

    /// Another process's environment (same user), from `KERN_PROCARGS2`:
    /// argc, the executable path, then argv and the environment as C strings.
    static func environment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }  // executable path
        while i < size, buf[i] == 0 { i += 1 }  // its padding
        var strings: [String] = []
        var start = i
        while i < size {
            if buf[i] == 0 {
                if i == start { break }  // an empty string ends the block
                strings.append(String(decoding: buf[start ..< i], as: UTF8.self))
                start = i + 1
            }
            i += 1
        }
        guard strings.count >= argc else { return nil }
        var env: [String: String] = [:]
        for s in strings.dropFirst(argc) {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env
    }

    /// Whether `id` can still be resumed (its transcript is on disk).
    static func hasTranscript(_ id: String) -> Bool { transcripts().contains(id) }

    /// The first line that says something: pasted blocks, image tokens and
    /// fences dropped; a slash command is not a title.
    static func title(_ prompt: String) -> String? {
        let tokens = /\[(Pasted text|Image) #\d+[^\]]*\]/
        for raw in prompt.split(whereSeparator: \.isNewline) {
            var line = String(raw).replacing(tokens, with: "")
            line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if line.isEmpty || line.hasPrefix("```") { continue }
            if line.hasPrefix("/") { return nil }
            return line.count > 140 ? String(line.prefix(140)) + "…" : line
        }
        return nil
    }
}
