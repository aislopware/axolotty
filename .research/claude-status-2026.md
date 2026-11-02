# Tracking Claude Code's status, November 2026

What the owner asked for: no inspector; the agent side is what slop-desk was (Claude Code status tracking), but done the current best way, not slop-desk's (it is a year old). Three studies, 2026-11-02:
- a static reading of the installed Claude Code 2.1.316 binary (strings only; nothing run);
- Anthropic's docs and changelog, and how today's tools do it;
- slop-desk's own code, as the baseline.

## What Claude Code offers

| Channel | Separates waiting from idle | Carries the question | Subagents | Reaches Axolotty |
|---|---|---|---|---|
| **OSC 7501** (since 2.1.295) | yes: `blocked`, with `kind=permission\|question\|auth` | yes, in `msg` ("answer: Q (a · b)", "approve Bash: …") | yes: one record per task id, cleared with `state=clear:id=` | directly and over ssh; **not inside tmux** (tmux answers only DA1, tmux #5713, PR #5830 open) |
| `claude agents --json` | yes: `status` busy\|waiting\|idle, plus `waitingFor` | no | no | anywhere on the host; Anthropic calls it "the supported way to read session state from outside Claude Code" |
| `~/.claude/sessions/<pid>.json` | yes | no | no | not a stable interface (the docs say don't parse it); rewritten exactly when status changes |
| Hooks (Notification, PermissionRequest, Stop) | yes | tool input | SubagentStart/Stop | need Claude's config written, which Axolotty never does. The Notification hook waits about 6 s. |
| Title glyph, BEL, OSC 9/777, OSC 9;4 | no | no | no | guesses only. The glyph is dropped once 7501 is answered. Auto notifications pick nothing for `TERM_PROGRAM=Axolotty`. |
| Messaging socket (`peerProtocol` 1, `notify_idle`) | idle only | no | no | built for Claude-to-Claude messaging, behind a policy switch; not for terminals |

The OSC 7501 mapping inside 2.1.316:
- busy, or idle with queued input: `working`, with `progress` as the percentage of todos done;
- a permission, sandbox, worker or goal prompt: `blocked` with `kind=permission`;
- needs input: `blocked` with `kind=question`;
- an auth failure: `blocked` with `kind=auth`;
- a turn completed: `done`;
- `error` for an error, `idle` before the first turn.

The probe waits 2 s and loses to an earlier DA1 reply. It is turned off by `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` and in background sessions.

## How the field does it

- **On native OSC 7501:**
  - iTerm2 3.7.5, where a key press marks a result seen;
  - herdr-core and the new Herdr;
  - cmux, as a backstop to its hooks;
  - libghostty, whose GUI doesn't show it yet;
  - Codex (since 9 Oct), pi 1.1.0 and Crush also emit it.
- **Hooks or wrappers:** Superset, Warp's plugin, cmux. They pay in double reporting and reconciling rules (cmux's 3 s rule).
- **Screen scraping:** Herdr TUI's manifests, Claude Squad's `capture-pane`. Brittle: "ten changes in three months".
- **Owning the process:** Conductor, vibe-kanban, Nimbalyst. They use the SDK or `stream-json` and are not terminals.

## What Axolotty does (and why)

1. **OSC 7501 is the one source.** It covers every field (state, kind, progress, msg, title, per-id records), keeps the lifetime rules of the spec, and keeps `done` and `error` until seen.
2. **Inside tmux** (and for a Claude that hasn't reported for itself 5 s after starting), the host asks `claude agents --json`.
   - Never on a timer, since a call costs about 0.9 s. An FSEvents stream on `~/.claude/sessions` (names only) says when a session changed and which pid, and the host asks only when that pid is one of its panes'.
   - A session belongs to a pane by process ancestry: the pane's process, or, in tmux, the shell of a tmux pane in the session the client in our pane shows. Several Axolotty panes sharing one tmux server stay apart, which an inherited environment variable would not do.
   - Its records (`agents:<pid>`) give way the moment the pane's Claude speaks for itself, so nothing is reported twice.
   - Verified live: tmux on its own socket in a pane, Claude inside went working → done, then blocked (question) → done.
3. **A grace second before speaking.** A permission a rule grants at once never toasts.
4. **Not built, by choice:**
   - hooks (they write Claude's config, report twice and lag about 6 s);
   - screen scraping;
   - the messaging socket;
   - an inspector or approvals in the GUI (the TUI does approvals).

## Open, worth doing next

- **Peek & Reply** (slop-desk ⌘⌥J): a card with the waiting agent's question and recent output, answered by typing into its TUI without moving focus. The thing slop-desk users would miss most.
- **A clickable rollup** of working, waiting and done at the top of the sidebar (slop-desk's rail marks).
- **Sounds you can choose** per state, and whether they play while the app is in front.
- **A tmux passthrough for 7501** when tmux PR #5830 lands: nothing to do but keep the probe reply first.
