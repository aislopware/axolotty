# Axolotty redesign: synthesis of the six studies

This document draws on six studies, all in `.research/wow/`:
- `critique.md`: fresh-eyes critique, scored 25/40.
- `composition.md`: window composition.
- `agent-layout.md`: the content area.
- `re-electron.md`: Codex, Claude and Cursor, from their shipped bundles.
- `re-native.md`: Warp, ChatGPT, Dia, Zed and Otty.
- `re-orchestrators.md`: Conductor, opencode, Paradev, Factory, Emdash, Sculptor and Nimbalyst.

## The premium bar

- **Content area:** Codex, Claude Code desktop, Zed, Conductor, Cursor 3 and Warp ADE.
- **Composition:** Codex, Claude, Conductor, Dia and Factory.
- **Terminal-first siblings:** Paradev, Otty and herdr.

## Verdict

The study of the shipped bundles shows that Axolotty's small values already match the premium tier: row heights, radii, ink alphas, the badge geometry (identical to Cursor's), and timing. So "not impressive" is a problem of **composition, hierarchy and colour meaning**, not of tokens. All six studies converge on the same three causes:

1. **No figure and ground.** Sidebar against terminal measures 1.03:1, and the 40 pt band is the terminal's own colour, so it reads as missing rows.
2. **Nothing is said where the eyes are.** No study found a premium app that leaves the top band empty. Every one names the project, the session and its state there.
3. **The brand colour means nothing.** Magenta appears only as the caret. Working and done are drawn grey, and "needs you" is a 6 px dot.

## Decisions (where the studies disagreed)

| Question | Options seen | Decision and reason |
|---|---|---|
| Chrome lighter or darker than the content (dark mode) | Codex and Claude: darker sidebar, with a lifted card. Warp, Zed, ChatGPT and Conductor: lighter. | **Lighter frame**, `mix(bg, fg, 0.06)`. The terminal background (#151214) is already near-black, so mixing toward black cannot make contrast (1.03:1). Mixing toward fg gives 1.14:1, plus radius and gutter. The terminals become deep screens in a warm bezel. |
| Inset card or flat | Codex (r12 at a 4 inset, flagged), Claude (8 inset), Dia (r10 at a 6 inset), Otty Floating Card; or flat (Conductor, Warp) | **Sheets: radius 10, gutter 6** (Dia's geometry, concentric with the ~16 window corner). Zero lines at rest. |
| Band height | 44–48 (Codex, Claude) against 34–36 (Zed, Warp) | **Keep 40.** Every point is a terminal row. The band becomes the context header at no cost. |
| Working indicator | Accent spinner (critique, agent-layout); dot grid (Conductor 4×4, Paradev 3×3) | **Accent spinner.** The dot grid is Conductor's signature. Magenta means *working*. |
| Done, unseen | Accent (Cursor), green (critique) | **Green** (`status(.done)`). The accent is reserved for working. |
| Project mark | 16 pt wash tile (now) against a 20 pt solid tile with a knockout initial | **20 pt solid tile**, L 0.72 C 0.12 dark / L 0.56 C 0.13 light, on the six hues. The tiles are 8 RGB units apart today, which is unreadable at 1×. |
| Needs you | 6 px dot | A **row wash plate** in the sidebar, an **amber strip** on the pane in splits, and a **chip** with the question in the header. |

## Principle changes (design-system §1)

- §1.1 "The terminal is the window" becomes **"The window is a frame; terminals are screens set in it."**
- §1.3 "Say a thing once" becomes **"once per question"**. The sidebar answers *which*; the header answers *what, and how is it doing*. The header shows the session even with the sidebar open.
- §1.4: **magenta = working** (and the caret); amber = needs you; red = failed; green = finished-unseen; tone = focus. No cue does two jobs.

## Phases

**Phase 1** transforms the screenshot. *Shipped 2026-11-02.*
1. Frame and sheets:
   - Frame token; band, sidebar and window painted in it; sidebar hairline deleted.
   - Stage inset 0/6/6/0; sheets r10.
   - Gutter 6; divider pill shown only on hover.
   - Pane padding 14/10/8; light mode gets a contact shadow.
2. Context header in the band: project tile, name › program icon, title, branch · state cluster. Working shows the accent spinner and "Working 4:12"; waiting and failed show the chip. Split, Split Down and More appear on hover.
3. State colours: accent spinner, green done dot, amber/red row wash plates.
4. Projects as objects: 20 pt solid tile, header row 32, gap 20, name x 44, title x 67.
5. Pane strip (28) in splits only. It floods amber with the question when that pane needs you, replacing the 1.5 pt inner stroke.

**Phase 2** *Shipped 2026-11-02 (the mark as the app icon waits for the app bundle).*
- A 2 pt accent progress line per sheet, driven by OSC 9;4.
- A receipt on done ("✓ 4m 12s").
- Empty state with launch tiles and a project pill.
- Sidebar footer.
- An opaque "+" menu instead of the system menu.
- The Axolotty mark.

**Phase 3** *Partly shipped 2026-11-02.*
- ~~A need bar with Allow / Deny~~: dropped (design-system §8.1); the strip's question and a click to the pane stay.
- A diff chip and Changes popover. *Shipped.*
- Find in scrollback, ⌘-click links, keep-awake while working (from the slopty inventory). *Shipped.*
- Metadata in the hover cards. *Next.*

## Not copied

- Composers or chat transcripts.
- A right inspector column (it costs 25–35 % of a 1× window).
- Accent focus borders.
- Kanban.
- Counts at rest on visible rows.
- Conductor's dot-grid signature.
- Glass of any kind.
