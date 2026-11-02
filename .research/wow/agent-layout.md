# Axolotty: the content area (everything right of the sidebar)

Research date: 2026-11-02. Scope: the context header, pane chrome, focus, agent state, footer and empty state of the best AI-agent workspaces and agentic terminals, measured where possible, and a concrete proposal for Axolotty. The sidebar is out of scope; see `design-system.md` §4 and §8.

**How the numbers were obtained.**

- **[m]** Measured by me from a 1x capture (`screencapture -o -l`) with per-pixel sampling. Warp, Ghostty and the Axolotty baseline were measured this way.
- **[src]** Exact values from public source code or config defaults.
- **~** Estimated from official screenshots or video frames. Captures were scaled by traffic-light pitch (20 pt between dot centres) or halved from 2x. Treat every **~** value as ±2 pt.
- **[re]** Exact values from the bundle analysis in `.research/wow/re-electron.md` (Codex, Claude desktop).
- **Reconciliation:** Codex and Claude values below are reconciled against `re-electron.md`. Where a web estimate disagreed, the [re] value replaced it, and the estimate is kept in brackets. `re-orchestrators.md` and `re-native.md` did not exist yet when this was written. Where they disagree with a **~** value for Conductor, opencode, Sculptor, Paradev, Emdash, Nimbalyst, Factory, Warp, Zed or Otty, theirs wins.

**Captures.**

- Local: `/tmp/agent-layout-study/`
  - Warp: `warp-now.png`, `warp-split2.png`, `warp-split2-sticky.png`, `warp-split3.png`
  - Ghostty: `ghostty-now.png`
  - CodexMonitor: `codexmonitor-readme.png`
- Web: `/tmp/agent-layout-study/web/`
- Earlier studies: `/tmp/chrome-study/` and `/tmp/sidebar-study/`
- Axolotty: `.impeccable/baseline/now-dark.png`, `.impeccable/review/pass3-empty.png`, `pass6-dark.png`

The sibling critique `.research/wow/critique.md` reached several of the same conclusions independently: frame and sheets, a pane identity strip, and launch tiles. This document gives those ideas their measured precedents and refines them where the research disagrees.

---

## 0. Verdict

The best products in this space do one thing Axolotty refuses to do: **they label what you are looking at, where your eyes already are.**

