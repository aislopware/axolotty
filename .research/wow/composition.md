# Axolotty: window composition study

- **Date:** 2026-11-02.
- **Question:** what makes the most admired apps in Axolotty's own domain feel premium at the level of window composition and layout, and what should Axolotty's window become.
- **Scope:** composition only. That means figure and ground, the top band, columns, the heading, the signature element, how colour is placed, and empty states. Widget polish is out of scope because it is already done.
- **Companion files** in `.research/wow/`:
  - `critique.md`: an independent critique of the baseline.
  - `agent-layout.md`: the content-area proposal.
  - `re-electron.md`: exact values from the Codex and Claude desktop bundles.

  This file was reconciled against `re-electron.md`; where a screenshot estimate disagreed with a bundle value, the bundle value wins. `re-orchestrators.md` and `re-native.md` did not exist when this was written; if they disagree with a `~` value here for those apps, theirs wins.

**Notation for numbers:**

| Mark | Meaning |
|---|---|
| **[re]** | Exact, from a shipped bundle (`re-electron.md`). |
| **[m]** | Measured by me with per-pixel sampling, from a 1x capture or from an official image at a known scale. The scale comes from the traffic-light pitch (20 pt between dot centres). |
| **~** | Estimated from an official image or video frame, ±2 pt. Video frames also carry compression error in hex values (about ±2/255). |
| **ΔL** | The tone step between two surfaces, in OKLab lightness × 100. A step under ~2 is invisible at a glance; 3–5 reads as "a different surface". |

---

## 0. Verdict

The baseline is not generic because of any widget. It is generic because it has **no figure**:

- **Sidebar against terminal is ΔL 2.0.** Sidebar `#100e0f` against terminal `#151214`; in contrast terms that is 1.03:1 (critique.md RC1).
- **The 40 pt band is painted in the terminal's own ground and is empty.** It reads as rows the terminal failed to print. The first text starts at y = 70.
- **Two 1 px lines do all the structuring.** One of them starts at y = 40 and the other at y = 0.

Every app in the premium tier below makes one surface the obvious **object**, using radius, inset and a 3–5 ΔL step. Every one of them also puts **the name of what you are looking at in the top band**.

Axolotty does neither, so a screenshot reads as "Ghostty with a Finder sidebar".

**Recommendation: replace principle 1.**
- **Current principle 1:** "the terminal is the window: no card around the terminal".
- **Replacement:** "the window is a frame; each terminal is a sheet set in it."
- **Frame:** one tone for the band, the sidebar and the gutters.
- **Sheets:** the terminal's own `bg`, radius 10, inset 6, no line anywhere.
- **Band:** the band becomes the context line, `[project tile] project › [agent mark] session`, plus live state.

This is Direction A in §4.

---

## 1. Which apps set the premium bar, and why

The bar is set by design reception, launch-post praise and visible craft, not by popularity. The owner ruled out generic Mac apps (Slack, Xcode, Proxyman, VS Code, Raycast, Things and so on). Two local captures, VS Code and Slack, are kept in §2 only as transfer evidence, labelled as such.

### Tier 1: the bar

| App | Why it is the bar |
|---|---|
| **OpenAI Codex app** | Now also the ChatGPT desktop app (since 9 July 2026). It is the most polished agent workspace shipping. Its token model is the same as ours (derived from bg and ink, plus one contrast scalar) [re]. It ships a second, **inset-card "page surface" layout** behind a feature gate [re], so OpenAI's own design team is moving this way. |
| **Claude desktop, Code tab** (April 2026 redesign) | A warm grey ramp, its own type families, and an explicit surface ladder [re]. Its panes sit in an 8 pt inset with radius-10 panel cards [re]. A mascot is its empty state. |
| **Factory desktop** | The strictest monochrome in the set. Orange appears only on live work. Of all the shots, it has the clearest type rhythm. |
| **Conductor** | The best-regarded orchestrator. It is warm near-black with state colour only on PR status. Its band carries tabs, PR state and the primary action. |
| **Dia** | The canonical "content card on a tinted canvas". Its chrome takes the theme colour and its headings use an editorial serif. |

### Tier 2: strong, with one idea worth taking

| App | Idea worth taking |
|---|---|
| **Kiro (Crew)** | The only app in the set where every column is a card on a canvas. |
| **Cursor 3 agents window** | Tone-only column edges. A rich title band. |
| **Sculptor** | Warm paper tones. Title plus branch chip in the band. |
| **Warp ADE** | The densest polished agent terminal. |
| **Otty** | The closest native relative of Axolotty. It ships a "Floating Card" theme. |
| **Amp** | A per-thread planet glyph. |

### Tier 3: useful precedents, not the bar

| App | Note |
|---|---|
| **cmux** | Native, on libghostty, the closest technical sibling. Practical rather than beautiful. |
| **Zed agent panel** | Dense IDE layout. |
| **Emdash** | Clean three columns. |
| **Granola** | Partial shot only. |
| **Crush** | A TUI, but one owned gradient rule. |
| **Long tail** | Nimbalyst, Jean, Vibe Kanban, Wave, Paradev, herdr, opencode: busy or utilitarian. |
| **No usable official window image** | Perplexity Mac, Comet, Jules, Goose, Windsurf, Trae SOLO, Devin. |

**Ghostty** is kept as the terminal-craft baseline. It is full-bleed with an 8 pt padding and a transparent titlebar showing the window title, and nothing else (local config: `window-padding-x/y = 8`).

