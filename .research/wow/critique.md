Method: design review only (detector not applicable, native platform)

# Axolotty: why it isn't impressive yet

- **Date:** 2026-11-02
- **Critic:** independent. I read no earlier critiques, and I treated `.research/design-system.md` as a claim to test, not a rule to follow.
- **Surface:** main window, Operate mode. The owner wants presence too, so this report scores precision and presence together.
- **Evidence:** all captures at 1× (1180×760). Pixel values were sampled with `magick … -format %[pixel:p{x,y}]`. Crops are given as `WxH+X+Y` on the named file.
- **Context:** the `impeccable context` command returned `NO_PRODUCT_MD`, so this review takes its product context from the code and `.research/design-system.md`.

---

## 0. Verdict in one paragraph

The craft is real and the presence is close to zero. Every individual mark is careful: ink-centred initials, hairlines one device pixel wide, a concentric palette, a springing plate. But the composition contains nothing to look at:

- Only **3.3 % of the window's pixels are anything other than the two background greys**.
- The sidebar and the terminal are separated by a contrast of **1.03:1**.
- The brand colour appears on screen **only as the terminal caret**.
- The most important fact in an agent app, "who needs me", is a **6 px dot**.

Take away the vendor marks and this screenshot could be Ghostty next to a Finder sidebar. The design system has followed "say a thing once", "colour carries meaning" and "no decoration" so strictly that the window now says almost nothing, carries almost no colour and has no structure. The fix is not more decoration. It is composition (figure and ground), letting state colour appear where the state is, and making projects and agents into objects you can see at 1×.

---

## 1. Heuristic scores (Nielsen, 0–4)

| # | Heuristic | Score | Key issue |
|---|---|---|---|
| 1 | Visibility of system status | **2** | State is drawn, but at 1× it is a 6 px dot on a 16 px icon. The working spinner is neutral grey. No global roll-up is visible by default (the status bar is off). |
| 2 | Match between system and real world | **3** | Real vendor marks and plain words ("Needs you", "Finished"). |
| 3 | User control and freedom | **3** | Close on hover, double-click to equalise or reset, Escape everywhere. Recently Closed and resume are not shipped yet. |
| 4 | Consistency and standards | **3** | The palette shows "codex · refactor…" while the sidebar trims it to "refactor…" (`pass6-jump` 600×40+414+200). The "+" menu is a translucent NSMenu while every other float is opaque. opencode and Pi get stand-in SF Symbols instead of marks. |
| 5 | Error prevention | **3** | Unsafe-paste confirmation; the shell outlives the agent; no destructive actions at rest. |
| 6 | Recognition rather than recall | **2** | Project tiles are indistinguishable at 1×. Panes in a split carry no identity. The palette and the toast drop the project hue. |
| 7 | Flexibility and efficiency | **3** | ⌘J with grouped scopes and `! . ~` prefixes, ⌘1–9, holding ⌘ to reveal shortcuts, 1–9 inside the presets menu. Strong. Inline allow/deny and peek are still missing. |
| 8 | Aesthetic and minimalist design | **2** | Minimal to the point of absence. No figure and ground, no focal point, no brand. |
| 9 | Error recognition and recovery | **2** | A failed agent is a 6 px red dot. A failed split pane has no in-pane signal. Only the waiting state gets an in-pane cue, a 1.5 pt amber inner stroke. |
| 10 | Help and documentation | **2** | Tooltips and menus only. The empty state is generic and teaches nothing about agents. |
| **Total** | | **25/40** | **Acceptable**: the foundations are solid, but significant improvement is needed before it delights. |