- **A heading above the work.** Every top-tier app puts a 28–44 pt line above the work: project / title, plus branch or PR. It sits there even when a sidebar is open.
- **State inside the work.** Each turns agent state into a few precise, live words *inside* the content: "Worked for 1h 24m", "Claude is working 6m 7s", "Edited 16 files +824 −317 [Review]", "Needs you".
- **Panes as objects.** The agentic terminals (herdr, cmux, Paradev, Warp, Claude's panes) give each split pane its own 28–30 pt identity strip. herdr and Claude go further and set panes into a frame as inset cards.

Axolotty says all of this once, in the sidebar, at 6 pt. The 932×720 pt area where the eyes actually rest is a black slab with no name, no state and no figure. Measured ink coverage of the baseline is 3.3 % (critique.md §RC1). That is why it reads as "a text dump in a box".

The fix is not more chrome. Four moves are enough:

1. **Name it.** One context line in the band you already pay 40 pt for.
2. **Make panes objects.** Sheets set in a frame, with a strip only when there are two or more panes.
3. **Make state live.** A 2 pt progress line driven by the agent itself (OSC 9;4), an amber strip when an agent needs you, and a receipt when it finishes.
4. **Make the empty state launch agents.**

---

## 1. Who sets the premium bar, ranked

The ranking is by craft of the content area: hierarchy, precision, calm at rest, and how specific the state copy is. Feature count does not count. Ratings are 1–5. The "Lesson for Axolotty" column is what transfers to a native terminal that hosts other agents' TUIs.

| # | Product | Craft | Why it sets (or misses) the bar | Lesson for Axolotty |
|---|---|---|---|---|
| 1 | **OpenAI Codex app** (now inside ChatGPT desktop) | 5 | A quiet canvas, one reading column, one fixed composer. Work appears as compact cards. Nothing is on screen that isn't the task. | Title + project in the window header (~40, 13 semibold + 13 grey). Work becomes one-line receipts: "Worked for 1h 24m ›", "Edited 16 files +824 −317 [Review]". |
| 2 | **Claude desktop, Code tab** | 4.5 | Panes are instruments: inset cards, ~28 headers, ~6–8 gaps, ~8 radius. State copy is warm and exact: "✳ 27s · ↓39.9k tokens", "Waiting on you / Working / Resolved". The unfocused split is dimmed. | Per-pane breadcrumb header. A branch bar on top of the composer (`main ← claude/x +966 −55 [Create PR]`). The turn receipt. The closest premium precedent for "panes as cards". |
| 3 | **Zed** (agent panel, threads) | 5 | Every strip sits on one 32 pt module **[src]**; title bar 34 **[src]**. Grey on grey, with almost no chrome. Inline subagent cards carry "+12 −20". | A strict height module. Project ▾ / worktree ▾ / branch ▾ in the title bar. The "N files changed" accordion above the composer. |
| 4 | **Conductor** | 4 | Dense but deliberate. A green "Ready to merge [Merge]" header on the Changes panel. A tick minimap (one tick per message) on the transcript edge. Turn footer "2m, 4s" + file chips. | Put git/PR state where the decision is made. The elapsed time plus changed files *is* the receipt. |
| 5 | **Cursor 3 Agents window** | 4 | Tiled panes, and focus is pure tone (focused white, unfocused grey canvas). The prompt sticks to the top of each pane. | Focus by tone, never by a border. Each pane has its own ~30 header. |
| 6 | **Warp 2.0 ADE** | 4 | Blocks with rails, a sticky command header, an approval card docked above the input (`Reject ^C · Edit ⌘E · Run ⏎`). Rounded context chips. Too many chip rows. | Approvals dock above the input with key hints. A pane header appears **only when split** [m]. |
| 7 | **Charm Crush** (TUI) | 5 (aesthetic) | A brand achieved inside cell constraints: gradient wordmark, `╱╱╱` hatching, muted greys. Every row carries information: `23% (46.1K) $4.15`, `◇ Claude Opus 4  1m42s` per turn. | One bold signature element; everything else neutral. Per-turn identity + elapsed. |
| 8 | **Devin** | 4 | Calm, editorial, monochrome. Colour is reserved for state ("Approval required" in orange). | Restraint. State words in colour, everything else grey. |
| 9 | **Emdash** | 4 | Linear-grade restraint around real CLI TUIs as tabs. Hairlines are exact. Colour only for diffs and state. | The closest *structural* peer: it frames other agents' TUIs and doesn't redraw them. |
| 10 | **herdr-app** | 4 | Every number is deliberate **[src]**: cards gap 8 / radius 10 / 1 px border, 30 pt pane header (icon · agent · ~/cwd · state), "Needs you" pill, focus = 1 px accent border. | The closest *visual* peer for a multi-agent terminal. Its per-pane strip spec is the consensus. |
| 11 | **Otty** (native agent terminal, reversed) | 4 | AppKit-first. The composer and prompt queue *push the terminal up* instead of covering it. Hover-revealed chrome (0.15 s in, 0.4 s dwell, 0.2 s out). Unfocused alpha 0.6. | Native mechanics: bottom insets that reflow the grid, and controls revealed on hover. |
| 12 | opencode desktop | 4 (code only) | Sticky 48 px session header with a 16 px fade beneath; permission and question "docks" in the composer region; 0.5 px hairlines **[src]**. | A fade under a sticky header instead of a rule. |
| 13 | Amp | 3.5 | Personality: coloured orbs, an accent-coloured thread title, queued-message cards above the composer, a live state word ("Streaming / Thinking / Running Tools"). | Live state *words*, not just a spinner. |
| 14 | Factory Desktop | 3.5 | Brand voice (mono chips, orange autonomy bars), but a flat transcript hierarchy. | An "Open a panel" chooser as an empty right column. |
| 15 | Jules | 3.5 | Excellent flow storytelling (plan → approve with a countdown → "Ready for review" card); plain Material visuals. | The "Ready for review" receipt card. |
| 16 | Ghostty | 3.5 (as a terminal) | Native, invisible chrome. Unfocused split at 0.7 [m][src]. Divider 1 px *darker* than the ground [m]. OSC 9;4 progress bar at the top of the surface. | The progress protocol, and dimming done right (overlay the ground, so only ink dims). |
| 17 | Sculptor, Paradev, Kiro, Trae SOLO, Jean, Nimbalyst, cmux, Wave, Goose | 2.5–3 | Competent but utilitarian: stock components, stacked strips (Paradev 48+36+28), loud focus colour (Wave's green 2 px), or density without rhythm. | Individual mechanics only: cmux's attention ring, Paradev's 60 % unfocused header, Sculptor's "1 / 8" todo indicator above the input. |

**The bar, distilled from ranks 1–11:**

1. A single context line heads the work, at 28–44 pt. It shows the title and project, with the branch and diff close by.
2. Agent state is a short, specific, live phrase with a number.
3. Panes are objects with their own 28–30 pt identity and are told apart by tone, not lines.
4. Approvals dock where the work is.
5. A finished turn leaves a receipt: elapsed time and files changed.
6. One signature element. Everything else is grey.

For Axolotty, ranks 1–3 set the finish, and the peers that frame agent TUIs set the structure: Emdash, herdr, Warp, Otty, Claude's panes.

---

## 2. Comparison table (content area only)

**Key:** H = height in pt. "Per" = per window (W) or per pane (P). Focus/unfocused describes split panes. "State" = where agent progress and approvals live: I inline, B bottom dock, R right panel, S sidebar only.

| Product | Context header: H, Per, contents | Type scale | Pane chrome | Focus / unfocused | Separator | State | Footer |
|---|---|---|---|---|---|---|---|
| **Axolotty (baseline)** [m] | 40, W, **empty** with the sidebar open; the chip appears only when waiting | n/a | none | 0.28 ground overlay on unfocused (text 255→~186 at peak) [m]; hollow cursor | 1 px fg≈0.065 hairline from y 40 [m] | S (sidebar badge) + 1.5 pt amber inner stroke [src] | status bar 24, off |
| Codex app | **46** toolbar (classic) or **44** titlebar ("page surface" layout) [re] (~40 est.), W: title 13 semibold + project 13 grey; sidebar trigger, back/forward, open-in, diff/review toggles | 13 / 13 | page-surface variant: **main surface is one inset card, radius 12, 4 right / 4 bottom, sidebar runs under its corners** [re]; classic: flush, 0.5 px seam [re] | n/a | hairline / card edge | I ("Working for {time}", file card) + R (diff panel, surface = main mixed 6 % toward ink [re]) | none; "Work locally ⌄" under composer |
| Claude desktop | **48** frame row [re] (~40–44 est.), P: `project / title` breadcrumb; pane icons (Terminal, Changes, Browser, Files, Preview) | 13 | panes in a grid inside an 8 pt content inset [re]; ~28 pane headers with ×; pane grip 32×3 pill at 20 % on hover [re] | **unfocused pane opacity 0.75 + saturate 0.85 over 120 ms** [re] | split = 1 px border [re] | I (tool rows, receipt) + B (approval card r10/12, pad 12, docks above the composer [re]; branch bar, CI chip) + R | composer sub-row ~22 (mode, model, usage ring) |
| Zed | 34 W title bar [src] (project▾ / worktree▾ / branch▾) + 32 P panel toolbar [src] (thread title, +, ⤢, …) | ~13 | 32 tab bars [src] | border 0, inactive opacity 1.0 by default [src] | 1 px | I + B ("N files changed" accordion) | ~28–30 status bar |
| Conductor | ~38 P tab strip of chats; right panel header `#8376 ▲ Ready to merge [Merge]` | 13 | none | n/a | hairlines | I (collapsed tool calls, turn footer + file chips) + R (Changes/Checks/Review) | none |
| Cursor 3 | ~30 P: agent title 13 grey + local/cloud icon, ··· | 13 | per-pane header + composer | focused white / unfocused grey canvas | hairline | I (sticky prompt, "Worked for 5m 38s") + B (`Review +53 −6`) + R (PR changes) | none |
| Warp 2.0 [m] | titlebar 36 [m]; pane header 34 **only when split** [m], centred title ~12 at fg≈0.55 [m], ⋮ × | ~12 | header only in splits | **13 px accent corner triangle** [m]; no dimming by default (text stays 245) [m] | 1 px fg≈0.14 [m] | I (blocks, rails) + B (approval card, chips) + R (Code review) | 2 rows of ~20 chips (cwd, branch, `343 • +42037` diff) [m] |
| Ghostty [m][src] | ~28 native transparent titlebar, proxy icon + title 13 bold secondary | 13 | none | unfocused-split-opacity 0.7 (ground overlay; ink 255→190) [m][src] | 1 px *darker* than ground [m] | OSC 9;4 bar at top of surface | none |
| Otty [src] | titlebar: centred title 13 secondary; mode pills 20 tall top-right of pane | 13 | drag-handle capsule 16 wide, × on hover | unfocused alpha 0.6 [src] | divider 1 px fg 0.08, 2 px on hover over 0.16 s [src] | B (prompt queue: card radius 12, input bar 36 r8, inset 12) + toasts | none |
| herdr-app [src] | tab row 42 (tabs 29, r7, 12.8 px) | 12 | **30 pane header** (icon 14 · agent · ~/cwd dim · state); split/zoom/close on hover | **1 px accent border** on the focused card; no dim | **cards: gap 8, r10, 1 px border**, also when alone | P header ("Needs you" pill 18, r5, 10.5 semibold, 15 % wash) + S + R (368) | 28: machine, branch, `● N agents · N needs you`, ⌘⇧P |
| cmux [src] | 30 P tab strip per pane (11 pt, 1.5 pt active underline) | 11 | per-pane tabs | Ghostty 0.7 | 1 pt | **attention ring 2 pt, inset 2, r6, accent, glow 0.35/3**; 0.6 s arrival pulse | none |
| Paradev [src] | 48 tab bar + ~36 launcher + 28 pane header | 12 | 28 header, `bg-muted/30` | focused 2 px border primary/15 (only when split); **unfocused header 60 %** | 1 px | R (Files/Changes/Review ~530) | none |
| Emdash | ~38 W: `project / task ▾` + branch chip + icon groups | 13 | ~40 agent tabs (vendor logo + name) | active tab white | hairlines | the agent TUI itself + R (Changed / Staged / PRs ~280) | ~36 under right panel |
| opencode desktop [src] | 48 sticky, with a 16 px fade below: project avatar · worktree / branch · title + spinner | 13 | tabs | n/a | 0.5 px hairlines | B (permission/question docks, todo pill, queue) + R | composer is the footer |
| Crush (TUI) [src] | 32-col right sidebar as header (logo, title, cwd+branch, model, `23% (46.1K) $4.15`, modified files) | cells | none | n/a | none | I (`✓ Bash…`, `◇ Opus 4 1m42s` per turn) + modal permissions | 1 row key help; status takes it for 5 s |
| Amp | ~28 P: status dot + accent-coloured title, Share | 13 | right panel tabs | n/a | hairline | I + B (queued messages, live state word in the composer) | none |
| Devin | ~60 P: title 18 + PR chip; right-pane tabs share the row | 18 | two panes | n/a | hairline | I + R (PR, Computer, Changes) | ~50 replay scrubber |
| CodexMonitor [src] | 40 min, sticky, 1 px bottom border: title 14/600 › branch 12/600 ▾; Open-in, terminal, copy, panel icons | 14 / 12 | none | n/a | border-subtle | I ("1:03 Working…" with elapsed) + B (context ring in composer meta) + centred approval card 460 wide | none |

**Sources for the table:** see §7. CodexMonitor values come from `/Volumes/Lacie/Workspace/oss/CodexMonitor/src/styles/main.css` (`.main-topbar`, `.workspace-title`), `base.css` (`--main-topbar-height: 40px`), `approval-toasts.css`, and `features/composer/components/ComposerMetaBar.tsx`.

---

## 3. Patterns that make a content area feel crafted and alive

Each pattern lists the apps behind it and its spec.

### P1. A context line above the work, even with the sidebar open
- **Apps:** Codex (46 / 44 [re], title 13 semibold + project 13 grey), Zed (34 [src]: project▾ / worktree▾ / branch▾), Claude (`acme-web / Build the alignment grid…`), Emdash (`project / task ▾` + branch chip), opencode (48 sticky: avatar · worktree / branch · title), CodexMonitor (title 14/600 › branch 12/600).
- **Spec consensus:** 34–44 pt tall. Project in secondary ink and title in primary, both 13. The branch sits 12 in tertiary or in a chip. Actions are icons on the right, 28 targets with 14 glyphs. A separator is optional: Zed and CodexMonitor use a 1 px border, opencode a 16 px fade, Codex nothing.
- **Why it works:** the sidebar answers "which one?"; the header answers "what am I looking at, and in what state?". Every top-tier app repeats the title because those are two different questions.

### P2. Live state as a short phrase with a number
- **Apps:** Codex ("Working for {time}" [re], with a Thinking / Working / Searching / NeedsInput / Paused / Ready state machine), Claude ("Claude is working 6m 7s", "✳ 27s · ↓39.9k tokens"), Codex ("Worked for 1h 24m ›"), Cursor ("Worked for 5m 38s"), Amp ("Streaming / Thinking / Running Tools"), CodexMonitor ("1:03 Working…"), Crush (`◇ Claude Opus 4  1m42s`), Conductor ("2m, 4s").
- **Spec:** 12–13 regular, secondary ink, tabular digits, beside a small mark: a spinner, the vendor glyph, or ✳. Elapsed counts up once a second. It never pulses.
- **Why it works:** it is the single most "alive" thing on these screens, and it is calm. It is text that changes, not animation.

### P3. The receipt: when work ends, say what changed
- **Apps:** Codex ("Edited 16 files +824 −317 [Review]" card), Conductor (turn footer "2m, 4s" + file chips `HeroHeadline.tsx +2 −7`), Jules ("Ready for review" card with +25 / −1 and Time: 2 mins), Zed (subagent card "— 1 files changed +12 −20"), Warp (`343 • +42037` diff chip in the input [m] and `± +42037 −0` in the titlebar [m]).
- **Spec:** one line, tabular, +N in a green and −N in a red at about 0.85 ink, and one action (Review).

### P4. Panes as objects: an identity strip per pane, but only when there are several
- **Apps:**
  - herdr: 30 [src], icon 14 · agent name medium (max 260) · ~/cwd dim · state; split/zoom/close on hover
  - cmux: 30 [src]
  - Wave: 30 [src]
  - Paradev: 28 [src]
  - Claude panes: ~28
  - Cursor: ~30
  - Warp: 34 [m], **shown only when split** [m], and the single pane has none
- **Spec consensus:** 28–30 tall, 12 text, 14 icon, ~10 horizontal padding. Actions appear on hover only. No rule under the strip: herdr uses a 1 px border, the others use tone or nothing.

### P5. Focus by tone, attention by colour, never the same cue
- **Focus apps:**
  - Ghostty: 0.7 overlay of the ground on unfocused panes [m][src]
  - Otty: alpha 0.6 [src]
  - Claude: unfocused pane opacity 0.75 and saturate 0.85, transitioning over 120 ms [re]
  - Cursor: grey canvas on the unfocused pane
  - Paradev: unfocused header at 60 % [src]
  - Borders appear only in utility-tier apps (herdr 1 px accent, Wave 2 px green, Paradev 2 px primary/15). Warp uses a 13 px corner triangle [m], which reads as a glitch.
- **Attention apps:**
  - cmux: ring 2 pt, inset 2, r6, glow 0.35/3, 0.6 s arrival pulse [src]
  - herdr: "Needs you" pill, 15 % wash [src]
  - Devin: orange "Approval required"
  - Claude desktop: awaiting = amber `#fab219` 6 pt dot; running = a muted dot blinking 0.3↔1 over 1.2 s, with no spinner [re]
  - Codex: "Needs approval" is a 13 pt text pill on a green 20 % wash; "Needs input" is the same on blue 15 % [re]. A worded pill, not a dot.
  - Ghostty 1.4: `bell-features` includes an opt-in `border` [src]
- **Rule:** focus is quiet and neutral (ink and tone). Attention is loud and chromatic (amber). If both use the accent, a screen of four panes cannot be read.

### P6. Sheets in a frame instead of lines
- **Apps:**
  - herdr: gap 8, radius 10, 1 px border, `lone: true` so even a single pane is a card [src]
  - **Codex "page surface" layout: the whole main area is one inset card, radius 12, inset 4 right and 4 bottom, the sidebar's ground running under its corners [re].** This is the top-ranked app choosing a sheet in a frame.
  - Claude: right-column cards with ~6–8 gaps and ~8 radius; the content area sits in an 8 pt inset, and an inset floating-card frame variant (inset 8, radius 8) exists but is a fallback [re]
  - Trae and Kiro Crew: tool panel as an inset card, r8–10, 6–8 gutter
  - Otty: floating card, r8, margin 8 (on glass, which we don't use)
- **Against:** Codex, Conductor and Cursor are flush with hairlines. They have one transcript, not several terminals.
- **Why sheets fit Axolotty:** with several agents in one window, objects beat lines. The gap *is* the divider, so the number of rules drops to zero (owner: "few, elegant dividers").

### P7. Approvals dock where the work is, and they push content, they don't cover it
- **Apps:**
  - Warp: approval card above the input with `Reject ^C · Edit ⌘E · Run ⏎`
  - opencode: permission/question docks [src]
  - Otty: prompt queue and composer reserve bottom rows and slide the terminal up; input bar 36 r8 inset 12; card r12; shift 0.18 s in / 0.14 s out [src]
  - Claude: branch bar and CI chip above the composer
  - CodexMonitor: a centred modal card, the anti-pattern
- **Rule for a terminal:** a visible TUI already draws its own approval prompt. Axolotty should add an approval surface only where the TUI's own prompt isn't reachable, which means the **unfocused** pane.

### P8. A real progress signal from the agent, not a scraped one
- **Ghostty** draws a native progress bar at the top of the surface for OSC 9;4. It supports indeterminate, numeric, error and success states (release notes 1.2.0).
- **Claude desktop** itself animates run state with a 1.1 s linear sweep [re].
- **Claude Code** emits OSC 9;4 when `terminalProgressBarEnabled` is on. It is unreliable inside tmux, and an earlier bug cleared it between tool calls (resolved).
- **Spec:** a 2 pt line at the very top edge of the pane. Indeterminate is a 30 % segment sweeping (Otty's `IndeterminateProgressBar`: 0.3 × track, 0.8 s ease-in-out [src]).

### P9. One signature element; everything else neutral
- **Examples:**
  - Warp: blocks with rails and a sticky command header [m] (`warp-split2-sticky.png`: the command line pins to the pane top with a hairline beneath)
  - Crush: gradient wordmark and hatching
  - cmux: blue rings
  - Conductor: the tick minimap
  - Codex: the "What should we build?" empty state
- **For Axolotty:** see §5.6.

### P10. Footers only when they count or act
- **Earn their space:** herdr (`● N agents · N needs you`, palette hint), Crush (key help with a 5 s status takeover), Warp (chips that are actions).
- **Do without:** Codex, Claude, Conductor, Cursor, Amp, Factory, Emdash, cmux.
- **Verdict:** Axolotty's status bar should stay off. The header absorbs branch and state.

---

## 4. Diagnosis of the Axolotty baseline content area

Capture: `.impeccable/baseline/now-dark.png`, 1180×760 at 1x. Pixel values [m].

1. **The band is 37,000 px of nothing.** Over the content (x 248–1180, y 0–40) the band is pure ground `(21,18,20)`, the same as the terminal. With the sidebar open it shows nothing at all. The shell's blank first line pushes the first glyph to y ≈ 66, so the top 66 pt of the work area say nothing. Every premium app spends this exact strip on identity (P1). We pay for it and leave it blank.

2. **Nothing in the content says what it is.** The selected session is "tmp / zsh", but neither pane says so. Nor does anything say which project, which branch, which agent, or whether that agent is working.
   - "Say a thing once" was applied as "say it in the sidebar", and the sidebar is at the edge of vision.
   - The one in-content cue, a band chip, appears only for waiting or failed sessions.
   - A working agent, the product's main verb, has **no presence in the content area at all**.

3. **Two panes are two identical text dumps.**
   - The split is a 1 px line `(35,32,34)` on `(21,18,20)`, about fg 0.065.
   - It **starts at y 40** while the sidebar seam runs from y 0, so it hangs from nothing.
   - Neither pane has a name. In a session where one pane runs Claude and the other runs tests, you cannot tell which is which without reading terminal output.

4. **Focus is legible only up close.**
   - The unfocused pane gets a 0.28 overlay of the ground (peak ink 255 → ~186, measured as (98,189,174) against (128,255,234)) and a hollow cursor. That is about the Ghostty default (0.7 opacity → 190), and it is fine as a *secondary* cue.
   - But it is the *only* cue, and on a mostly empty pane there is nothing to dim, so the two panes look alike.
   - Premium apps add a second cue in chrome: Cursor tone, Paradev header ink, Claude dimmed panes with live headers.

5. **Attention uses a border, the weakest shape.**
   - A waiting pane gets a 1.5 pt amber inner stroke at 0.7 (`TerminalView.swift:113, 360–376`).
   - At 1x, a 1.5 pt line on a 470 pt-wide pane is easy to miss. It also competes with the divider and the sidebar seam: three lines of different meaning and equal visual weight.
   - cmux's ring works because it is 2 pt *with a glow and an arrival pulse*. herdr's works because it is a filled pill *with words*.

6. **No moment of completion.** When an agent finishes, the content area does not change. Codex, Claude, Conductor, Jules and Zed all leave a receipt (P3); Axolotty leaves a neutral dot in the sidebar.

7. **No figure and ground.**
   - Sidebar `(16,14,15)` against terminal `(21,18,20)` is 1.03:1 (critique.md RC1). The window is one slab.
   - With splits, the panes are not objects either. Nothing about the composition says "a desk of agents".

8. **The empty state is generic.** `pass3-empty.png` shows a 26 pt terminal glyph, "No sessions open" and New Session / Open Folder… It doesn't mention agents or projects, the two things the product is for. Compare Codex's "What should we build?" over a composer with a project pill, Cursor's repo / cloud / branch chips, and Emdash's four ⏎ action rows.

9. **What is right and must stay:**
   - opaque surfaces
   - tone-based dimming
   - no status bar
   - the band chip carrying the agent's own question
   - instant-in / soft-out motion
   - whole-pixel marks at 1x
   - the program icon with its state badge

   The proposal builds on these rather than replacing them.

---

## 5. Proposal: the Axolotty content area

**Base numbers.**

- Window: default 1180×760, minimum 720×440.
- Band: 40.
- Sidebar: 248.
- Terminal: SF Mono 13, cell pitch ~17.
- Colour notation is relative to the theme:
  - `bg` = terminal background, `fg` = terminal foreground
  - `mix(a, b, t)` = linear blend from a toward b
  - `accent` = the theme's accent (Axolotty magenta)
  - `amber`, `red`, `green` = the status hues already in `Tokens.swift`
  - Text tiers: `text` 1.0, `text2` 0.72, `text3` 0.50, `text4` 0.32 (dark).

### 5.0 Principle changes

These change `design-system.md` §1 and must be written into it.

- **§1.1 becomes "The window is a frame; terminals are screens set in it."**
  - The band, the sidebar and the gutters are one *frame* tone. Each pane is a *sheet* in the terminal's own `bg`.
  - This follows herdr, Claude and critique.md change 1. With one pane, the sheet still exists (herdr `lone: true`), so splitting never changes the window's structure.
- **§1.3 "Say a thing once" is refined to "say each thing once *per question*".**
  - The sidebar answers "which?".
  - The context header answers "what am I looking at, and how is it doing?". It shows the project and session title even with the sidebar open, because every premium app does (P1).
  - The header adds what the row cannot hold: branch, diff, elapsed time, and the live state phrase.
- **§1.4 is extended.** Accent (magenta) means *working* (critique.md change 2). Amber means *needs you*. Neutral ink and tone mean *focus*. No cue does two jobs.

### 5.1 Frame and sheets

| Part | Spec |
|---|---|
| Frame tone | dark `mix(bg, fg, 0.06)`; light `mix(bg, fg, 0.05)` (critique.md change 1, gives 1.14:1 and 1.10:1). Paints the band, sidebar and gutters. Sidebar hairline deleted. |
| Stage | Below the band. Insets: top 0, right 6, bottom 6, left 0 with the sidebar open (its 8 pt plate inset is the gutter), left 6 with it hidden. |
| Sheet | Fill `bg`; radius **10** (Codex's card uses 12 at a 4 inset [re]; 10 at a 6 inset keeps the same concentric step against the ~16 window corner), continuous (window corner ~16 at 1x, minus the 6 inset, keeps it concentric); `masksToBounds`. Dark: no border, no shadow. Light: contact shadow y1 b3 black 0.07. |
| Gutter between sheets | **6** (herdr 8, Claude 8 content inset [re], Codex 4 [re], Wave 3; 6 keeps two more columns at 1x than 8). Nothing drawn at rest. Hover over the 9 pt hit area: a 2×28 pill in `borderStrong`, fading in on `tick`. Claude's grip is the same idea at 32×3 and 20 % [re]. While dragging: `accent`. |
| Terminal padding in a sheet | x **14**, top **10**, bottom **8** (up from 12 / 8 / 6, to clear the corner curve). |
| Cost | About 14 pt of width (≈2 columns) and 6 pt of height (0 rows) against today. |

Rules on screen at rest: **zero**. The palette keeps its one rule under the field.

### 5.2 Context header (per window, in the 40 pt band)

The header is the band, re-used. It adds no height. It describes the **shown session** and sits over the stage, starting where the sheet's text starts.

```
x = stage.minX + 14 (aligned to the terminal's first column)
┌──────────────────────────────────────────────────────────────────────────────────────────────┐
│ [A] axolotty  >  refactor host protocol   (br) ax/host-proto  +412 -96   ......   (C) Working 4:12   [split][more] │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
 tile16 8 name 13sb 6 chev 6 title 13 text2  16 glyph11 4 branch 12 text3  8 diff chip                state cluster   hover-only
```

**Leading group** (left to right, baseline-aligned on the band's centre, every mark on whole pixels):

| Element | Spec | Precedent |
|---|---|---|
| Project tile | 16 pt hue tile from `ProjectHue` (the 20 pt solid tile proposed in critique.md change 3 also works; keep it equal to the sidebar's). | Zed/Claude project crumb, Emdash |
| Project name | 13 semibold, `text`. Click → reveals the project in the sidebar, or opens the project menu if the sidebar is hidden. | Codex, Claude |
| Separator | SF Symbol `chevron.compact.right`, 9 pt, `text4`, 6 pt either side. Not a "/" glyph (anti-slop rule). | Zed, CodexMonitor |
| Session title | 13 regular, `text2`; truncates first (tail); min 80 pt. Double-click renames (same action as the sidebar). The `AgentTitle.trimmed` rule applies. | Codex, Claude |
| Branch | `arrow.triangle.branch` 11 pt `text3`, 4 pt gap, branch 12 regular `text3`, middle-truncated at 160. Hidden outside a git repo. 16 pt gap before it. | Zed, Emdash, CodexMonitor |
| Diff chip | Shown only when the worktree is dirty. `+412` in `green` and `−96` in `red`, both 11 medium tabular at 0.85 alpha, 4 pt apart. Hover plate 22 tall, radius 6, `hover`. Click → **Changes popover** (§5.5). | Warp `±` [m], Codex file card, Cursor `Review +53 −6` |

**Trailing group** (right-aligned, 12 pt from the stage's right edge):

| Element | Spec |
|---|---|
| State cluster, working | Vendor mark 14 (real Claude/Codex/Gemini vector) carrying the 8 pt **accent** spinner badge, 6 pt gap, "Working" 12 `text2` + elapsed `4:12` 12 tabular `text3`. Elapsed ticks once a second, from the agent's last working transition. With several live agents in the session's panes, the cluster names the focused pane's agent and appends `+1` in `text3`. |
| State cluster, waiting | Today's chip, kept: amber wash pill 22 tall, radius 11, the agent's question 12 medium, max 280, **Show** when another pane holds it. |
| State cluster, failed | Same chip with `red` wash. |
| State cluster, idle / shell | Nothing. |
| Receipt (transient) | On working → done: the cluster becomes `✓ 4m 12s · 6 files +128 −14` (12, `text2`, check in `green`) for 8 s, or until the session is focused and a key is pressed. Then it clears (fade over `tickOut`). The sidebar's unseen dot persists as today. |
| Actions (hover only) | Split Right, Split Down and More, as 28×28 icon buttons with 14 glyphs. Revealed when the pointer is in the band over the stage: 150 ms fade in; dwell 400 ms then a 200 ms fade out (Otty's measured timing). Never shown at rest. |

**Why 40 and not 44–48.** Codex uses 44–46 and Claude 48 [re], but both are chat apps with one transcript. Zed uses 34 [src] and Warp 36 [m], and both are content-dense. Axolotty is a terminal, where every point is a row. The band is already 40, so the header costs nothing new.

**Behaviour.**

- **Sidebar hidden:** the leading group starts 20 pt after "+" (existing rule). The title stays, and the program icon is replaced by the project tile.
- **Overflow:** the session title truncates first, then the branch hides, then the diff chip drops to `±` only. The project name never truncates below 60 pt.
- **Not key:** every ink drops one tier (`text` → `text2` and so on). Colours keep their hue at 0.6 alpha.
- **Height and type:** 40 pt band, 13 / 12 / 11 type; one header per window. Per-pane identity lives in strips (§5.3).
- **Optional census:** critique.md change 5 proposes amber, red and accent counts at the far right. If it is adopted, it counts **other** sessions only, sits to the right of the state cluster after a 16 pt gap, and hides at zero. Without that rule it duplicates the cluster.

### 5.3 Pane strip (only with 2 or more panes, none zoomed)

Inside the top of each sheet, on the sheet's own `bg`, with no rule (P4).

```
╭──────────────────────────────────────────────────────────╮
│ (C) Claude  ~/ax/Sources              Working 4:12  [z][x] │  28 pt strip
│ ...terminal rows start 6 pt below the strip...             │
```

| Part | Spec |
|---|---|
| Height | **28** (herdr 30, cmux 30, Paradev 28, Claude ~28; 28 keeps the Axo control module). Terminal top padding under the strip is 6 instead of 10. |
| Leading | Program icon at 14 (vendor mark for agents, SF Symbol 12 medium for programs) at x 12, with its state badge. 8 pt gap. Program or agent name in 12 medium. 8 pt gap. The pane's cwd relative to the project root, 12 regular `text3`, middle-truncated, hidden below 280 pt pane width. |
| Trailing | Working: elapsed `4:12`, 11 tabular, `text3`. Done-unseen: 6 pt `green` dot. Hover only: Zoom (`arrow.up.left.and.arrow.down.right`) and Close (`xmark`), 22 pt buttons with 12 glyphs, 4 apart, 8 from the edge. |
| Focus | Focused strip: name `text`, cwd `text3`. Unfocused strip: name `text3`, cwd `text4` (Paradev's header dimming). The sheet's content keeps the 0.28 ground overlay, which matches Claude's 0.75 opacity [re] and Ghostty's 0.7 [src]. The change animates over 120 ms (Claude [re]) instead of snapping. No accent and no border. |
| Needs you | The whole strip fills with `amber` wash 0.16 dark / 0.12 light. The name becomes the agent's question, 12 medium, `text`. A 6 pt amber dot replaces the elapsed time. The wash fades in over 200 ms ease-out and the badge pops 0.6 → 1.0 on `Motion.pop`, once. **This replaces the 1.5 pt amber inner stroke** (`TerminalView.swift:113, 360–376`). |
| Failed | The same, with `red` wash. |
| Interactions | Double-click toggles zoom. Dragging the strip moves the pane (drop zones: Otty's 5-zone overlay, accent fill 0.35 and stroke 0.9 [src]; later). Right-click opens the pane menu. |
| One pane | No strip. The header (§5.2) carries the identity, as Warp does [m]. |
| Four or more panes | Strip is still 28. The cwd hides below 280 pt width and the name truncates at 140. |

### 5.4 Agent state inside the sheet

**(a) Progress line**, driven by the agent (P8).

- **Placement:** 2 pt tall, across the full sheet width at the very top inside edge, clipped by the sheet's corner radius. With a strip it sits at the strip's top, so the strip and the line read as one header.
- **Source:** OSC 9;4 only. Never scraped.
- **States:**

  | OSC 9;4 state | Rendering |
  |---|---|
  | indeterminate (3) | a 30 % segment in `accent` sweeping over 1.1 s (Claude's run sweep [re]), ease-in-out, track `accent` at 0.12 |
  | numeric (1;n) | a determinate fill |
  | error (2) | `red` |
  | warning/paused (4) | `amber` |
  | clear (0) | fade out over 250 ms (Otty's `stopAnimating`) |

- **Reduce Motion:** a static line at 0.5 alpha.
- **Why:** this is the most "alive" mark possible at a cost of 2 pt. It is accurate because the agent reports it, and it is invisible when idle.
- **Gate:** Claude Code emits it only with `terminalProgressBarEnabled` and not through tmux, so treat it as an enhancement. The header's "Working 4:12" (from hook state) remains the baseline signal.

**(b) Need bar**, for the **unfocused** waiting pane only (P7).

- **Placement:** docked inside the sheet's bottom, inset 8 left, right and bottom.
- **Size:** 40 tall, radius 8. Fill `mix(bg, fg, 0.08)` with an `amber` wash 0.10 over it.
- **Contents:** vendor mark 14 · the agent's question, 13 regular `text`, one line, tail-truncated · then trailing **Allow** (primary: solid fg, inverted ink, 24 tall, radius 6) and **Deny** (secondary). Buttons appear only for agents whose accept and deny keys are known (roadmap §8.1). Otherwise a single **Focus** button.
- **Layout effect:** the bar reserves its height plus 8 from the bottom of the grid; the terminal shrinks by whole rows (Otty `applyPaneBottomInset`) rather than being covered. Animate the reservation over 180 ms ease-out in and 140 ms ease-in out (Otty [src]). Grids reflow once, at the end.
- **Hidden when:** the pane is focused (the TUI's own prompt is right there), or when the pane is too short (< 8 rows).
- **Why:** in a four-agent grid you can approve one agent without leaving the one you are typing in. No other terminal does this natively. cmux and herdr only point at the problem.

**(c) Changes, receipts, context.**

- Changes and the receipt live in the header (§5.2). Nothing is overlaid on terminal text.
- Context % and cost appear only if an agent reports them (`axolotty report-metadata`, roadmap §8.5). They go in the header state cluster's hover card, never at rest.

### 5.5 Changes popover (from the header's diff chip)

| Part | Spec |
|---|---|
| Surface | Opaque `elevated`, radius 12, padding 6, two-layer float shadow (§5 Surfaces). 380 wide, max 420 tall. Appears 6 pt below the chip with the palette's motion (160 ms from 98 % scale, 4 pt rise). |
| Header row | 34 tall: branch 13 semibold, `text3` "vs main" 12, trailing totals `+412 −96` 11 tabular. |
| File rows | 28 tall, radius 8 hover plates (inset 6). Program-style file glyph 12 · file name 13 `text` · parent path 12 `text3` (middle-truncated) · trailing `+n −m` 11 tabular in green and red at 0.85. |
| Actions | Row click: open in the user's editor. ⌥-click: run `git diff -- <file>` in a new split to the right, zoomed (it uses the user's pager and `delta` if present, so no diff engine is built). Footer row: "Open in Editor", plus "New Session to Review…" (starts the project's default agent with a review prompt). |
| Keyboard | ⌘⇧D toggles the popover; arrows and return as in every list. |

The deferred alternative is a right inspector column (Conductor ~335, Paradev ~530, herdr 368). It would cost 25–35 % of a 1x window and duplicate what agents already draw. Revisit only if users keep the popover open.

### 5.6 Signature

When an agent asks for you, its sheet's strip floods amber and every other sheet stays neutral grey. While agents work, a thin magenta line breathes at the top of their sheets.

A four-agent screenshot reads as a control desk: four dark screens in a warm frame, four vendor marks, two magenta progress lines, one amber strip with a question in it. That composition is Axolotty's equivalent of Warp's blocks and cmux's rings. It uses no glass and adds no lines.

### 5.7 Empty and new-session states

**No session (window empty)**, replacing `pass3-empty.png`. Centred in the stage, on a single sheet (the frame stays).

| Part | Spec |
|---|---|
| Mark | Axolotty mark at 40 in `accent` (critique.md change 9), or the current glyph until the mark exists. |
| Title | "Start a session" 20 semibold `text`, 16 below the mark. |
| Launch tiles | 20 below the title. One tile per installed preset (Shell, Claude, Codex, Gemini…): **88×72**, radius 12, `Surface(.rest)`, 10 gap. Vendor mark 24 centred at y 22, name 12 medium `text2` at y 50, digit 1–n 11 tabular `text4` at the top-right (8, 8). The keys 1–n launch. |
| Where | 16 below the tiles, a one-line target: project tile 16 + project name 13 `text2` + `chevron.up.chevron.down` 9. It is a pop-up of recent projects (hue tiles) plus "Open Folder…". The default is the last-used project. This is Codex's project pill and Cursor's repo chips. |
| Nothing else | No copy paragraph and no shortcut hints (they live in tooltips). |

**New session (first frame).**

- The sheet appears with the shell's ground immediately.
- Until the first byte arrives (usually < 100 ms), the header shows the project and title and nothing else.
- For agent presets, the header state cluster reads "Starting Claude…" with the spinner until the agent's first hook fires; then it reads "Working" or clears.
- No skeletons and no splash.

**Reconnecting** (remote host): existing behaviour (spinner replaces the mark, buttons dropped), inside the sheet.

### 5.8 One pane against two or three

**One pane (1180×760, sidebar open):**

```
┌───────────────────────┬────────────────────────────────────────────────────────────────────────────┐
│ o o o   [sb] [+]      │ [A] axolotty > design system  (br) main  +128 -14            (C) Working 4:12 │ band 40, frame tone
│                       │╭──────────────────────────────────────────────────────────────────────────╮ │
│ [T] tmp               ││==========                                   (2pt accent progress, OSC 9;4) │ │
│     [>] zsh           ││ * Claude Code                                                              │ │
│                       ││   Opus 5.5 · ~/axolotty                                                    │ │
│ [A] axolotty          ││                                                                            │ │
│  ##(C) design system  ││ > Implement the pane strip from agent-layout.md                            │ │
│     [>] build & test  ││                                                                            │ │
│     (G) refactor host ││ * Read Sources/AxMacUI/Panes/PaneContainerView.swift                       │ │
│                       ││ * Update PaneHeaderView.swift (+142 -0)                                    │ │
│ [S] slopty            ││   Thinking...                                                              │ │
│     (C) review        ││                                                                            │ │
│     [>] zsh           ││                                                                            │ │
│                       ││  sheet: bg, radius 10, text inset 14 / 10 / 8                              │ │
│                       ││                                                                            │ │
│                       │╰──────────────────────────────────────────────────────────────────────────╯ │
└───────────────────────┴────────────────────────────────────────────────────────────────────────────┘
  frame tone (sidebar + band + 6 pt right/bottom gutter); no hairlines anywhere
```

**Three panes (one tall left, two stacked right), with the bottom-right agent waiting and unfocused:**

```
│ [A] axolotty > refactor host protocol  (br) ax/host-proto  +412 -96        (C) Working 4:12 +1 [hover: split more] │
│╭──────────────────────────────────────────────╮ ╭─────────────────────────────────────────────╮ │
││=====                                (accent) │ │ [>] zsh  ~/ax                               │ │ strip 28, unfocused ink
││ (C) Claude  ~/ax/Sources        4:12 [z][x]  │ │ $ swift test --filter Pane                  │ │
││                                              │ │ Test Suite 'PaneTests' passed               │ │
││ * Update FramedConnection.swift (+88 -12)    │ │ $ _                                         │ │
││ * Running swift build...                     │ ╰─────────────────────────────────────────────╯ │
││                                              │ ╭─────────────────────────────────────────────╮ │ 6 pt gutter, nothing drawn
││                                              │ │#(X) Allow edits to Package.swift?        o # │ │ strip floods amber 0.16
││  focused: strip ink full, content undimmed   │ │# ................................................ │
││                                              │ │  (Codex TUI, dimmed 0.28)                   │ │
││                                              │ │ ┌─────────────────────────────────────────┐ │ │
││                                              │ │ │(X) Allow edits to Package.swift? [Allow][Deny]│ │ need bar 40, r8, inset 8
││                                              │ │ └─────────────────────────────────────────┘ │ │
│╰──────────────────────────────────────────────╯ ╰─────────────────────────────────────────────╯ │
```

**Legend.**

- `[A]` project hue tile
- `(C)` / `(X)` / `(G)` vendor marks (Claude / Codex / Gemini)
- `[>]` program glyph
- `(br)` branch glyph
- `##` selection plate
- `#` amber wash
- `=====` progress line
- `[z][x]` hover-only zoom and close

**Geometry at 1180×760 with the sidebar open:**

- Stage: 926×714.
- Two columns: 460 each.
- Right stack: 354 per sheet.
- Terminal columns: ≈ 58 per 460 pt sheet (SF Mono 13 ≈ 7.8 pt advance; estimate).

### 5.9 Motion summary

| Event | Motion |
|---|---|
| Sheet split or close | Existing spring relayout, with grids frozen until it settles. The new sheet fades from 0 → 1 over `swift` (200 ms) as it grows. |
| Strip appears (1 → 2 panes) | Height 0 → 28 inside the same spring. Text fades in over `tick`. |
| Needs-you | Strip wash 200 ms ease-out. Badge pop once (0.6 → 1.0, `pop`). No loop. |
| Progress | 1.1 s sweep; 250 ms fade on clear. |
| Receipt | Cross-fade from the state cluster over 200 ms; out over `tickOut` after 8 s. |
| Hover actions | 150 ms in; 400 ms dwell; 200 ms out. |
| Reduce Motion | All of the above become opacity only. The progress line is static. |

### 5.10 Build order (each step ships alone)

1. **Context header** in the band (§5.2). This is the largest visible change, and it builds only on data the app already has.
2. **Frame and sheets** (§5.1). Delete the sidebar seam and the pane hairline.
3. **Pane strip**, with the amber needs-you wash replacing the inner stroke (§5.3).
4. **Progress line** from OSC 9;4 (§5.4a); it needs the VT parser to surface 9;4.
5. **Empty state** with launch tiles and a project pop-up (§5.7).
6. **Changes popover** (§5.5).
7. **Receipt** (§5.2). It needs a working → done edge with timestamps, plus a git numstat at that moment.
8. **Need bar** with Allow / Deny (§5.4b), gated on known agent keys.

### 5.11 What not to copy

- **Composers.** The agent's TUI is the composer. Codex, Claude, Cursor and Factory need one because they are not terminals.
- **Transcript minimaps, tool-call accordions, inline diffs.** The TUI owns its transcript.
- **Right inspector columns at rest** (Conductor, Paradev, Devin). Too costly at 1x.
- **Accent borders for focus** (herdr, Wave, Paradev) and Warp's corner triangle.
- **Stacked strips** (Paradev 48 + 36 + 28).
- **Status bars, mono chips as costume, coloured thread titles.**

---

## 6. Local measurements (detail)

**Warp 0.2026.10.21** [m]

- **Captures:**
  - `/tmp/agent-layout-study/warp-now.png`: the user's existing window, captured only.
  - `warp-split2.png`, `warp-split2-sticky.png`, `warp-split3.png`: a new window I opened at the project and closed afterwards.
- **Titlebar:** 36, hairline at y 35 `(49,52,55)` on `(29,32,34)`.
- **Pane headers:**
  - With one pane, there is **no pane header**.
  - With 2 or more, the header is ~34 (y 36–69): a centred title of ~12 in `(148,156,161)` (≈ fg 0.55 over the ground), ⋮ and × at the right, no rule under it.
- **Focused pane:** a 13×13 accent-blue corner triangle at top-left `(108,150,180)`.
- **Unfocused panes:** not dimmed. Text peaks at 228–245 in all panes.
- **Dividers:** pane divider 1 px `(59,63,65)`. The input separator is fainter: `(40,43,45)` at the block-list edge and `(49,52,55)` above the input.
- **Input area:** ~88 tall, with chips ~20 tall (folder path, branch, `343 • +42037` diff).
- **Blocks:** a block header in ~12 mono grey (`cwd git:(main) (0.103s)`).
- **Sticky command header:** pins to the top of the pane on scroll, with a hairline under it (`warp-split2-sticky.png`).
- **Titlebar diff chip:** `± +42037 −0` at the right of the titlebar.
- **Empty pane:** a blank ground with the input at the bottom.
- **Not captured:** Warp's agent mode, because AI menu items are disabled on this install.

**Ghostty 1.4.0** [m][src]

- **Captures:** `/tmp/chrome-study/ghostty/g1–g3.png` and `/tmp/agent-layout-study/ghostty-now.png`. The user's window was captured only; it was blank because its screen was cleared.
- **Split divider:** 1 px `(24,26,31)` on ground `(40,44,52)`, so the divider is darker than the ground.
- **Unfocused split:** text peaks at `(190,191,194)` against `(255,255,255)` focused, an exact match for `unfocused-split-opacity = 0.7` with the fill = background (`ghostty +show-config --default --docs`).
- **Titlebar and window defaults:** `macos-titlebar-style = transparent`, `window-padding-x/y = 2`, `bell-features = no-system,no-audio,attention,title,no-border`.

**Axolotty** [m]

- **Capture:** `.impeccable/baseline/now-dark.png`.
- **Grounds:** sidebar `(16,14,15)`, seam `(30,28,29)`, terminal `(21,18,20)`, pane hairline `(35,32,34)` starting at y 40.
- **Unfocused pane:** text peak 0.72 of focused.
- **Band:** empty over the content; first glyph at y ≈ 66.

**Otty** [src] (`/Volumes/Lacie/Workspace/oss/otty-reversed/Docs/05`, `06`, `07-interactions-animations.md` §1, §7–§12)

- **Titlebar:** title 13 `secondaryLabelColor` centred; chrome buttons 28×24; hover-reveal 0.15 s, dwell 0.4 s, fade 0.2 s.
- **Panes:** unfocused alpha 0.6; divider 1 px fg 0.08, 2 px on hover over 0.16 s; relayout 0.2 s.
- **Composer:** pushes the terminal up (0.18 s ease-out in, 0.14 s ease-in out); default height 240.
- **Prompt queue:** card r12 with border fg 0.18 and bg `mix(bg, fg, 0.10)`; input bar 36 r8, bg `mix(bg, fg, 0.08)`; inset 12; reserved space is the content height + 24.
- **Mode pills:** 20 tall, r6, right margin 8, instant show/hide.
- **Indeterminate bar:** 0.3 × track, 0.8 s.
- **Transcript:** sticky user headline.

**CodexMonitor** [src] (`/Volumes/Lacie/Workspace/oss/CodexMonitor/src`)

- **Topbar:** 40 min, padding 8 / 20 / 6, 1 px `border-subtle`, sticky with a backdrop blur.
- **Title:** 14/600; branch 12/600 in a pill-button.
- **Composer meta bar:** context ring (`ComposerMetaBar.tsx`).
- **Working indicator:** inline with elapsed time (`Messages.tsx` `WorkingIndicator`).
- **Approvals:** a centred card `min(460px, 100vw−48)` (`approval-toasts.css`), the anti-pattern noted in P7.
- **Capture:** `/tmp/agent-layout-study/codexmonitor-readme.png`.

---

## 7. Sources

**Premium agent apps.**

- **Bundle analysis (Codex, Claude desktop):** `.research/wow/re-electron.md` §1.3–1.4 and §2.3–2.4
- **Codex:**
  - https://openai.com/index/introducing-the-codex-app/
  - https://learn.chatgpt.com/docs/app.md
  - https://learn.chatgpt.com/docs/code-review.md
  - https://learn.chatgpt.com/docs/codex-manual.md
  - Video: https://cdn.openai.com/devhub/videos-learn/proactive-teammate-v2-1080p-v1.mp4
  - Captures: `web/codex_vid_window_full.png`, `codex_vid_filechanged_card.png`, `codex_vid_sidepanel_browser.png`, `/tmp/sidebar-study/codex/built.png`, `/tmp/sidebar-study/codex2/mini.png`
- **Claude desktop:**
  - https://code.claude.com/docs/en/desktop.md
  - https://claude.com/blog/claude-code-desktop-redesign
  - https://www.youtube.com/watch?v=rWaQSQEm_aY
  - https://www.youtube.com/watch?v=omihvjf0A2k
  - Captures: `web/claude_redesign_split.png`, `claude_redesign_panes.png`, `claude_projects_split.png`, `claude_projects_t_sheet.png`
- **Zed:**
  - https://zed.dev/docs/ai/agent-panel
  - Source: github.com/zed-industries/zed (`crates/ui/src/utils/constants.rs`, `assets/settings/default.json`)
  - Captures: `/tmp/sidebar-study/zed/parallel-agents_layout.png`, `terminal-threads_running-threads.png`
- **Conductor:**
  - https://www.conductor.build
  - https://docs.conductor.build/core/diff-viewer
  - https://www.conductor.build/changelog
  - Captures: `/tmp/sidebar-study/conductor/hero-dark.png`, `/tmp/sidebar-study/conductor2/new-workspace.png`
- **Cursor 3:**
  - https://cursor.com/changelog/3-0
  - https://cursor.com/changelog/3-1
  - Captures: `web/cursor_mux1_t4.png`, `cursor_mux3_t4.png`, `cursor_mux_sheet.png`
- **Warp:**
  - docs.warp.dev: /terminal/windows/split-panes, /terminal/appearance/pane-dimming, /agents/capabilities/agent-notifications, /code/code-review, /terminal/windows/configurable-toolbar
  - Captures: `web/warp_agent-modality-conversation-view.png`, `/tmp/sidebar-study/warp/multi-agents.png`, and the local captures in §6
- **Charm Crush:**
  - github.com/charmbracelet/crush (`internal/ui/model/ui.go`, `header.go`, `sidebar.go`, `status.go`)
  - Captures: `web/crush_demo_last.png`, `crush_demo_f60.png`
- **Devin:**
  - https://docs.devin.ai/get-started/devin-intro
  - https://docs.devin.ai/work-with-devin/devin-session-tools
  - Captures: `web/devin-intro-t88.png`, `devin-intro-t105.png`, `devin-tools-0.3.png`
- **Emdash:**
  - https://github.com/generalaction/emdash
  - https://emdash.com/changelog
  - https://emdash.com/blog/public-v1-beta
  - Captures: `web/emdash-changelog-v1prod.png`, `emdash-hero-light.png`
- **herdr-app:**
  - https://github.com/herdrdev/herdr-app (`defaults/layouts/main.json`)
  - herdr.dev
  - Captures: `web/herdr_site_app_mock.png`, `herdr_site_viewport.png`
- **opencode:** github.com/anomalyco/opencode (`packages/app/src`, `session-identity-header.css`, `session/requests/*-dock.tsx`); capture `web/opencode_app_e2e_session-project-menu.png`
- **Amp:**
  - https://ampcode.com/news/amp-on-ios-and-macos
  - https://ampcode.com/news/agents-everywhere
  - https://ampcode.com/news/agents-in-orbs
  - https://ampcode.com/news/agents-panel
  - Captures: `web/amp_macos_full.png`, `amp_newlook_sheet.png`
- **Factory:** https://factory.com/news/working-with-droid-in-the-desktop-app; captures `web/factory_window_openpanel.png`, `factory_paneltabs_sheet.png`
- **Jules:**
  - https://jules.google/docs/
  - https://jules.google/docs/review-plan/
  - https://jules.google/docs/changelog/
  - Captures: `web/jules-plan.png`, `jules-done.png`
- **Sculptor:** https://github.com/imbue-ai/sculptor and https://imbue.com/sculptor/; captures `web/sculptor_chat_panel.png`, `sculptor_agent_tabs.png`
- **Paradev:** https://github.com/ParadevAI/Paradev (`packages/panes/...`, `TabBar.tsx`, `PaneHeader.tsx`, `Pane.tsx`); captures `web/paradev_diff-viewer.png`, `paradev_readme-hero_3s.png`
- **Kiro:**
  - https://kiro.dev/
  - https://kiro.dev/crew/
  - https://kiro.dev/docs/specs/
  - Captures: `web/kiro-session-pr.png`, `kiro-ide-spec-task-11.png`
- **Trae SOLO:** https://docs.trae.ai/ide/solo-mode and https://docs.trae.ai/ide/multitasking; captures `web/trae-solo-ui.png`, `trae-solo-multitask.png`
- **Jean:** https://github.com/coollabsio/jean and https://jean.build; captures `web/jean-worktrees.png`, `jean-diff-review.png`
- **Nimbalyst:** https://nimbalyst.com (demo video); captures `web/nimbalyst_demo_t15.png`
- **Goose:**
  - https://goose-docs.ai/
  - https://github.com/aaif-goose/goose
  - https://goose-docs.ai/blog/2026/04/08/goose-acp-and-new-tui
  - Captures: `web/goose-neighborhood-cart.png`

**Terminals and protocols.**

- **cmux:** https://github.com/manaflow-ai/cmux and https://github.com/manaflow-ai/bonsplit (`TabBarMetrics.swift`, `GhosttyConfig.swift`, `PanelOverlayRingMetrics`); capture `/tmp/sidebar-study/cmux/notification-rings.png`
- **Wave:** github.com/wavetermdev/waveterm (`frontend/app/theme.scss`, `block.scss`); capture `web/wave_hero.png`
- **Ghostty:**
  - Config reference via `ghostty +show-config --default --docs` (1.4.0)
  - https://ghostty.org/docs/install/release-notes/1-2-0 (OSC 9;4 progress bars)
  - https://github.com/ghostty-org/ghostty/discussions/10710
- **Claude Code OSC 9;4:**
  - https://claudeissues.com/issue/55111-bug-osc-9-4-progress-bar-clears-during-tool-execution-instead-of-staying-visible
  - https://claudeissues.com/issue/57366-bug-terminalprogressbarenabled-osc-9-4-doesnt-work-inside-tmux
- **Dimming defaults:** WezTerm `inactive_pane_hsb` (s 0.9, b 0.8) and kitty `inactive_text_alpha` (1.0) are from their official config docs. They are mentioned only for the dimming norm.

**Local.**

- Otty: `/Volumes/Lacie/Workspace/oss/otty-reversed/Docs/` (01, 05, 06, 07) and `/tmp/sidebar-study/otty/*.png`, `/tmp/chrome-study/web/o_sheet.png`
- CodexMonitor: `/Volumes/Lacie/Workspace/oss/CodexMonitor/src/styles/{main,base,composer,approval-toasts}.css`, `features/composer/components/ComposerMetaBar.tsx`
- Axolotty source:
  - `Sources/AxMacUI/Chrome/BandView.swift`, `Chrome/StatusBarView.swift`
  - `Panes/PaneContainerView.swift`
  - `Terminal/TerminalView.swift` (attention stroke, lines 113, 360–376)
  - `Design/Axo.swift` (metrics)
