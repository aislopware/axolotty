# slop-desk → Axolotty: lessons (2026-11-02)

Source: `/Volumes/Lacie/Workspace/oss/slop-desk` @ `e3a9b91f` (2036 commits, ~175 K Swift LOC in 22
SwiftPM targets + ~559 K Rust LOC in 88 crates). Read-only study. Paths below are relative to that repo
unless absolute.

## 0. TL;DR

- slop-desk **never called libghostty-vt's C API from Swift.** Era 1: full libghostty *surface* from a
  Zig fork (`External.zig` custom-IO patch), driven from Swift `@MainActor`. Era 2: `libghostty-vt` via the
  MIT Rust bindings (`libghostty-rs`) in `rust/slopdesk-vterm`, renderer in Rust (termrender + objc2 Metal +
  CoreText), exposed to Swift as 69 hand-written `slopdesk_term_surface_*` doors. The era-2 *patterns* map
  1:1 onto the vt C ABI; Axolotty just deletes the middle language.
- Surface → vt switch reason holds: **whoever owns the grid owns layout** (blocks, collapse, docked prompt).
- Renderer wins (measured): 2 drawables, `BGRA8Unorm`, opaque, no transaction present, instanced quads from
  `vertex_id`, 3-slot ring, **skip draw when engine Clean**, gated blink, CoreText ASCII fast path (6x),
  shelf atlas invalidating on growth, sprite box/braille/powerline.
- Failure was organizational: Rust→Swift→Rust round trip, ~85 s xcodebuild planning, 88 crates, essay
  docs + ratchets. Keep the engineering (oracles, ttyrec corpus, fork discipline); drop the bureaucracy.

## 1. libghostty-vt usage

### 1.1 Engine ownership (`rust/slopdesk-vterm/src/session.rs`)

One `VtSession` owns **every** engine handle together, because every handle is `!Send`/`!Sync` and
upstream locks nothing:

`terminal, render (RenderState), row_iter, cell_iter (reused, never per-frame), key encoder+event, mouse
encoder+event, selection gesture, kitty PlacementIterator, frame` — `Frame` (plain data) is all that leaves.

Rule worth copying for Axolotty: one Swift `final class TerminalCore` (or a C struct) owns
terminal + render state + iterators + encoders; nothing else ever touches a ghostty handle; what
leaves is a POD frame / instance buffer. Allocate iterators once and reuse; vt reuses their memory.

### 1.2 Calls used (Rust binding → C ABI in `include/ghostty/vt/*.h`)

| purpose | binding call | C equivalent |
|---|---|---|
| create | `Terminal::new(cols,rows)` then `resize(cols,rows,cell_w_px,cell_h_px)` | `ghostty_terminal_new`, `ghostty_terminal_resize` |
| feed | `vt_write(bytes)` (never fails; malformed input is logged) | `ghostty_terminal_vt_write` |
| pty replies | `on_pty_write(cb)` → push into bounded sink | terminal option callback (`ghostty_terminal_set`) |
| clipboard | `on_clipboard_write(cb)` (OSC 52 / OSC 1337 Copy, already base64-decoded **bytes**) | same |
| modes | `mode(Mode::SYNC_OUTPUT)`, `set_mode`, `is_mouse_tracking`, `active_screen` | `ghostty_terminal_get` / `_set` |
| viewport | `scroll_viewport`, `viewport_active`, `scrollbar`, `scrollback_rows` | `ghostty_terminal_scroll_viewport`, `_get` |
| theme | `set_default_fg/bg/cursor_color`, `set_default_color_palette`, cursor shape/blink | `ghostty_terminal_set` |
| limits | `set_scrollback_max_lines/bytes`, `compress()` + `compression_activity` | `ghostty_terminal_compress`, `_compression_activity` |
| metadata | `title()`, `pwd()`, `cursor_x/y` | `ghostty_terminal_get` |
| off-viewport rows | `grid_ref(point)` → cell by cell (pinned prompt header) | `ghostty_terminal_grid_ref`, `ghostty_grid_ref_cell/row` |
| selection | `set_selection`, `select_word/line/all`, `format_selection_buf`, gesture state machine | `selection.h` |
| keys | `key::Encoder::set_options_from_terminal(t)` + `encode(event)` | `ghostty_key_encoder_setopt_from_terminal` + encode |
| mouse | `mouse::Encoder::set_options_from_terminal(t)` | `mouse.h` |
| paste | `encode_paste(text, bracketed)` | `ghostty_terminal_paste` / `paste.h` |
| oracle | `fmt::Formatter` over the whole screen | `formatter.h` |
| glyph protocol | `set_glyph_protocol_enabled(false)` | `ghostty_terminal_set` |

Not registered on purpose: `on_enquiry`, `on_xtversion` (engine answers correctly), `on_bell`,
`on_desktop_notification`, `on_progress_report` (in slop-desk the HOST sniffed those so replays
did not re-fire them — for a local Axolotty, register them, but see replay hazard in §1.5).

### 1.3 Render-state iteration (the pattern to port verbatim) — `session.rs:1136-1265`