**Design specificity verdict: category-interchangeable.** Nothing in the composition, colour or type belongs to *Axolotty* or to *running many agents*. The only product-specific pixels are borrowed: the Claude, Codex and Gemini marks. There is no app mark (`fd -e svg -e png -e icns` finds no brand asset in `Sources/`). The mauve tint in the neutrals (#151214, #FCF9FB) is the one owned idea, and it sits below the threshold of perception.

---

## 2. Root causes of "not impressive", ranked by impact

### RC1 · Composition: one black slab with no figure and ground (largest impact)

**Pixel evidence (`baseline/now-dark.png`):**

- **Sidebar and terminal are the same colour.** The sidebar ground at (100,400) is `#100E0F`; the terminal ground at (400,600) is `#151214`. The contrast is **1.03:1**, so the two columns read as one surface. A single hairline at x = 247, `#1E1C1D`, does all the separating, from y = 0 to 760 (crop `6x760+244+0`).
- **The band reads as missing terminal.** It covers x 248–1180, y 0–40 and is pure `#151214`, the same as the terminal (crop `932x40+248+0`). The eye takes these 37,000 px as terminal rows that failed to print, not as a titlebar. The shell's leading blank line extends the dead zone to y ≈ 66.
- **The split divider hangs from nothing.** It starts at y = 40 (`#232022` at (714,40), the ground at (714,39); crop `240x120+600+0` at 400 %), while the sidebar seam runs the full height. The two lines that are supposed to be equals (design-system §1.2) begin at different heights. The pane line looks cut off, not placed.
- **Light mode has the same problem.** Sidebar `#F5F2F4` against ground `#FCF9FB` is about 1.05:1 (`review/pass6-light.png`, (100,400) against (400,600)).
- **There is almost nothing on screen.** Measured ink coverage, meaning pixels that are neither ground nor sidebar, is **3.3 %**.

**Code:**

- `Design/Tokens.swift:123` sets `sidebar = bg.mix(black, 0.24)`. On a near-black ground, mixing toward black cannot produce visible contrast; the result is 1.03:1.
- `Window/SessionViewController.swift:58–61` gives the band the terminal's ground (`GroundView`).
- `Window/ShellView.swift:179–206` puts a hairline on the sidebar column.
- `Panes/DividerView.swift` draws the divider as a 1 device-pixel line in `borderSubtle` (fg 0.065 over ground, 1.15:1).
- `.research/design-system.md` §1.1, "The terminal is the window… no card around the terminal, no moat", is the principle behind all of this.

**Why it matters:** composition is what a screenshot shows before any detail. Two planes the eye can't tell apart, plus a 40 pt strip that looks like part of the terminal, add up to "just a terminal". The principle "the terminal is the window" suits a single-terminal app like Ghostty. Axolotty's unit is the **agent** and the **project**, so the window should *hold* terminals, not dissolve into one.

### RC2 · Colour and brand: the accent appears on screen only as the caret

**Pixel evidence:**

- **Where the accent appears.** In `now-dark.png`, the only brand magenta is the terminal cursor: the outline at (368,328) and the bar at (832,243).
- **The working spinner is grey.** On "design system", crop `60x100+30+140` at 800 %, the spinner is a white/grey ring.
- **The done dot is grey.** On "review" it is also a neutral grey dot (crop `20x20+36+282`).
- **All the colour belongs to someone else:** Claude orange, Codex blue, and the shell prompt's ANSI colours.

**Code:**

- `rg "Color\.accent"` outside `Design/` returns four call sites:
  - `Button.swift:235`, the focus ring, shown only with Full Keyboard Access;
  - `Primitives.swift:254–255`, the field caret and selection;
  - `DividerView.swift:49`, while a divider is dragged.
- `Palette.activity(.working)` is `#DE7BCF` and `.done` is `#55C975` (`Sources/AxModel/Theme.swift:106–108`), but **neither is used**:
  - `Sidebar/StatusGlyphView.swift:93` uses `mark.strokeColor = textSecondary`.
  - `StatusGlyphView.swift:66` (`dotColor`) sends every state except blocked and error to `textSecondary`.
  - `Components/ProgramIcon.swift:237` uses `arc.strokeColor = Axo.Color.text`.
- So the design system defines a five-state colour vocabulary and ships two of the colours.

**Why it matters:** the app is named after a pink animal and has a pink accent, yet no screenshot shows pink. "Colour carries meaning" is right. But the most frequent meaning in this product, *an agent is working*, was given no colour, so the chrome has no chroma of its own. The window takes on the colour of whatever is running inside it.

### RC3 · Hierarchy: the most important fact is the smallest mark, and projects aren't prominent

**Pixel evidence:**

- **"Who needs me" is 6 px.** Crop `60x100+30+140` at 800 % shows the waiting (amber) and failed (red) badges as 6×6 px. That is 36 px each in a 897k-px window, about 0.004 %.
- **A row that needs you looks like any other row.** "refactor host protocol and fr…" (amber, needs you) and "build & test" (red, failed) differ from an idle row only by moving title ink from 0.72 to 1.0, a difference you can't see across the room.
- **Project tiles look alike.** Tile fills are (50,50,65) for **T**, (37,54,61) for **A** and (42,53,64) for **S**, sampled at (18,50), (18,122) and (18,254) on a (16,14,15) sidebar. These are three slate squares about 8 RGB units apart. "tmp" and "slopty" can't be told apart by hue at 1×. Light mode has the same problem: (234,232,238) against (209,224,229).
- **The type hierarchy has one step.** In the whole sidebar, a project differs from a session only by weight (13 semibold against 13 regular) and a 23 px indent.
- **Group spacing barely separates projects.** The project-to-project pitch is 42 pt against a 30 pt session pitch, a ratio of 1.4, so projects don't read as blocks.

**Code:**

- `Design/ProjectHue.swift:31–34` sets the glyph at OKLCH L 0.78 / C 0.09 on a 22 % wash.
- `ProjectHue.swift:120` sets the tile radius to 4.5.
- `SidebarRows.swift:18–26` (`SidebarMetric`) sets slot 16, header 28 and header gap 14.
- `SidebarRows.swift:416–419` only changes ink.
- `StatusGlyphView.swift:110` sets the dot at `d = 6`.

**Why it matters:** this is the owner's own constraint, "projects prominent". It fails the squint test: squint at `now-dark.png` and you see one list of grey lines. In an app built to supervise many agents, the waiting agent has to be the first thing the eye lands on, not the last.

### RC4 · Emptiness: "say a thing once" leaves nothing where the eyes are

**Pixel evidence:**

- The content column takes **79 % of the window width** and has **zero** pieces of app chrome (crop `932x760+248+0`): no pane identity, an empty band (title hidden while the sidebar is open), and no roll-up (status bar off by default, `Model/Preferences.swift:28`).
- In a two-pane session there is no way to tell which pane holds which agent, or which one is working. The sidebar has one row per *session*, not per pane.
- In `review/preset.png`, Claude Code draws its own full-width rules (`#625F72` at y 668 and 702) and its own coloured mascot. Agent TUIs bring structure and colour; the app chrome adds none to frame them.

**Code:**

- `Chrome/BandView.swift:13–28`: the title shows only while the sidebar is hidden, and the chip only while the *shown* session waits.
- `Panes/PaneContainerView.swift:354–364`: the only per-pane signals are a 0.28 dim and a 1.5 pt amber inner stroke (`Terminal/TerminalView.swift:113`).

**Why it matters:** "say a thing once" is a good rule for *data*. Applied to *location*, it means the information sits 600 px from where you are reading. A pane is the one thing the sidebar can't name, so the pane must name itself.

### RC5 · Typography: system defaults, a single size, no voice

**Pixel evidence:**

- All the chrome text in `now-dark.png` is SF 13. The only other size is the 10 pt bold tile initial.
- The terminal is SF Mono 13, which is what Terminal.app, Xcode and half of all screenshots use.

**Code:** `Design/Axo.swift:96–119`. `Font.terminal` is `monospacedSystemFont`, and `Prim.Size` t5–t7 are used only in the palette and the empty state.

**Why it matters:** in a terminal, the monospace face covers about 75 % of the pixels. It is the single most visible "brand" choice, and it was left at the platform default. This is acceptable in Operate mode, but it's why the screenshot reads as generic. The sidebar's one-step scale also flattens project against session (see RC3).

### RC6 · Motion: well-crafted, but invisible and generic

**Evidence:**

- The selection plate springs (`SidebarRows.swift:184–213`), hover is instant in and soft out, and the sidebar uses a panel spring. All of it is correct, and all of it is standard.
- When an agent changes state, the only motion is a dot appearing or the ring spinning in grey. Nothing *happens* when an agent finishes or starts asking, the two moments this product exists for.
- A session switch is a 100 ms cross-fade (`SessionViewController.swift:91–96`).

**Why it matters:** motion doesn't show in stills, but it shapes the in-use impression of "this feels alive" or "this feels like Terminal". The app has no authored moment.

### RC7 · Small inconsistencies that cheapen the craft (lower impact, quick to fix)

- **The "+" menu is the only glass in the app** (`review/z-menu2.png`). The purple background blurs through the system NSMenu material, against the owner's "no glass" rule. Its icons mix real marks (Claude, Codex) with stand-ins: `{}` for opencode and a sparkle for Pi. Code: `SidebarViewController.swift:422` (`menu.popUp`).
- **The palette doesn't follow the row-title rule.** It shows "codex · refactor host protocol…" and "claude · design system" (`pass6-jump.png` around (460,218) and (460,372)), while the sidebar trims the vendor prefix. Project detail is grey text ("axolotty · 3m") with no hue tile.
- **The toast truncates its title** to "refactor host protocol and frame c…" in a 340 pt card while the body line has room. It omits the project. Crop `340x56+828+48` on `pass6-toast2.png`.
- **The empty state is stock** (`review/pass3-empty.png`, crop `300x170+560+290`): a terminal glyph, "No sessions open" and two buttons. It could belong to any app.
- **Selection nearly disappears when the window isn't key.** In light mode, a non-key selection is (236,233,235) on (245,242,244), about 1.08:1 (`pass6-light.png` (120,85)).

---

## 3. What is already good, and must be kept

1. **Pixel discipline at 1×.** Initials are centred by their ink bounds on whole pixels (`ProjectHue.swift:125–138`), hairlines are one device pixel, divider offsets are snapped, and every layer renders at the backing scale. Most native apps don't do this. Keep it as a rule for every change below.
2. **The floats.** The palette uses radius 14, padding 6 and row radius 8 (concentric), a 48 pt field and 34 pt rows. ⌘J groups agents into Needs you, Finished and Working with elapsed time, and the `! . ~` prefixes are clever. The toast places itself top-right, away from the prompt, with **Show** only when the agent is asking. These are the best surfaces in the app and should become the model for the "+" menu.
3. **Real vendor marks with cut-out state badges.** The agent's identity never disappears, and state is layered on top. This is the right idea; it is simply drawn too small (see change 2).
4. **Chrome derived from the terminal theme.** All tokens come from the theme's background and foreground, Warp-style, so any theme stays coherent. The mauve-tinted neutrals (#151214 / #FCF9FB) are the start of a brand; keep them and turn them up.
5. **Restraint at rest.** No counts in rows, no chevrons until hover, no disclosure triangles, a neutral selection plate, the agent's own question in the chip, and the vendor prefix trimmed from titles. Keep all of it; the changes below add *structure and state*, not noise.
6. **The keyboard model.** ⌘1–9, holding ⌘ to reveal ⌘n, presets picked with 1–9, and the jump scopes.

---

## 4. The 10 highest-leverage changes

Changes 1–3 together transform the screenshot. Each is specified down to the token and file. None of them uses glass, gradient or translucency.

### 1. Frame and sheets: give the window figure and ground (`Tokens.swift`, `ShellView.swift`, `SessionViewController.swift`, `PaneContainerView.swift`, `DividerView.swift`, `TerminalView.swift`)

Replace "the terminal is the window" with "**the window is a frame and the terminals are screens in it**".

**New plane token in `DesignTokens`: `frame`.**

| | Value | Night / Day | Contrast vs ground |
|---|---|---|---|
| Dark | `bg.mix(fg, 0.06)` | `#221F21` | 1.14:1 (now 1.03) |
| Light | `bg.mix(fg, 0.05)` | `#F2EEF0` | 1.10:1 |

In dark, the frame sits *lighter* than the terminal, so each terminal reads as a deep screen set into a warm charcoal bezel. Mixing toward black can't produce contrast at this luminance; mixing toward the foreground can.

**Planes:**

- `sidebar` = `frame`.
- The window background, the sidebar column and the band are all painted `frame` (`GroundView` becomes `FrameView` for the root; `SidebarColumn.updateLayer` uses `frame`).
- **Delete the sidebar hairline** (`ShellView.swift:180,196,204`).

**Stage:**

- The panes area is inset **top = band (40)**, **right 6**, **bottom 6**, **left 0** with the sidebar open. The sidebar's plates already stop 8 pt short of its edge, which gives an 8 pt gutter.
- With the sidebar hidden, the left inset is **6**.

**Each pane is a sheet:**

- Fill `ground`, radius **10** (`Prim.Radius.r4`). The window corner measures about 16 at 1×, so 16 − 6 = 10 keeps it concentric. Use continuous corners, `masksToBounds` on the pane host layer.
- **Dark:** no border and no shadow; value contrast carries it.
- **Light:** one contact shadow (y 1, blur 3, black 0.07), no border.

**Splits:**

- `PaneContainerView.gap` goes from 1 to **6**, so the frame shows between sheets.
- `DividerView` at rest draws **nothing**.
- On hover, it draws a **2×28 pill** in `borderStrong`, centred in the gutter, fading in over `tick`.
- While dragging, the pill is `accent`. Keep the 9 pt hit area.

**Pane padding:** 12/8/6 becomes **14 / 10 / 8** (x / top / bottom), for clearance from the corner curve.

**Result:**

- The band becomes a titlebar and stops looking like a missing terminal row.
- The sidebar becomes part of the frame.
- **The window has no hairline anywhere**, which fully meets "few, elegant dividers".

**Cost:** about 14 pt of width and 6 pt of height, roughly 2 columns and 0 rows at SF Mono 13.

### 2. Brand pink means "alive", and state is readable at 1× (`StatusGlyphView.swift`, `ProgramIcon.swift`, `SidebarRows.swift`, `Tokens.swift`)

**Working:**

- The spinner arc becomes `Axo.Color.accent` (#DE7BCF dark, #B24CA5 light), and the track becomes accent at 0.22. Change `StatusGlyphView.swift:92–93` and `ProgramIcon.swift:236–237`.
- Update design-system §1.4 to read: "**magenta = an agent is working, and the caret**".

**Done (unseen):** use `status(.done)` (#55C975 / #00943E) instead of `textSecondary` (`StatusGlyphView.swift:63–67`).

**Badge size:** dots go from **6 to 7** pt with the 1 pt moat; the spinner stays 8 inside the 16 slot, but with a 1.5 pt stroke.

**Row wash for "needs you":**

- `SidebarOutlineView` gains a third plate type, the **state plate**, drawn under each waiting or failed session row.
- It uses the same rect as the selection plate (inset 8, radius 8, 28 tall) and is filled with `statusWash(.blocked)` (amber 0.16 dark / 0.12 light) or `statusWash(.error)`.
- If a row is both selected and waiting, the neutral selection plate wins and the amber badge stays.
- Title ink rule: waiting and failed rows get full ink; the others keep the current rule.

**Result:** at 1×, the row that needs you becomes a 224×28 amber field instead of a 6 px dot, and every working agent shows a pink ring. The brand colour now means the product's main verb.

### 3. Projects as objects (`ProjectHue.swift`, `SidebarRows.swift` `SidebarMetric` and `WorkspaceCell`)

**Tile:**

- Size goes from **16 to 20** pt, radius from 4.5 to **6** (continuous).
- The fill becomes **solid hue**: dark OKLCH **L 0.72 C 0.12**, light **L 0.56 C 0.13**, at the same six hue angles.
- The initial is **11 bold** in `ground` ink (#151214 in dark, #FFFFFF in light), still centred on its ink bounds.
- A solid tile with a knockout letter reads as identity, like a Linear team or Slack workspace mark, not as state. Measured now: three slate squares 8 RGB units apart. Proposed: six clearly different hues at equal lightness.

**Header metrics:**

- `headerRow` goes from 28 to **32**, and `headerGap` from 14 to **20**. The project pitch becomes about 52 against the 30 session pitch, a 1.7× rhythm, so projects read as blocks.
- `nameX` = 16 + 20 + 8 = **44**.
- Session icons align under the name at x 44, and titles move to x **67**.

**Name:** 13 semibold, full ink. Unchanged; the tile does the work.

**Collapsed project:** the roll-up dot after the name becomes the same amber or red **wash pill**, 20×16 with the count in 11 pt tabular digits. A count is allowed here because it is *hidden information*, not a count at rest on a visible row.

### 4. Pane identity strip in splits (new `Panes/PaneHeaderView.swift`, laid out by `PaneContainerView`)

**When it shows:** only when a session has more than one pane and none is zoomed. A single pane stays clean, because the sidebar row already names it.

**Strip layout:** **26** pt tall, inside the top of the sheet, on the sheet's ground, with no rule.

- Program icon at **14** pt, at x 12.
- Title in `Axo.Font.smallStrong` (12 medium): `textSecondary`, or `text` when the pane is focused.
- Trailing: elapsed time in `Axo.Font.meta` (`textTertiary`) for live agents.
- Close and zoom icons appear on hover, as 22 pt `IconButton`s.

**State:**

| State | Strip treatment |
|---|---|
| Waiting | Fill `statusWash(.blocked)`; the title becomes the agent's question (the text that already drives the chip). |
| Failed | `statusWash(.error)` |
| Working | Pink spinner badge (change 2) |

The amber strip replaces the 1.5 pt amber inner stroke (`TerminalView.swift:113, 360–376`). That stroke is a coloured border, and a weaker signal than the strip.

**Interaction:** double-clicking the strip toggles zoom.

### 5. A census in the band (`BandView.swift`, `MainWindowController.refreshChrome`; reuse `RollupButton` from `StatusBarView.swift`)

**Placement:** trailing in the band, 12 pt inset from the right edge.

**Content:** up to three icon-and-number pairs:

- an amber dot with the count of waiting agents;
- a red dot with the count of failed ones;
- a pink spinner with the count of working ones.

**Style:**

- The counts are 11 medium with tabular digits (a new `Axo.Font.metaStrong`; `Axo.Font.numeric` is 13).
- Each hit area is 22 tall, with a 10 pt gap between pairs.
- A pair is hidden when its count is 0.

**Behaviour:** clicking a pair calls the existing `jump(to:forward:)`. The band chip stays immediately to the left.

**Why:** it fills the band with the product's live state and puts heuristic 1 (system status) at the top of the eye path. The status bar keeps only the branch and cwd, and can stay off.

### 6. Carry the project hue everywhere a session appears (`PaletteController.swift:178–212, 545–630`; `ToastCenter.swift:124–196`; `BandView.swift`)

- **Palette rows:** the detail becomes a **12 pt project tile** plus the project name, then " · 3m".
- **Fix the row-title trim** so it handles lowercase vendor prefixes. "codex · …" shows as "refactor host protocol and frame codec" with the Codex mark, matching the sidebar (`pass6-jump` (460,218)).
- **Toast:** a meta line under the body, in `textTertiary` 11 pt: tile, project name, elapsed time. Let the title wrap to 2 lines before truncating.
- **Band with the sidebar hidden:** tile, then the project name in `textTertiary`, then the program icon and title.

### 7. Replace the "+" menu with an opaque float (`SidebarViewController.swift:~400–430`)

**Build:** a `Surface(.float)` popover using the palette's row metrics:

- radius 12, padding 6, inner row radius 6;
- rows 30 tall with a 16 icon, 13 pt title, and the trailing digit in `Axo.Font.shortcut`.

**Behaviour and look:**

- Opaque `elevated` fill. **Removes the only glass in the app** (`z-menu2.png`).
- The keyboard works as it does today: 1–9 picks, arrows move, Return opens.

**Icons:**

- opencode and Pi get real marks, or every non-vendor entry uses the program-kind glyph consistently.
- Never a sparkle standing in for a logo.

Context menus can stay native NSMenu; this is the one menu that is part of the brand flow.

### 8. A terminal face with a voice (`Axo.swift:114–123`, `Preferences.swift`, a font bundled in `Resources/`)

- Ship an OFL monospace as the **default** terminal font, at 13 pt with a line pitch of ×1.15.
- Candidates, in order: **Commit Mono** (neutral, crisp at 1×), **JetBrains Mono** (wider, very legible), **Geist Mono**.
- Hint-test each at 1× before choosing; SF Mono's main strength is its 1× rendering.
- SF Mono stays a one-click option.

This changes 75 % of every screenshot's pixels and is the cheapest way to stop looking like Terminal.app.

### 9. An empty state that launches agents (`SessionViewController.swift:210–286`)

**Mark:** the terminal glyph is replaced by the **Axolotty mark** (see section 5), 40 pt, in `accent`.

**Title:** "Start a session" in 20 semibold (`Prim.Size.t7`).

**Launch tiles:** below the title, a row of tiles, one per installed preset (Shell, Claude, Codex, Gemini…):

- each **88×72**, radius 12, `Surface(.rest)`;
- the vendor mark at 24, the name in 12 medium, and the digit 1–n in 11 pt tabular `textTertiary` in the top-right corner;
- the keys 1–n launch directly.

**Folder action:** "Open Folder…" as a secondary text button beneath.

This turns the emptiest screen into the most on-brand one, and it explains the product: this is where you run agents.

### 10. One authored motion: a state change you can feel (`SidebarRows.swift`, `ProgramIcon.swift`, `PaneHeaderView`)

**Becoming waiting or failed:**

- The state plate or strip wash fades in over `Motion.swift` (200 ms, ease-out).
- The badge pops from 0.6 to 1.0 on `Motion.pop` (0.30 / 0.10 bounce).
- It runs once. No pulsing loop.

**Becoming done:** the pink ring finishes its revolution, then cross-fades into the green dot over 200 ms.

**Rows never move.** No re-sorting on activity, as now.

**Reduce Motion:** opacity only.

---

## 5. Signature proposal

These are two elements that would make an Axolotty screenshot recognisable at a glance. Neither uses glass or decoration.

### A · "Bezel and screens", with identity strips

The window is a warm charcoal (or warm paper) **frame**, with **rounded terminal screens** set into it 6 pt apart, and no lines anywhere (change 1). Whenever more than one agent shares a session, each screen carries its **identity strip** (change 4), and the strip **floods amber when that agent asks for you**.

A screenshot of four agents then reads like a control desk: four screens, four vendor marks, one amber strip. Nobody else ships that. Warp has blocks, cmux has tabs, and Ghostty has nothing. It follows from the product (supervising agents) rather than from taste, and it comes with fewer dividers than today.

### B · "Axolotl pink means alive"

The brand magenta becomes the colour of **working agents**, and stays rare everywhere else: no pink buttons, no pink selection.

- **Where it appears:** the sidebar rings, the census spinner, the strip badges and the caret.
- **Why that's enough:** with six agents running, the screenshot shows a few small pink rings on a warm neutral ground. That small, repeated mark becomes the brand.

**Optional, test before committing:** draw the working mark as **three short gill strokes** (1.5 pt, fanned at −35°, 0° and +35°, 4 pt long, in a 10 pt box) instead of a generic arc. They would "breathe" in sequence, with opacity going 0.35 → 1 → 0.35, staggered 0.15 s, on a 1.2 s cycle. A ring says "loading"; gills say "Axolotty is thinking".

- **Reduce Motion:** static strokes at full ink.
- **Gate:** it must read as a spinner at 1× in a 16 pt slot. If it reads as decoration, drop it and keep the pink ring.
- **App mark:** draw the same three strokes larger, as the app mark (empty state, About, app icon). That makes the mark *geometry*, not illustration.

---

## 6. Personas (brief)

- **Alex, the power user running six agents:**
  - Waiting rows can't be found without reading every 6 px dot.
  - Without the status bar there is no global count.
  - In a split, they can't tell which pane is Codex.
  - ⌘J rescues them; the window itself doesn't.
- **Jordan, a first-timer:**
  - The empty state says "No sessions open" and offers "New Session", which gives a shell.
  - Nothing says this app runs Claude, Codex or Gemini until they find the "+" on hover in a project header.
- **Sam, low vision or 1080p at a distance:**
  - The project hues are indistinguishable.
  - The state badges are 6 px, below a comfortable size for 3:1 marks.
  - The unfocused split relies on a 0.28 dim alone.

## 7. Questions to consider

- Who is the window for: someone reading one terminal, or someone supervising many agents? The current principles serve the first; the product is the second.
- If magenta means "working", what does the caret's magenta mean? (Answer: the caret marks where *you* are working. One accent, two subjects, both "alive". Accept the overlap.)
- Does "say a thing once" apply per piece of data or per place? A pane is a place the sidebar can't name.

## 8. Run notes

- **Assessment:** A only. The detector doesn't apply to a native platform, and no sub-agents were spawned.
- **Context loader:** `impeccable context` ran and reported no PRODUCT.md or DESIGN.md. The code and `.research/design-system.md` served as context.
- **Persistence:** no snapshot was written to `.impeccable/critique/`. This file is the deliverable, and no source files were edited.
- **Temporary files:** zoom crops are in `/tmp/axcrit/`.