---

## 2. Measured comparison

All values are at 1x. "Sheet" means a rounded content surface inset from the window edges.

| App (tier) | Composition | Sheet radius / insets / edge | Canvas vs content tones (ΔL) | Top band: height and contents | Sidebar: width (% of window), tone, separator | Heading and type scale | Signature | Colour |
|---|---|---|---|---|---|---|---|---|
| **Axolotty baseline** [m] | Full-bleed; band shares the terminal's ground | none | Sidebar `#100e0f` darker than terminal `#151214` (**ΔL −2.0**) | 40, **empty** apart from toggle and "+". Title only appears when the sidebar is hidden | 248 (21 %), darker, 1 px `#1e1c1d` from y 0; pane split 1 px `#232022` from y 40 | No heading. One size (13), project vs row by weight only | none | Accent appears only on the caret (critique RC2) |
| **Codex: classic** (T1) [re] | Full-bleed, sidebar on vibrancy or opaque | none | Dark: sidebar `#141414`, main `#181818` (ΔL −1.8). Light: `#f6f6f6` vs `#ffffff` (−2.7) | 46. Toggle, back/forward, **thread title**, actions (open-in, diff panel) | 275 default (240–520), 0.5 px seam at 1x = 1 px | Sidebar head "Codex ▾" ~18 semibold; rows 13/430 weight; empty headline ~28 | Blossom mark, composer radius 22 | Blue unread dot, green approval pill, diff colours |
| **Codex: page surface** (T1) [re] | **One inset sheet** | **r12**, insets right 4, bottom 4, top = titlebar 44, left butts the sidebar (the sidebar ground runs 16 px under the corners). Edge `0 0 0 .5px` border-strong at 4–6 % plus `0 4 16 #0000000d` | Shell ground (sidebar and band) vs `--color-surface` card | 44, on the shell ground | On the shell ground, **no seam** | as above | The inset white sheet plus icon rail in marketing (`web-codex-hero.png`) | as above |
| **Claude desktop / Code** (T1) [re]+~ | Flush sidebar; **content inset 8**; panes and right-column panels are cards | Panel r10 (12 comfortable), panel inset and gap 8; frame-card variant inset 8, r8 (fallback) | Dark ladder: `#0b0b0b` (surface 0), sidebar `#111111`, page `#151515`, **terminal or panel `#1a1a19`**, composer `#20201f`. That is about 2 ΔL per step and 3.9 from sidebar to panel. Light `#f9f9f7` / `#fcfcfb` / `#fff` | 48. **Breadcrumb "acme-web / Build the alignment grid demo"** (~13; project dim, session bright), pane icons on the right | 288 (24 %), 0.5 px seam at 10 % ink | Title 20/25, body 13/19; custom sans with lighter weight in dark | **Clawd pixel mascot** in clay `#d97757` as the empty state | Clay only on the mascot; amber awaiting, blue ready |
| **Factory desktop** (T1) ~ | Full-bleed | none | Warm near-black: sidebar `#0e0c0b`, content `#0f0d10` (ΔL ~0.7), hairline only | ~28. **Session title in bold + project in grey** + "⋯" | ~20 %, hairline | Plan steps as bold rows with orange bullets; tool calls indented with icons | **Orange `#ed5c19` live bullets** and send square | Orange only for live state |
| **Conductor** (T1) [m] | Full-bleed, 3 columns | none | Dark: sidebar `#1b1918` **lighter** than chat `#13110f` (**ΔL +3.6**); light: `#fcfbfc` / `#fdfdfd` / `#fff` | 39 + hairline. Session tabs; **PR "#8376 · Ready to merge"** on a green-tinted strip; green Merge | 255 (18 %), 1 px hairline | Body ~14 | Right panel: changed files with diff stats; Run pane "Start Dev ⌘R" | Green only for merge state |
| **Dia** (T1) ~ | **Content card on a tinted canvas** | r~8, insets top/bottom ~5, right ~6.5, left 0 (butts the sidebar), no border | Canvas = theme colour `#f5e7bd`; card `#fef9ed` (ΔL 5.4) | 36, **inside the card**: nav + breadcrumb "Dia / Prep for my CMO 1:1" | ~169 (19 %), on the canvas, **no separator** | Editorial serif-italic headings | Theme-tinted chrome, orb | Chrome takes the theme hue |
| **Kiro Crew** (T2) [m, 2x] | **Every column a card on a canvas** | r~16, inset 10–11, gap 10, 0.5 pt border `#342f3c` | Canvas `#18161c`, cards `#201d24` (ΔL 3.2), plus border | 53. Environment tabs (active pill tinted purple + count), centred ⌘K search, bell | Icon-rail card 70 + sessions card ~422 (26 %) | "Sessions" ~15; two-line rows (project small above, title 14) | Ghost avatar tile; purple on every live state | Violet-tinted greys, purple accent |
| **Cursor 3 agents** (T2) ~ | Full-bleed | none | Light: sidebar `#e8e8e8` vs chat `#fcfcfc` (ΔL 6), **tone edge only, no line** | ~34. Chat title; diff stat, "Local / main" chips, black **Commit & Push** | 221 (16 %) | Repo group labels small and muted | Black primary button; todo card at the head of the chat | Diff tints only |
| **Sculptor** (T2) ~ | Full-bleed, 3 panes | none | Warm paper: sidebar `#f9f7f2`, content `#f2f0e7` (content darker), right panel `#fbf9f3` | ~37. **Task title + mono branch chip**, Merge and Sync on the right | ~314 (23 %), hairlines | Two-line rows: title, "Just now – branch" | Green sync chip | Green for status only |
| **Warp ADE** (T2) ~ | Full-bleed split, no sidebar | none | Agent pane `#272a2c`, doc pane `#1e2022` | 35. Tab pill with magenta dot, "Code review", avatar | — | Doc headings ~20 semibold; task headings mono ~16 | Floating "Tasks 4/9" checklist; chip row (path, branch, ±, model) | Magenta brand dot, diff green |
| **Warp, local** [m] | Full-bleed | none | Sidebar `#262a2c` **lighter** than panes `#1d2022` (ΔL +4.1); 1 px seams `#313437`/`#3b3f41` | 36. Centred search field | 249 (19 %) | Per-pane 30 pt title strip | Block headers | ANSI only |
| **Otty default** [m, 2x] | Full-bleed | none | Light: sidebar `#f5f4f0`, terminal `#fcfbfa` (ΔL 2.2), 1 pt hairline `#e0dfd5` | ~38. **Centred session title** over the terminal column | 220 (22 %) | "TABS" label; rows 13 with trailing kind ("zsh") | Live badges (hand = waiting, spinner) | Near none |
| **Otty "Floating Card" theme** [src: `theme-template.toml`] | **Terminal as a floating rounded card** | r8, margin top 4 / right 16 / bottom 16 / left 16, 1 px `#e5e5e5`, Tailwind shadow-md; padding 8/16 | Card `#fff` on window backdrop (glass in their version) | Titlebar shares the one backdrop | Sidebar `border-right: none` "so the card appears to float freely" | — | — | — |
| **cmux** (T3) [m, 2x] | Full-bleed, Ghostty theme | none | Sidebar = terminal `#272823`, 1 pt hairline `#363731` | ~30. Toggle, bell with badge, "+", back/forward. **Each pane has a ~27 pt bold title row** | 356 (19 %) | Workspace title bold + PR line + branch/path lines | **Selected workspace as a solid blue `#3f8ff7` card** (r~6, ~93 tall) | System blue only |
| **Amp** (T2) ~ | Full-bleed teal-black | none | `#0c1617` everywhere, hairline | ~30. Nav, search, white compose button; thread title + actions on the right | ~283 (17 %) | Rows 13 | **Per-thread planet glyphs** | Teal-black ground |
| **Zed agent** (T3) ~ | Full-bleed, docked panel | none | Panel `#373a42` vs editor `#2e3139` | 32 + 30 tab bar | — | "New Thread" header | — | Syntax only |
| **Emdash** (T3) ~ | Full-bleed, 3 columns | none | `#111111` / `#191919` | ~34. **Breadcrumb "electron-app / fix-navigation"** | ~20 % | "PROJECTS" label with folders | Agent tabs with vendor marks | Vendor marks only |
| **Ghostty** (baseline) [m] | Full-bleed | none | — | Transparent titlebar, window title | — | — | — | Theme |
| *VS Code 1.10x (transfer only)* [m] | **Side bar and editor as separate cards** | r~6, inset 4, gap 4–5, 1 px `#e3e5e6` | Canvas `#fafafd`, cards `#f7f7f7`/`#fff` | 35, command centre | — | — | — | — |
| *Slack (transfer only)* [m] | **Workspace as an inset card on the theme canvas** | r~8–9, top 40, gap 4, no border | Canvas `#504f51`, card `#fff` | 40, history + search | 70 rail on the canvas | "Activity" ~18 bold | Aubergine canvas | Theme canvas |