```rust
if held_for_synchronized_output(now)? { return Ok(Clean) }        // DEC 2026, 1 s timeout
let snapshot = render.begin_update(terminal)?.end()?;             // PHASE 1: only phase reading terminal
let reported = snapshot.dirty()?;                                  // Clean | Partial | Full
let force = refill || reported == Full;
// ⚠️ read cursor + default colours + alt-screen BEFORE the clean early-out (real bug, §1.5)
let colors = snapshot.colors()?; let cursor = cursor_of(&snapshot, ..)?;
let moved = cursor != frame.cursor || colors != frame.colors || alternate != frame.alternate;
if !force && reported == Clean { return if moved { Partial } else { Clean } }
let mut rows = row_iter.update(&snapshot)?;                        // PHASE 2: render-state memory only
while let Some(row) = rows.next() {
    let selection = row.selection()?;                              // per-row selection span
    if !row.dirty()? && !force && selection == target.selection { continue }
    let raw = row.raw_row()?; semantic = raw.semantic_prompt()?;   // OSC 133 per row
    wrapped = raw.is_wrapped()?;
    let mut cells = cell_iter.update(row)?;
    while let Some(cell) = cells.next() {
        let raw = cell.raw_cell()?;
        let style = if raw.has_styling()? { cell.style()? } else { Style::default() }; // skip style read
        if raw.has_text()? && !concealed { cell.graphemes_len()?; cell.graphemes_buf(&mut scratch)? }
    }
    row.set_dirty(false)?;            // engine flag cleared here; damage now lives in Frame row flag
}
snapshot.set_dirty(Clean)?;
```

Key points:
- **Two phases**: `begin_update…end` is the only part that needs the terminal; row/cell iteration
  reads render-state memory only. Axolotty: hold the terminal lock for phase 1 only, iterate outside.
- Per-row `dirty` + per-row selection compare → only damaged rows refilled. Frame keeps its own sticky
  row-dirty flag that the *renderer* clears after an actual draw (dropped frame ≠ lost damage).
- Resolve colours yourself: bold does **not** brighten (ghostty `bold-color` unset); inverse/faint
  need the raw style bits, not pre-resolved colours; SGR 8 hides glyph AND underline/strike/overline.
- Reuse scratch buffers (`scalars: Vec<char>`, `text: String`) on the session → full repaint allocates 0.
- The current Axolotty bench headers (`.research/bench/ghostty/include/ghostty/vt/render.h`) are newer
  than slop-desk's pin `22d13172`: they add `begin_update/end_update`, `row_iterator_next_dirty`,
  `ROW_DATA_ID`, `OVERSCAN`, `get_multi`, image iterators, `search.h`, `formatter.h`. Prefer
  `next_dirty` and `get_multi` over slop-desk's per-field calls.

### 1.4 Threading model

- Fork era: surface feed/refresh/draw main-only. Moving feed to a serial queue deadlocked: feed parked on
  libghostty's 64-slot app mailbox whose only consumer was `ghostty_app_tick` on main, while main did
  `queue.sync` (docs/31).
- vt era: **everything on main** (`@MainActor TerminalRendererSurface`, incl. Metal + CoreText). Floods handled
  by `ingestByteBudget = 256 KiB` per sync MainActor pass, `Task.yield()` only between passes, one drain +
  one present per batch (`TerminalSurfaceDriver.feedBatch`), backpressure awaited before each pass.
- Axolotty (local): Ghostty-style split is better — IO thread does read + `vt_write` under a per-terminal
  mutex (≤256 KiB per lock hold); display-link/render thread locks only for `render_state_update`, then
  iterates + encodes unlocked; main only for AppKit events. Never hold the mutex across Metal work.

### 1.5 Pitfalls they hit (each cost a debugging round)

1. **Cursor-only changes report Clean.** `?25h/?25l`, `OSC 12`, bare `CUP` write no cell → `dirty==Clean`.
   Reading cursor after the early-out left a stale/hidden cursor at an idle prompt after lazygit exits.
2. **PTY replies must be drained after every feed AND every resize** (`CSI 6n`, `CSI c`, `CSI >q`,
   `OSC 10/11/4 ?`, in-band size report). Undrained → vim/tmux hang or guess. Drop a reply *whole* if the
   queue is full (half an escape is worse than silence); clipboard queue evicts oldest.
3. **Replay hazard**: re-feeding a retained output ring into a fresh engine re-answers old `CSI 6n`
   (types `^[[3;7R` at the live prompt) and re-applies old OSC 52. Drain-and-discard after replay.
4. **Key encoder resync resets user prefs**: `set_options_from_terminal` resets `macos_option_as_alt`
   → re-apply after every sync. Sync after every feed (programs enable kitty kbd mid-stream), not per key.
5. **Mouse encoder resync forgets the last reported cell** → resync on feed only, not per event
   (else duplicate motion reports).
6. **Key press shape must match ghostty `SurfaceView_AppKit.keyEvent`**: `text` =
   `characters(byApplyingModifiers:)` with Control removed; `consumed_mods` = all held mods except
   ctrl/cmd; `unshifted` = `characters(byApplyingModifiers: [])` first scalar; drop PUA function-key text;
   forward `flagsChanged` (report-all-keys). Sending raw `event.characters` broke ⌃C/⌥ keys.
