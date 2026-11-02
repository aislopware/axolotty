// axolotty — command-line control of an Axolotty host, for people, scripts
// and coding agents. Talks to $AXOLOTTY_SOCKET (set in every pane) or
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
      new [--cwd DIR] [--name NAME] [--worktree BRANCH] [-- CMD…]
                                          new session (prints its pane id); --worktree starts
                                          it in DIR's repository's .worktrees/BRANCH (made
                                          or reused; the branch is created from HEAD)
      send [--pane P] TEXT… [--no-enter]  paste the text (bracketed), then Enter on its own
                                          ≥200 ms later: how to hand a prompt to an agent's TUI
      send [--pane P] --keys ctrl+c,enter named keys ([ctrl|alt|shift|super+]key: a-z 0-9
                                          enter esc tab space backspace delete up down left
                                          right home end pageup pagedown f1-f12)
                                          send refuses a pane waiting for its person; --force
      capture [--pane P] [--scrollback]   the pane's screen (and history) as plain text
      wait [--pane P] --for done|blocked|error|exit [--timeout SEC]
                                          done: the program finished (done, or idle again
                                          after working); exit: it exited
      wait --pane P1,P2… --for GOAL       any of several panes; prints those that got there
      wait [--pane P] --for command [--timeout SEC]
                                          the next shell command to finish; prints it and
                                          exits with its status
      close [--pane P]                    end a pane's program and close it
      attach [--pane P]                   use a pane from this terminal (over ssh, another
                                          emulator); ^] detaches, the program keeps running
      mcp                                 serve these operations to an agent over MCP (stdio)

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
    let o = Options(argv, valued: ["cwd", "name", "worktree"])
    await run {
        let p = try await Ops.newSession(cwd: o.flags["cwd"], name: o.flags["name"], command: o.command,
                                         worktree: o.flags["worktree"])
        print(p.raw.uuidString.lowercased())
    }

case "send":
    let o = Options(argv, valued: ["pane", "keys"], switches: ["no-enter", "force"])
    await run {
        let text = (o.positional + o.command).joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n")
        try await Ops.send(pane: o.flags["pane"], text: text, enter: !o.switches.contains("no-enter"),
                           keys: try Ops.keys(o.flags["keys"]), force: o.switches.contains("force"))
    }

case "capture":
    let o = Options(argv, valued: ["pane"], switches: ["scrollback"])
    await run {
        print(try await Ops.capture(pane: o.flags["pane"], scrollback: o.switches.contains("scrollback")))
    }

case "close":
    let o = Options(argv, valued: ["pane"])
    await run { try await Ops.close(pane: o.flags["pane"]) }

case "wait":
    let o = Options(argv, valued: ["pane", "for", "timeout"])
    let goal = o.flags["for"] ?? "done"
    let panes = o.flags["pane"].map { $0.split(separator: ",").map { String($0) as String? } } ?? [nil]
    await run {
        let timeout = Double(o.flags["timeout"] ?? "") ?? 0
        if panes.count > 1 {
            // Several panes: name the ones that got there, one a line.
            for (p, info) in try await Ops.wait(panes: panes, goal: goal, timeout: timeout) {
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