### Notes on the table

- **Codex dark has the smallest step in the set (ΔL 1.8)**, about the same as Axolotty's (2.0). Yet Codex reads as a sheet and Axolotty doesn't. The difference is geometry: radius 12, a 4 pt gutter showing on two sides, and a 0.5 px ring.
- **The step can be tiny when shape carries the edge.** Tone alone needs ΔL ≥ 3.5 to read (Conductor 3.6, Warp 4.1, Dia 5.4, Cursor 6).
- **Which side is lighter, in dark mode.** Among premium dark examples, the chrome is the lighter surface and the content is the deepest: Conductor, Warp, Claude Code's sidebar card (`#0a0a0a` over a `#030303` content, ~video), and Zed.
- **Exceptions:** Codex (canvas darker) and Kiro (canvas darker, cards lighter).
- **Light mode:** every light example puts the content at the brightest value (Codex, Dia, Cursor, Otty).
- **The common rule** is "content at the extreme, chrome one step toward the middle". That is `mix(bg, fg, t)` in both modes. It is also the only rule that still produces a step on near-black themes, where mixing toward black has nowhere to go.

---

## 3. The patterns that separate premium from generic

### P1. One surface is the object: a sheet set in a frame

**Apps:**

| App | Treatment |
|---|---|
| Codex page surface | r12, gutter 4 [re] |
| Claude | 8 inset, r10 panels [re] |
| Dia | r8, gutter ~5–6 |
| Kiro | r16, gutter 10 |
| Otty Floating Card | r8, margin 4/16/16/16 |
| herdr | r10, gap 8 (agent-layout.md) |
| Transfer evidence | VS Code and Slack (r6–9, gutter 4) |

**Counter-examples:** Conductor, Cursor, Factory and Sculptor are full-bleed with hairlines or tone edges. Each has one transcript per window, not a grid of terminals. All of them still pass the figure test through a ΔL ≥ 3.5 column step, which Axolotty doesn't have.