7. **IME**: `interpretKeyEvents` first; commits → text to encoder; composing presses encoded as
   `composing=true` (→ no bytes). Marked text is **drawn, never fed**. `macos-option-as-alt` bypasses the
   input context entirely (else Option is spent). Telex/CJK were the critical tests. Clear marked text
   on `resignFirstResponder`.
8. **Wheel**: ask `owns_wheel` (mouse tracking, or alt-screen + DEC 1007) before spending travel; emit one
   button-4/5 press **per row**, or cursor keys under alternate scroll; carry sub-row remainder.
9. **DEC 2026 sync output**: hold frame while set, ≤1 s (ghostty `sync_reset_ms`), resize ends the hold,
   then clear the mode so the next `?2026h` starts fresh. Draw returns HELD → re-poll next tick.
10. **Glyph protocol** (`ESC _ 25a1`) is enabled by default and *answers support* → disable unless you
    can rasterize registered outlines, else TUIs print tofu.
11. **Kitty graphics**: vt decodes no PNG — install a decoder hook. The bindings' optional PNG decoder was
    broken (reserved capacity, passed len 0). Close file/shared-memory transmission media.
12. **OSC 52 soundness**: an older bindings rev built `&str` via `from_utf8_unchecked` over pty bytes and
    sliced NULL for "clear clipboard" — treat clipboard payloads as untrusted bytes; validate UTF-8.
13. Resize no-op when unchanged (resize ends sync output, may emit a size report). DEC 1004: report only if
    set, report current focus on the OFF→ON edge, idempotent `set_focused`.
14. Paste via the engine encoder (scrubs NUL/ESC/DEL, LF→CR unbracketed, strips embedded `ESC[201~`); a Swift
    `"\e[200~"+text+"\e[201~"` was an injection bug. `compress()` one bounded step per quiet period.

### 1.6 Verification that paid off (copy this)

- **Formatter oracle** (`vterm/src/conformance/mod.rs`): frame text vs `Formatter` over the same terminal
  (independent readers). Corpus: ghostty's `test/fuzz-libghostty/corpus/stream-cmin` (3 271 files, in-tree).
- **Incremental vs fresh**: feed in 1/3/7-byte cuts, render each; final frame must equal one-shot feed.
- **Recorded TTY corpus** (`slopdesk-ttyrec`): nvim/fzf/lazygit/less/opentui, one chunk per pty `read(2)` +
  recorded input re-encoded under negotiated modes. Never record machine state (`top`). Break-test each sweep.

## 2. Terminal rendering

### 2.1 Split (all Rust in slop-desk; Swift in Axolotty)

- `slopdesk-termrender` (pure, testable without GPU/fonts via fake shaper/rasterizer): atlas, glyph
  cache, quad structs, layout, block list, chrome, paint. Units: **device pixels, top-left origin**,
  points→pixels converted once by the view.
- `slopdesk-apple-text`: CoreText font stack, fallback, shaping, rasterization.
- `slopdesk-apple-metal`: device, queue, layer, 3 pipelines, instance ring, 2 atlas textures, per-image
  textures. "Decides nothing."
- Axolotty equivalent: `RenderModel` (pure Swift, unit-testable, no Metal), `FontStack` (CoreText),
  `MetalRenderer`. Keep the "pure layout/paint has no GPU" boundary — it made 90 % of renderer bugs
  reachable from `swift test`.

### 2.2 CAMetalLayer config (`rust/slopdesk-apple-metal/src/surface.rs`)

```
pixelFormat = .bgra8Unorm          // NOT _sRGB: linear blending thins AA stems
framebufferOnly = true
isOpaque = true                    // render pass clears to theme bg
maximumDrawableCount = 2           // most latency-relevant number; 3 = +1 vblank
displaySyncEnabled = true          // torn text reads as wrong glyphs
presentsWithTransaction = false    // true serialises present behind AppKit layout on main
allowsNextDrawableTimeout = true   // occluded window / Space switch → skip frame, not hang
drawableSize & contentsScale set together, always; re-measure in viewDidChangeBackingProperties
```

### 2.3 Pipeline (`shaders.metal`, `renderer.rs`)

- No vertex buffer: `drawPrimitives(.triangleStrip, 0, 4, instanceCount)`, corners from `vertex_id`
  (`float2(vid&1, (vid>>1)&1)`); viewport size via `setVertexBytes`.
- Instances (`packed_` types + `static_assert(sizeof)` matched to Swift/Rust structs):
  `RectInstance{float4 rect; uchar4 color; uint style}`=24 B, `GlyphInstance{float4 rect; float4 uv;
  uchar4 color; uint colorAtlas}`=40 B, `ImageInstance{rect, uv}`=32 B.
- Rect styles in the fragment shader, analytic AA (no MSAA): solid, dotted (period 3×h, duty .5),
  dashed (8×h, .625), curly (sine, stroke h/4, wavelength 2h), hollow (1 px outline = unfocused cursor).
  Pattern phase-locked to the run's left edge; painter emits **one instance per run**, not per cell.
- Premultiplied alpha, blend `One / OneMinusSourceAlpha`. Two atlases: `Alpha8` coverage (text, tinted in
  shader `rgb*a`) and `BGRA8` premultiplied (emoji, sampled unchanged).
- Draw order: images z<min/2 → backgrounds → images mid → **underline/overline pass** → glyphs →
  images z≥0 → overlays (strikethrough, cursor, selection outlines). Underlines under glyphs so descenders
  cross them.
