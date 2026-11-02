# Axolotty design system

This file describes what ships in `Sources/AxMacUI`, measured from the build, not from intentions. It replaces the visual-layer sections of `design-spec.md`: glass, `NSSplitViewController`, system sidebar material, and the NSPanel palette. Every value below has a single home in code.

**Mode:** Operate. Axolotty is a tool used for hours. Scanability and native expectations outrank expression, and craft shows in precision.

**Target density:** 1× is a first-class target (the owner works on a 1920×1080 display). Every mark is placed on whole pixels at 1×, and hairlines are one device pixel.

## 1. Principles

1. **The window is a frame; terminals are screens set in it.** (Changed 2026-11-02 from "the terminal is the window": Axolotty's unit is the agent and the project, so the window holds terminals rather than dissolving into one. See `.research/wow/synthesis.md`.)
   - One `frame` tone paints the band, the sidebar and the gutters: bg mixed toward fg at 0.06 dark, 0.05 light. The terminal ground is already near-black, so only a lighter frame can make figure and ground (1.14:1, against 1.03:1 before).
   - Each pane is a sheet: radius 10 (continuous), set 6 pt from the window edges and 6 pt apart. Light sheets add a one-pixel `border` contact edge; dark sheets need none.
2. **Gutters are the dividers.** No line at rest anywhere in the window: not under the band, not at the sidebar seam, not between panes. Hovering a gutter shows a 2 × 28 `borderStrong` grip; dragging tints it accent and runs it the full length. The palette's rule under its field is the only line left.
3. **Say a thing once per question.**
   - The sidebar answers *which*: projects, sessions, and their state badges.
   - The band answers *what, and how is it doing*, for the shown session, with the sidebar open or closed: project › program and title, branch, then working time or the chip.
   - In splits, each pane's strip answers *who is this, and do they need me*.
   - The folder lives in the prompt; the strip shows it only relative to the project.
4. **Icons carry identity; colour carries meaning.** No cue does two jobs.
   - Programs get a glyph by kind. Agents get their real vendor mark. Projects get a solid hue tile.
   - Magenta (the brand accent) means *working*, and the caret. Amber waits. Red failed. Green finished-unseen. Focus is told by ink and dimming, never by colour.
5. **No glass, no decoration.**
   - Surfaces are opaque.
   - Depth comes from a two-layer shadow, an outer contact ring and an inner rim, all built from one continuous-corner path.
6. **Instant in, soft out.** Hover and press appear at once and recover over 100–150 ms. Panels move on springs with no bounce. Reduce Motion turns movement into opacity.

## 2. Tokens (`Design/Tokens.swift`, `Design/Axo.swift`)

There are three layers:

| Layer | Contents |
|---|---|
| `Prim` | Space 0–48 on a 2/4 grid; radii 4, 6, 8, 10, 12, 14; ink alphas; type sizes 10–20 |
| `DesignTokens` | Derived per theme from its background and foreground, as Warp blends them. Registered for dark and light; `install(theme)` re-derives them |
| `Axo.Metric` | Per-component values |

`Axo.Color.*` are dynamic NSColors, so appearance changes need no code.

| Token | Dark | Light |
|---|---|---|
| ground (terminal, sheets) | theme bg | theme bg |
| frame (band, sidebar, gutters) | bg → fg 0.06 | bg → fg 0.05 |
| elevated (floating surfaces) | bg → fg 0.10 | white |
| hover / selected / pressed | fg 0.055 / 0.09 / 0.13 | fg 0.045 / 0.07 / 0.10 |
| border / subtle / strong | fg 0.10 / 0.065 / 0.16 | fg 0.13 / 0.085 / 0.20 |
| text tiers | 1, 0.72, 0.50, 0.32 | 1, 0.70, 0.50, 0.34 |
| float shadows | (y1 b2 0.32) + (y10 b28 0.36) | (y1 b2 0.07) + (y10 b28 0.11) |

- Selection is a neutral plate, never the accent. When the window is not key, it steps down to `hover`.
- The primary action is the solid foreground with inverted ink.

### Type (SF Pro, system tracking)

| Size | Use |
|---|---|
| 13 regular | rows, body |
| 13 semibold | project names, titles |
| 12 | detail |
| 11 semibold | section headers |
| 11 | captions, tooltips |
| 17 | palette field |

Shortcuts and counts use monospaced digits (`Axo.Font.shortcut`, `.meta`). The terminal is SF Mono 13 with a cell pitch of about 17 (natural line × 1.1, the same as Ghostty).

### Motion

| Name | Value |
|---|---|
| tick / tickOut | 150 / 100 ms |
| swift | 200 / 140 ms |
| glide | 260 ms |
| springs | snap 0.25, standard 0.35, panel 0.40, pop 0.30 / 0.10 bounce |

- Palette: in over 160 ms from 98 % scale, 4 pt high; out over 100 ms.
- Sidebar: panel spring. Grids freeze while it moves, then reflow once.

## 3. Window

- **Band:** 40 tall (empty `.unifiedCompact` toolbar), painted in `frame`. Every point of it is a terminal row, so it is never taller.
  - The traffic lights, then our own sidebar toggle and "+" (28 targets, 14 glyphs), centred on the band.
  - Context header (`Chrome/BandView.swift`): 16 pt project tile, project name 13 semibold full ink, `chevron.compact.right` in tertiary, program icon with its badge, session title 13 secondary, then `arrow.triangle.branch` and the branch in 12 tertiary (it gives way first when narrow). With the sidebar open it starts on the terminal's text column (14 inside the sheet); hidden, 20 pt after "+".
  - Trailing state: working shows a magenta spinner and "Working m:ss" in tabular digits, ticking each second; waiting or failed show the chip with the agent's own question. Idle shows nothing.
  - The band drags the window.
- **Sheets:** stage inset 0 / 6 / 6 / 0 (top, right, bottom, left with the sidebar open; 6 on the left when it is hidden). The empty state is a sheet too.
- **Pane strip** (`Panes/PaneStripView.swift`), only with two or more panes and none zoomed: 28 tall inside the top of the sheet, no rule; rows start 6 below it.
  - Program icon with badge on the text column, name 12 medium (full ink focused, tertiary otherwise), cwd relative to the project in 12 tertiary (hidden under 280 pt), elapsed m:ss while working. Zoom and close on hover. Double-click zooms.
  - Waiting or failed: the whole strip floods with that state's wash (0.16 dark, 0.12 light, 200 ms in) and the name becomes the agent's question. This replaced the 1.5 pt amber inner stroke.
- **Sidebar:** 248 wide (200–360, persisted), with our own column and resize handle (double-click resets). ⌃⌘S toggles it (`toggleSessionSidebar:`, because NSWindow already owns `toggleSidebar:`).
- **Terminal pane padding:** 14 left and right, 10 top, 8 bottom. Leftover rows fall to the bottom.
- **Unfocused panes:** dimmed by a ground overlay at 0.28 dark, 0.22 light. The cursor turns hollow.
- **Minimum contrast:** text keeps 3:1 against its own ground (`ax_min_contrast` in AxFrame). Truecolor a theme cannot remap is moved toward black or white by the least amount needed. The theme's own mid-tones survive.
- **Status bar:** off by default.
- **Sidebar footer** (`Sidebar/SidebarFooter.swift`): 36, on the frame, no rule. Settings and the appearance toggle (Match System → Night → Day, glyph says which) leading; the census trailing as compact buttons (glyph + count, noun in the tooltip) that jump to the next session in that state. Zero counts hide.
- **Progress line** (`Terminal/ProgressLine.swift`): 2 pt across the top inside edge of a sheet, under its corner mask, only from the program's own OSC 9;4. Determinate fills from the left; indeterminate sweeps a 30 % segment over 1.1 s; magenta normally, red on error, amber when paused; fades out over 250 ms when cleared. Reduce Motion: a static half-alpha line.
- **Receipt:** when an agent's run ends the host keeps its length (`PaneInfo.lastRun`). The band shows "✓ Worked 4m 12s" (tertiary; the check green while the finish is unseen) and a split's strip shows "✓ 4m 12s", until the next run starts.

## 4. Sidebar (`Sidebar/SidebarRows.swift`)

Measured from Codex, Linear, Zed, Conductor, Claude desktop, Raycast and Mail, and contrasted with Warp and cmux.

| Part | Spec |
|---|---|
| Plates | Inset 8; 28 tall with a 2 pt gap; radius 8. The selection plate springs between rows; hover plate appears instantly and fades out on tick. No disclosure triangles. |
| Project header | 32 tall, 20 pt above every project but the first: projects are the objects of the list. 20 pt solid hue tile at x 16 with the initial knocked out in `frame` ink (12 bold, drawn by its ink bounds and cap height on whole pixels, not a centred line box; size and radius scale with the side). Name at x 44 in 13 semibold, always full ink. Hover shows the chevron and "+". When collapsed, a dot after the name if anything inside waits or failed. |
| Project hue | One of 6 OKLCH hues: 105, 150, 190, 220, 245, 280 (olive to indigo). Red, amber and the magenta accent already mean something, so they are left out. Tiles are solid (dark L 0.72 C 0.12; light L 0.56 C 0.13), which puts the six 20+ RGB units apart; the old 22 % wash left them 8 apart, unreadable at 1×. Text in a hue uses L 0.78 C 0.09 dark, L 0.52 C 0.10 light. Chosen by an FNV-1a hash of the project root, so it is stable everywhere. |
| Project "+" | A menu: Shell, then each agent installed on the host (local: found on PATH or the usual install directories; remote: Claude, Codex, Gemini), each with its icon; 1–9 pick from the open menu. The pick opens a shell in the project and types the agent's command, so integration and history stay and the shell outlives the agent. |
| Session row | Icon at x 44 (under the project name), title at x 67 in 13 regular. A row whose agent waits or failed sits on a wash plate of that colour (selection-plate geometry): "who needs me" is answered by area, not a 6 px dot. Title ink is 0.72 at rest; full ink when selected, hovered, or when an agent in it is live (working, waiting, failed, finished-unseen). No weight changes. |
| Row title | What the icon already says is not said again (`AgentTitle.trimmed`, tested): an agent's own status glyphs ("✳", braille spinner frames) and a leading vendor name followed by a separator ("Codex · Fix login" → "Fix login"; "Claude docs" stays). The same rule applies wherever the icon sits beside the title: row, band, toast, palette. The full title stays in the hover card and VoiceOver, and the palette still matches it. |
| Trailing slot | Hover shows close. Holding ⌘ for 0.4 s shows `⌘n` in tabular digits: ⌘1–⌘8 by order, and ⌘9 only on the last row when it is not already one of those. |
| Hover card | After 550 ms: title in semibold, then state with elapsed time, folder and message in secondary ink. |

### Program icon (`Components/ProgramIcon.swift`)

- **Programs:** an SF Symbol at 12 medium, by kind:

  | Kind | Symbol |
  |---|---|
  | shell | terminal |
  | editor | pencil.line |
  | git | arrow.triangle.branch |
  | ssh | network |
  | monitor | gauge |
  | js | shippingbox |
  | scripting | `</>` |
  | build | hammer |
  | containers | cube |
  | databases | cylinder |
  | pagers | book |
  | logs | doc.text |

- **Agents:** Claude, Codex and Gemini draw from their vendors' own vectors (`AxRender/BrandMarks.swift`, LobeHub traces, MIT) at 14 in the 16 slot. `SVGPath` parses the geometry and is tested. Other agents use an SF Symbol.
- **State:** a badge at the lower right, on whole pixels, cut out of the glyph with a 1 pt moat: 6 pt dots (a 14 pt vendor mark keeps three quarters of itself), an 8 pt spinner. The glyph itself never changes.

  | State | Badge |
  |---|---|
  | working | 8 pt magenta spinner: a 2 pt arc over a 0.28 track of itself, 0.35 of the circle, 0.9 s a turn; or a determinate arc |
  | waiting | amber dot |
  | failed | red dot |
  | done (unseen) | green dot |

## 5. Surfaces (`Components/Surface.swift`)

- **One path:** `ContinuousRect` (an iOS-style squircle) drives the fill, inner ring, top rim, outer ring and shadowPath, so the corners always agree.
- **Layer scale:** every self-made layer renders at the backing scale.
  - New layers use `crisp()` and `ShapeLayer` defaults.
  - `ShellView` re-syncs the tree when the window changes screens.
  - AppKit never updates the contentsScale of sublayers we add.
- **Palette:**
  - Geometry: width 600, 80 below the band, radius 14 with padding 6, so rows have radius 8 (concentric).
  - Field and type: field 48 tall with 17 pt text and a 16 pt lens; one rule under the field.
  - Rows: 34 tall. Section headers 11 semibold.
  - Three scopes: ⌘⇧P commands and sessions; ⌘⇧O sessions, workspaces and recent folders; **⌘J Jump to Agent**. Jump to Agent lists every session with an agent in it or something happening, grouped Needs you (waiting and failed), Finished, Working, Idle, newest change first; the detail is the project and the time in that state. A leading `!`, `.` or `~` narrows to one group.
  - Row content: a session shows its program icon, title and project; a command shows its SF Symbol and title. Shortcuts are menu-style text, not keycaps.
  - Height is fixed while typing. "No matches for “x”" sits in the list's place.
  - No hint footer: arrows, return and escape are what every list answers to.
- **Toasts:**
  - Placement: top-right under the band, at most three. Not bottom-centre, because a terminal's bottom row is the live prompt.
  - Look: radius 10, 340 wide; the program icon with its badge, a title, and up to three lines of body. A card that asks for you (waiting or failed) gets a small secondary **Show** button, trailing and centred on the title line: the whole card is a button, but nothing about a card says so.
  - Timing: 6 s if it asks for something (it is also a button), 4 s otherwise; hover pauses it.
- **Tooltips:** 500 ms delay, instant while warm; 11 pt; padding 4×8; radius 6; 6 pt below the control. None while a menu is open.
- **Menus** (`Overlays/PopMenu.swift`): our own, not NSMenu (the system menu is glass on macOS 26+). An opaque float surface in the window's overlay layer, radius 14 with padding 6, rows 28 with radius-8 neutral plates; 16 pt image, 13 pt title, trailing key (tabular, tertiary) or check; separators are a 1 px `borderSubtle` line. A button at a column's end opens it back into the column (trailing-aligned). Keys come through a local monitor so focus never moves: ↑↓, return, 1–9, esc; any ⌘/⌃/⌥ shortcut closes it and passes on. Motion is the palette's.
- **Launch keys:** one numbering everywhere: 1 is Shell, 2–9 the installed agents in order (the "+" menu and the empty state's tiles).
- **Diff chip and Changes** (`Chrome/GitChanges.swift`, `Chrome/ChangesPopover.swift`): the band's "+n −m" against HEAD (tracked edits plus untracked files as all-added), green and red meta type, no box; hidden when clean or outside a repo. Click or ⇧⌘C opens Changes: a float surface 380 wide (radius 12) with branch, "vs HEAD" and totals, one row per file (kind glyph, name, its folder in tertiary, counts; a deleted file dims), and Review Changes, which starts the first installed of Claude Code or Codex on the diff in a new session. Click opens the file; ⌥-click opens its diff in a split (`less -Rc`, titled with the file name). Git runs without taking the index lock and gives up after 2 s; at most 1000 files.
- **Find** (`Terminal/FindCard.swift`, ⌘F, ⌘G, ⇧⌘G): a card in the pane's top-right (under the strip in splits), 304×34, radius 10: lens, field, "3 of 12" in tabular tertiary ("No matches" in secondary), up, down, close. Matches are painted by the frame builder as cell grounds under the text: every match the theme's yellow mixed 30 % into the ground, the current one 62 % (light: 38 / 80). Return and ↓ walk to older matches (up the screen), ⇧return and ↑ to newer; a fresh needle starts at the newest. A match that would land under the card is brought a third of the way down. Literal match, ASCII case-insensitive (libghostty's search: scrollback, both screens, soft wraps, live while open). A one-line selection seeds ⌘F; esc closes and hands focus back.
- **Links:** hold ⌘ and the link under the pointer is underlined, 1 px in the terminal's own foreground (no new hue on the grid), with a hand cursor; ⌘-click opens it. OSC 8 hyperlinks first, then URLs and file paths read across soft wraps (`TerminalLinks`). A path counts only if it exists, resolved against the pane's directory on this Mac; with a `:line[:col]` it opens at that line in the first installed of Cursor, VS Code, Zed or Windsurf, otherwise in its default app.
- **New lines** (`Terminal/NewOutputPill.swift`): while the person reads scrollback and output keeps arriving, the viewport stays put and a float capsule, 26 tall, centred 10 above the sheet's bottom, says "↓ 18 new lines" (meta type, secondary). The count is rows added to scrollback since they scrolled away. Clicking it, typing, or scrolling to the bottom returns them there and the pill fades.
- **Hover card** (`Components/HoverCard.swift`, sidebar session rows, 550 ms): float surface, radius 8, at most 320 wide. Title in caption semibold, then one fact per line (16 tall, 2 apart), each led by a 10 pt mark in a 14 pt column: the state dot in its status colour ("Working · 4m"), `hand.raised` for what a waiting agent asks (`text.bubble` for what a working one says), `folder`, `arrow.triangle.branch` with "main  ↑2 ↓1   +120 −34" (counts tabular, the diff in the chip's colours), `network` with "localhost:5173 · 8080". Only facts that exist appear; git facts load on hover and slot into the open card without a fade.
- **Port chip** (`Chrome/PortChip.swift`): after the diff chip in the band, "◎ 5173" (or "◎ 5173 +2"), tertiary glyph, meta type, radius-6 hover plate, hand cursor. Click opens http://localhost:port; several ports open a menu. The host scans each pane's process tree for listening TCP sockets every 2 s (libproc), so a dev server started in the background counts. Local hosts only.
- **Size badge** (`Terminal/SizeBadge.swift`): "120 × 40" centred on a pane while its grid changes (window resize, divider drag, zoom, font size), not on first layout. Float surface, radius 8, 28 tall, tabular meta; in on Tick, out 700 ms after the last change. The same badge confirms pane commands in place: "Copied 42 lines".
- **Ended bar** (`Terminal/EndedBar.swift`): a pane whose program ended with a non-zero code (a clean exit closes the pane) keeps its screen, loses its cursor, and shows a float bar 36 tall, radius 10, centred 12 above the bottom: error dot, "Exited with code 3" (caption, secondary), a small secondary "Restart" with `arrow.clockwise`, and the ↩ key. Return or the button starts the same command in the same directory in that slot (a new pane takes the old one's place in the split).
- **Command blocks** (OSC 133, zsh integration): ⌘↑ / ⌘↓ jump the viewport to the previous / next prompt; ⌥⌘C copies the latest command's output (libghostty's output selection; a running command gives its output so far). The shell sends each command line (`133;C;cmdline_url=`), so the host records the last command, exit code and duration (for `wait --for command`). A long command's end is no status record (built and dropped). A finish in front of the person (focused pane, key window, active app) is seen as it happens.

## 6. Empty state and the mark

- **The mark** (`Design/AxoMark.swift`): geometry, not artwork. A wide head with knocked-out eyes, three round-capped gill strokes a side, and from 28 pt up the axolotl's smile cut out of the head. Always one ink: the accent.
- **Empty state** (`Window/EmptyStateView.swift`): a sheet like any pane; the band hides (the sheet says it all).
  - Mark 48 in accent; 16 below, "Start a session" in 20 semibold.
  - 20 below: one launch tile per installed preset (Shell first): 88×72, radius 12, a resting card that lifts to a float on hover; the program's mark at 24, its short name in 12 medium, its key in the top-right. Keys 1–n launch.
  - 16 below: where it starts, a borderless pop-up of project tile + name + `chevron.up.chevron.down`, defaulting to the last project used; its menu lists projects with their tiles, then Open Folder….
  - No copy paragraph, no shortcut hints.
  - Reconnecting: a spinner in place of the mark, the title, and one line that the sessions keep running. No actions.

### Agent status

Read from the agent's own door, never the screen. Claude Code (2.1.316+) speaks OSC 7501 itself once the terminal answers its probe: working with the live task, blocked with the question ("approve Bash: …"), done, error, per-subagent records. Axolotty adds nothing on top of that (a hook relay was built and removed: two records per pane disagree). Other agents report through OSC 7501 too. The CLI is linked into every pane's PATH, first even after the person's rc files. A pane never inherits an agent's session markers (`CLAUDECODE`, …) from whatever started the server. While any pane works, the host holds an idle-sleep assertion (the display may still sleep).

A waiting program's ask is worded once (`StatusRecord.ask`) for the strip, the header chip, the hover card and notifications: its own words with the first letter raised ("Approve Bash: npm test"), else what it waits for from OSC 7501 `kind=` ("Needs approval", "Has a question", "Needs sign-in"), else "Needs input".

**Passwords:** when a pane's program reads a hidden line (canonical input with echo off: sudo, ssh, `read -s`; raw-mode TUIs don't count), the host flags it after the prompt's output, and while that pane has focus in the key window the client holds Secure Keyboard Entry. A `lock.fill` at 11 pt, tertiary, sits on the first row's trailing edge (tooltip says why); both go when echo returns.

**Attention:** one notification per pane (request id `pane-<uuid>`), replaced rather than stacked. A banner or toast is withdrawn as soon as its pane settles: seen, back to working, idle, or closed. Blocked is time-sensitive and plays the sound; error plays the sound; done is passive (Notification Center only, no banner over another app). The Dock badge counts panes that need the person (blocked + error), never finished ones. A pane that finishes while it is focused in the key window is marked seen at once: there was nothing to miss.

**Inside tmux:** tmux doesn't pass Claude Code's OSC 7501 probe, so for a pane whose foreground is a tmux client, the host asks Claude Code with `claude agents --json`. It asks only when FSEvents on `~/.claude/sessions` says one of that pane's sessions changed, never on a timer. Sessions are matched by process ancestry. The results become `agents:<pid>` records: busy is working, waiting is blocked (permission or question), and idle after work is done. They give way, and the pane is no longer read from outside, as soon as its Claude reports natively. Details and sources: `.research/claude-status-2026.md`.

**A grace second:** a state change waits one second before it toasts or posts a banner, then re-checks the state, so a permission a rule grants at once never reaches the person. The row and the Dock badge change at once.

**Progress:** OSC 7501 `progress=` (Claude Code reports the share of its todos done) turns the row's spinner into an arc, as OSC 9;4 does.

**Subagents:** Claude Code reports each subagent as a record of its own beside the main one (id "": flat agent ids such as `ab89c272635bed8ac`, observed live), and a subagent's record goes when it finishes. `StatusBook.subagentsWorking` counts them. The band's timer reads "Working 4:12 · 2 subagents", and the hover card adds a person.2 fact. The row does not change: the spinner already says working.

**Pin and Mark as Unread** (row menu, Session menu, palette): both are flags the host stores on the session (`pinned`, `unread`), so they survive restarts and show in every client.
- Pin: pinned sessions head their project in the order they were pinned. A drag can't move an unpinned session above them. At rest the row's trailing slot holds a pin (11 pt, tertiary ink), centred where the close button appears on hover.
- Mark as Unread: an accent dot on the icon (the same 6 pt badge and moat as the status dots, shown only while no status claims the badge), and the title in full ink. The client clears it when the person switches to the session, as Mail does. The window regaining focus doesn't count.

**Back and Forward** (⌥⌘[ ⌥⌘]): through sessions in the order they were shown, browser-style. A new visit drops the forward history, and closed sessions are skipped.

**Reopen Closed Session** (⇧⌘T) brings a Claude Code session back in its conversation. At close, the app finds which conversation that session's Claude held: its `~/.claude/sessions/<pid>.json`, matched by the process's inherited `AXOLOTTY_PANE_ID`, read through `KERN_PROCARGS2`. Reopening runs `claude --resume <id>` while the transcript is still on disk. Anything else reopens as a shell in the same folder.

**Copy on select** (Settings › Selection, off by default): a mouse selection goes to the pasteboard when the button comes up.

**Worktree sessions** (⌥⌘T, "New Worktree…" at the foot of a project's "+", or `axolotty new --worktree BRANCH`): the palette in a third shape. Its field leads with the mark of what will start (the first installed agent; ⇥ / ⇧⇥ cycle through Shell and the agents) instead of the lens. Rows: the typed name as a new branch "from <HEAD>" (spaces become dashes, never highlighted), then existing worktrees, then local branches checked out nowhere. The host runs git: `<repo>/.worktrees/<branch with / → ->`, listed in `.git/info/exclude` (never the person's .gitignore); an existing worktree is reused. The session is named for the branch and remembers its folder. "Remove Worktree…" (Session menu, row menu) asks once, then again in stronger words if the tree has changes; it closes the session and deletes the folder, never the branch.

**Resume Claude Session** (⇧⌘R, local host): the palette led by Claude's mark. Rows are past conversations titled by the first thing the person asked (pasted blocks, image tokens and fences dropped; a slash command is not a title), "This project" (its worktrees included) then "Recent"; the detail is the other project's name and "3h ago", and a long title gives way to it (detail keeps up to 40% of the row). Read-only from Claude Code's files: `history.jsonl` for prompts, a transcript must still exist, and a conversation a live process holds (`sessions/<pid>.json`) is left out. ↩ opens `claude --resume <id>` in the project's workspace (made if missing), named for the question.

**Fonts and themes** (Settings): Appearance is Match System / Always Dark / Always Light, with a dark theme and a light theme picked separately. The theme lists are Axolotty Night and Day, then every Ghostty theme on the Mac (`~/.config/ghostty/themes` first, then Ghostty.app's own), split by the background's lightness; each item carries a 34 × 14 swatch (background, foreground, red, green, blue, magenta). The chrome derives from the theme (`DesignTokens.install`), so a Dracula terminal gets a Dracula sidebar. Font lists SF Mono then every installed fixed-pitch family, each item set in its own face; a family without a bold face is emboldened by the renderer.

**Quick Select** (⇧⌘Space): every URL, path, git hash (7–40 hex with a letter and a digit) and IPv4 address on screen is underlined in the theme's cursor colour and labelled on a small plate of that colour (label in caps, the theme's cursor-text ink), over the hit's first cells. Home-row letters first, the nearest (lowest) hit gets the first; past 26 the tail becomes two-letter, prefix-free. Typing a label copies the text ("Copied" badge); typing it with ⇧ opens it (URL in the browser, path in the editor); ⌫ steps back; Esc or a click leaves. `TerminalHints` (AxModel) finds and labels; nothing is sent to the program.

**Copy Mode** (⇧⌘X): the keyboard selection, keys as in vi.
- Moving: h j k l and the arrows, w b e (across line ends), 0 ^ $, g G (oldest and newest line), H M L, ⌃u ⌃d.
- Selecting: v, V and ⌃v start a character, line or block selection. The same key again drops it.
- Copying: y or ↩ copies and leaves. With nothing selected, the cursor's line is copied. The badge says "Copied" or "Copied N lines".
- Leaving: Esc, q, a click or a resize leaves.

The cursor is an accent outline over a quarter-tint of its cell. A tag in the cursor colour sits at the pane's top right, level with the first row, for as long as the mode lasts. It reads COPY, SELECT, SELECT LINES or SELECT BLOCK, then the cursor's line out of the total. The tag is there because nothing typed reaches the program meanwhile, and a mode you can't see is a trap. The viewport follows the cursor through scrollback and returns to the bottom on leaving. Rows are screen rows (0 is the oldest scrollback line, `VTTerminal.scrollPosition` and `select(screen:)`).

**Claude Code start preset** (Settings): "Claude starts in" (its usual mode, Plan, Accept edits, Auto), "Claude model" and "Claude effort" become `--permission-mode`, `--model`, `--effort` on every Claude Code Axolotty starts ("+", empty state, worktree, review, resume). Empty means Claude Code's own settings decide; its config is never written.

**Open in Editor** (⌥⌘O): the focused pane's repository root (else its folder) in the first installed of Cursor, VS Code, Zed, Windsurf; Finder when none. "Show in Finder" sits beside it in the Session menu.

**Agents drive Axolotty** (`axolotty` CLI and `axolotty mcp`): one set of operations (`Sources/axolotty/Ops.swift`) behind both. MCP tools: `list_panes`, `new_session`, `send_input`, `read_pane`, `wait_for`, `close_pane`. `send` hands text over one way only, the way another agent's TUI takes a prompt: a bracketed paste with Enter sent on its own ≥ 200 ms later (Ink reads an Enter inside the paste as text); keys go by name (`ctrl+c,enter`) and the host encodes them in the program's own keyboard mode. Input to a pane whose agent waits for its person is refused unless forced: an agent never answers another agent's permission prompt by accident. `wait` (one pane, or the first of several) judges every change as it comes, so a `done` the person saw and cleared before the waiter looked still counts; `done` also means idle again after working. `wait --for command` returns the next shell command's end and exits with its status. Claude Code started from Axolotty gets the tools through `--mcp-config "$AXOLOTTY_MCP"`, a file Axolotty owns (Settings → Agents; on by default); the agent's own configuration is never written. Shell integration: zsh (ZDOTDIR), bash 3.2+ (`--rcfile` that reads the login files), fish ≥ 4 (marks itself; Axolotty only keeps its CLI first on PATH). Built and dropped as unused: `status`, `notify`, `commands`, `events`, `attach`, `split`, `focus`, `ports`, `ping`, `capture --format`.

## 7. Anti-slop rules (Impeccable craft floor, applied)

- No kickers or eyebrows. No uppercase letter-spaced headers. No counts, chevrons or footers at rest.
- No Unicode glyphs standing in for icons (no "/" crumbs, no ↑↓ hint caps). Every icon is an SF Symbol or a real vendor vector.
- No colour without meaning, and no gradient except a vendor's own mark.
- No monospace as costume: mono is for the terminal; digits in chrome are tabular SF.
- No modal where an inline state does.
- Text selection, caret, focus ring and scrollbars are themed (accent caret, accent-wash selection, overlay scrollers, focus ring only with Full Keyboard Access).

## Sources

- **Sidebar density study:** Linear, Otty, Things, Raycast, Craft, Arc, Mail, Finder, Notes, Notion, Superhuman, Conductor, cmux, Warp, Zed, Cursor, Codex, Zeron.
- **Project header and agent icon study:** Codex, Conductor, Linear, Zed, Claude desktop, Cursor, Warp.
- **Chrome study:** Ghostty (config source), Zed (`command_palette.rs`, `elevation.rs`, `pane_group.rs`, `toast_layer.rs`), Warp, Raycast, Terminal, Otty docs, WWDC25 session 310.
- **Utility sidebar study:** herdr 0.9.5 (run live in an isolated session) and herdr-app, CodexMonitor, Otty, cmux, Claude Squad, Conductor, Paradev (formerly Superset), Agent Deck, Vibe Kanban, Rex.
- **Captures:** `/tmp/sidebar-study/`, `/tmp/chrome-study/`, `.impeccable/review/` (pass6: dark, light, toast, Jump to Agent, presets menu).

## 8. Roadmap from the utility study

Shipped: Jump to Agent (⌘J), agent presets on "+", Show on asking toasts. Next, in order of value, each kept off the row at rest:

1. ~~Inline Allow / Deny~~ **Dropped 2026-11-02.** The agent's own TUI answers its prompts: no key is safe across agents (Claude Code's "Yes" moves position; every key is rebindable), slopty built GUI approvals and deleted them, and a blocking permission hook would hide the TUI's dialog. Needing you means the strip floods and names the question; clicking takes you there.
2. **Peek:** hold ⌥ over a row and the hover card becomes a live, read-only view of the pane's last dozen rows.
3. ~~Two sounds~~ **Shipped as one:** blocked and error sound; done is silent and passive.
4. ~~Worktree sessions~~ **Shipped** (see Agent status).
5. **Facts in the hover card:** ahead/behind, diff ± and listening ports shipped; PR, CI and context % next.
6. **Mark Unread / Mark Read**, **Pin** (floats within its project, no section), **multi-select** with plural menu items, **Recently Closed** with agent resume.

Not copied: second-line token rows, counts at rest, a second Agents panel, kanban lanes, prefix keys, rows that move on activity, auto-approve, screen-scraped state.
