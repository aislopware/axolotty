// Claude Code status for panes that can't hear it directly.
//
// Claude Code reports itself over OSC 7501, but only once the terminal
// answers its probe, and tmux doesn't pass that probe through (tmux #5713).
// A Claude inside tmux in a pane would show nothing. For panes running
// tmux the host asks Claude Code itself: `claude
// agents --json` is its documented way to read session state from outside
// (pid, `status` busy|waiting|idle, `waitingFor`). One call costs about
// 0.9 s of a process, so it is never polled: Claude rewrites
// `~/.claude/sessions/<pid>.json` exactly when a session's status changes,
// and an FSEvents stream on that folder (names only, contents never read)
// says when to ask, and about which pid.
//
// A session belongs to a pane when its parent chain reaches the shell of a
// tmux pane in the session the pane's tmux client shows. Records go in
// under `StatusBook.agentsPrefix` ids, so they never pass for subagents,
// and are dropped the moment a Claude Code in the pane speaks for itself.
//
// The same list is read once when a person closes a session that has
// Claude Code in front: its `sessionId` (live processes only) is what
// reopening the session resumes (`Server.closeLater`).
import AxModel
import AxSys
import CoreServices
import Darwin
import Foundation

nonisolated enum ClaudeAgents {
    /// One live session from `claude agents --json`.
    struct Entry: Equatable, Sendable {
        var pid: Int32
        /// busy | waiting | idle (| shell: idle with a background shell).
        var status: String
        var waitingFor: String?
        var name: String?
        /// The conversation's UUID, usable with `claude --resume`.
        var sessionId: String? = nil
    }

    /// A watched pane's tmux client (its foreground) and the client's -L/-S flags.
    struct Target: Equatable, Sendable {
        var client: Int32
        var socket: [String]
    }

    static func parse(_ data: Data) -> [Entry] {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { e in
            guard let pid = (e["pid"] as? NSNumber)?.int32Value, let status = e["status"] as? String else { return nil }
            return Entry(pid: pid, status: status, waitingFor: e["waitingFor"] as? String, name: e["name"] as? String,
                         sessionId: e["sessionId"] as? String)
        }
    }

    /// The record a session's state becomes, given what the host showed for
    /// it last. A session that goes quiet after working has finished (done,
    /// kept until seen); one that was already quiet reports nothing.
    static func record(_ e: Entry, previous: StatusRecord.State?) -> (StatusRecord.State, StatusRecord.Need?)? {
        switch e.status {
        case "busy": return (.working, nil)
        case "waiting":
            let need: StatusRecord.Need = switch e.waitingFor {
            case "input needed": .question
            case "dialog open": .question
            default: .permission  // permission prompt, sandbox request, worker request
            }
            return (.blocked, need)
        default:
            if previous == .working || previous == .blocked { return (.done, nil) }
            if previous == .done { return (.done, nil) }
            return nil
        }
    }

    /// Which pane each session belongs to: the first whose roots meet the
    /// session's parent chain.
    static func assign(_ entries: [Entry], roots: [PaneID: Set<Int32>],
                       ancestors: (Int32) -> [Int32] = ClaudeAgents.ancestors) -> [PaneID: [Entry]]
    {
        var out: [PaneID: [Entry]] = [:]
        for e in entries {
            let chain = ancestors(e.pid)
            guard let pane = roots.first(where: { !$0.value.isDisjoint(with: chain) })?.key else { continue }
            out[pane, default: []].append(e)
        }
        return out
    }

    /// `pid` and its parents up to launchd (at most 64).
    static func ancestors(_ pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var p = pid
        while p > 1, chain.count < 64 {
            chain.append(p)
            p = ax_proc_ppid(p)
        }
        return chain
    }

    /// The processes whose descendants count as the target's: the shells of
    /// every tmux pane in the session the client shows.
    static func roots(_ t: Target) -> Set<Int32> {
        guard let clients = run(tmux, t.socket + ["list-clients", "-F", "#{client_pid} #{session_id}"]),
              let line = clients.split(separator: "\n").first(where: { $0.hasPrefix("\(t.client) ") }),
              let session = line.split(separator: " ").dropFirst().first,
              let panes = run(tmux, t.socket + ["list-panes", "-s", "-t", String(session), "-F", "#{pane_pid}"])
        else { return [] }
        return Set(panes.split(separator: "\n").compactMap { Int32($0) })
    }

    static func isTmux(_ pid: Int32) -> Bool {
        var name = [CChar](repeating: 0, count: 64)
        guard ax_proc_name(pid, &name, name.count) > 0 else { return false }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).hasPrefix("tmux")
    }

    /// -L NAME / -S PATH from a tmux client's argv.
    static func socketFlags(_ argv: [String]) -> [String] {
        var out: [String] = []
        var i = 1
        while i < argv.count {
            if argv[i] == "-L" || argv[i] == "-S", i + 1 < argv.count {
                out += [argv[i], argv[i + 1]]
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Executables

    static func find(_ name: String) -> String? { Executables.find(name) }

    static let claude = find("claude")
    static let tmux = find("tmux")

    static var sessionsDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(filePath: dir).appending(path: "sessions")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/sessions")
    }

    /// Live sessions, or nil when Claude Code can't be asked.
    static func list(timeout: Double = 8) -> [Entry]? {
        guard let out = run(claude, ["agents", "--json"], timeout: timeout) else { return nil }
        return parse(Data(out.utf8))
    }

    /// Runs `exe` and returns its standard output, or nil if it failed or
    /// took longer than `timeout` seconds. The agent session markers of
    /// whoever started the server stay out of its environment.
    static func run(_ exe: String?, _ args: [String], timeout: Double = 3) -> String? {
        guard let exe else { return nil }
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.filter { !ShellEnvironment.isAgentSessionMarker($0.key) }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { if p.isRunning { p.terminate() } }
        timer.resume()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// FSEvents on Claude Code's session folder: the pids whose files changed
/// (created, rewritten or removed). Names only; nothing is read.
nonisolated final class ClaudeSessionWatch: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "axolotty.claude-sessions")
    private let onChange: @Sendable ([Int32]) -> Void

    init?(directory: URL, onChange: @escaping @Sendable ([Int32]) -> Void) {
        self.onChange = onChange
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return nil }
        var context = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<ClaudeSessionWatch>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self)
            var pids: [Int32] = []
            for i in 0 ..< count {
                guard let path = list[i] as? String else { continue }
                let name = (path as NSString).lastPathComponent
                guard name.hasSuffix(".json"), let pid = Int32(name.dropLast(5)) else { continue }
                pids.append(pid)
            }
            if !pids.isEmpty { me.onChange(pids) }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, callback, &context, [directory.path(percentEncoded: false)] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    deinit {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }
}