- Instance ring: 3 slots + `DispatchSemaphore(3)`; buffers double, never shrink. **Bug:** draw call used
  buffer *capacity* instead of written *count* → stale tail of a previous larger frame drawn.

### 2.4 Glyph atlas & CoreText

- Shelf packer (`termrender/src/atlas.rs`): shelf height fixed by first glyph; join shortest fitting shelf
  within a slack ratio. **Growth doubles and invalidates everything** (bump generation, re-rasterize lazily)
  — no repack. At max (4096²) reset+repack instead of caching `nil` forever (real bug).
- `GlyphKey { font: u16 (fallback index), glyph: u32, size_px: u16 (device px), subpixel: u8 phase,
  synthetic: bold/italic }`. NaN x → phase 0.
- Shaping (`apple-text/src/shape.rs`): **fast path** `CTFontGetGlyphsForCharacters` for pure-ASCII
  one-char-per-cell runs (0.75 µs vs CTLine 4.4 µs per 80-cell run); everything else via `CTLine`
  (fallback, wide, emoji, combining). Fast path legal only if the configured face has no ASCII GSUB:
  **probe once per FontStack** by shaping every printable-ASCII pair through CTLine and comparing to cmap
  (1.5–2.8 ms one-time). Ligatures land on first cell; painter splits runs at cursor + colour change.
- Raster: own `[UInt8]` buffer, `CGBitmapContext` alpha-only, null colourspace, **font smoothing OFF**
  (grayscale coverage, no LCD), bounds from `CTFontGetBoundingRectsForGlyphs` rounded outward,
  FreeType-style bearings. Synthetic italic shear 0.21 (tan 12°); synthetic bold = stroke.
- Font metrics: follow ghostty `src/font/Metrics.zig` exactly (cell width, height, baseline, underline
  thickness, line-height gain). Cursor thickness `max(thickness+1, 2)`.
- **Sprite face** (`termrender/src/sprite/`, ported from ghostty `src/font/sprite/draw/`, MIT): box
  drawing U+2500–257F, blocks U+2580–259F, Braille U+2800–28FF, Powerline U+E0B0–E0BF/E0D2/E0D4, plus
  arrows. Drawn from cell geometry so they tile; nonzero winding, consistent polygon winding.
- Grid padding: balance the sub-cell remainder on all sides (ghostty `window-padding-balance=true`); the
  default dumps it bottom/right and looks off against even gutters.
- Block/hollow cursor on a wide char spans 2 cells; glyph under block cursor uses default bg unless theme
  sets `cursor_text`.

### 2.5 Smoothness: what caused jank and what fixed it (docs/31, 68 §6.6, 72)

| jank | fix |
|---|---|
| one MainActor job + parse + redraw per wire chunk during floods | batch drain, 256 KiB budget passes, one present per batch |
| every display tick laid out + painted + submitted even when idle; a byte/frame program = 120 passes/s | draw returns `nowhere/drawn/skipped/held`; skip when engine Clean + same graphics generation + no `repaint` flag (scroll, selection, focus, blink, theme, font, geometry, marked text set it) |
| display link running forever per pane | pause display link when nothing pending; only `needsPresent` ticks |
| blink timer repainting idle panes | 600 ms phase inside the display-link tick, armed only if `wants_blink` (cached per drawn frame); keystroke resets phase |
| layout passes with identical size re-resizing | same-size guard (resize no-op) |
| retina↔non-retina move kept old glyphs | `viewDidChangeBackingProperties` re-measure |
| CTLine per ASCII run | monospace fast path |
| typing under flood queued behind ingest | input send path off-main / separate from ingest |

Measured: vt parse 428–495 MB/s ASCII, 109 MB/s SGR-heavy log, 128 MB/s TUI repaint, 231 MB/s CJK/emoji
(M-series Studio). Painter full-screen TUI quad rebuild 0.5 ms/frame (dirty-row quad reuse rejected as
not worth it given the skip-on-clean). Key→render-feed loopback 1.4 ms median. Swift `[[Cell]]` with
`String` cells measured **17.9 MiB/s** vs Rust flat rows 186 MiB/s (docs/52) — never keep a per-cell
`String` grid in Swift; use flat `[UInt32]`/arena buffers.

Rejected: Mosh-style predictive echo (needs a second parser; agent TUIs are alt-screen anyway). A "glitch
caret" (dim nudge if no echo in 175 ms) was built behind a flag — irrelevant locally.

### 2.6 Blocks (Warp-style), relevant to an agentic terminal

OSC 133 segments the frame into blocks (`termrender/src/block.rs`); alt-screen = plain grid, no chrome.
Chrome overflow rides `scroll_y`, never PTY rows (else SIGWINCH per prompt). Chrome is drawn in the same
Metal pass (an AppKit layer over Metal lagged a frame on scroll). No hover wash, no resting gutter bar — only
a red bar on failed blocks (user feedback).

## 3. PTY / process supervision (docs/51, `rust/slopdesk-posix/src/pty.rs`)

### 3.1 Spawn

