# Rex (Superlogical) and herdr — study for Axolotty (2026-11-02)

Sources: Rex docs (superlogical.com/rex/docs/llms-full.txt, read in full), Mitchell Hashimoto's architecture/demo videos (transcribed), @almonk UI tour (frames + whisper), Classmethod hands-on review, HN #49098965, r/Ghostty, the public `rex` preview binary (`go version -m`, `strings`; never run), herdrdev/herdr + herdr-core source. "(secondary)" = third-party claim.

## Rex — what it is
- "The multiplexer for all work", by Superlogical (Mitchell Hashimoto, Jack Pearkes, Alasdair Monk, Hector Simpson). Free, no account, no telemetry, closed source.
- Beta: macOS app since 2026-10-05, iOS TestFlight since 2026-10-22 (iPad + "Duo"), Linux/FreeBSD servers (alpha).
- Server + CLI = one Go binary `rex` (cgo) embedding libghostty (`go.mitchellh.com/libghostty`), gopher-lua (Lua 5.1 config), tsnet (built-in Tailscale), sqlite, CBOR, websocket. Packages: `server/persist/{attach,restore}`, `session/record_restore`, `snapshot/*`, `loginserver` (PAM), `agentharness/known/{claude,codex,opencode,pi}`.
- Mac app bundles the server at `Rex Beta.app/Contents/Helpers/Rex Server.rex`, installs a copy under `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/`, socket `~/Library/Application Support/rex/server.sock`. Sparkle updates.

## Rex — sync protocol (architecture video)
1. Client attaches → server pauses PTY processing, sends a hand-designed binary frame with only the **visible screen**, then READY → user can type/select/scroll immediately.
2. Then **raw PTY bytes are tee'd to every client** ("like SSH"); every client runs libghostty: "N replica distributed terminal state machines".
3. Input serialized at the server: one writer, many readers.
4. Scrollback streams afterwards, **newest first**.
5. Each client has its own viewport. Each split is its own stream.
- Scale: 10k active terminals in 3.8 GB (~400 KB each vs ~5 MB tmux); idle terminals "parked" as encrypted snapshots on disk, unparked in ~200 µs; quiet PTYs moved to a shared epoll thread.
- API compatibility across client/server versions via JSON-pointer rewrite rules ("API revision 7").
- Terminfo `xterm-rex` = Ghostty's + capability `Pst` advertising OSC 7501; ssh_config snippet falls back to `xterm-256color`.

## Rex — object model
Server → session ("one project", generated names like `drifting-cedar`) → window (tab) → block (one application; today a terminal) + floating layers; blocks can be detached (alive, unplaced). UUID ids; targets resolve by full id → label → position → id suffix (≥4 chars); ambiguous = exit 3. Env per terminal: `REX_SESSION`, `REX_BLOCK`, `REX_SERVER`, `REX_BIN_DIR` (rex first on PATH). Block methods: `format` (text/html/vt), `process` (child + foreground: name, cwd, pid, ancestors), `pwd`, `title`, `size`, `write`, `reset`, `resize`, `set_theme`, `program_status`, `list_dir`.

## Rex — agent state
- **OSC 7501 only** (Program Status Protocol, spec 0.4): `ESC]7501;state=…:kind=…:app=…:id=…:progress=…:title=<b64>:msg=<b64> ST`. States idle/working/done/blocked(kind permission|question|auth)/error/clear; hierarchical ids; report replaces record; working/blocked dropped on exit or OSC 133 A; done/error persist until seen; `OSC 7501;?` feature query; ≤4096 B per sequence, ≤256 records; OSC 9;4 may map to the root record until real 7501 arrives; notifications SHOULD be rate-limited.
- Claude Code ≥2.1.295 emits it (`app=claude-code`, msg like "approve Write: /path"); Codex emits it (`terminal_program_status.rs`).
- No screen scraping. `rex skill setup` installs a skill + one SessionStart hook (`rex __internal session-start --agent claude`, 5 s timeout) that only tells the agent which session/block it is in; skill stub prints the current guide from the CLI so updates propagate. Claude, Codex (hooks + skill), OpenCode, Pi (skill). `--session-naming` lets agents name the session. Palette: "Install Rex for Agents".

## Rex — Activity Mode (⌘. / eye button; designed by Alasdair Monk)
Sidebar scoped to processes reporting status, grouped by **host** ("This Mac", "Studio") then **session**. Row: app icon, title (7501 title or terminal title), status line (Working/Done/Idle or msg), relative time, "•••" while working. Agents in one tab group together; click → navigate to pane. Unread dot = done & unseen. Completion sound; macOS notification only when Rex isn't frontmost. ⌘1… jumps. Mitchell: "Lots of heuristics and other signals as input to decide what exactly to show when."
Normal mode: unfocused tab shows spinner while working, symbols when blocked; blocked tab gets a blue dot on its icon (Classmethod); session picker marks sessions with done/blocked work; tab icon = processes of its panes (stacked, animated); terminal title becomes tab name.