**Why it works:**
- A radius turns a region into a thing. The gutter is a divider that costs no ink.
- Once the content is an object, the chrome around it can be quiet and still read as deliberate rather than missing.

### P2. The top band names what you're looking at

Every tier-1 app puts a context line in the band, **even with the sidebar open**:

| App | Band contents |
|---|---|
| Claude | `project / session` breadcrumb, 48 [re] |
| Codex | thread title, 44–46 [re] |
| Factory | bold title + grey project, ~28 |
| Conductor | tabs + PR state + Merge, 39 |
| Sculptor | title + branch chip, ~37 |
| Cursor | title + diff stat + branch + Commit, ~34 |
| Emdash | `project / branch`, ~34 |
| Dia | breadcrumb inside the card, 36 |

Heights run 28–53, median ~38.

**Axolotty:** 40 pt and empty. The title appears only when the sidebar is hidden, under "say a thing once".

**Why it works:** the eye rests on the content, and the band is the first line of it. A named band also turns 40 pt of dead ground into a header, which is what makes the empty band read as missing (critique.md RC1).

### P3. The chrome sits on one ground

**Apps:**
- **Codex page surface:** the titlebar and sidebar share the shell ground, and the sidebar ground runs under the card's corners [re].
- **Dia:** the sidebar and band are the canvas.
- **Otty:** "the sidebar, titlebar, and the margin strip around the card all share this one backdrop" (theme-template comment).
- **Kiro:** canvas behind everything.

**Axolotty** does the opposite. The band is painted as terminal while the sidebar runs a different tone to y = 0, so chrome and content interleave.

**Why it works:** two planes, chrome and content, is the minimum that reads as composed. Three half-planes reads as accidental.

### P4. Separate with space and tone; at most one line, at 0.5 pt

**Apps:**
- **Codex:** seam 0.5 px, or none in page surface [re].
- **Claude:** 0.5 px seam, panels separated by an 8 gap [re].
- **Dia:** no separator.
- **Cursor:** tone only.
- **Kiro:** gaps of 10.

**Axolotty:** two 1 px lines of different lengths (critique.md RC1).

**Why it works:**
- Lines are the cheapest structure, and they read as cheap.
- Gaps scale with the grid and give every pane the same edge.
- This matches the owner's "few, elegant dividers".

### P5. One owned signature object

| App | Signature |
|---|---|
| Claude | Clawd, the clay pixel mascot that **is** the empty state |
| Codex | Blossom mark above "What should we build?" (~28), radius-22 composer |
| Factory | Orange live bullets |
| cmux | Blue selected-workspace card |
| Kiro | Ghost tile plus purple live text |
| Amp | Per-thread planet glyphs |
| Dia | Theme-tinted chrome plus serif italic |
| Crush | One hatched gradient rule |
| Conductor | Merge strip |

**Axolotty:** none. There is no app mark in `Sources/` (critique.md §1); the only brand pixel is the caret.

**Why it works:** a screenshot needs one thing the viewer can name. In every case that thing is either *the brand at rest*, a mascot or mark in the empty space, or *the live state drawn large in one hue*.

### P6. One live hue, drawn where the state is, at a size you can see

**Apps:**
- **Factory:** orange bullets on running steps.
- **Kiro:** "Thinking…" and "Loop 0/24" in purple text.
- **cmux:** a whole blue card for the selected workspace, plus notification rings on panes.
- **Codex:** approval and input pills 20 tall [re].
- **Claude:** amber awaiting dot plus the approval card docked in the pane [re].
- **Conductor:** green merge strip in the band.

**Axolotty:** the working spinner is neutral grey. The waiting and failed signals are 6 px dots, 0.004 % of the window (critique.md RC2/RC3).

**Why it works:** chroma in an otherwise neutral window is the focal point, so it has to be the most important fact, and the right size for it.

### P7. Hierarchy has a head

**Apps:**
- **Codex:** sidebar head ~18 semibold; empty headline ~28.
- **Claude:** title 20/25 [re].
- **Warp:** doc headings ~20.
- **Granola:** serif ~21.
- **Kiro:** two-line rows with the project as a small kicker over a 14 title.

**Axolotty:** one size (13), with project and session differing only by weight.

**Why it works:** without a head there is no entry point. For Axolotty the composition-level fix is the band breadcrumb with the project tile. It puts the project where the eye is, meeting "projects prominent" without inflating the sidebar.

### P8. Low-content states are anchored

**Apps:**
- **Empty states with a centred mark, one line and one action:** Claude (mascot plus composer with chips), Codex (mark, headline, three suggestions, composer), Dia (orb plus "Ask anything" card), opencode (logotype plus input), Conductor ("▶ Start Dev ⌘R").
- **Sidebars anchored at the bottom:** Claude (org plus theme toggle), Cursor (user and org), Factory (user), Amp (online avatars plus nav), Codex (a "Projects" section).

**Axolotty:**
- The sidebar ends at "zsh" around y = 320, leaving 440 pt of void.
- The empty state is a generic glyph with two buttons (critique.md RC4).

**Why it works:** an anchored bottom edge makes a short list look intentional instead of unfinished.

### Dark and light, briefly

**Dark:**
- The premium dark apps are warm near-black, not blue-grey:
  - Claude: `#151515`, a warm grey ramp.
  - Conductor: `#13110f`.
  - Factory: `#0f0d10`.