- `openpty` with explicit cooked termios: `iflag ICRNL|IXON|IXANY|IMAXBEL|BRKINT|IUTF8`,
  `oflag OPOST|ONLCR`, `cflag CREAD|CS8|HUPCL`, `lflag ICANON|ISIG|IEXTEN|ECHO|ECHOE|ECHOK|ECHOKE|ECHOCTL`,
  38400 baud, standard cc chars. Initial winsize passed to `openpty` (no ioctl needed); later
  `TIOCSWINSZ` writes `ws_xpixel/ws_ypixel` too (sixel/kitty need pixel size).
- Mark master **and** slave `FD_CLOEXEC` immediately; serialise openpty→fork with a lock so no other
  thread's fork inherits another pane's master (orphan shell never gets SIGHUP; leaked slave → master never
  EOFs).
- Child: reset signal mask + all dispositions to `SIG_DFL` (launchd-inherited `SIG_IGN` otherwise breaks
  hangup + zsh history save), `setsid`, `ioctl(slave, TIOCSCTTY)`, `dup2` 0/1/2, close slave & master,
  best-effort `chdir` (never `_exit` on chdir failure), `execve`, `_exit(127)`. Exec-confirmation pipe.
- **THE Swift lesson** (commit `71bf21dd`): Swift code between `fork` and `exec` crashed ~6 % of children
  (10 `.ips` in one day, `asi` "crashed on child side of fork pre-exec", filed under the *parent's* name).
  `for sig in 1...31` instantiated `ClosedRange` generic metadata → `os_unfair_lock` held by a dead thread
  → abort. Passing Swift `Array`s to `execve` allocates; `SIG_DFL` is a computed property. **Axolotty: do
  fork/exec in C** (`posix_spawn` with `POSIX_SPAWN_SETSID` + a tiny exec trampoline that does
  `TIOCSCTTY`, or a C `fork` window with only raw syscalls, argv/envp built before fork). Also don't fork
  while another thread is inside a CoreGraphics/framework call (pthread_atfork handlers SIGKILL the child).
- `O_NONBLOCK` cleared on master before spawn (Happy bug #301).

### 3.2 Reading / writing

- **Exactly one reader of the master** (a second `read` steals bytes; tests polling it hung 30 s). Pump
  thread: `poll(2)` on master + wake pipe, 32 KiB chunks, ring with absolute offsets (4 MiB), announced eviction.
- Writes on a dedicated queue, split at 16 KiB, merge tiny ones. Closing a master while a `write(2)` is parked
  recycles the fd number into another pane: close input gate, bounded wait (2–5 s), then close (or leak).
- Order output before `exited` (drain to EOF, join, then report). Keep a small graveyard of rings so a fast
  command that exits before the view subscribes doesn't render empty.
- One writer of winsize (a late second writer reverted the "redraw jiggle": shrink 1 row, let the TUI see
  SIGWINCH, restore — which is what makes `claude` fully repaint after reattach).

### 3.3 Survival across app restarts (what superd bought)

A launchd daemon (superd) forked every shell and held every master, passing dups via `SCM_RIGHTS`, so a host
restart didn't SIGHUP agents (master keeps `read/TIOCSWINSZ/tcgetpgrp` across SCM_RIGHTS; only the forker can
`waitpid`; **relinquish ≠ destroy** as two code paths). Cost: daemon, versioned protocol, adoption, owner tags.
Axolotty v1: no daemon; restore layout/cwd/scrollback from disk. Add one only if agents must outlive the app.

### 3.4 Shell integration (`rust/slopdesk-superd/src/shellintegration.rs`)

zsh via generated `ZDOTDIR` shim dir (sources user's real `.zshenv/.zshrc`; gives up silently if
`/etc/zshenv` reassigns ZDOTDIR or not zsh):
- `TRAPWINCH` chaining any existing handler, then `zle && zle reset-prompt` (zsh emits no reprint on resize
  → blank prompt otherwise).
- OSC 133 via `add-zsh-hook` (compose with p10k/starship/omz, never overwrite): preexec →
  `OSC 133;E;<escaped cmd>` + `OSC 133;C`; precmd → capture `$?` first, `OSC 133;D;<code>` + `OSC 133;A`;
  append `%{\e]133;B\a%}` to PROMPT once.
- Cursor-shape hooks (bar in insert, block while running). Env opt-outs per feature.
- Shim dir lifetime = the child's; delete on known death only.
- Env injected: `TERM=xterm-ghostty` (ship terminfo), `SLOPDESK_PANE_ID`, socket paths. Curated env passed
  through whole.

## 4. Agent detection

One pure state machine per pane (`rust/slopdesk-agent/src/machine.rs`), clock injected, fed by six
signals in two tiers. **The agent's own word (hooks / `ctl report`) outranks the screen; the tier is
chosen by whether a hook feed is live, never by the agent's name.** Statuses: `None < Idle < Done <
Working < NeedsPermission` (also the rollup urgency order).

### 4.1 Presence: which agent is in the pane

- 1 Hz: `tcgetpgrp(master)` → `proc_pidpath(leader)` → exact basename match (`claude`, not `claudefoo`);
  native installer path `…/claude/versions/2.1.218` canonicalised to its app dir (`agent/src/process.rs`).
- Deep probe only when the leader is a generic runtime/shell (`sh bash zsh fish tmux node bun python…`):
  `proc_listpids(PROC_PGRP_ONLY)`, recheck each pid's pgid, argv via `sysctl(KERN_PROCARGS2)`; cache 5 s
  on hit / 1 s on miss (`hostsession/src/probe.rs`). Covers npm `claude` (`#!/usr/bin/env node`).
- Argv unwrap (`agent/src/job.rs`, port of herdr): leader first; refuse to unwrap after `-e/--eval/-p/-c/-m`;
  realpath tokens; score unwrapped=3, literal=2, other=1.
- Alias table (`kind.rs`, 21 kinds): `claude|claude-code, codex, gemini, opencode|open-code,
  cursor|cursor-agent, copilot|ghcs, amp, droid, kiro, cline, pi…` (no aider). Wrappers (`node npx bun deno
  mise`) never count as presence, only make absence inconclusive.
- Not used: OSC 133 (claude holds the shell's command block open for hours → "busy" forever; agent-done must
  outrank command-busy in badges); env sniffing.

### 4.2 Claude Code hooks (authoritative tier)

- Installed into `$CLAUDE_CONFIG_DIR/settings.json` (default `~/.claude/settings.json`) by
  `rust/slopdesk-hook/src/install.rs`, idempotent merge keyed on the command basename marker; user hooks
  untouched. Enforced on every connection (docs/58: "agent detection is what this app IS"). One entry per
  event, no matcher: `{"hooks":[{"type":"command","command":"\"~/.claude/hooks/slopdesk-agent\""}]}`.
  `is_installed` requires ALL events (partial old installs get re-installed).
- Events: `SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest,
  PermissionDenied, Elicitation, ElicitationResult, Notification, Stop, StopFailure, SessionEnd, PreCompact`.
  Not SubagentStart/Stop (a late subagent revives an idle pane).
- Transport: env `SLOPDESK_SOCKET_PATH` (AF_UNIX in per-user TMPDIR, 0600) + `SLOPDESK_PANE_ID` (UUID, set
  last so callers can't override) + ctl socket/bin; `TERM_PROGRAM=slopdesk`. Relay = zero-dep compiled binary
  copied to `~/.claude/hooks/`: read stdin, write `pane=<id>\n<json>\n`, 2 s write timeout, **always exit 0**
  (non-zero breaks the turn), synchronous (ordering matters). `sh|cat|nc` cost 12.4 ms/call and once stalled
  19.5 s; binary = 3.2 ms. Listener: 2 s read timeout, 64 KB cap, separate accept vs fold serial queues.
- Other agents get no hooks; they join the authoritative tier via `slopdesk ctl report working|blocked|done|idle`.

Mapping (`hookevent/src/lib.rs`, `machine.rs::apply`):

| event | effect |
|---|---|
| SessionStart | Idle, clear blocks |
| UserPromptSubmit | Working |
| PreToolUse / PostToolUse | resolve own `tool_use_id`; Working only if no other block outstanding |
| PreToolUse(AskUserQuestion) | blocked (label = `tool_input.questions[0].question`) |
| PermissionRequest | blocked "Permission needed: {tool}"; PermissionDenied = call ends |
| PostToolUseFailure | call ends; `is_interrupt` → quiet Idle (Esc fires no Stop) |
| Elicitation / ElicitationResult | block keyed by `elicitation_id` (fallback `elicitation:<server>`) |
| Stop / StopFailure | Done (label `last_assistant_message` / `error_message`); after PreCompact → quiet Idle |
| SessionEnd | None + 3 s lockout (process lingers ~1–1.5 s; poll/title would resurrect it) |
| Notification | by `notification_type`: `permission_prompt`→Permission; `agent_needs_input`/`elicitation_dialog`→Waiting; `idle_prompt` ignored (re-raised "needs you" ~60 s after every turn); text fallback "permission/approval/wants to/would like to" |

- **Block list, not a flag**, keyed by `tool_use_id` (batched `[AskUserQuestion, Bash]`: Bash's PostToolUse
  used to clear the question). Don't mint ids for missing ones. Emptied at turn boundaries / process gone.
- **Session ownership**: first `session_id` claims the pane; foreign session events dropped (nested
  `claude -p` inherits PANE_ID); handover only on foreign SessionStart while Idle/Done/None.
- Esc has no hook: PTY input classifier treats bare `ESC`, `ESC ESC`, kitty `CSI 27 u`, `^C` as cancel →
  NeedsPermission → quiet Idle. Excludes focus reports, mouse (`CSI M`), arrows (those re-rang the cue).

### 4.3 Screen + title tier (fallback for everything, corroboration for Claude)

- OSC 0/2 title: Claude's first char Braille `U+2800–28FF` = working, `✳ ` (U+2733) = idle. Spinner promotes
  only if an agent is present, never clears a hook block, never after Done (late spinner repaint after Stop →
  double completion). `✳` demotes working→idle only (missed-Stop safety net).
- Rule manifests (`rust/slopdesk-screend/manifests/*.toml`, 19 from herdr, priority-ordered, highest wins):
  Claude `live_blocked_form` 980 = after last horizontal rule contains "enter to select" + "esc to cancel";
  `live_prompt_box` idle 950 `^\s*❯` vetoed by dialog footer and `^\s*❯\s+\d+\.\s`+sibling `^\s{2,}\d+\.\s`;
  `bash_permission_prompt` 850 "do you want to proceed?". Codex: title "Action Required"→blocked, title
  spinner `[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]`→working, "allow command?" / "press enter to confirm or esc to cancel"→blocked,
  `^[•◦]\s+Working \([^)]*esc to interrupt\)`→working. Gemini: `│ Apply this change`/`│ Allow execution`→
  blocked, "esc to cancel"→working. opencode: `△ Permission required`→blocked, "esc to interrupt" or
  `(■|⬝){4,}`→working.
- Scan every 300 ms (100 ms while a hold pends), off the read loop; skip idle panes with no new bytes.
  **Never read mid-frame**: hold while DEC 2026 is open (≤1 s per frame generation; byte-level opener detector
  across read splits).
- Debounce: working→idle needs 3 reads @100 ms (cap 700 ms) unless idle is visible; blocked→idle needs 3 reads,
  no bypass; 3 s startup grace; Done decays to Idle after 8 s; authoritative status survives process absence
  30 s (600 s if a wrapper holds the foreground).
- Conflict: `authoritative_covered` from first hook until session end (not a recency window — a 10-min
  permission wait is silent by design). Under coverage the screen only corroborates; a dissent stopwatch
  (reset by an agreeing read, NOT by hooks, checked every tick) overrides after 3 s (raise) / 10 s (release)
  as a quiet transition.

### 4.4 Notifications

- Edges (`attention.rs`): enter NeedsPermission or Done; Working/Needs→Idle counts as completion for hookless
  agents; one "finished turn" per turn. A **quiet** bit (compact, Esc, interrupts, stopwatch corrections)
  updates dots without banner/sound.
- Drop the agent's own OSC 9/777/99 while hook-authoritative (else two banners per event under xterm-ghostty).
- Gates: per-event toggles (task complete / awaiting input / explicit OSC), notify-while-foreground
  `off|always|tabUnfocused`, no toast for the focused pane, token bucket on OSC notifications, secret redaction,
  dock bounce when backgrounded. Sounds `NSSound` "Submarine" (finish) / "Glass" (needs input).
- "Done" = client-side **unread** latch: set only if the pane wasn't visible, cleared on visit or new activity.

### 4.5 What failed

Two competing state machines + client `name.contains("claude")`; screen outranking hooks (torn repaint matched
`❯ 1.` and cleared a real block, each flap = banner+sound); "any keystroke unblocks"; PreCompact ignored
(`/compact` announced done); any PreToolUse clearing permission blocks; hook resetting the dissent stopwatch;
detection behind feature flags (only hooks produce Done). Diagnosis tool that worked: replay the raw PTY
journal at chunk sizes 256 B–8 KiB.

### 4.6 For Axolotty

In-process, no daemon: `$TMPDIR/axolotty-<uid>/hooks.sock` 0600, `AXOLOTTY_PANE_ID`/`AXOLOTTY_SOCKET_PATH`,
tiny C relay (always exit 0), same event list + mapping + block list + session ownership + lockouts from day
one. Presence via `tcgetpgrp` at 1 Hz. Screen tier reads libghostty-vt rows directly (no second parser),
only when DEC 2026 is closed. Ship `axolotty report <state>` for hookless agents. Also add Codex `notify`
config and Gemini hooks if their CLIs now support them (slop-desk did not).

## 5. UI / UX and design tokens

Tokens live in `Sources/SlopDeskSlate/SlateDesign.swift` (static constants, lint fails raw literals). Docs
disagree on island radius (DESIGN.md says 26/8); the live token is `Metric.islandRadius = 16`.

- **Final look "ONE ISLAND"**: cream ground (Alucard `#FFFBEB`) under side columns + one lifted dark terminal
  island (Dracula Pro). Reason is contrast math: `#22212C` on black = 1.32:1; on cream ≈ 13:1.
- Terminal: bg `#22212C`, fg `#F8F8F2`, comment `#7970A9`, selection `#454158`, accent `#9580FF`; ANSI 0–7
  `454158 FF9580 8AFF80 FFFF80 9580FF FF80BF 80FFEA F8F8F2`, brights repeat (8 = `7970A9`, 15 = `FFFFFF`).
  Font: bundled JetBrainsMono Nerd Font 13 pt, block cursor, scrollback 10 000.
- Chrome: semantic system colours (`labelColor`…`separatorColor`), status `systemGreen/Orange/Red`; ONE accent
  `#644AC9`/`#9580FF` spent only on selection wash 15 %, active tab, focus corner, divider drag, links, find.
- Type: system 40/15sb/13/12/11/10; "instrument voice" JetBrains Mono 12 tracking 1.2 for numbers/caps;
  chords always in system font (mono squashes ⇧⌘⌥⌃).
- 8 pt grid (4/8/12/16); heights 24/28/32/44/48; sidebar 220; radii 4/6/8/10/12/16/20; island margin 8;
  top band 40 (controls centred at y=20), traffic-light reserve 80; opacity rungs .08/.12/.15/.20/.28/.35/
  .5/.6/.72/.88; shadows only on floating things.
- Motion: cubic-bezier only, no springs: standard (.42,0,.58,1) 200 ms, fadeSlideIn 180, reveal 150,
  fadeOut 140, smallFade 120, stackReflow (.4,0,.2,1) 280, columnSlide 320. One click-ack: SF Symbol bounce.

**IA that worked**: Session → Tab → n-ary split tree → Pane (Zellij close = siblings share space); tree holds
`PaneID`s, leaf views keyed by PaneID (never reuse a surface across panes). Divider drag = ghost seam + commit
on release; double-click evens one seam only. `NSSplitViewController` navigator | terminal | panel; window
`.fullSizeContentView` + transparent titlebar + empty `.unifiedCompact` `NSToolbar` to get a 40 pt band with
AppKit-placed traffic lights (moving button frames by hand flickered). Sidebar grouped by project A→Z, 32 pt
rows; when hidden, tabs move into the titlebar strip. Agent status in a fixed mark column (spinner working,
ring present, check unseen-done, elapsed `2m15s`; amber/red retitle row); top-band rollup with three
always-drawn slots (waiting/working/finished) — fixed positions read as a legend. ⌘⇧U = jump to oldest pane
needing attention; ⌘⌥J = Peek & Reply to a blocked agent without switching. Overlays (palette ⌘⇧P, Open
Quickly ⌘⇧O, toasts) are borderless `NSPanel`s, toasts non-activating. Focus = small accent corner triangle,
no pane dimming. Keybindings: one table (77 rows) feeding menu/palette/cheat-sheet (⌘/), dispatched by one
`NSEvent.addLocalMonitorForEvents(.keyDown)`; menu items show chords but don't bind (no double fire); every
default chord ⌘/⌥-prefixed so Ctrl-letters reach the terminal; config can bind a chord to literal bytes.

**Reversed**: infinite canvas (keyboard-hostile, non-deterministic; all competitors use split trees);
SwiftUI shell (53 files needed AppKit, 32 introspect hacks, full-window hosting view eats clicks); ~10 visual
directions in 6 weeks (grain/glow/shaders = "AI slop"; cards within a few RGB of the terminal = no depth);
Liquid Glass/`NSVisualEffectView` on overlays (nothing to refract → grey slab; never put glass over a live
`CAMetalLayer`); notices drawn on the terminal (≈1.5–2.2:1 contrast → moved to cream capsule 7–15:1); theme
picker/editor; title shimmer for "working"; pane dimming; per-pane command ladder; composer/prompt-queue
agent input UI (duplicated typing in the terminal); settings GUI + onboarding (82 files).

**Config (docs/58)**: no settings window; ⌘, opens `~/.config/<app>/config.toml` in the user's editor;
starter file = comment + `#:schema ./config.schema.json` (+ schema copied beside it); never pre-fill
defaults. One key table generates JSON Schema (draft 2020-12, `additionalProperties:false`), the Swift config
value and diagnostics. Reload on app activation with an equality guard (re-applying identical config
re-measured every terminal and flashed on ⌘Tab); no watcher. Read-only CLI `config path|edit|show|get|
validate|schema`; validate flags duplicate chord spellings.

## 6. Process & architecture

### 6.1 Never again

1. **Two languages on the hot boundary.** Rust↔Swift FFI meant an xcframework rebuilt per Rust edit (17 MB,
   3 slices), a content-hash stamp because SwiftPM won't relink on a changed `.a` (20 min of phantom-bug
   chasing), a 69-door header, a 1 820-line calling-convention doc, and a **Rust→Swift→Rust round trip**
   (docs/40). Axolotty: Swift + C only, prebuilt libghostty-vt `.a` + module map, no Zig/Rust in the loop.
2. **A boundary that keeps moving** ("Rust is default" → "Swift stays" → reversed same day). Decide once.
3. **88 crates / 22 SwiftPM targets / 78 lock files**, each with own lint table. Few modules, one package.
4. **xcodebuild as inner loop** (~85 s planning with nothing to compile). Prefer `swift build`; keep the
   Xcode project trivial; measure planning time early.
5. **A daemon per concern** (7 daemons): protocols, version skew, AF_UNIX buffer tuning (8 KB default on
   macOS), restart semantics.
6. **Scope creep**: video streaming, iOS, multi-client, code-server/Android panels ate most effort.
7. **Bureaucracy as quality**: invariant ratchets for doc sections, 27–41-agent reviews, essay comments 3–10×
   the code. Short docs, one decision log.
8. Design churn without true-size mocks; SwiftUI shell; settings GUI (82 files); flags for core features
   (nine deleted) — all reverted.
9. **Wrong perf unit**: FFI crossing ≈ 1 ns; allocations cost (100–230 ns per `Data`/`String`). Rank by allocs.

### 6.2 Keep
- One owner per fact (one reader of the PTY, one writer of winsize, one keybinding table, one config schema).
- Owning the grid (vt + own renderer) — enables blocks, docked prompt, pinned headers.
- Conformance sweeps (formatter oracle, incremental-vs-fresh, ttyrec); "measured regression is the only veto".
- Fork-window discipline + disassembly test; draw-skip, 2 drawables, display-link pause, blink gating.
- Config file + JSON Schema + reload on activation; agent status fused in one place with precedence (§4).
- `TERM=xterm-ghostty` + ship terminfo; `CLAUDE_CODE_NO_FLICKER=1` for agent panes; compiled hook relay;
  `just` as the single entry point; commit subjects as release input.
