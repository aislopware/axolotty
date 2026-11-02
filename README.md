# Axolotty

A terminal for working with coding agents, on macOS. Sessions are grouped by project in a sidebar that shows what each agent is doing (working, waiting for you, finished, failed), and agents can see and drive the terminal themselves.

Programs run in a small PTY holder (`axolotty-ptyd`) under a server (`axolottyd`), so closing the app, or updating it, leaves every shell and agent running. The app is one client of that server; the `axolotty` CLI and its MCP server are others.

## What it does

- **Agent status from the agent itself.** Claude Code reports over OSC 7501; other programs can use `axolotty status`. Rows, the band, the Dock badge, toasts and notifications all follow it. A notification goes away as soon as you've seen its pane.
- **Find who needs you.** Go to Session (⌘J) lists sessions as needs-you, then finished, then working. Next waiting agent is ⇧⌘U.
- **Worktree sessions.** ⌥⌘T, or "New Worktree…" on a project's "+", starts an agent on its own branch in `<repo>/.worktrees/<branch>`. "Remove Worktree…" deletes the folder and keeps the branch.
- **Keep your place.**
  - Pin sessions to the top of their project.
  - Mark a session unread for later.
  - Reopen a closed session (⇧⌘T) in its folder.
  - Subagents at work show beside the agent's timer.
- **Shell integration** for zsh, bash and fish:
  - prompt jumps (⌘↑ ⌘↓);
  - a notice when a long command finishes while you're looking elsewhere;
  - a pane's ended bar, where ↩ restarts the program in place.
- **On screen:**
  - ⌘-click links and `file:line`;
  - Find (⌘F);
  - Secure Keyboard Entry while a program reads a password.
- **What agents produced:**
  - the diff chip and Changes popover (⇧⌘C);
  - listening ports with one-click open;
  - Open in Editor (⌥⌘O).
- **Look:** Axolotty Night and Day, following the system or fixed, in any installed monospaced font.

## Agents drive Axolotty

Claude Code started from Axolotty gets its tools via `--mcp-config "$AXOLOTTY_MCP"`, a file Axolotty owns. The agent's own config is never written. The same operations are available from any pane:

```
axolotty ls                                  # workspaces, sessions, panes, status
axolotty new --cwd ~/code/app --worktree fix/login -- claude
axolotty send --pane 1a2b --paste "Run the tests and fix what fails"
axolotty wait --pane 1a2b --for done
axolotty wait --pane 1a2b,3c4d --all --for done   # several agents at once
axolotty commands --pane 1a2b --failed       # shell commands with exit codes
axolotty events --json                       # follow every change
axolotty attach --pane 1a2b                  # use a pane from ssh; ^] detaches
axolotty mcp                                 # the same, as MCP tools over stdio
```

`send` won't type into a pane whose agent is waiting for its person unless you pass `--force`. That way an agent never answers another agent's permission prompt by accident.

## Build

Requirements: macOS 26 or later and the Swift toolchain named in `Package.swift`. `Vendor/GhosttyVT.xcframework` comes from `scripts/build-ghostty-vt.sh`, which needs Zig, and only has to run when the pinned commit changes.

```
swift build                                  # everything, debug
swift test
AXOLOTTY_HOME=/tmp/axdev swift run AxolottyDev   # the app against a scratch server
scripts/package-app.sh                       # dist/Axolotty.app (release, ad hoc signed)
```

Set `SIGN_IDENTITY` to sign `dist/Axolotty.app` with a Developer ID instead. The app registers the server as a LaunchAgent on first launch; `AXOLOTTY_HOME` keeps a development server and its state separate from your real one.

Design notes live in `.research/design-system.md`.