- Axolotty's mauve-tinted `#151214` is in good company.
- Dark mode looks best when the content is the deepest plane: Conductor, Claude Code's sidebar card, Warp.

**Light:**
- The light shots that feel premium are the warm-paper ones:
  - Sculptor: `#f2f0e7` / `#f9f7f2`.
  - Otty: `#f5f4f0` / `#fcfbfa`.
  - Granola: `#f7f8f3`.
  - Dia: the theme canvas.
- Codex light is the exception: pure `#fff` on `#f6f6f6`.
- Light mode is where a sheet on a canvas reads strongest: Codex, Dia, Otty Floating Card, Slack.

---

## 4. The baseline against those patterns

| Pattern | Baseline | Why it reads generic |
|---|---|---|
| P1 Object | No sheet; ΔL −2.0 between columns | Nothing to look at; the window is one slab. Ink coverage is 3.3 % (critique.md). |
| P2 Named band | 40 pt, empty, in the terminal's ground | Looks like unprinted terminal rows. The first text is at y = 70, i.e. 9 % of the height is dead before anything is said. |
| P3 One chrome ground | The band belongs to the terminal and the sidebar to itself | Three half-planes: the sidebar column, a band fused to the terminal, and the terminal. |
| P4 Separation | 1 px seam from y = 0; 1 px pane split from y = 40 | Two lines of different lengths look cut off, not placed (critique.md RC1). |
| P5 Signature | None | Remove the vendor marks and the screenshot is any terminal. |
| P6 Live hue | Accent only on the caret; working is grey; attention is a 6 px dot | The most important fact is the smallest mark. |
| P7 Head | No heading; one type size | No entry point for the eye; projects don't lead. |
| P8 Anchored | Sidebar void below y ≈ 320; no footer | Looks unfinished at low session counts, which is the first-run state. |

**What "the terminal is the window" got right:**
- Terminals are where the pixels go: 79 % of the width.
- Ghostty proves full-bleed is right for a *single-terminal* app.

**What it gets wrong for Axolotty:**
- Axolotty's units are the **project** and the **agent**, and a window shows several terminals.
- Full-bleed with hairlines is what the tier-3 tools do. Every tier-1 app either makes one surface an object (Codex, Claude, Dia) or gets a ΔL ≥ 3.5 column step plus a named band (Conductor, Factory). Axolotty has neither.

---

## 5. Composition directions

**Notation:**

| Symbol | Meaning |
|---|---|
| `bg`, `fg` | The theme's terminal background and foreground |
| `mix(a, b, t)` | sRGB blend from a toward b |
| ΔL | Measured on the default dark theme (`#151214` / `#EBE6EA`) and light theme (`#FCF9FB` / `#2A2429`) |

**Facts all three directions share:**
- Window default 1180×760.
- Band 40 (fits the measured 34–48 range; keep it).
- Sidebar 248.
- Window corner ~16 at 1x.
- **No glass.** Every surface is opaque.

**What `mix(bg, fg, 0.05)` gives on each theme** (computed):

| Theme | Result | ΔL vs `bg` |
|---|---|---|
| Axolotty dark | `#201d1f` | **+4.8** |
| Axolotty light | `#f2eef0` | **−3.2** |
| Dracula `#282a36` | | +3.9 |
| Catppuccin Mocha `#1e1e2e` | | +3.8 |
| Pure black | `#0d0d0d` | +16 (sRGB mixing near black is steep, which is the right direction) |

`agent-layout.md` §5.1 picks 0.06 (ΔL +5.7 dark, −3.9 light). Both values sit inside the measured premium range (Conductor 3.6, Claude Code ~4.8, Dia 5.4). I'd take **0.05** as the floor and let 0.06 be the light-mode value if 0.05 looks too faint at 1x.

### Direction A: Frame and sheets (recommended)

Codex page surface, plus Claude's inset panes, plus Otty's Floating Card. Consistent with `agent-layout.md` §5.1.

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  ▯  +            [A] axolotty  ›  ✳ refactor host protocol   ⎇ ax/host  +412 −96   ◔ Working 4:12 │ band 40, FRAME tone
│                                                                                             │
│  [T] tmp           ╭────────────────────────────────────╮ ╭────────────────────────────────╮ │
│      ▭ zsh         │ /private/tmp via ⓟ v3.15.2 …        │ │ /private/tmp via ⓟ v3.15.2 …   │ │
│                    │ ❯ clear; for i in 0 1 2 …           │ │ zsh: command not found: 15     │ │
│  [A] axolotty      │                                     │ │                                │ │
│      ✳ design sys  │  sheet = bg, r10                    │ │  sheet = bg, r10               │ │
│    ▸ ▭ build & test│                                     │ │                                │ │
│      ◆ refactor …  │                                     │ │                                │ │
│                    │                                     │6│                                │ │
│  [S] slopty        │                                     │ │                                │ │
│      ✳ review      │                                     │ │                                │ │
│      ▭ zsh         ╰────────────────────────────────────╯ ╰────────────────────────────────╯ │
│  ─ ─ ─ ─ (no rule)                                                                     6   │
│  ⚙  ◐                 ← sidebar footer anchors the bottom (settings, appearance)            │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
   sidebar 248 on FRAME       stage: top 40 (flush to band), right 6, bottom 6, left 0
