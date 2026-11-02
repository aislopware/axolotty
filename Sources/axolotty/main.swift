// axolotty — command-line control of an Axolotty host, for people, scripts,
// hooks and coding agents. Talks to $AXOLOTTY_SOCKET (set in every pane) or
// the standard runtime socket. `axolotty mcp` serves the same operations to
// agents over MCP (stdio).
//
// Exit codes: 0 ok · 1 failed · 2 usage · 3 not found / ambiguous · 4 host unreachable · 124 timeout
// (`wait --for command` exits with the command's own status instead).
import AxClient
import AxModel
import AxProtocol
import Foundation

let usage = """
    usage: axolotty <command> [options]

      ls [--json]                         workspaces, sessions and panes with status
      new [--cwd DIR] [--name NAME] [--workspace NAME] [--worktree BRANCH] [-- CMD…]
                                          new session (prints its pane id); --worktree starts
                                          it in DIR's repository's .worktrees/BRANCH (made
                                          or reused; the branch is created from HEAD)
      split [--pane P] [--down] [--before] [-- CMD…]
                                          split a pane (prints the new pane id)
      send [--pane P] TEXT…               type text into a pane (\\n = Enter)
      send [--pane P] --paste TEXT… [--no-enter]
                                          paste (bracketed), then Enter on its own ≥200 ms later:
                                          how to hand a prompt to an agent's TUI
      send [--pane P] --keys ctrl+c,enter named keys ([ctrl|alt|shift|super+]key: a-z 0-9
                                          enter esc tab space backspace delete up down left
                                          right home end pageup pagedown f1-f12)
                                          send refuses a pane waiting for its person; --force
      capture [--pane P] [--scrollback] [--format plain|vt|html]
      status STATE [--pane P] [--id ID] [--app APP] [--message MSG]
                                          report idle|working|done|blocked|error|clear
      notify TITLE [BODY]                 desktop notification through the app
      wait [--pane P] --for done|idle|blocked|error|exit [--timeout SEC]
      wait --pane P1,P2… [--all] --for GOAL
                                          any of several panes (or, with --all, every one);
                                          prints those that got there
      wait [--pane P] --for command [--timeout SEC]
                                          the next shell command to finish; prints it and
                                          exits with its status
      commands [--pane P] [--last N] [--failed] [--json]
                                          the pane's finished shell commands with exit codes
      events [--pane P] [--json]          follow activity changes, finished commands,
                                          exits and notifications (one line or JSON each)
      focus [--pane P]                    mark a pane seen
      close [--pane P]                    end a pane's program and close it
      attach [--pane P]                   use a pane from this terminal (over ssh, another
                                          emulator); ^] detaches, the program keeps running
      mcp                                 serve these operations to an agent over MCP (stdio)
      ping                                check the host is up

    P is a pane id or a unique prefix (≥ 4 characters); default $AXOLOTTY_PANE_ID.
    """

func fail(_ msg: String, _ code: Exit) -> Never {
    FileHandle.standardError.write(Data("axolotty: \(msg)\n".utf8))
    exit(code.rawValue)
}

struct Options {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []
    var command: [String] = []

    /// `valued` flags take a value; `switches` are the bare flags this verb
    /// knows. Anything else is a usage error; -h/--help prints usage.
    init(_ args: ArraySlice<String>, valued: Set<String> = [], switches known: Set<String> = []) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a == "--" {
                while let rest = it.next() { command.append(rest) }
                break
            }
            if a == "-h" || a == "--help" {
                print(usage)
                exit(Exit.ok.rawValue)
            }
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    flags[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if valued.contains(name) {
                    guard let v = it.next() else { fail("--\(name) needs a value", .usage) }
                    flags[name] = v
                } else if known.contains(name) {
                    switches.insert(name)
                } else {
                    fail("unknown option --\(name)\n\(usage)", .usage)
                }
            } else {
                positional.append(a)
            }
        }
    }
}

func json<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: (try? enc.encode(value)) ?? Data(), as: UTF8.self)
}

/// Runs one operation; an `OpError` becomes its message and exit code.
func run(_ body: () async throws -> Void) async {
    do { try await body() } catch let e as OpError { fail(e.message, e.exit) } catch { fail("\(error)", .failed) }
}

var argv = CommandLine.arguments.dropFirst()
guard let verb = argv.popFirst() else {
    print(usage)
    exit(Exit.usage.rawValue)
}

