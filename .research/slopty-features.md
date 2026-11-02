# Slopty feature inventory, mapped against Axolotty (2026-11-02)

**Purpose.** List what Slopty ships, mark what it only planned, and say for each feature what
Axolotty already has. The aim is to decide what Axolotty still has to build.

**Excluded by the owner:** the inspector, Slopty's right-side read-only agent pane
(`crates/slopty-shell/src/inspector.rs`, `docs/decisions/inspector.md`). Its internals are not
inventoried here.

**Method.** All reading was static: the docs first, then the code.
- No Slopty or Axolotty binary, build, script or app was run.
- Slopty was read at HEAD `98847d8` (2026-11-01).
- Axolotty has no commits yet, so its citations point at the working tree as of 2026-11-02. Some
  of those files (`Chrome/ChangesPopover.swift`, `Chrome/GitChanges.swift`) were being edited
  while this was written.
- Slopty paths are relative to `/Volumes/Lacie/Workspace/oss/slopty`. Axolotty paths are
  relative to `Sources/` unless they say otherwise.

## 0. Read this first: Slopty pivoted on 2026-10-30, and its README is stale

- **Commit `99d0ffe6c`** (2026-10-30, "run each agent in its own TUI beside a read-only
  inspector") deleted the GUI agent stack: 743 files and about 144k lines.
  - Removed: the chat composer; the driven Claude, Codex, pi and ACP modes; GUI approvals; the
    prompt queue; fork, rewind and ask-aside; usage meters; and the todo and background trays.
  - The rule now (`docs/decisions/agents.md:7-147`, "TUI-first") is that every agent runs as its
    own TUI in a terminal. The GUI is read-only toward the agent.
- **Commit `105bf0197`** (the same day) replaced the tiling workspace with Ghostty-style splits.
  It also turned Changes, Files, Browser and Remote window into panes you summon.
- **The canvas, the sticky notes and the minimap were built and then deleted.** So were the
  projects, boards, budgets and merge queue. The CHANGELOG (stops at 0.1.0, 2026-09-05) and
  `HANDOFF.md` describe an older product.
- **Two README claims are stale:**
  - The README says a `claude` typed by hand in a Slopty shell gets Slopty's tools and hooks
    "with nothing to set up". The shell wiring for that was removed in `a0091d20f`
    (2026-10-16). Only an agent that Slopty itself starts gets hooks and tools
    (`crates/slopty-worker/src/thread/start.rs:227-262`). A hand-typed `claude` is now only
    observed, through Claude Code's session registry and transcript.
  - `SLOPTY_NO_CLAUDE_MOD` exists only in the docs.
- **Conflict with Axolotty's Phase 3:** Slopty once had Allow/Deny on the agent badge
  (`0a264ec`). It sent Enter or Esc into the TUI. It deleted it and now rules it **harmful**:
  - `docs/decisions/layout.md:132-137`: "answering an agent's question or permission from a GUI
    form, auto-approve and auto-resume, a composer or prompt queue that types into a TUI".
  - `docs/decisions/agents.md:142-146`: "The TUI asks in its terminal and takes the answer
    there… a push carries no request and no buttons".
  - Axolotty's planned need bar with Allow and Deny (`.research/wow/synthesis.md`, Phase 3) runs
    against this ruling. See item 3 in §2 for a way to build it that avoids what went wrong in
    Slopty.

Status words used below:
- **SHIPPED**: the code exists at HEAD.
- **REMOVED**: it was built, then deleted (the commit is named).
- **PLANNED**: it appears only in docs or research.
- **unverified**: the claim could not be confirmed statically.

## 1. Feature table

Value means value for an agentic terminal: **H** high, **M** medium, **L** low.

### 1.1 Terminal

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| VT engine | SHIPPED: libghostty-vt on the worker (`docs/ARCHITECTURE.md` §2) | **has**: libghostty-vt on the host (`AxVT/VTTerminal.swift`); mirrors on clients (`AxClient/MirrorTerminal.swift:8-11`) | H | Same architecture: the host owns the VT, clients mirror it. |
| Splits: right/down, zoom, equalize, directional focus, resize | SHIPPED: `crates/slopty-shell/src/shell/chrome_keys.rs:135-144`; double-click a divider to equalize (`shell/panes.rs:169`) | **has**: `AxMacUI/App/Actions.swift:170-197`, `AxMacUI/Panes/PaneContainerView.swift:456,507`, `AxModel/SplitTree.swift` | H | At parity. Slopty also has ⌘⏎ "auto" split by aspect. Axolotty lacks it (S). |
| Dim unfocused panes | SHIPPED: `crates/slopty-terminal/src/element.rs:655` | **has**: `AxMacUI/Model/Preferences.swift:20` | M | |
| Tabs | None. One session per view plus a sidebar list (`shell/tabs.rs`); tab groups and colours were ruled out (`layout.md:138-145`) | **has** the same model: a sidebar of sessions, each a split tree (`AxModel/HostState.swift:59-77`) | — | Same choice. |
| Scrollback | SHIPPED: 50,000 lines (`crates/slopty-worker/src/manager.rs:23`); an idle session's history is compressed, largest first (`crates/slopty-worker/src/compress.rs`) | **has**: 16 MiB per pane (`AxHost/PaneHost.swift:17-19`) | M | Compressing idle history matters only with dozens of panes. |
| Find in scrollback | SHIPPED: a Ghostty-style corner card with a count; regex, case and whole-word toggles; matches across soft wraps; shares the system find pasteboard (`crates/slopty-terminal/src/view/find_card.rs`, `crates/slopty-engine/src/search.rs`) | **has**: ⌘F corner card with a count (`AxMacUI/Terminal/TerminalView.swift`, `AxVT/VTSearch.swift`); no regex or whole-word toggles yet | H | Agents print long logs; reading them needs find. |
| Hyperlinks (OSC 8) and detected URLs, hover preview | SHIPPED: `crates/slopty-terminal/src/url.rs`, `view/overlays.rs` | **has**: OSC 8 and detected URLs, ⌘-click (`AxVT/VTLine.swift`, `AxMacUI/Terminal/TerminalView.swift`) | H | |
| ⌘-click a path to open it at its line; ⌘-click a localhost URL | SHIPPED: `crates/slopty-terminal/src/view.rs:398-417` | **has**: ⌘-click `file:line` opens the editor at the line, URLs in the browser (`AxMacUI/Terminal/LinkOpener.swift`) | H | Agents print `file:line` all the time. |
| Quick select (labels every URL, path and hash on screen) | SHIPPED, ⇧⌘Space: `crates/slopty-terminal/src/view/quick.rs` | **has**: ⇧⌘Space (`AxModel/TerminalHints.swift`, Quick select in `TerminalView.swift`) | M | |
| Keyboard copy mode (vi keys; line and block) | SHIPPED, ⇧⌘X: `crates/slopty-terminal/src/copy_mode.rs` | **has**: ⇧⌘X, `AxMacUI/Terminal/TerminalView.swift` (Copy mode), screen rows via `AxVT/VTSelection.swift` | M | |
| Mouse selection: word, line, rectangle (⌥-drag), word across soft wrap | SHIPPED: `crates/slopty-terminal/src/view.rs:283,1356` | **has**: `AxMacUI/Terminal/TerminalView.swift:641-690` (⌥ rectangle at :669), `AxVT/VTSelection.swift` | M | Whether a word follows a soft wrap in Axolotty is unverified. |
| Copy on select | SHIPPED: `[terminal] copy_on_select` | **has**: Settings › Selection (`Preferences.copyOnSelect`, applied on mouse-up in `TerminalView.swift`) | L | |
| Command blocks (OSC 133): prompt jumps ⌘↑/⌘↓, copy last output ⇧⌘C, block menu (copy command/output, rerun, select), exit status | SHIPPED: `crates/slopty-engine/src/osc133.rs`, `crates/slopty-terminal/src/view.rs:4475` | **partial**: zsh emits OSC 133 (`AxHost/ShellEnvironment.swift:69-125`) and the VT parses it (`AxVT/VTTerminal.swift:47-50`). Only status uses it (`StatusBook.programEnded`, `AxModel/AgentStatus.swift:88`). No block UI | H | The data is already there; the work is UI. |
| Command duration; "long command finished unwatched" badge and notice | SHIPPED: `crates/slopty-terminal/src/view.rs:390`, `crates/slopty-ui/src/workspace/attention.rs` | **partial**: an agent's run gets a receipt ("✓ Worked 4m 12s", `AxMacUI/Chrome/BandView.swift:16,100`). Plain commands get nothing: a done/error receipt for long commands was built, then **dropped** (2026-11-02) | M | |
| Shell integration for zsh, bash and fish; terminfo install; an ssh wrapper that carries terminfo | SHIPPED: `crates/slopty-pty/src/shell_integration.rs`, `terminfo.rs`, `ssh.rs`; CLI `slopty ssh` (`apps/slopty-cli/src/lib.rs:95-105`) | **partial**: zsh only (`AxHost/ShellEnvironment.swift:69`). No bash, fish, terminfo or ssh wrapper | M | |
| Progress OSC 9;4 | SHIPPED: tab ring, Dock tile bar, bar along the pane's top (`crates/slopty-terminal/src/progress.rs`, `crates/slopty-platform/src/dock.rs`) | **has**: a 2 pt accent line (`AxMacUI/Terminal/ProgressLine.swift`, `AxModel/HostState.swift:13-16`) | M | Slopty also shows progress on the Dock tile (S). |
| Program notifications (OSC 9 / 777 / 99) | SHIPPED: `crates/slopty-engine/src/ghostty.rs:4896` | **has**: `AxVT/VTTerminal.swift:11`, `AxMacUI/App/AttentionCenter.swift:51` | M | |
| OSC 7501 program-status protocol | SHIPPED: `crates/slopty-engine/src/ghostty/status.rs`, `crates/slopty-proto/src/terminal.rs:917-955` (adds `need` and `progress` fields) | **has**: `AxModel/AgentStatus.swift:27-123`, `AxHost/Server.swift:651` | H | Axolotty lacks Slopty's `need` kind (permission/question/auth). Add it. |
| Bell | SHIPPED: a visual flash; `[terminal] alert` = never / when hidden / always | **partial**: bounces the Dock when inactive (`AxMacUI/App/AttentionCenter.swift:53-54`); no flash | L | |
| Paste protection | SHIPPED: judged on the worker (`crates/slopty-engine/src/ghostty.rs:3248`) | **has**: `AxMacUI/Terminal/TerminalView.swift:810`, `AxMacUI/Model/Preferences.swift:21` | M | |
| OSC 52 clipboard | SHIPPED: write **and** read, OSC 5522, Kitty paste events (`crates/slopty-engine/src/ghostty/clipboard.rs`) | **partial**: write only, local host only (`AxMacUI/App/AttentionCenter.swift:57-62`) | L | |
| Kitty keyboard protocol, key releases, focus reporting | SHIPPED: `crates/slopty-engine/src/ghostty.rs:805` | **has**: `AxVT/VTInput.swift:3`, `AxProtocol/Messages.swift:8-38` (release), `ClientMessage.focus` | M | |
| IME composition | SHIPPED (CHANGELOG 0.1.0) | **has**: `AxMacUI/Terminal/TerminalView.swift:535-616` | M | |
| Kitty graphics and Unicode-placeholder images | SHIPPED: `crates/slopty-engine/src/graphics.rs`, `placeholder.rs`. No sixel; no iTerm2 1337 | **missing**: nothing in `AxRender` | M | Agent TUIs rarely use images. |
| Box drawing, blocks, Braille, Powerline, sextants drawn from the cell | SHIPPED: `crates/slopty-terminal/src/sprite.rs` | **has** in part: `AxRender/BoxDrawing.swift` | L | Sextant and octant coverage in Axolotty is unverified. |
| Minimum-contrast pass | SHIPPED: 3.0:1 (`crates/slopty-settings/src/lib.rs:134`) | **has**: 3 (`AxRender/TerminalRenderer.swift:189-192`) | M | |
| Window takes the program's OSC 11 background | SHIPPED: `crates/slopty-shell/src/shell/window_appearance.rs` | **missing** (the frame uses its own tokens) | L | |
| "↓ N new lines" pill (never scroll the reader away) | SHIPPED: `crates/slopty-terminal/src/view/follow.rs` | **has**: `AxMacUI/Terminal/NewOutputPill.swift` | M | |
| "120 × 40" overlay on resize | SHIPPED (same module) | **has**: `AxMacUI/Terminal/SizeBadge.swift` | L | |
| Ended bar ("exited, code X") with ↩ to restart in place | SHIPPED: `crates/slopty-terminal/src/view/ended.rs`; restart in place `bcc89cf1a` | **partial**: keeps the exit status (`AxModel/HostState.swift:23`); a clean exit closes the pane (`AxHost/Server.swift` `closeOnCleanExit`). No bar, no restart | M | |
| Automatic Secure Keyboard Entry when the PTY stops echoing | SHIPPED: `crates/slopty-settings/src/lib.rs:161` | **has**: `AxMacUI/Terminal/SecureInput.swift`, driven by the pane's `readsSecret` | M | Password prompts in agent-driven shells. |
| Predictive local echo (mosh-style) | SHIPPED: `crates/slopty-predict` | **missing** | L now, M once remote | Only useful over a WAN. |
| Clear screen | SHIPPED: ⌥⌘K | **has**: ⌘K (`AxMacUI/App/Actions.swift:135`) | L | Slopty moved ⌘K to its session picker. |
| Fonts: family choice; bundled Geist Mono and Nerd symbols | SHIPPED: `crates/slopty-kit/src/fonts.rs:17-25`; separate terminal/UI/code fonts. Ligatures forced off | **partial**: the system monospaced font only; size only (`AxRender/TerminalFont.swift:7`, `AxMacUI/Model/Preferences.swift:14`) | M | People expect to pick a font. Nerd Font symbols matter for prompts. |
| Themes | SHIPPED: 9 built in, separate light and dark picks (`crates/slopty-shell-theme/src/builtins.rs`), high-contrast variants | **partial**: Night and Day plus Match System (`AxModel/Theme.swift:80-90`, `AxMacUI/App/SettingsWindowController.swift:72`) | M | Ghostty-compatible keys are already in place (`AxModel/Theme.swift:51`), so importing Ghostty themes is cheap. |
| Cursor shape and blink; option as alt | SHIPPED (`[terminal] option_as_alt`) | **has**: `AxMacUI/Model/Preferences.swift:9-18` | L | |

### 1.2 Sessions, workspaces and persistence

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| PTY keeper that outlives the server and the app | SHIPPED: `slopty-ptyd`; hands sessions to a new build in place (`crates/slopty-pty/src/succession.rs`) | **has**: `axolotty-ptyd/main.c:1-12`, `AxHost/Holder.swift:7-15` (content-addressed copy, setsid) | H | Axolotty has no handover to a new ptyd build (Slopty's "succession"). Low priority while ptyd rarely changes. |
| Sessions come back after a reboot under their old screen and a divider; nothing is rerun | SHIPPED: `crates/slopty-worker/src/restore.rs:1-20` | **partial**: a fresh shell starts in the old cwd (`AxHost/Server.swift:185-195`). The old screen is not kept above it, and its checkpoint (`AxHost/PaneHost.swift:470-500`) is not reused after a reboot | M | |
| Restart an ended session in place, resuming its agent | SHIPPED: `crates/slopty-proto/src/terminal.rs:335-339`, `crates/slopty-client/src/term.rs:603` | **has**: the ended bar's ↩ restarts in place (`Intent.restartPane`); Reopen Closed Session (⇧⌘T) resumes the Claude conversation it held (`ClaudeHistory.held(byPane:)`) | M | Resuming needs the Claude session id, which needs hooks (§2 item 1). |
| Reopen closed session or view | SHIPPED: ⇧⌘T, last 20 (`crates/slopty-shell/src/shell/closed_tabs.rs`) | **has**: `AxMacUI/Window/MainWindowController.swift:420` | M | |
| Sidebar grouped by project, stable order, 72 h "Inactive" fold, rail when collapsed | SHIPPED: `crates/slopty-shell/src/shell/sidebar.rs`, `docs/decisions/layout.md:258` | **has** projects and a stable order (`AxMacUI/Sidebar/SidebarViewController.swift`); **missing** the Inactive fold and the rail | M | |
| Hover card on a row (full title, machine, branch, ports) | SHIPPED: `crates/slopty-shell/src/shell/session_hover_card.rs` | **partial**: a hover card with time in state (`AxMacUI/Sidebar/SidebarViewController.swift:451-464`, `AxMacUI/Components/Tooltip.swift:91`) | M | Overlaps Phase 3 "metadata in the hover cards". |
| Session picker ⌘K across every machine, "filter or create", past Claude sessions found by typing | SHIPPED: `crates/slopty-shell/src/shell/picker.rs`, `past_sessions.rs` | **partial**: Open Quickly ⇧⌘O and Jump to Agent ⌘J (`AxMacUI/Overlays/PaletteController.swift:11`). No past-session search, no create-on-no-match | H | Resuming past Claude sessions is a frequent agent workflow. |
| Search past prompts (`~/.claude/history.jsonl`, Codex, pi) | SHIPPED: `crates/slopty-agent/src/history.rs` | **partial**: ⇧⌘R lists past Claude Code conversations by their first prompt (`AxMacUI/Sidebar/ClaudeHistory.swift`); no full-text search over every prompt, no Codex | M | Read-only use of the agent's own files. |
| Go to Directory ⇧⌘G (open a session in a folder) | SHIPPED: `crates/slopty-shell/src/shell/picker.rs` | **partial**: Open Folder as Workspace ⌘O (`AxMacUI/App/Actions.swift:124`) and the palette's `.directory` item (`AxMacUI/Overlays/PaletteController.swift:27`) | L | |
| Back and Forward through visited sessions (⌥⌘[ ]) | SHIPPED: `crates/slopty-shell/src/shell/chrome_keys.rs:130-131` | **has**: ⌥⌘[ ⌥⌘] (`MainWindowController.goBack/goForward`) | L | |
| Several clients on one host: one size driver, take over | SHIPPED (CHANGELOG "take-over pill"; `docs/decisions/multi-client.md`) | **has**: `AxProtocol/Messages.swift:147-149` (`viewport`, `takeSize`) | M | |
| Open the session's folder in your editor (⌥⌘O; VS Code/Cursor ssh-remote, zed://ssh) | SHIPPED: `crates/slopty-shell/src/shell/open_in.rs` | **has**: ⌥⌘O, local folders (`MainWindowController.openInEditor`); no ssh-remote editors | M | |
| `$EDITOR` and `$BROWSER` handed to the client (`slopty edit --wait`, `slopty browse`) | SHIPPED: `apps/slopty-cli/src/lib.rs:107-122`, `crates/slopty-worker/src/handoff.rs` | **missing** | L locally, M remote | Only matters once hosts are remote. |

### 1.3 Agents

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Recognise agent processes (name, launchers, package paths) | SHIPPED: `crates/slopty-agent/src/detect.rs` (gives Running/None only) | **has**: 16 agents (`AxModel/AgentStatus.swift:128-192`) | M | Axolotty recognises more agents than Slopty. |
| **Claude Code hook relay**: 15 events, async, merged in through `--settings` on agents Slopty starts | SHIPPED: `crates/slopty-agent/src/hooks.rs:21-40`, `apps/slopty-cli/src/hook.rs`, session-token vouching (`crates/slopty-agent/src/vouch.rs`) | **not built, by choice**: Claude Code reports its own status over OSC 7501; a relay was built and removed (two records per pane) | **H** | The biggest gap. Without it, a stock `claude` in Axolotty shows only "running". |
| Status from the transcript and session registry (`~/.claude/sessions/<pid>.json`), following `/clear` and `/resume` | SHIPPED: `crates/slopty-agent/src/transcript.rs`, `conversation.rs`, `crates/slopty-worker/src/thread/claude.rs` | **not needed**: OSC 7501 from Claude Code itself; the session registry is read only to resume (`ClaudeHistory`) | H | The fallback for a `claude` the person typed. Read-only, so it writes nothing into `~/.claude`. |
| Phase vocabulary (Idle, Working, Waiting, NeedsYou, Done, Failed, Stopped) and wait kinds (permission, question, plan, input, task, compacting) | SHIPPED: `crates/slopty-proto/src/thread.rs:298-350` | **partial**: five activities (`AxModel/AgentStatus.swift:2-25`); no wait kind | H | The wait kind is what lets the need chip say "Needs approval · run cargo test" (`crates/slopty-shell/src/shell/marks.rs:103`). |
| One mark vocabulary everywhere (row, title, picker, inbox, Dock badge); "seen" synced across devices | SHIPPED: `crates/slopty-shell/src/shell/marks.rs:1-90`, `crates/slopty-worker/src/thread/marks.rs` | **has**: `AxMacUI/Sidebar/StatusGlyphView.swift`, `ClientMessage.seen` (`AxProtocol/Messages.swift:160`), design-system rules | H | At parity in concept. |
| GUI Allow / Deny / Always / accept edits | **REMOVED** `99d0ffe6c`; ruled harmful (`docs/decisions/layout.md:132-137`) | **not built, by choice**: the TUI does approvals; Axolotty shows the ask and takes you to it | contested | See §0 and §2 item 3. |
| `[agents] autonomy` = auto / full / ask, mapped to Claude's permission modes at start | SHIPPED: `crates/slopty-settings/src/lib.rs:373-390` | **has**: Settings › Claude starts in / model / effort, passed as flags at start (`AxMacUI/Sidebar/AgentPresets.swift`) | M | Also needs flags at start. Pairs with presets. |
| MCP tools for agents: `machines`, `agent_start/tell/read/wait/stop`, `agents`, `branch_bring`, `show_visual`, `show_page`, `ui_state/terminal/open/region/chat/split` | SHIPPED: `crates/slopty-tools/src/tools.rs:222-286`, `crates/slopty-tools/src/ui.rs`; `slopty mcp` on stdio (`apps/slopty-cli/src/mcp.rs`) | **has**: `axolotty mcp`: list_panes, new_session (with worktree), send_input, read_pane, wait_for (one or the first of several panes), close_pane (`axolotty/MCP.swift`). split_pane, list_commands, report_status and notify were built, then dropped | H | Wrapping the existing CLI verbs as an MCP server is small. |
| `agent_tell` typing safety: bracketed paste, Enter ≥200 ms later once the paste is read, refused while the agent needs the person | SHIPPED: `crates/slopty-worker/src/session.rs:426`, `docs/decisions/agents.md:94-121` | **has**: `send` and MCP `send_input`: bracketed paste, Enter ≥200 ms later, refused while the agent waits for its person unless forced (`axolotty/Ops.swift`) | H | Ink TUIs read an Enter in the same read as part of the paste. |
| Agent-to-agent tree (parent/child across machines, `agent_wait` any/all) | SHIPPED: `crates/slopty-tools/src/tools.rs:30-140` | **partial**: `axolotty wait --pane A,B` and MCP `wait_for` `panes`, any of them (`axolotty/Ops.swift`); `--all` was dropped; no parent/child tree | M | |
| Start an agent in a new git worktree (or a fresh clone) | SHIPPED: `agent_start` worktree/repo (`crates/slopty-tools/src/tools.rs:58-75`); setup scripts; merged worktrees swept | **has**: ⌥⌘T, `new --worktree`, MCP `new_session.worktree` (`AxHost/Worktrees.swift`) | H | The standard way to run parallel agents. |
| Start presets: model, mode (plan), effort | SHIPPED: `crates/slopty-worker/src/thread/start.rs:227-262` | **partial**: "+" menu and empty-state tiles start a bare agent (`AxMacUI/Sidebar/AgentPresets.swift`, `AxMacUI/Window/EmptyStateView.swift:12-20`) | M | |
| Auto-trust the folder before starting, so the trust dialog cannot block | SHIPPED: `crates/slopty-agent/src/trust.rs` | **not built, by choice**: it writes Claude Code's own config, which Axolotty never does | L | It writes Claude's own config. Avoid, per the owner's rule about `~/.claude`. |
| Refuse to resume a session another live `claude` holds | SHIPPED: `crates/slopty-worker/src/thread/claude/held.rs` | **has**: a session a live `claude` holds is left out of ⇧⌘R (`ClaudeHistory.live()`) | L | Needed once resume exists. |
| Codex and pi | SHIPPED as TUIs with Slopty's tools (`crates/slopty-agent/src/codex/tui.rs`, `pi.rs`); their status is title and terminal only | **partial**: recognised and launchable (`AxModel/AgentStatus.swift`); no tools, no status | M | |
| Codex app-server, ACP, pi RPC (driven agents) | **REMOVED** `99d0ffe6c` | missing | L | Not worth it (§3). |
| Subagents as nested threads, with a "running N" pill | SHIPPED: `crates/slopty-shell/src/running_pill.rs` | **missing** | M | Read from hooks (SubagentStart/Stop). |
| Watch the window or simulator an agent drives, inferred from its tool calls | SHIPPED: `crates/slopty-worker/src/thread/screens.rs` | missing | L | Needs streaming (excluded). |
| Keep the machine awake while an agent works with no client attached | SHIPPED: `crates/slopty-worker/src/wake.rs:1-17`, `[worker] keep_awake` | **has**: `Server.updateWake` (`ProcessInfo.beginActivity(.idleSystemSleepDisabled)`) while any pane works | M | One `IOPMAssertion` while any pane is working. Matters for a laptop left running. |
| Chat GUI, composer, queue, fork, rewind, ask-aside, send-later, usage meters | **REMOVED** `99d0ffe6c`, `3ba7e37b7` | — (synthesis.md "Not copied") | — | Ruled out on both sides. |
| Projects, boards, budgets, verifier, merge queue, schedules (`task_*`) | **REMOVED** `b96dbc039`, `3317d1d3b` | — (synthesis.md: no kanban) | — | |
| Claude Code as an IDE (`~/.claude/ide/<port>.lock`: openDiff, selection, diagnostics) | PLANNED: `.research/ideas-2026-09-30.md:423-470`; nothing in code | missing | M | Worth a spike later: it is Claude's official door for showing a diff to accept. |

### 1.4 Attention and notifications

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Banners only for sessions out of sight; withdrawn once seen; a tap opens the session | SHIPPED: `crates/slopty-ui/src/workspace/attention.rs:1-40`, `crates/slopty-platform/src/notify.rs:1-30` | **has** in part: muted when on screen, a toast while the app is active (`AxMacUI/App/AttentionCenter.swift:64-80`), a click reveals the pane (`:103-112`). **Missing**: withdraw once seen | H | |
| Needs-you banners as Time Sensitive (break through Focus) | SHIPPED: `crates/slopty-platform/src/notify.rs:771` | **has**: blocked → `.timeSensitive`, done → `.passive` (`AxMacUI/App/AttentionCenter.swift:121`); breaking through Focus also needs the entitlement on a signed build | M | S: `interruptionLevel = .timeSensitive` plus the entitlement. |
| No sound | SHIPPED (sound removed; `layout.md:278-297`) | Axolotty plays `.default` (`AxMacUI/App/AttentionCenter.swift:90`) | L | A matter of taste. |
| Dock badge (needs-you + failed) and one bounce | SHIPPED: `crates/slopty-app/src/lib.rs:194-199` | **has**: badge counts waiting panes (`AxMacUI/App/AttentionCenter.swift:34-37`); bounces on blocked/error (`:75`) | M | Check whether "failed" is counted. |
| Inbox: needs-you → failed → done-unseen → working, keyboard-only, read-only | SHIPPED, ⇧⌘J: `crates/slopty-shell/src/shell/inbox.rs` | **partial**: Jump to Agent palette ⌘J (`AxMacUI/Window/MainWindowController.swift:487`) | M | |
| Jump to the next session that needs you | SHIPPED, ⌘J: `crates/slopty-shell/src/settings.rs:745` | **has**: ⇧⌘U and ⌥⇧⌘U (`AxMacUI/App/Actions.swift:163-166`, `AxMacUI/Window/MainWindowController.swift:450`) | H | |
| Fleet-wide attention ladder; notice routed to the device the person is at | SHIPPED: `crates/slopty-server/src/hub.rs` (ladder), `docs/ARCHITECTURE.md` §5 | n/a (single host) | L now | Becomes relevant with several hosts. |
| Push to an iPhone in a pocket (HPKE-sealed, APNs relay, service extension) | SHIPPED: `crates/slopty-push`, `apps/slopty-notify`, `crates/slopty-server/src/push.rs` | missing (planned in `.research/client-server-architecture.md` §8.3) | M later | |
| Haptic for needs-you on iPhone | SHIPPED: `crates/slopty-app/src/lib.rs:1251` | n/a | L | |

### 1.5 Palette, commands and keys

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Command palette ⇧⌘P, ranked by use | SHIPPED: `crates/slopty-shell/src/shell/command_palette.rs`. Sections: recent files, sessions, commands, files, in files (content), in sessions (words said). Commands from `crates/slopty-shell/src/app_menus.rs:286-319` | **has**: `AxMacUI/Overlays/PaletteController.swift` (commands, sessions, agents) built from `Command.all` (`AxMacUI/App/Actions.swift:105-206`) | H | Missing: ranking by how often and how lately, and full-text search over session output. |
| Rebindable shortcuts (recorder, conflict check); `[keys.terminal]`; follows the keyboard layout | SHIPPED: `crates/slopty-shell/src/settings/shortcuts.rs`, `crates/slopty-terminal/src/view.rs:183-230`, `shell.rs:466` | **missing**: fixed chords in `AxMacUI/App/Actions.swift` | L–M | |
| macOS menu bar with key labels | SHIPPED: `crates/slopty-shell/src/app_menus.rs` | **has**: `AxMacUI/App/MainMenu.swift` | M | |

### 1.6 Files, changes and git

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Changes pane: working tree or branch vs base; unified/split; file tree; syntax colours; ignore whitespace | SHIPPED: `crates/slopty-shell/src/changes.rs`, `changes/review.rs`; git ops on the wire (`crates/slopty-proto/src/git.rs:30-200`) | **partial, in progress**: diff chip and Changes popover with per-file counts (`AxMacUI/Chrome/ChangesPopover.swift:3-6`, `AxMacUI/Chrome/GitChanges.swift`; local hosts only) | H | This is Phase 3. A full diff view is the next step. |
| Files pane: tree, editor, find, Markdown preview, image preview | SHIPPED: `crates/slopty-shell/src/files/*` (editor find/replace comes from gpui-base, unverified) | missing | L | Ruled out for Axolotty: use your own editor (open-in, §1.2). |
| Commit, push, PR/MR through gh or glab; post a review | SHIPPED on the worker (`crates/slopty-worker/src/repo/`). Whether the current shell offers commit/PR buttons is unverified (the commit sheet was removed in `b96dbc039`) | missing | L | The agent does git itself. |
| Branch shown in the chrome | SHIPPED | **has**: `AxMacUI/Chrome/StatusBarView.swift:155`, band branch (`AxMacUI/Chrome/BandView.swift`) | M | |
| Finder File Provider over each worker's home | SHIPPED: `apps/slopty-files` | n/a | L | Remote-only. |
| CLI file verbs: `ls stat mkdir mv trash search push pull cat put` | SHIPPED: `apps/slopty-cli/src/verbs.rs:178-310` | n/a | L | Local files need no verbs. |

### 1.7 Ports, browser and clipboard

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Ports listening in each terminal's process tree (libproc on macOS, `/proc` on Linux), scanned on demand | SHIPPED: `crates/slopty-worker/src/ports.rs:1-40`; `slopty ports` (`apps/slopty-cli/src/verbs.rs:257`); shown in the hover card | **has**: `PaneInfo.ports`, the hover card and one-click open (`axolotty ports` was dropped) | H | Agents start dev servers. Show "localhost:5173" and open it. |
| Forward a worker's ports to the same loopback port here, plus a SOCKS proxy | SHIPPED: `crates/slopty-client/src/tunnel.rs:1-30` | n/a (local) | M once remote | |
| Browser pane | SHIPPED: `crates/slopty-shell/src/app_menus.rs:300` | missing | L | Opening the system browser is enough. |
| Clipboard sync with workers (lazy, every type, secrets concealed) | SHIPPED: `crates/slopty-worker/src/clip.rs` | n/a (local) | M once remote | |
| File transfer both ways, resumable, survives a relaunch | SHIPPED: `crates/slopty-client/src/xfer.rs` | **partial**: dropped files paste as shell-quoted paths (`AxMacUI/Terminal/TerminalView.swift:865-886`) | L now | Remote needs an upload. |
| Kitty drag-and-drop (OSC 72) into programs | SHIPPED: `crates/slopty-terminal/src/view/file_drag.rs` | missing | L | |
| Pasting a picture | SHIPPED: put on the worker's pasteboard first (`crates/slopty-terminal/src/view.rs:451`) | **partial**: local paste goes through the system; images unverified | M | Claude Code reads a pasted image from the pasteboard. Works locally by default. |

### 1.8 Multi-machine, remote, deploy and update

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Remote hosts | SHIPPED: plaintext QUIC (`noq`) over Tailscale/VPN; admission by tailnet `whois` and `[network] allow` (`docs/ARCHITECTURE.md` §1, `crates/slopty-tailnet`) | **missing**: Unix socket only (`AxClient/HostConnection.swift:95`, `AxHost/Server.swift:245-251`). The client model holds several hosts (`AxMacUI/Model/AppModel.swift:15,52`). Planned as TCP+TLS with pairing (`.research/client-server-architecture.md` §8.2) | H (strategic) | |
| Server: directory of machines, leases, MCP endpoint | SHIPPED: `apps/slopty-server`, `crates/slopty-server` | n/a | L | Not needed for one person with a few Macs. |
| Install on a machine over SSH (system ssh, password once, host-key fingerprint) | SHIPPED: `crates/slopty-deploy/src/lib.rs:1-12`, `apps/slopty-cli/src/deploy.rs:57`, `crates/slopty-app/src/ssh.rs:94` | missing | M later | |
| Update all machines; never take one back to an older build; keep shells across an update | SHIPPED: `crates/slopty-client/src/update.rs`, `crates/slopty-app/src/ssh.rs:406` | n/a. The local holder already survives app updates (`AxHost/Holder.swift:7-15`) | M later | |
| Version-mismatch notice | SHIPPED: `crates/slopty-client/src/update.rs:1-30` | **partial**: `protocolVersion` in the hello (`AxProtocol/Messages.swift:103,177`); the UI behaviour is unverified | M | |
| Reconnect with backoff; drop a silent host after 15 s | SHIPPED (CHANGELOG) | **has**: reconnect (`AxClient/HostConnection.swift`), "Reconnecting" empty state (`AxMacUI/Window/EmptyStateView.swift:4-7`) | M | |
| Wake-on-LAN, `slopty wake` | SHIPPED: `crates/slopty-proto/src/lan.rs`, `apps/slopty-cli/src/verbs.rs:44-49` | n/a | L | |
| `slopty attach` (a raw terminal; `^]` detaches) | SHIPPED: `apps/slopty-cli/src/lib.rs:143-158`, `attach.rs` | **dropped** (2026-11-02): `axolotty attach` was built, then removed as unused | M | Lets you use an Axolotty pane from ssh or another terminal. |
| `slopty ssh` (carries terminfo) | SHIPPED: `apps/slopty-cli/src/lib.rs:95-105` | missing | M | |
| SSH agent forwarding with per-use approval | PLANNED: `.research/ideas-2026-09-30.md:566` | n/a | L | |

### 1.9 Window and desktop streaming (excluded unless argued essential)

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Window and display streaming: ScreenCaptureKit → VideoToolbox HEVC 4:4:4 → Reed–Solomon FEC → QUIC datagrams, BBR3, adaptive bitrate | SHIPPED: `crates/slopty-capture`, `slopty-codec`, `slopty-media`; `docs/ARCHITECTURE.md` §3 | missing | L | Not essential: Screen Sharing and Parsec exist (§3). |
| Remote input injection, cursor, curtain, virtual display sized to the client, audio (Opus), drag and drop into streamed apps | SHIPPED: `crates/slopty-input`, `slopty-veil`, `slopty-vdisplay`, `crates/slopty-media/src/audio.rs`, `slopty-dnd` | missing | L | |
| `slopty windows` and `slopty capture` (PNG of a window, for agents) | SHIPPED: `apps/slopty-cli/src/verbs.rs:263-279` | missing | M | A local `screencapture -l` wrapper would give agents most of this (S). |

### 1.10 CLI verbs (agent- and script-facing)

| Slopty verb (`apps/slopty-cli/src/verbs.rs`) | Axolotty equivalent (`axolotty/main.swift`) | Value |
|---|---|---|
| `workers` | n/a (single host); `ping` (:103) | L |
| `terminals` | `ls` (:109) | — |
| `open` / `close` / `resize` | `new` (:135), `split` (:154), `close` (:220) | — |
| `send` (text, paste, named keys `[mods+]key`) | `send` (:168), text only | **M**: add `--paste` and `--keys ctrl+c,enter` |
| `screen` / `output` (absolute line ranges with a cursor) | `capture --scrollback --format` (:177) | M: line ranges let an agent read incrementally |
| `commands` (OSC 133 commands with exit codes) | dropped (built, then removed) | **H**: an agent can check "did the test command pass?" |
| `wait` (on terminal events) | `wait --for done\|idle\|blocked\|error\|exit` (:226) | add `--for command` (next command end, with its code) |
| `events` (a feed with a cursor; `--needs` filter) | dropped (built, then removed) | M |
| `agent start\|tell\|wait\|stop\|status\|read`, `agents` | partial via `new -- claude` and `status` | H (§2 items 7-9) |
| `ports` | missing | H |
| `cat` / `put` / `ls` / `mv` / `trash` / `search` / `push` / `pull` | n/a (local) | L |
| `windows` / `capture` | missing | M |
| `attach` | dropped (built, then removed) | M |
| `mcp` | missing | H |
| `ui state\|terminal\|open\|diff\|show\|hide\|split` (an agent drives the window) | missing | M: "open this file beside me", "show the diff" |
| `hook` (hidden relay) | `status` (:188) is the manual equivalent | H |
| `settings path\|init`, `crashes`, `worker doctor\|screens\|awake` | missing | L |

### 1.11 iOS and iPad

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| iPhone: a session list, then the terminal edge to edge under one band | SHIPPED: `crates/slopty-shell/src/shell/compact.rs` | missing (planned in `.research/client-server-architecture.md` §10, Phase 2) | M | All of iOS depends on remote hosts. |
| Blink-style key row: Esc ⌃ ⌥, arrow joystick, ⌘ layer with F-keys, keys chosen by the running program; hidden with a hardware keyboard | SHIPPED: `crates/slopty-shell/src/shell/compact/key_row.rs:1-30` | missing | M | |
| iPad: Mac layout in regular width; key row in the shortcut bar; ⌘ menus | SHIPPED: `apps/slopty-ios/src/keyboard.rs` | missing | M | |
| Long-press selection, copy/paste key | SHIPPED per the CHANGELOG (not re-checked) | missing | M | |
| Files and Photos pickers to upload | SHIPPED: `crates/slopty-platform/src/file_drop/picker.rs` | missing | L | |
| Connect a phone by QR code | SHIPPED: `crates/slopty-shell/src/settings/invite.rs` | missing (QR pairing planned, §8.2) | M | |

### 1.12 Settings, onboarding, accessibility, performance

| Feature | Slopty status | Axolotty status | Value | Notes |
|---|---|---|---|---|
| Settings file | SHIPPED: `settings.toml`, hot-reloaded, editable for another machine (`crates/slopty-settings/src/lib.rs`), plus `ui-settings.json` | **has**: UserDefaults with 8 keys (`AxMacUI/Model/Preferences.swift:14-21`) and a Settings window (`AxMacUI/App/SettingsWindowController.swift`) | M | Host-side settings will need a file once hosts are remote. |
| Settings pages: Devices, Providers (detect and install agents per device), Appearance (accent, glass/solid, smooth scroll), Files, Notifications (one switch), Shortcuts, Archived | SHIPPED: `crates/slopty-shell/src/shell.rs:518-532` | **partial**: one window: theme, font size, option-as-alt, cursor, status bar, dim, paste confirm | L–M | |
| First run | SHIPPED: lands on Settings → Devices with Add device open; "Use this Mac" shows a Screen Recording/Accessibility checklist; finds servers on the tailnet; offers to move the app to Applications (move offer unverified in code) | **has**: an empty state with launch tiles (Shell 1, agents 2-n) and a project pill (`AxMacUI/Window/EmptyStateView.swift:8-20`); agents found on PATH (`AxMacUI/Sidebar/AgentPresets.swift:15-27`) | M | Axolotty's first run fits a local app better. |
| Open at login | SHIPPED: `crates/slopty-platform/src/login.rs` | **has** for the daemon: an SMAppService LaunchAgent (`AxMacUI/App/ServerLauncher.swift:9-36`) | L | |
| Update-available notice | REMOVED from the UI (the status bar went; `crates/slopty-platform/src/fetch.rs` is unused) | missing | L | Use Sparkle when distributing. |
| Crash reports for every process (`slopty crashes`) | SHIPPED: `crates/slopty-crash` | missing | M | Cheap for a three-process system. |
| Accessibility tree | SHIPPED: AccessKit roles and labels (~274 labels), keyboard ring, tests read the tree (`crates/slopty-kit/src/a11y.rs`) | **partial**: the terminal exposes its text (`AxMacUI/Terminal/TerminalView.swift:890`); a few labels (`AxMacUI/App/AppDelegate.swift`, `AxMacUI/Components/Button.swift`) | M | AppKit gives most of this for free. Audit the sidebar rows and band. |
| Reduce Motion / Increase Contrast | SHIPPED: Reduce Motion (`crates/slopty-app/src/lib.rs:95`); Increase Contrast partial (`crates/slopty-shell/src/lit.rs:102`) plus high-contrast themes | **has**: Reduce Motion (`AxMacUI/Design/Axo.swift:283`); Increase Contrast read (`AxMacUI/Panes/PaneContainerView.swift:358`) | M | |
| Performance claims | Keystroke echo p50 / p90 / max 4.4 / 4.8 / 5.1 ms (release) and 4.9 / 5.9 / 11.7 ms (debug) on loopback; window stream capture→decoded p50 about 11 ms; first frame about 250 ms after Open (`docs/MEASUREMENTS.md:166,508-509`). 422 dated measurement sections. Note the README sets no budgets | `.research/bench/` exists; the Phase 1 gates G1–G5 (`.research/client-server-architecture.md` §10) are correctness gates, not latency budgets | M | Axolotty should publish the same two numbers: echo p50/p99 and attach-to-first-frame. |

## 2. What Axolotty should build next (ranked, grouped by shared plumbing)

Ranked by value to an agentic terminal over effort. Items in a group share plumbing, so build
each group in order. Effort: **S** is under a day, **M** a few days, **L** a week or more.
The inspector and window streaming are excluded.

### Group A: know what the agent is doing (hooks → status → need)

1. **Claude Code hook relay (M).** When Axolotty starts `claude`, add
   `--settings '<json>'` naming `axolotty hook` for Slopty's 15 events
   (`crates/slopty-agent/src/hooks.rs:22-40`). The hook posts to `$AXOLOTTY_SOCKET` with
   `$AXOLOTTY_PANE_ID`, and the host maps events to the `StatusBook`.
   - Never write `~/.claude/settings.json`.
   - *Why first:* today a stock `claude` shows only "running", so every attention feature above
     it is blind.
2. **A need kind and need words in status (S).** Add `need` (permission/question/plan/auth) to
   `StatusRecord` and to OSC 7501, as Slopty does (`crates/slopty-proto/src/terminal.rs:917-955`).
   Fill it from `PermissionRequest`/`Notification` (tool name and command).
   - *Why:* the band chip, the pane strip and notifications can then say "Needs approval · run
     cargo test" instead of "needs input".
3. **The Phase 3 need bar, built safely (M).** Show the question and the tool. Its primary action
   is to **focus that pane** (↩), so the person answers in the TUI.
   - If Allow/Deny buttons stay, answer only through Claude Code's own `PermissionRequest` hook
     decision (a blocking hook that returns allow/deny), never by typing Enter or Esc into the
     TUI.
   - Spike first: does the TUI dialog close when the hook answers? This is **unverified**.
   - *Why:* Slopty shipped key-typing Allow/Deny and then deleted it as harmful
     (`docs/decisions/layout.md:132-137`), because it raced the TUI and broke as Claude's dialogs
     changed.
4. **Session ownership and the block ledger (S).** Claim a pane on the first event that carries a
   session id, and drop other ids (a nested `claude -p` posts to the parent's pane). Keep
   "blocked" as a set keyed by `tool_use_id`, ended also by `PostToolUseFailure`. Treat Esc as a
   finished turn with no `Stop` (`.research/slopty-lessons.md` §4.1).
   - *Why:* without these, statuses stick or flip wrongly.
5. **Transcript and registry fallback for a `claude` the person typed (M).** Read
   `~/.claude/sessions/<pid>.json` for the pane's process, then follow its transcript JSONL
   (read-only).
   - *Why:* Slopty covers typed sessions this way, since it dropped shell wiring. No config is
     touched.
6. **Notifications done right (S).** Make needs-you banners Time Sensitive, withdraw a banner
   once its pane is seen, and count failed panes in the badge (`AxMacUI/App/AttentionCenter.swift`).
   Add an Inbox list (⇧⌘J) beside Jump to Agent: needs-you → failed → done → working.

### Group B: let agents drive Axolotty (CLI → MCP)

7. **Safe `send` to an agent (S).** Add `axolotty send --paste` (bracketed) with Enter as a
   separate write ≥200 ms later, refused while the pane is `blocked`. Add `--keys ctrl+c,enter`
   (`docs/decisions/agents.md:94-121`).
   - *Why:* orchestrating agents through the CLI is unreliable without it.
8. **`axolotty mcp` (S–M).** A stdio MCP server over the existing verbs: `ls`, `new` (with
   agent, cwd, worktree), `send`, `capture`/`output`, `wait`, `status`, `notify`, `close`. Hand
   it to started agents with `--mcp-config` (`crates/slopty-agent/src/mcp.rs:19-23`).
   - *Why:* Slopty's `agent_start/tell/wait/read` tools are its most agent-native feature, and
     Axolotty already has the verbs.
9. **CLI verbs agents need (S each):**
   - `commands`: OSC 133 commands with their exit codes. The VT already parses them
     (`AxVT/VTTerminal.swift:47-50`).
   - `wait --for command`.
   - `output --from <line>`: incremental reads.
   - `events --follow`: a status-change feed.
   - `attach` (`^]` detaches). Built, then dropped.

### Group C: worktrees and resume (start agents well)

10. **New agent in its own git worktree (M).** An option in the "+" menu and the CLI: make
    `.worktrees/<name>` from a chosen base, run a repo setup script if one exists, and offer to
    remove merged clean worktrees, keeping ones with unpushed work.
    - *Why:* the standard pattern for parallel agents. The sidebar already groups by project.
11. **Resume past Claude sessions from the picker (M).** Search `~/.claude/history.jsonl` and
    project transcripts by what was asked, then open `claude --resume <id>` in its folder.
    Refuse to resume a session a live process holds.
12. **Restart an ended session in place (S, after 1).** Add an ended bar: "exited · code X ·
    ↩ restart". It reruns the recipe; for an agent, `--resume` with the session id that the
    hooks recorded.
13. **Start presets (S).** Per agent: permission mode (plan/auto/default), model and effort.
    Remember the last start, like Slopty's `[agents] autonomy` but per launch.

### Group D: terminal craft agents' output needs

14. **Find in scrollback (M).** A Ghostty-style corner card with a count and regex/case/word
    toggles, running on the local mirror. Use ⌘F and share the find pasteboard.
15. **Links (M).** OSC 8 plus URL and `path:line` detection on the logical line, a hover
    preview, ⌘-click to open: URLs in the browser, paths in the person's editor at the line
    (see 20).
16. **Command blocks UI (M).** Prompt jumps ⌘↑/⌘↓, copy last output, a block menu (copy
    command/output, rerun), a failed-exit mark, and "long command finished unwatched" through
    the existing toast and notification path. The OSC 133 data is already on the host.
17. **Bash and fish shell integration (S).** Today only zsh gets OSC 133/7
    (`AxHost/ShellEnvironment.swift:69`).
18. **Never yank the reader (S).** A "↓ N new lines" pill while scrolled up, a resize overlay,
    and automatic Secure Keyboard Entry when the PTY turns echo off.
19. **Quick select and keyboard copy mode (M).** Label every URL, path and hash on screen (⇧⌘Space).
    Add vi-key copy mode (⇧⌘X).

### Group E: changes, editor and ports (what the agent produced)

20. **Open in editor (S).** ⌥⌘O opens the session's folder or a clicked path in the person's
    editor (VS Code, Cursor, Zed or `$EDITOR`). Links (15) and the Changes popover reuse it.
21. **Finish Changes into a real diff view (M).** Building on the in-progress chip and popover:
    a unified/split diff of the working tree, and branch vs base, as a summoned pane (Esc back to
    the terminal). It stays read-only.
22. **Ports per pane (S–M).** Walk each pane's process tree with libproc
    (`crates/slopty-worker/src/ports.rs`). Scan when output mentions `localhost:`, then every 2 s
    while busy. Show the ports in the hover card and band, click to open, and add
    `axolotty ports`.
    - *Why:* agents start dev servers, and the person wants to see them.
23. **Keep the Mac awake while an agent works (S).** An `IOPMAssertion` from the host while any
    pane is `working`, with a silence cap.

### Group F: appearance and settings

24. **Fonts and themes (S–M).** Pick the terminal font family, bundle a Nerd Font symbols
    fallback, and import Ghostty themes (the keys already match, `AxModel/Theme.swift:51`).
    Allow separate light and dark picks.

### Group G: beyond one Mac (largest; do after A–E)

25. **Remote hosts (L).** TCP+TLS or `ssh host axolottyd --stdio`, per
    `.research/client-server-architecture.md` §8.2. Then add, in this order: open-in-editor
    over ssh-remote, port forwarding at the same loopback port (`crates/slopty-client/src/tunnel.rs`),
    clipboard sync, drop-to-upload, install over SSH, and update-all that never downgrades.
    iOS (key row, push relay) comes after remote works.
    - *Why last:* `.research/slopty-lessons.md` §4.4 item 11 records that Slopty's early remote,
      iOS and tailnet scope cost it the local product.

**Overlap with the planned Phase 3** (`.research/wow/synthesis.md`):
- Need bar = items 2–3. Recommendation: focus the pane, or decide through the hook, never type
  keys.
- Diff chip and Changes popover = item 21 (in progress).
- Hover-card metadata = item 22 (ports) plus branch, cwd and time in state. Slopty's hover card
  shows title, machine, branch and ports (`crates/slopty-shell/src/shell/session_hover_card.rs`).

## 3. Slopty ideas not worth copying

- **Parsec-class window and desktop streaming** (HEVC 4:4:4, FEC, BBR3 tuning, audio, virtual
  displays, curtain, drag and drop into streamed apps). It is tens of thousands of lines and
  hundreds of measurement sections, and macOS Screen Sharing and Parsec already do it. The owner
  excluded it. The one piece worth keeping is a still capture for agents (`slopty capture`), done
  locally with `screencapture`.
- **A GUI that drives the agent**: composer, prompt queue, GUI approvals that type keys, fork,
  rewind, ask-aside. Slopty built it, kept chasing Claude Code releases, and deleted 144k lines on
  2026-10-30. Axolotty's synthesis already rules out composers.
- **The inspector and the prompt-box "mod"** (a Claude plugin that mirrors the TUI's input box).
  The inspector is excluded by the owner, and the mod exists only to feed it.
- **Projects, boards, budgets, verifier, merge queue, schedules.** Built and deleted
  (`b96dbc039`, `3317d1d3b`). Kanban is also in Axolotty's "Not copied".
- **The infinite canvas, sticky notes, minimap, and following another client's viewport.** Built
  and retired twice (slop-desk and Slopty).
- **Usage and context meters.** They need private endpoints. Slopty removed them (`3ba7e37b7`).
- **Driven Codex app-server, ACP and pi RPC adapters.** Removed. Each agent's TUI plus hooks or
  OSC 7501 is enough.
- **Auto-trusting a folder by writing Claude Code's config** (`crates/slopty-agent/src/trust.rs`).
  It writes the agent's own files, against the owner's rule that `~/.claude` is not touched.
  Let the TUI ask once.
- **Plaintext QUIC with no app crypto, trusting the tailnet**, plus a vendored, patched QUIC stack
  (datagram echo copies, pacer patches). That is too much transport for a terminal. Axolotty's
  plan of TLS or SSH stdio is simpler and safe off-tailnet.
- **The server role (fleet directory, leases, fleet attention ladder).** It is a fourth daemon,
  justified only by a fleet. With a few hosts, a client can dial each directly.
- **`show_visual` / `show_page`** (native charts and sandboxed WKWebView pages offered to agents
  as tools). Large, and MCP Apps calls are already refused in Slopty (`docs/decisions/agents.md:144`).
- **Finder File Provider, Wake-on-LAN, a browser pane, the built-in file editor.** Niche, or
  better done by the system and the person's own editor.
- **Predictive local echo.** Useless locally. Revisit only for iOS over a WAN.
- **Things Slopty itself rejected** (`docs/decisions/layout.md:138-145`): a quick terminal, tab
  colours and groups, broadcast input, auto-approve, a menu bar extra or Watch app, notification
  sounds.

## 4. Could not verify

- Whether Slopty's current shell still offers Commit or PR buttons. The worker git ops exist; the
  UI strings were not found.
- The Files editor's find/replace and go-to-line come from gpui-base, not Slopty's own code.
- Slopty's "move to Applications" offer (README only).
- Slopty's iOS long-press selection was not re-checked after the 2026-10-30 rewrite.
- Whether a Claude Code `PermissionRequest` hook decision closes the TUI dialog while it is open.
  This needs a spike before item 3.
- In Axolotty: whether a word selection follows a soft wrap; sextant and octant drawing; image
  paste for remote hosts; the version-mismatch UI.