```

**Tones**

| Surface | Spec |
|---|---|
| Frame (band, sidebar, gutters, the strip under the sheets) | `mix(bg, fg, 0.05)` in both modes: dark `#201d1f` (ΔL +4.8), light `#f2eef0` (−3.2). It replaces today's `sidebar = mix(bg, black, 0.24)`. |
| Sheet | Exactly `bg`. The terminal's colours are never touched. |
| Selection plate and hover in the sidebar | Re-derived on the frame tone, same alphas as today. |

**Geometry**

| Part | Spec |
|---|---|
| Stage | Insets: top 0 below the band, right 6, bottom 6. Left 0 with the sidebar open, because the sidebar's 8 pt plate inset already gives the gutter; left 6 when the sidebar is hidden. |
| Sheet corners | Radius **10**, continuous. 16 − 6 = 10 keeps the bottom-right corner concentric with the window. Codex uses 12 at a 4 inset [re]; same idea. |
| Gutter between split sheets | 6, nothing drawn at rest. Hovering the 9 pt hit area shows a 2×28 grip pill in `borderStrong`; it turns `accent` while dragging (agent-layout.md §5.1). |
| Terminal padding inside a sheet | x 14, top 10, bottom 8, to clear the corner curve. |
| Cost | ~14 pt of width (≈ 2 columns) and 6 pt of height (0 rows). |

**Edges**

| Mode | Treatment |
|---|---|
| Dark | **None.** The ΔL 4.8 step plus the radius is the edge, so there are zero lines on screen. |
| Light | Contact ring `0 0 0 1px fg@5 %` plus shadow `y1 b3 black 7 %`, from the Codex and Claude card recipes. Light needs it because ΔL 3.2 is near the threshold. |

**Lines on screen at rest:** zero in dark, one 1 px ring per sheet in light. Today there are two seams.

**Band, the context line, on the frame**

The band starts at the sheet's text x (stage minX + 14).

| Part | Spec |
|---|---|
| Project tile | 16 |
| Project name | 13 medium in `text2` |
| Separator | SF Symbol `chevron.right` at 9, `text3` |
| Session | Session icon (vendor mark or program glyph, 16) + **session title, 13 semibold, `text`** |
| Branch | 16 gap, then the branch glyph and name, 12 `text3` |
| Diff | Diff chip, when known |
| Trailing state cluster | Working: accent spinner + elapsed time. Needs you: amber chip carrying the agent's question. Failed: red. |

- The same ordering as Claude's `project / session` and Emdash's breadcrumb. The details are in agent-layout.md §5.2.
- **Shown with the sidebar open.** "Say a thing once" becomes "once per question" (agent-layout.md §5.0).

**Panes**
- Focus is shown by tone: the existing unfocused dim (0.28) stays.
- A waiting pane gets a 1.5 pt amber inner ring that follows the sheet radius. A working pane gets nothing in the sheet; the band says it.
- With two or more panes, each sheet gets a 26 pt identity strip inside its top edge (agent-layout.md §5.3).

**Sidebar**
- It sits directly on the frame, with no hairline.
- Projects keep their 16 tiles, but tile hues need the chroma raised so they are distinguishable at 1x (critique.md RC3). That is a widget change, noted, not part of this study.
- **Anchor the bottom** with a 36 pt footer row:
  - settings
  - appearance
  - host or connection state
- The footer sits on the frame with no rule; spacing separates it.

**Signature**
- **The sheet itself.** A rounded, warm-black screen set in a mauve frame, with the magenta accent appearing as live state (working spinner, band clock). That is what a screenshot of Axolotty would be remembered by.
- **The empty state:** an Axolotty mark (to be drawn; none exists) centred in the sheet, above one 15 pt line and the New Session / Open Folder actions.

### Direction B: Floating sidebar card

The terminal is still the window. This is Claude Code desktop's video look, plus Kiro, applied to the sidebar only.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│╭──────────────────────╮  [A] axolotty › ✳ refactor host protocol        ◔ Working 4:12 │ band 40 = terminal bg
││ ● ● ●   ▯  +         │                                                              │
││                      │ /private/tmp via ⓟ v3.15.2 …          │ /private/tmp via …    │
││ [T] tmp              │ ❯ clear; for i in …                   │ zsh: command not …    │
││     ▭ zsh            │                                       │                       │
││ [A] axolotty         │        terminal full-bleed,           │                       │
││     ✳ design system  │        bg, as today                   │                       │
││     ◆ refactor …     │                                       │                       │
││ [S] slopty           │                                       │                       │
││                      │                                       │                       │
││ ⚙  ◐                 │                                       │                       │
│╰──────────────────────╯                                       │                       │
└──────────────────────────────────────────────────────────────────────────────────────┘
 card inset 8 (top/left/bottom), r12; traffic lights inside the card