switch verb {
case "-h", "--help", "help":
    print(usage)

case "ping":
    _ = Options(argv)
    await run {
        let start = ContinuousClock.now
        let (c, st) = try await Ops.connect()
        await c.ping()
        print("ok \(st.name) \(ContinuousClock.now - start)")
    }

case "ls":
    let o = Options(argv, switches: ["json"])
    await run {
        let (_, st) = try await Ops.connect()
        if o.switches.contains("json") {
            print(json(st))
            return
        }
        print(st.name)
        for w in st.workspaces {
            print("  \(w.name)  \(w.root)  [\(st.activity(ofWorkspace: w.id).rawValue)]")
            for sid in w.sessions {
                guard let s = st.sessions[sid] else { continue }
                print("    \(st.sessionTitle(sid))  \(sid)  [\(st.activity(of: sid).rawValue)]")
                for p in s.tree.panes {
                    guard let info = st.panes[p] else { continue }
                    let mark = p == s.focus ? "*" : " "
                    let agent = info.agent.map { " \($0.displayName)" } ?? ""
                    // A waiting program's ask ("Has a question" when it gave no words).
                    let words = info.status.headline.map { $0.state == .blocked ? $0.ask : $0.message } ?? ""
                    let msg = words.isEmpty ? "" : " — \(words)"
                    print("     \(mark)\(Ops.short(p))  \(info.cols)x\(info.rows)  \(info.program)\(agent)  \(info.pwd)  [\(info.activity.rawValue)]\(msg)")
                }
            }
        }
    }

case "new":
    let o = Options(argv, valued: ["cwd", "name", "workspace", "worktree"])
    await run {
        let p = try await Ops.newSession(cwd: o.flags["cwd"], name: o.flags["name"], workspace: o.flags["workspace"],
                                         command: o.command, worktree: o.flags["worktree"])
        print(p.raw.uuidString.lowercased())
    }

case "split":
    let o = Options(argv, valued: ["pane"], switches: ["down", "before"])
    await run {
        let p = try await Ops.split(pane: o.flags["pane"], down: o.switches.contains("down"),
                                    before: o.switches.contains("before"), command: o.command)
        print(p.raw.uuidString.lowercased())
    }

case "send":
    let o = Options(argv, valued: ["pane", "keys"], switches: ["paste", "no-enter", "force"])
    await run {
        let text = (o.positional + o.command).joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
        try await Ops.send(pane: o.flags["pane"], text: text, paste: o.switches.contains("paste"),
                           enter: !o.switches.contains("no-enter"), keys: try Ops.keys(o.flags["keys"]),
                           force: o.switches.contains("force"))
    }

case "capture":
    let o = Options(argv, valued: ["pane", "format"], switches: ["scrollback"])
    await run {
        guard let format = CaptureFormat(rawValue: o.flags["format"] ?? "plain") else { throw OpError.usage("unknown format") }
        print(try await Ops.capture(pane: o.flags["pane"], format: format, scrollback: o.switches.contains("scrollback")))
    }

case "status":
    let o = Options(argv, valued: ["pane", "id", "app", "message"])
    await run {
        guard let word = o.positional.first else { throw OpError.usage("status needs a state") }
        try await Ops.report(pane: o.flags["pane"], state: word, id: o.flags["id"] ?? "", app: o.flags["app"] ?? "",
                             message: o.flags["message"] ?? o.positional.dropFirst().joined(separator: " "))
    }

case "notify":
    let o = Options(argv, valued: ["pane"])
    await run {
        guard let title = o.positional.first else { throw OpError.usage("notify needs a title") }
        try await Ops.notify(pane: o.flags["pane"], title: title, body: o.positional.dropFirst().joined(separator: " "))
    }

case "focus":
    let o = Options(argv, valued: ["pane"])
    await run { try await Ops.markSeen(pane: o.flags["pane"]) }

case "close":
    let o = Options(argv, valued: ["pane"])
    await run { try await Ops.close(pane: o.flags["pane"]) }

case "wait":
    let o = Options(argv, valued: ["pane", "for", "timeout"], switches: ["all"])
    let goal = o.flags["for"] ?? "done"
    let panes = o.flags["pane"].map { $0.split(separator: ",").map { String($0) as String? } } ?? [nil]
    await run {
        let timeout = Double(o.flags["timeout"] ?? "") ?? 0
        if panes.count > 1 {
            // Several panes: name the ones that got there, one a line.
            for (p, info) in try await Ops.wait(panes: panes, all: o.switches.contains("all"), goal: goal, timeout: timeout) {
                print("\(Ops.short(p)) \(info.map { $0.exitStatus != nil ? "exited" : $0.activity.rawValue } ?? "closed")")
            }
            return
        }
        let info = try await Ops.wait(pane: panes[0], goal: goal, timeout: timeout)
        guard goal == "command" else { return }
        guard let r = info?.lastCommand else { throw OpError.notFound("pane closed") }
        let code = r.exitCode ?? 0
        print("exit \(code) · \(String(format: "%.1f", r.duration))s · \(r.command)")
        // The command's own status, kept clear of the CLI's 124 (timeout).
        if code != 0 { exit(Int32(min(max(Int(code), 1), 123))) }
    }

case "commands":
    let o = Options(argv, valued: ["pane", "last"], switches: ["failed", "json"])
    await run {
        var list = try await Ops.commands(pane: o.flags["pane"])
        if o.switches.contains("failed") { list = list.filter(\.failed) }
        if let n = o.flags["last"].flatMap(Int.init), n >= 0 { list = Array(list.suffix(n)) }
        if o.switches.contains("json") {
            print(json(list))
            return
        }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        for r in list {
            let code = (r.exitCode.map(String.init) ?? "?").padding(toLength: 4, withPad: " ", startingAt: 0)
            let took = String(format: "%7.1fs", r.duration)
            print("\(time.string(from: Date(timeIntervalSince1970: r.endedAt)))  \(code)\(took)  \(r.command)")
        }
    }

case "events":
    let o = Options(argv, valued: ["pane"], switches: ["json"])
    let asJSON = o.switches.contains("json")
    setvbuf(stdout, nil, _IOLBF, 0)
    await run {
        try await Ops.events(pane: o.flags["pane"]) { e in
            if asJSON {
                let enc = JSONEncoder()
                enc.outputFormatting = [.sortedKeys]
                if let d = try? enc.encode(e) { print(String(decoding: d, as: UTF8.self)) }
            } else {
                print(e.line)
            }
        }
    }

case "attach":
    let o = Options(argv, valued: ["pane"])
    await run { try await Attach.run(pane: o.flags["pane"] ?? o.positional.first) }

case "mcp":
    _ = Options(argv)
    await MCPServer().serve()

default:
    fail("unknown command \(verb)\n\(usage)", .usage)
}
exit(Exit.ok.rawValue)
