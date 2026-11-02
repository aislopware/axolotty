// `axolotty mcp`: the CLI's operations as MCP tools, over stdio (newline-
// delimited JSON-RPC 2.0). An agent running in an Axolotty pane can see the
// other panes, start sessions, hand prompts to other agents
// (bracketed paste, Enter on its own), read their screens and wait for them.
// Requests run concurrently (a long `wait_for` does not hold up the rest);
// replies are written one line at a time.
import AxModel
import AxProtocol
import Foundation

final class MCPServer: Sendable {
    static let version = "0.1.0"

    private actor Out {
        func write(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
            FileHandle.standardOutput.write(data + Data([0x0A]))
        }
    }

    private let out = Out()

    func serve() async {
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    await out.write(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
                    continue
                }
                let request = Request(msg)
                Task { await self.handle(request) }
            }
        } catch {}
    }

    /// The parts of a JSON-RPC message we use, copied out as Sendable values.
    private struct Request: @unchecked Sendable {
        var id: Any?
        var method: String
        var params: [String: Any]
        init(_ m: [String: Any]) {
            id = m["id"]
            method = m["method"] as? String ?? ""
            params = m["params"] as? [String: Any] ?? [:]
        }
    }

    private func handle(_ r: Request) async {
        guard let id = r.id else { return }  // a notification (initialized, cancelled): nothing to say
        switch r.method {
        case "initialize":
            let asked = r.params["protocolVersion"] as? String ?? "2025-06-18"
            await reply(id, [
                "protocolVersion": asked,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "axolotty", "version": Self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            await reply(id, [String: Any]())
        case "tools/list":
            await reply(id, ["tools": Self.tools])
        case "tools/call":
            let name = r.params["name"] as? String ?? ""
            let args = r.params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, Args(args))
                await reply(id, ["content": [["type": "text", "text": text]]])
            } catch {
                await reply(id, ["content": [["type": "text", "text": error.message]], "isError": true])
            }
        default:
            await out.write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "unknown method \(r.method)"]])
        }
    }

    private func reply(_ id: Any, _ result: [String: Any]) async {
        await out.write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: Tools

    private struct Args: @unchecked Sendable {
        let raw: [String: Any]
        init(_ raw: [String: Any]) { self.raw = raw }
        func string(_ k: String) -> String? { (raw[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func bool(_ k: String, _ d: Bool) -> Bool { raw[k] as? Bool ?? d }
        func number(_ k: String) -> Double? { (raw[k] as? NSNumber)?.doubleValue }
    }

    private func call(_ name: String, _ a: Args) async throws(OpError) -> String {
        switch name {
        case "list_panes":
            let (_, st) = try await Ops.connect()
            return Self.describe(st)
        case "new_session":
            let p = try await Ops.newSession(cwd: a.string("cwd"), name: a.string("name"),
                                             command: a.string("command").map { [$0] } ?? [], worktree: a.string("worktree"))
            return "Started pane \(p.raw.uuidString.lowercased())"
        case "send_input":
            try await Ops.send(pane: a.string("pane"), text: a.string("text") ?? "", enter: a.bool("submit", true),
                               keys: try Ops.keys(a.string("keys")), force: a.bool("force", false))
            return "Sent"
        case "read_pane":
            var text = try await Ops.capture(pane: a.string("pane"), scrollback: a.bool("scrollback", false))
            let last = Int(a.number("last_lines") ?? 120)
            if last > 0 {
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.count > last { text = lines.suffix(last).joined(separator: "\n") }
            }
            return text
        case "wait_for":
            let goal = a.string("until") ?? "done"
            let timeout = a.number("timeout_seconds") ?? 600
            if let many = a.raw["panes"] as? [String], !many.isEmpty {
                let all = a.bool("all", false)
                let got = try await Ops.wait(panes: many, all: all, goal: goal, timeout: timeout)
                let lines = got.map { p, info in
                    "\(p.raw.uuidString.lowercased()): " + (info.map { i in
                        i.activity.rawValue + (i.status.headline.map { ": \($0.message)" } ?? "")
                    } ?? "closed")
                }
                return (all ? "All reached \(goal):\n" : "Reached \(goal):\n") + lines.joined(separator: "\n")
            }
            let info = try await Ops.wait(pane: a.string("pane"), goal: goal, timeout: timeout)
            if goal == "command", let r = info?.lastCommand {
                return "Command finished: exit \(r.exitCode.map(String.init) ?? "?") after \(String(format: "%.1f", r.duration))s: \(r.command)"
            }
            guard let info else { return "The pane is gone" }
            return "Pane is \(info.activity.rawValue)" + (info.status.headline.map { ": \($0.message)" } ?? "")
        case "close_pane":
            try await Ops.close(pane: a.string("pane"))
            return "Closed"
        default:
            throw .usage("unknown tool \(name)")
        }
    }

    /// The host as an agent reads it: one line per pane under its session.
    static func describe(_ st: HostState) -> String {
        let me = Ops.env["AXOLOTTY_PANE_ID"].flatMap { PaneID($0) }
        var out = ["Host \(st.name)" + (me.map { "; you are pane \(Ops.short($0))" } ?? "")]
        for w in st.workspaces {
            out.append("workspace \(w.name) (\(w.root))")
            for sid in w.sessions {
                guard let s = st.sessions[sid] else { continue }
                out.append("  session \(st.sessionTitle(sid))")
                for p in s.tree.panes {
                    guard let i = st.panes[p] else { continue }
                    var facts = ["\(i.activity.rawValue)", i.agent?.displayName ?? i.program, i.pwd]
                    if let h = i.status.headline, !h.message.isEmpty {
                        facts.append("\"\(h.state == .blocked ? h.ask : h.message)\"")
                    }
                    if let c = i.lastCommand {
                        facts.append("last command `\(c.command)` exit \(c.exitCode.map(String.init) ?? "?")")
                    }
                    let mine = p == me ? " (you)" : ""
                    out.append("    pane \(p.raw.uuidString.lowercased())\(mine): " + facts.joined(separator: " · "))
                }
            }
        }
        return out.joined(separator: "\n")
    }

    static let instructions = """
        Axolotty is the terminal you run in. These tools see and drive its panes: list them, \
        start a session (optionally running a command, such as another agent), hand text to a \
        pane, read its screen, and wait until it is done, blocked, or its next shell command \
        ends. Pane ids accept unique prefixes of 4+ characters; omitting a pane means your own. \
        send_input pastes the text and presses Enter on its own afterwards, which is how to give \
        another agent a prompt. Never answer another agent's permission prompt for its person: \
        send_input refuses a pane that waits for its person unless force is set.
        """

    private static func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": props, "required": required, "additionalProperties": false]
    }

    private static var pane: [String: Any] { ["type": "string", "description": "Pane id or unique prefix (4+ chars); default: your own pane"] }

    static var tools: [[String: Any]] { [
        ["name": "list_panes",
         "description": "Every workspace, session and pane: activity (idle, working, blocked, done, error), program or agent, directory, what a waiting agent asks, and the last shell command with its exit code.",
         "inputSchema": schema([:]),
         "annotations": ["readOnlyHint": true]],
        ["name": "new_session",
         "description": "Start a new session (a terminal) in a directory, optionally running a command through the login shell (for example `claude` or `npm test`), optionally in its own git worktree so parallel agents do not edit the same files. Returns its pane id.",
         "inputSchema": schema([
             "cwd": ["type": "string", "description": "Directory (default: the server's)"],
             "worktree": ["type": "string", "description": "Branch: run in the repository's .worktrees/<branch>, made from HEAD if new (the branch is never deleted)"],
             "name": ["type": "string", "description": "Session name shown in the sidebar"],
             "command": ["type": "string", "description": "Command line to run instead of an interactive shell"],
         ])],
        ["name": "send_input",
         "description": "Give a pane input: the text as one bracketed paste, then Enter on its own afterwards (submit), which is how to hand a prompt to an agent's TUI. keys presses named keys after the text, for example `ctrl+c` or `esc,down,enter`. Refused while the pane waits for its person unless force is true.",
         "inputSchema": schema([
             "pane": pane,
             "text": ["type": "string"],
             "submit": ["type": "boolean", "description": "Press Enter after the text (default true)"],
             "keys": ["type": "string", "description": "Comma-separated [ctrl|alt|shift|super+]key: a-z 0-9 enter esc tab space backspace delete up down left right home end pageup pagedown f1-f12"],
             "force": ["type": "boolean"],
         ])],
        ["name": "read_pane",
         "description": "The text on a pane's screen (with scrollback if asked), last lines only.",
         "inputSchema": schema([
             "pane": pane,
             "scrollback": ["type": "boolean", "description": "Include history above the screen"],
             "last_lines": ["type": "integer", "description": "Keep only the last N lines (default 120, 0 for all)"],
         ]),
         "annotations": ["readOnlyHint": true]],
        ["name": "wait_for",
         "description": "Wait until a pane is done, idle, blocked, error or working, until its program exits, or (command) until its next shell command finishes, then say how it ended. With `panes`, wait on several (agents you started): until any one gets there, or every one with `all`.",
         "inputSchema": schema([
             "pane": pane,
             "panes": ["type": "array", "items": ["type": "string"], "description": "Several pane ids instead of `pane`"],
             "all": ["type": "boolean", "description": "With panes: wait for every one (default: the first)"],
             "until": ["type": "string", "enum": waitGoals],
             "timeout_seconds": ["type": "number", "description": "Default 600"],
         ], required: ["until"]),
         "annotations": ["readOnlyHint": true]],
        ["name": "close_pane",
         "description": "End a pane's program and close the pane.",
         "inputSchema": schema(["pane": pane], required: ["pane"]),
         "annotations": ["destructiveHint": true]],
    ] }

    private static let waitGoals = Ops.waitGoals
}