```

| Part | Spec |
|---|---|
| Sidebar card | `mix(bg, fg, 0.05)`, radius 12, inset 8 top/left/bottom. Width 248 including the inset, so the content is 232. Dark: no ring. Light: `0 0 0 1px fg@5 %` ring. |
| Traffic lights | Inside the card at (8 + 12, 8 + 12). |
| Terminal | Full-bleed `bg` from x = 256 (the card's right edge + 8). The band, over the terminal, carries the same breadcrumb as A. |
| Splits | A 6 gap of `mix(bg, fg, 0.05)`, or keep the 1 px line in `borderSubtle`. Either way it starts at the band's bottom edge, because the band is now the terminal's header. |

**Pros:**
- The smallest change to the terminal.
- Projects get a physical container, a strong "projects prominent" read.
- It keeps the Ghostty-like full-bleed terminal that terminal users expect.

**Cons:**
- Splits remain lines or ad-hoc gaps, so panes are still not objects.
- With the sidebar hidden, the window returns to the generic baseline.
- Claude itself ships this only as a fallback frame [re]; its default is a flush sidebar plus inset panes.

### Direction C: Full-bleed, re-toned and named

The Conductor and Factory route. It is the minimum.

```
┌─────────────────────────┬─────────────────────────────────────────────────────────────┐
│ ● ● ●  ▯  +             │ [A] axolotty › ✳ refactor host protocol  ⎇ ax/host   ◔ 4:12 │ band 40 = FRAME tone
│                         ├─────────────────────────────┬───────────────────────────────┤ ← no rule; the tone edge is the edge
│ [T] tmp                 │ ▭ zsh · ~/tmp               │ ✳ claude · refactor …         │ pane strips 26 (≥2 panes)
│     ▭ zsh               │ /private/tmp via …          │ /private/tmp via …            │
│ [A] axolotty            │                             │                               │
│     ◆ refactor …        │      bg                     │      bg                       │
│ [S] slopty              │                             │                               │
│                         │                             │                               │
│ ⚙  ◐                    │                             │                               │
└─────────────────────────┴─────────────────────────────┴───────────────────────────────┘
 sidebar + band = mix(bg, fg, 0.05); terminals = bg; seams: none (tone) or 1 px pane split
```

| Part | Spec |
|---|---|
| Sidebar and band | `mix(bg, fg, 0.05)`, lighter in dark, as in Conductor (ΔL +3.6) and Warp (+4.1). |
| Terminal | `bg` from y = 40 down. |
| Lines | No seam line; the tone step is the edge. |
| Panes | Split by a 1 px `borderSubtle` line from y = 40, plus a 26 pt identity strip per pane. |

**Pros:**
- Cheapest.
- No lost columns.
- It already beats the baseline on P2, P3 and P4.

**Cons:**
- This is what tier-2 and tier-3 tools look like. It fixes "broken" without reaching "impressive".
- There is no object, so the P1 gap to Codex, Claude and Dia stays.

### Pick: Direction A

1. **It is where the bar is moving.** OpenAI built and gated an inset-sheet layout for Codex [re]. Claude insets its panes 8 and draws panels as r10 cards [re]. Otty, the nearest native terminal, ships the terminal as a floating card. Dia's whole identity is a card on a canvas.
2. **It solves four patterns with one move.**
   - P1, an object.
   - P3, one chrome ground: band, sidebar and gutters on the frame.
   - P4, zero lines in dark.
   - It gives P2's breadcrumb a home that doesn't look like terminal.
3. **It suits multi-agent work.** A grid of agents reads as objects, and the window structure doesn't change between one pane and three (herdr's `lone: true`).
4. **It costs about two columns.** The owner's 1x display keeps whole-pixel edges: a 6 gutter and a radius of 10 are both integers.
5. **It needs no glass and adds no decoration.** Only opaque tones derived from `bg` and `fg`, which keeps principle 5 and the token model intact.

**What to change in `design-system.md`:**
- **§1.1** becomes "The window is a frame; each terminal is a sheet set in it."
- **§1.2** becomes "Separate with space and tone; no rules at rest."
- **§1.3** becomes "Say each thing once per question; the band names what you're looking at."
- **Tokens.** Replace `sidebar = mix(bg, black, 0.24)` with `frame = mix(bg, fg, 0.05)`. Add `sheetRadius 10`, `stageInset 6` and `sheetGutter 6`.

**Validate before committing.**
- Render A at 1x on the default dark and light themes, and on one near-black (`#000`) and one mid-tone (Dracula) theme.
- Check that the frame step is visible (ΔL 3.5–6).
- Check that the bottom-right corner looks concentric with the window corner.

---

## 6. Sources

**Local captures (1x, `screencapture -o -l`), in `/tmp/wow-study/`:**
- `warp-raw.png`
- `ghostty-raw.png`: the window was blank because the user's session was idle or cleared. The config was read with `ghostty +show-config`.
- Transfer only, not the premium bar: `vscode-raw.png`, `slack-raw.png`, `proxyman-raw.png`.

**Baseline:** `.impeccable/baseline/now-dark.png`.

**Reverse-engineered:**
- `.research/wow/re-electron.md` (Codex 26.1027.61615, Claude desktop 4.4212.0).
- `/Volumes/Lacie/Workspace/oss/otty-reversed/Assets/theme-template.toml` and `Docs/05-UI-Design-System.md` (Otty Floating Card theme and tokens).

**Web images, all in `/tmp/wow-study/`:**