## Rex — layout and visual design
- Default looks like Ghostty/Terminal. Title bar: host+session chip ("ping-panes / This Mac"), tab pills, buttons for Activity, command palette, +.
- Per-pane header: process icon, process name, cwd ("Node ~/apps/replay-web", "top as root ~"), split right/down, zoom, close. Optional coloured outline on the focused pane.
- Tab style setting: Above / Left / Right; Left/Right make a sidebar of hosts → sessions → tabs. Sidebar footer: settings, hosts, remote/Tailscale.
- Animated splits, auto-balance, zoom, drag panes between tabs/new tab, floating layers.
- 41 themes (27 dark/14 light), separate light/dark pick, imports Ghostty/iTerm2 schemes, Liquid Glass interface mode, full ProMotion animations, native scrollbar and scrolling.
- **Tab peek**: three-finger swipe down shows live Metal previews of other tabs; further drag → Mission-Control overview.
- **Go to Directory** (⌘⇧G) incl. remote hosts via `list_dir`; **Insert Path** picker with MRU that types into the prompt (works inside agents).
- Onboarding: a session opens a shell immediately ("feels like a normal terminal"); onboarding blocks; cold launch < half a Dock bounce.
- Settings: themes/fonts/tabs/sounds/notifications/Remote Control in app prefs; keybindings & actions in `~/.config/rex/init.lua` (no watching: `rex config reload|check`, `rex keymap`). Binding priority: defaults < init.lua < in-app "Change Shortcut…".
- Bindings: `rex.bind("cmd+d","pane.split",{direction="right"})`, sequences `ctrl+b>c`, modes (`resize/left`), physical keys `ctrl+[KeyA]`, Lua fns, `rex.action{…}` appear in palette. Seen shortcuts: ⌘⇧P palette, ⌘⇧G go to dir, ⌘. activity, ⌘1–9.

## Rex — CLI / API / events
CLI: `ls new run[--wait --split --ratio] split send send-key capture[--trim --unwrap --format] wait[--for] zoom move swap events[--json] do api list|describe|call block call whoami hosts server start|stop|status|logs|tailscale skill setup|status|remove|show client ls -C <client> actions`. Exit codes 0/1/2/3 not-found-or-ambiguous/4 unreachable/130.
Self-describing API (JSON Schema + examples per method) over Unix socket and HTTPS-over-Tailscale. Events: session (`window_*`, `block_created/closed`, `session_view_changed`, `client_*`), terminal (`child_exited pwd_changed title_changed bell process_changed desktop_notification progress_report clipboard_written program_status_changed/removed`), server (`session_created/destroyed keymap_changed tailscale_status_changed`). Lua: `rex.on/wait/after/every/exec/server(label)/client.queue` (needs Remote Control).

## Rex — persistence and remote
Processes survive app quit; ~64 MiB scrollback per terminal. Docs: "Restarting the shared server ends every session and every program in them" (personal/login servers survive package upgrades); agent-conversation resume missing (community `rexume`, `rexurrect`) — top Reddit complaint ("I'll need to stick with Herdr"). Remote hosts via palette "Add Remote Host…" or `rex.host{}`; built-in Tailscale, PAM login server, "full SSH replacement", mosh-like feel; iOS attaches to the same sessions.

## herdr (herdrdev/herdr, Rust TUI on libghostty-vt, ~47k★, v0.9.5)
- Background server owns PTYs, clients attach. Workspace → tab → pane; agent/session/machine.
- herdr 1 state: foreground pgid (`tcgetpgrp`, `KERN_PROCARGS2`, `proc_pidinfo`), unwrap node/python/bun launchers, then 22 per-agent TOML rule files matched against bottom-of-screen / OSC title / OSC 9;4 (remote-updated; `herdr agent explain`); working→idle confirmed 3× at 100 ms; 3 s startup grace. Hooks mostly give session identity + resume command. `herdr pane report-agent … --seq N` for self-reporting.
- herdr 2 (`herdr-core` + GPUI app): "Status comes only from OSC 7501. No screen detection".
- UX: sidebar Spaces + Agents with token rows; state rolls up pane→tab→workspace; Goto picker with blocked/working/idle/done filters; toasts (in-app / outer terminal / system); separate done vs request sounds; "done" seen tracked per client.
- API: JSON over Unix socket with schema; `agent start/prompt --wait --until/wait/send-keys`; `agent prompt` refuses a blocked agent; skill teaches agents the CLI. Persistence: layout + cwd + agent resume commands; `--handoff` keeps processes across updates; SSH machines in one agent list.

## Peers in brief
cmux (Swift/AppKit + libghostty; hooks first, blue ring on waiting pane, ⌘⇧U latest unread, vertical tabs with branch/PR/ports); Warp (OSC 777 JSON from plugin hooks); Ghostty 1.4 (OSC 9/777, 9;4 progress, notify-on-command-finish); Otty (hooks + OSC 26); diri (rule files choose authority; separate Engine keeps PTYs alive; MCP for agents); Paradev (pty-daemon survives updates); Claude Squad (tmux capture hashing).

## Takeaways for Axolotty
1. OSC 7501 is the primary state signal; answer `OSC 7501;?`; advertise via terminfo capability. Fallbacks: OSC 9/777, 9;4, process identity, opt-in hooks.
2. Activity view grouped host → workspace → session; unread dots; sounds; notifications only when not frontmost; jump shortcuts.
3. Rex's sync model (screen first → READY → raw byte tee → scrollback newest-first; per-client viewport; single input writer) — Axolotty does the same with libghostty snapshots.
4. Self-describing API + event stream + CLI with stable exit codes; skill installer + SessionStart context hook.
5. Beat Rex where users complain: survive server restarts (separate PTY holder), resume agents, open the sidebar by default, iOS client.