| App | File(s) | Source |
|---|---|---|
| Codex | `web-codex-hero.png`, `web-codex-parallel.png`, `web-codex-built.png`, `web-codex-review.png` | https://openai.com/codex/ (images.ctfassets.net/kftzwdyauwt9/40AI6Un4G1ur1Cp8JELmLX/…/CodexMini.png and siblings) |
| ChatGPT is Codex | — | https://daringfireball.net/linked/2026/07/09/todays-the-day-openai-fucked-up-the-chatgpt-mac-app; https://help.openai.com/en/articles/9703738-desktop-app-release-notes |
| Claude Code desktop | `web-claudecode-dark-empty-videoframe.png`, `web-claudecode-dark-panes-videoframe.png` | Frames of YouTube `rWaQSQEm_aY`, embedded in https://claude.com/blog/claude-code-desktop-redesign |
| Dia | `web-dia-sidebar-empty-videoframe.png`, `web-dia-sidebar-brief-videoframe.png` | Mux video `AfVIo00zNCeCXbiFeHQ7RuHZUfzl3agTCOno01XBF01lRs` on https://www.diabrowser.com/ |
| Conductor | `web-conductor-hero-light.png`, `web-conductor-hero-dark.png` | https://www.conductor.build/conductor-app-hero-light.webp, https://www.conductor.build/conductor-app-hero-dark.webp |
| Cursor 3 | `web-cursor3-agents-light-videoframe.png`, `web-cursor3-marketplace-light-videoframe.png` | Mux thumbnails from https://cursor.com/blog/cursor-3 |
| Granola | `web-granola-note-partial-light.png` | https://www.granola.ai/homepageAssets/features/feature-humans.webp |
| Zed | `web-zed-agent-newthread-dark.png`, `web-zed-agent-review-dark.png` | https://zed.dev/img/agentic/posters/explore-poster.webp, https://zed.dev/img/agentic/posters/review-poster.webp |
| Comet | `web-comet-illustration.png` (illustration only, unusable for metrics) | https://www.perplexity.ai/comet |
| Factory | `web-factory-desktop-frame14.png`, `-frame17-zoom.png`, `-frame29-zoom.png`, `web-factory-missioncontrol-tui.jpg` | https://factory.ai/videos/desktop-overview.mp4, https://factory.ai/images/features/mission-control.jpg |
| Kiro | `web-kiro-crew-session.png`, `web-kiro-specs.png` | https://kiro.dev/images/crew/session-pr.png, https://kiro.dev/images/home/secondary-specs.png |
| Sculptor | `web-sculptor-light.png` | https://cdn.sanity.io/images/dg1xe82e/production/b80b07295ac23210642226fbb4a68be295412811-2400x1350.png |
| Warp | `web-warp-ade-l.png`, `web-warp-ade-m.png`, `web-warp-terminal.png`, `web-warp-agentcli.png` | https://www.warp.dev/img/screenshots/warp-screenshot-l.png, …/warp-screenshot-m.png, https://www.warp.dev/img/products/homepage-v2-terminal.png, …/homepage-v2-agent-cli.png |
| cmux | `web-cmux-landing.png` | https://cmux.dev/_next/static/immutable/media/landing-image.1y26igml71ekg.png |
| Amp | `web-amp-desktop-dark.jpg`, `web-amp-orbs-dark.png`, `web-amp-orbs-light.png` | https://static.ampcode.com/docs/day-to-day-in-amp-screen-poster.jpg, https://ampcode.com/news/personal-self-hosted-orbs-editor-dark.avif, …-light.avif |
| Crush | `web-crush-tui.png`, `web-crush-brand.png` | https://github.com/user-attachments/assets/58280caf-851b-470a-b6f7-d5c4ea8a1968, https://github.com/user-attachments/assets/cf8ca3ce-8b02-43f0-9d0f-5a331488da4b (GIF frames) |
| Otty | `web-otty-screenshot-1.png` (= `web-otty-light.png`), `web-otty-screenshot-2.png`, `web-otty-code-agents.png` (= `web-otty-agents.png`), `web-otty-themes-dark.png`, `web-otty-themes-light.png`, `web-otty-files.png` | https://otty.sh/screenshots/screenshot-1.png, …/screenshot-2.png, https://otty.sh/img/code-agents.png, …/themes-dark.png, …/themes-light.png, …/files.png |
| Emdash | `web-emdash-dark.png`, `web-emdash-light.png` | https://www.emdash.sh/_next/static/media/hero-dark.aa029a9d.png, …/hero-light.c99191c3.png |
| Nimbalyst | `web-nimbalyst-dark.jpg`, `web-nimbalyst-light.jpg` | https://nimbalyst.com/videos/nimbalyst-demo-dark-20260429-poster.jpg, …-light-20260429-poster.jpg |
| Jean | `web-jean-worktrees.png` | https://jean.build/images/screenshots/worktrees.webp |
| Vibe Kanban | `web-vibekanban-light.png` | https://www.vibekanban.com/images/cta-product-desktop.webp |
| Wave | `web-wave-dark.png` | https://framerusercontent.com/images/x5bWAS6lLI79RTC6t3JzVdzJX0.webp |
| opencode | `web-opencode-poster.png`, `web-opencode-share.png` (no desktop window shot) | https://opencode.ai/_build/assets/opencode-poster-CbUiDHgA.png, https://opencode.ai/social-share.png |
| Paradev | `web-paradev-og.png` (OG image only) | https://paradev.com/og-image.png |
| herdr | `web-herdr-og.png` (OG image only) | https://herdr.dev/assets/og-herdr.png |
| Devin | `web-devin-desktop.png` (abstract art, not the product; unusable) | https://devin.ai/assets/images/new-home/code-test/recording-desktop.png |

**Searched, no usable window image:** Perplexity Mac app, Jules, Goose desktop, Windsurf, Trae SOLO.

**Honesty notes:**
- Video-frame hex values (Claude Code, Dia, Cursor, Factory) carry compression error.
- Radii read from crops are ±2 pt.
- Window scale for Factory is inferred from the video frame, so its pt values are soft and its ratios firm.
- Every hex value from a 2x or 3x official still was sampled from flat regions, not edges.
