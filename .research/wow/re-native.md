# Premium native AI and agent apps on macOS: reverse-engineered design ground truth

Date: 2 Nov 2026. Purpose: give the Axolotty redesign exact peer values in place of estimates.

Axolotty baselines:
- **Capture:** `.impeccable/baseline/now-dark.png`.
- **Design system:** `.research/design-system.md`, which specifies a 40 band, a 248 sidebar darker than the terminal, 28 rows, a hairline between panes, and agent state shown as a badge on the icon.

**Method:**
- **Exact values only.** Every value comes from shipped binaries and resources (asset catalogs, Swift symbols, disassembly, embedded TOML and CSS) or from the vendor's public source at a pinned commit.
- **Citations.** Each value cites a file, symbol, asset name or address.
- **Labels.** "Computed" marks arithmetic on recovered values. "Inferred" marks a role deduced from naming or structure.

| # | App | Version analysed | Signature (Team ID) | How |
|---|---|---|---|---|
| 1 | Warp | 0.2026.10.21.08.25.02 (`v0.2026.10.21.08.25.stable_02`); installed copy = latest stable | Denver Technologies, Inc (2BBY89MBSN), notarized | Public client source at commit `d57d9760`, plus bundle, plus a 1× capture of the running app |
| 2 | ChatGPT Classic (native SwiftUI) | 1.2026.184 (1784145287) | OpenAI OpCo, LLC (2DC432GLL2), notarized | Static: Assets.car and exported Swift symbols |
| 3 | Dia | 1.55.1 (89833) | The Browser Company of New York Inc. (S6N382Y83G), notarized | Static: asset catalogs, field-offset tracing and disassembly, chat CSS |
| 4 | Zed | source, commit `bc6fc117403d` (2 Nov 2026) | not applicable (source) | Source and the One theme JSON |
| 5 | Otty | 1.6.4 | Abner Lee (9HWK5273G4), notarized | Embedded theme TOML, bundle, the 1.0.4 write-up, and one capture |

Downloads all came from official domains, and each went into its own empty directory under `/Volumes/Lacie/Workspace/oss/re-apps/<app>/download/`:
- ChatGPT: `persistent.oaistatic.com`, linked from `chatgpt.com/download`.
- Dia: `releases.diabrowser.com`, linked from `diabrowser.com/download`.
- Otty: `downloads.otty.sh`, linked from `otty.sh`.

Each download was checked with `codesign -dv` and `spctl -a -t exec` (both accepted). DMGs were mounted `-nobrowse -readonly`, copied out and detached. Nothing was installed into /Applications, and nothing was signed into.

---

## 1. Warp

| | |
|---|---|
| Copy analysed | `/Applications/Warp.app` (installed; read only). It is the latest stable, so nothing was downloaded: `releases.warp.dev/channel_versions.json` gives `stable.version = v0.2026.10.21.08.25.stable_02`, and the installed `Info.plist` gives `WarpVersion = v0.2026.10.21.08.25.stable_02`. |
| Bundle and signature | `dev.warp.Warp-Stable` 0.2026.10.21.08.25.02. Developer ID Application: Denver Technologies, Inc, **Team 2BBY89MBSN**. Notarized; `spctl` accepted; signed 23 Oct 2026. |
| Stack | Rust with Warp's own GPU UI framework (`warpui`, Metal). AppKit is used only for the window shell (`crates/warpui/src/platform/mac/objc/window.m`). |
| Ground truth | The Warp client source is now public (`github.com/warpdotdev/warp`, AGPL/MIT). A shallow clone is at `/Volumes/Lacie/Workspace/oss/re-apps/warp/src` (commit `d57d9760`, 30 Oct 2026). That commit is nine days after the shipped build, and every value below was read from it. The values were cross-checked against the binary (`settings_schema.json` defaults, source paths embedded in `MacOS/stable`) and against a 1× capture of the running app, `re-apps/warp/captures/warp-live.png`. |
| Build flags | `app/Cargo.toml` `default = [...]` includes `minimalist_ui`, `new_tab_styling` and `vertical_tabs`, so the stable build ships the minimalist variants quoted here. |

### 1.1 Colour system: three seeds, everything else derived

Warp themes are three colours: `background`, `foreground` and `accent` (`WarpTheme::new`). Every chrome colour is a blend of those three at a fixed opacity (`crates/warp_core/src/ui/theme/color.rs`, `internal_colors`). This is the same model Axolotty's `DesignTokens` already uses.

| Seed | Dark (`dark_theme()`) | Light (`light_theme()`) | Evidence |
|---|---|---|---|
| background | `#050505` | `#FFFFFF` | `app/src/themes/default_themes.rs:262-285` |
| foreground | `#FFFFFF` | `#111111` | same |
| accent | `#19AAD8` | `#00C2FF` | same |
| ANSI normal (dark) | 0 `#616161` · 1 `#FF8272` · 2 `#B4FA72` · 3 `#FEFDC2` · 4 `#A5D5FE` · 5 `#FF8FFD` · 6 `#D0D1FE` · 7 `#F1F1F1` | — | `DARK_MODE_NORMAL_COLORS`, `default_themes.rs:11-19` |

| Derived token | Formula | Dark result | Light result | Evidence |
|---|---|---|---|---|
| `neutral_1` = `surface_1` | bg + fg @ 5 % | `#121212` | `#F3F3F3` | `internal_colors::neutral_1` |
| `neutral_2` = `surface_2` | bg + fg @ 10 % | `#1E1E1E` | `#E7E7E7` | `neutral_2` |
| `neutral_3` = `surface_3` | bg + fg @ 15 % | `#2A2A2A` | `#DBDBDB` | `neutral_3` |
| `neutral_4` (subshell) | bg + fg @ 20 % | `#373737` | `#CFCFCF` | `neutral_4` |
| `neutral_5` (cancelled glyph) | bg + fg @ 40 % | `#696969` | `#A0A0A0` | `neutral_5` |
| `neutral_6` (tooltip bg) | bg + fg @ 60 % | `#9B9B9B` | `#707070` | `neutral_6`, `tooltip_background()` |
| `fg_overlay_1…7` | fg @ 5 / 10 / 15 / 20 / 40 / 60 / 90 % (translucent) | — | — | `fg_overlay_1..7` |
| `outline()` | fg_overlay_2 (fg @ 10 %) | — | — | `color.rs:151` |
| `split_pane_border_color()` | fg_overlay_3 (fg @ 15 %) | — | — | `color.rs:249` |
| `inactive_pane_overlay()` | fg_overlay_2, laid over the pane | — | — | `color.rs:342` |
| text main / sub / hint / disabled | best-contrast fg @ 90 / 60 / 40 / 40 % (the details table also lists a disabled opacity of 20) | — | — | `DARKER_DETAILS`, `text_main`, `text_sub`, `text_disabled` |
| button hover / click | + fg @ 10 % / + black @ 20 % | — | — | `CustomDetails` |
| accent hover / pressed | accent + fg @ 40 % / accent + bg @ 30 % | — | — | `accent_hover`, `accent_pressed` |
| accent overlays | accent @ 10 / 25 / 40 / 60 % | — | — | `accent_overlay_1..4` |
| block selection | accent @ 25 % | — | — | `block_selection_color()` |
| text selection | `rgba(118,167,250,0.40)`, not themed | — | — | `text_selection_color()` |
| AI-block overlay | fg @ 5 % over the terminal background | — | — | `ai_blocks_overlay()` |
| UI warning / error / yellow / green | `#C28000` / `#BC362A` / `#E5A01A` / `#1CA05A`, fixed for every theme | | | `color.rs:135-149` |
| ANSI-derived status | `ansi_fg_X` = fg + ANSI X @ 50 %; `ansi_bg_X` = bg + ANSI X @ 50 % | magenta `#FFC7FE`, green `#DAFDB9`, red `#FFC1B9`, yellow `#FFFEE0` | — | `ansi_fg`, `ansi_bg` |

Measured on the user's live window (a custom theme with bg `#1D2022`):
- The vertical-tabs panel is `#262A2C`, which is bg + fg @ 5 %. **The sidebar is a tone lighter than the terminal, not darker.**
- The pane divider is `#313437`, which is fg @ ~10–15 %.
- The hairline under the title bar sits at y = 35.

### 1.2 Shape, type and motion

| Token | Value | Evidence |
|---|---|---|
| UI font | **Roboto**, bundled (Regular, Medium, Bold, Italic, plus RobotoFlex-Semibold) | `app/src/appearance.rs:309-328` |
| UI size | **12** (`DEFAULT_UI_FONT_SIZE`); header 18; overline 10; command palette 14 | `crates/warp_core/src/ui/appearance.rs:8-12` |
| Terminal font | Hack 13, line height ×1.2; the AI font is also Hack | `settings_schema.json` (`appearance.text.*`) |
| Notebook font | 14 | same |
| Radii | Row 4 (`ROW_CORNER_RADIUS`). Popups and menus 6. Dialogs 8 (`DIALOG_CORNER_RADIUS`). Visual and table cards 8. Cloud composer 8. Chips 2. Pills are full height / 2. | `vertical_tabs.rs:107`, `mode_selector.rs:21`, `common.rs:157,2460`, `input/agent.rs:38`, `message_bar/common.rs:537`, `orchestration_pill_bar.rs:73` |
| Spacing | Mostly 4 and 8; dialog padding 12 or 24; content padding 20 × 16 | `dialog.rs:24-27`, `view_impl.rs:1315-1333` |
| Icons | 24 grid; 16 in rows; 12 for badges | `icons.rs:6`, `vertical_tabs.rs:101-111` |
| Shimmer ("Warping…") | Period 3 s, band radius 6 glyphs, 8 glyphs of padding, repaint every 32 ms (~30 fps). Base ink = disabled text; peak = main text. | `warpui_core/src/elements/shimmer_math.rs:40-47`, `gui/shimmering_text.rs:227`, `ai/loading/shimmering_warp_loading_text.rs` |
| Window opacity / blur | 100 % / blur 1; backdrop `none` | `settings_schema.json` |
| Inactive-pane dim | **Off** by default (`should_dim_inactive_panes = false`) | `settings_schema.json`, `pane_group/pane/view/mod.rs:425` |

### 1.3 Main-window composition

```
 ┌────────────────────────────────────────────────────────────────────────────────┐
 │●●●  [▣][⚒]           ┌ Search sessions, agents, files… ┐             [±][⌂][◉] │ 34 + 1 hairline = 35
 │12 │14│6│ … 64 reserved + 16 → content starts at x 80     max 320 × 24, r4, fg5%   │  (titlebar = tab bar)
 ├──────────────────┬─────────────────────────────────┬───────────────────────────┤ ← 1 px fg@15 %
 │⌕ Search tabs…  ⚙+│           ~/.config          ⋮ ✕│         icon.svg        ⋮ ✕│ pane header 34, title centred
 │ /path/of/active  ├─────────────────────────────────┤                           │
 │(●) eza --all …   │ ~/.config (0.099s)              │   1  <svg …                │
 │    ~/.config     │ eza --all --header …            │   2    <rect …             │
 │(●) New session   │ ── block divider ─────────────  │                           │
 │╭───────────────╮ │ …output…                        │                           │
 ││(</>) icon.svg │ │ ─ restored-blocks overlay fg@10%│                           │
 │╰───────────────╯ │ [⌂ ~/.config ] ← prompt chip    ├───────────────────────────┤
 │ 248 (200–50 %)   │                                 │                           │
 │ bg + fg@5 %      │  input pinned to bottom         │                           │
 └──────────────────┴─────────────────────────────────┴───────────────────────────┘
```

| Aspect | Spec | Evidence |
|---|---|---|
| Inset or full-bleed | **Full-bleed.** `WORKSPACE_PADDING = 1.0`: one pixel of padding around the whole workspace and no card. Panes tile edge to edge. | `workspace/view.rs:561-563` |
| Titlebar | Warp draws its own tab bar into the title area. The window is `titlebarAppearsTransparent`, the title is hidden, and `backgroundColor = clear @ 0.01` (a non-zero alpha avoids a shadow-gap bug). | `objc/window.m:init_warp_nswindow` |
| Titlebar height | `TAB_BAR_HEIGHT 34` + `TAB_BAR_BORDER_HEIGHT 1` = **35**. It is passed to AppKit through `configureTitlebarHeight`, which resizes `NSTitlebarContainerView`. | `workspace/view.rs:574-586`, `update_titlebar_height` |
| Traffic lights | Re-laid by hand with Auto Layout: each button **14 × 14**, spacing **6**, left margin **12**, `centerY = titlebar.centerY + 1`. | `objc/window.m:configure_titlebar_height` (`buttonSpacing = 6.0`, `leftMargin = 12.0`, `buttonSize = 14.0`) |
| Space reserved after the lights | **64** (`TrafficLightData.width`), plus 16, so tab-bar content starts at **x = 80**. In fullscreen the left padding drops to 4. | `util/traffic_lights.rs:74`, `compute_tab_bar_left_padding` |
| Title-bar contents | Left: panel toggle and tools (24-tall buttons). Centre: the "Search sessions, agents, files…" field, ≤ 320 wide, 24 tall (16 + 4 + 4), radius 4, background fg @ 5 % (10 % on hover), placeholder in sub-text ink. Right: update pill (100 wide, 12 pt), inbox, avatar. | `workspace/view.rs:21110-21160`, `TAB_BAR_PILL_WIDTH`, `PILL_FONT_SIZE` |
| Horizontal tabs (classic layout) | The active tab is a pill filled with fg @ 10 % and bordered fg @ 20 %; inactive tabs have a fg @ 15 % border; hover fills fg @ 5 %. Close button 20; 8 horizontal padding; 5 vertical padding. | `tab.rs:1796-1838`, `TAB_CLOSE_BUTTON_WIDTH` |
| Vertical tabs panel | **248** wide (min 200, max 50 % of the window), on bg + fg @ 5 %. The control bar has a search field 24 tall and a split "+" button. Rows: padding 8, radius 4, gap 4. Groups are inset 8 with a 4-pt header pad. | `vertical_tabs.rs:91-133, 1267-1281, 1735` |
| Vertical-tab row states | Selected: fg @ 10 % fill **and** a 1 px fg @ 15 % border. Hover: fg @ 5 %. Custom tab colour: 15 % at rest, 50 % on hover or selected. | `pane_row_background`, `render_pane_row_element` |
| Row content | A 24-pt "icon-with-status" (circle 76 %, glyph 43 %, status badge 57 % at the bottom right). Title 12 on line 1; subtitle (cwd or branch) on line 2. In expanded mode, line 3 holds metadata badges (12 pt) such as diff stats and PR link. A hover sidecar (320 wide, ≤ 420 tall, radius 4) shows details. | `ui_components/icon_with_status.rs`, `VERTICAL_TABS_ICON_SIZE`, `DETAIL_SIDECAR_*` |
| Pane splits | Divider **1 px** (`MinimalistUI`) in `split_pane_border_color` (fg @ 15 %), with a 4-pt invisible grab margin. Minimum pane 50; keyboard resize step 10. | `pane_group/tree.rs:29-40, 1428`, `pane_group/mod.rs:228-230` |
| Pane header | **34** tall (`PANE_HEADER_HEIGHT`) with a centred title. Trailing ⋮ and ✕; edge padding 4. When enabled, an inactive pane gets fg @ 10 % over its header and body. A shared session has a 2-pt accent border. | `pane/view/header/mod.rs:47`, `components.rs:19`, `pane/view/mod.rs:420-437` |
| Blocks (terminal output) | Each command is a block. Padding in lines (normal mode): top 1.1, prompt→command 0.19, command→output 0.5, bottom 1.0. Prompt→editor 10 px; editor bottom 20 px. Block dividers are on; a failed block uses ANSI red; a selected block is accent @ 25 %. | `settings/mod.rs:559-578`, `color.rs` |
| Input | Pinned to the bottom (`input_mode = pinned_to_bottom`). The prompt is rendered as chips (folder chip, git chip). | `settings_schema.json`, `message_bar/common.rs:536-540` |

### 1.4 Agent surfaces

| Surface | Spec | Evidence |
|---|---|---|
| Agent conversation (AI block) | Lives in the same block list as shell output. It sits on an fg @ 5 % overlay so it reads as a different kind of block, with content padding **20 h × 16 v** and **16** between items. Restored AI blocks get fg @ 15 %. | `view_impl.rs:1315-1333`, `ai_blocks_overlay()` |
| Working | A shimmering status line, **"⟨Warp glyph⟩ Warping…"** or "Warping with ⟨model⟩…", using the 3-s shimmer from disabled ink to main ink. Thinking traces show, then collapse (`thinking_display_mode = show_and_collapse`). | `common.rs:115`, `status_bar.rs:934`, `settings_schema.json` |
| Waiting | `ConversationStatus::Blocked` → **StopFilled** glyph in ANSI yellow; the status text is "Agent waiting for instructions...". Permission requests are inline cards (requested command, editor ≤ 500 tall, 16 v padding) with Run, Edit and Reject. | `agent/conversation.rs:5157`, `common.rs:112`, `inline_action/requested_command.rs:82,107` |
| Done / failed / cancelled | Success → **Check**, ANSI green. Error → **Triangle**, ANSI red. Cancelled → StopFilled in neutral_5. In progress → **ClockLoader** in ANSI magenta. | `ConversationStatus::status_icon_and_color` |
| Status badge geometry | On a 24 box: brand circle 18.2 (76 %), glyph 10.3 (43 %), badge ring 13.7 (57 %) with its icon 8.2 (34 %), anchored bottom-right and overhanging 19 %. The badge is cut out of the circle by a ring in the container's background colour. | `icon_with_status.rs` (`CIRCLE_RATIO`, `ICON_RATIO`, `DEFAULT_BADGE_RATIO`, `DEFAULT_BADGE_ICON_RATIO`, `DEFAULT_OVERLAY_OVERHANG_PAST_CIRCLE_EDGE`) |
| Third-party CLI agents (Claude Code, Codex, Gemini, Amp, …) | Detected per pane. They get the same circle with a **brand-colour fill**: Claude `#D97757`, Gemini `#4285F4`, OpenAI/Codex `#000000`, Copilot `#8534F3`, Amp `#F34E3F`, Cursor `#26251E`, OpenCode `#808080`. A **CLI agent toolbar/footer** shows chips such as model, cwd, branch and diff. **Rich Input** is an optional composer docked over the CLI agent: editor max height 236, padding 10 top / 8 bottom; it auto-opens or closes when the agent blocks. | `terminal/cli_agent.rs:34-110`, `ai/blocklist/view_util.rs:48`, `terminal/input.rs:397-399`, `agents.third_party.*` settings |
| Orchestration (sub-agents) | A **pill bar** of child agents: pills 22 tall, radius 11, 15-pt avatar disc, label ≤ 83, gap 8. Hovering shows a 280-wide card with status badge. | `orchestration_pill_bar.rs:72-296` |
| Cloud composer (the v2 agent input) | A centred card ≤ **720** wide, radius 8, padding 16 h / 16 top / 16 bottom, min editor 80, chips row below. | `terminal/input/agent.rs:36-60` |

**Signature:** the **block**, which turns terminal output into discrete, selectable objects with a header and padding. Agent turns are blocks in the same stream, set apart by a 5 % tint and a shimmering "Warping…" line.

**Shell signature:** a 35-pt title strip that is the tab bar, with a centred search field. In the 2026 layout this is joined by a 248-pt vertical-tabs column with **brand-coloured agent circles and status badges**.

---

## 2. ChatGPT for Mac: "ChatGPT Classic", the native SwiftUI app

| | |
|---|---|
| Which app | As of Nov 2026, `chatgpt.com/download` offers two Mac apps: the new unified **"ChatGPT"** (`persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg`, 833 MB, built on the Codex app and covered by the Codex study), and the native SwiftUI app, renamed **"ChatGPT Classic"** (`persistent.oaistatic.com/classic/public/ChatGPT_Classic.dmg`). This section covers the native one; the old `sidekick/public/ChatGPT.dmg` is an older build (9 Jul) of the same app. Both URLs come from the official page's own JavaScript bundle. |
| Copy analysed | **1.2026.184 (1784145287)**, bundle `com.openai.chat`. DMG at `re-apps/chatgpt/download/ChatGPT_Classic.dmg` (SHA-256 `a94117fb…1ff7b4`); app copied to `re-apps/chatgpt/app/ChatGPT Classic.app`. |
| Signature | Developer ID Application: OpenAI OpCo, LLC, **Team 2DC432GLL2**. Notarized; `spctl` accepted; signed 16 Jul 2026. |
| Method | **Static only; never launched.** The design system is in two places: `Contents/Frameworks/Assets.framework/…/Assets_Assets.bundle/Assets.car` (966 colour renditions, 392 custom vector glyphs, 11 Lottie animations) and the 115 MB `ChatGPT.framework`, which still exports about 187,000 Swift symbols. Static getters and stored-property initialisers were found by name and their arm64 constants decoded. Tools: `assetutil`, `dyld_info`, `otool`, `llvm-objdump`, capstone. Dumps are in `/tmp/re-chatgpt-out/`. No prompt injection was found. |
| Labels | Values are exact unless marked "inferred". |

### 2.1 Colours (Assets.car `ChatGPT/*` and `OneOff/*`; Display P3)

| Role | Light | Dark | Colour name |
|---|---|---|---|
| Window / conversation canvas | `#FFFFFF` | `#212121` | `ChatGPT/bg/primary`, `OneOff/MainSurfacePrimary` |
| Secondary / tertiary surface | `#E8E8E8` / `#F3F3F3` | `#303030` / `#414141` | `ChatGPT/bg/secondary`, `bg/tertiary` |
| Elevated panel / popover | `#FFFFFF` | `#303030` | `ChatGPT/bg/elevated/primary` |
| **Sidebar tint** (over the native sidebar material) | black 1 % | **white 10 %** | `ChatGPT/component/Sidebar/bg` |
| Card | `#F7F7F8` | `#1E1E1E` | `OneOff/BackgroundCard` |
| Composer field / border | `#FFFFFF` / black 10 % | `#212121` / `#888` 50 % | `OneOff/InputMessageBackground`, `InputMessageBorder` |
| User bubble | black 5 % | white 13 % | `OneOff/UserMessageBackground` |
| Code block | `#F8F8F8` | `#212121` | `OneOff/CodeBlockBackground` |
| Separators light / default / heavy | black 5 / 10 / 15 % | white 5 / 15 / 20 % | `ChatGPT/border/*` |
| Text primary / secondary / tertiary | `#0D0D0D` / `#5D5D5D` / `#8F8F8F` | `#FFFFFF` / `#CDCDCD` / `#AFAFAF` | `ChatGPT/text/*` |
| Accent (text / icon) | `#3A83F7` | `#63A8F8` | `ChatGPT/text/accent` |
| Accent hover / press wash | `#0285FF` 4 / 9 % | `#99CEFF` 15 / 20 % | `interactive/bg/accent/*` |
| Primary button (inverted ink) | `#0D0D0D`; hover 80 %, press 90 % | `#FFFFFF`; hover 80 % | `interactive/bg/primary/*` |
| Ghost / row hover and selected | black 5 % | white 10 % | `interactive/bg/secondary/hover`, `/selected` |
| Focus ring | `#0D0D0D` | `#FFFFFF` | `interactive/border/focus` |
| Error / warning / success text | `#FF002A` / `#D25E28` / `#1F4E25` | `#FF8583` / `#F1A275` / `#EFFAF3` | `text/status/*` |
| Error / warning / success bg | `#FFF0F0` / `#FDF5F1` / `#DEF3E5` | `#4D100E` / `#45240D` / `#1F4E25` | `bg/status/*` |
| **Agent surface / border** | black 4 % / 5 % | white 8 % / 10 % | `OneOff/AgentBackground`, `AgentBorder` |
| Codex theme | text `#539AF8`, bg `#FFFFFF` | text `#A4CDFB`, bg `#0D0D0D` | `ChatGPT/theme/codex/*` |
| PR open / merged / closed / draft | `#008C2E` / `#8E3CF3` / `#D6303D` / `#59636E` | `#69BA65` / `#C26FFD` / `#FD756F` / `#B2B2B2` | `OneOff/PR-foreground/*` (backgrounds at 20 %) |
| Tool running text | `#CDCDCD` | `#4A4A4A` | `OneOff/ToolInProgressText` |

### 2.2 Shape, type and motion

| Token | Value | Evidence |
|---|---|---|
| Fonts | **SF only**, through semantic text styles. No OpenAI Sans or Söhne is bundled; the only bundled fonts are for maths. | `OpenAIFont.OpenAI.*` initialisers → `.style(Font.TextStyle.X)`; `mathFonts.bundle` |
| Line-height multiple | largeTitle 1.15, title 1.16, title2 1.22, title3 1.20, headline 1.17, everything else **1.35** | `Font.TextStyle.lineHeightMultiple` |
| Weight | headline semibold; nav title medium | `Font.TextStyle.defaultWeight`; `ConversationNavigationBarCenterTitleLabel` |
| Elevation 1 | black 5 %, blur 16, y 4 | `Elevation.OpenAI.elevation1` |
| Elevation 2 | black 10 %: blur 15 y 10 + blur 6 y 4 | `elevation2` |
| Elevation 3 | black 10 %: blur 10 y 8 + blur 25 y 20 | `elevation3` |
| Elevation 4 | black 10 %, blur 25 y 20 | `elevation4` |
| Radii | card **12**; rounded button 12; sheet 28; user bubble **16**; file chip 12; autocomplete popover 14 / items 8; **composer 16** (Mac) | `RoundedRectangle.standardCardRadius`, `OAISheetConstants`, `MessageRowStyle.userMessageBackgroundCornerRadius`, `MessageInputStyle` (Mac closure) |
| Spacing | message row vertical 12; user ↔ assistant gap 32; inline actions 12; sheet padding 24 | `MessageRowStyle.*`, `OAISheetConstants.*` |
| User bubble | insets 2 / 13 / 8 / 13; max width 66 % | `userMessageInnerPadding`, `userMessageProportionalFraction` |
| **Chat column** | **992** on macOS (728 elsewhere) | `UIConstants.chatMaxWidth` (`platform == .macOS ? 992 : 728`) |
| Fade above composer | 40 | `UIConstants.conversationGradientMaskHeight` |
| Motion | conversation easeInOut 0.2 s · banner spring 0.3 / 0.825 · composer chip spring 0.375 / 1.0 · autocomplete spring 0.2 / 0.7 · nav-bar content spring 0.2 · launcher snapping spring 0.5 / 1.0 (edge inset 20) | `Animation.conversation`, `.defaultBannerBar`, `.messageInputChip`, `MessageInputAutocompletePickerStyle.animation`, `WindowSnapper.Configuration` |
| Circular spinner | 32, stroke 4, angular gradient, **0.8 s** per turn, track 40 % | `OpenAICircularProgressStyle` |

### 2.3 Main-window composition

```
┌───────────────────────────────┬───────────────────────────────────────────────────┐
│ ● ● ●  [≡]                    │ [≡][✎]  ← 117 / 137 offset   Title / Model ⌄  [✎][⋯]│ nav bar 52 (40 compact)
│                               │ pad 12 leading / 10 trailing; buttons 34×28        │
├───────────────────────────────┤                                                   │
│ Sidebar: ideal 250 (200–500)  │        ┌──────── chat column ≤ 992 ────────┐      │
│ native material + tint        │        │ assistant text …  ⬤               │      │
│ (black 1 % / white 10 %)      │        │         ┌ user bubble r16 ┐       │      │
│ header rows ≥ 34              │        │         └ ≤ 66 % wide     ┘       │      │
│ Projects · GPTs · Library     │        └───────────────────────────────────┘      │
│ history                       │         ░░ 40-pt fade mask ░░                     │
│                               │   ┌─ composer r16 · min-h 60 · pad 16/16/16 ──┐  │
│                               │   │ [+] Ask anything…               [🎙] [⬆30] │  │
│                               │   └────────────────────────────────────────────┘  │
└───────────────────────────────┴───────────────────────────────────────────────────┘
  detail column minWidth 400 · root min 700 × 500 · canvas = split with a 220 min pane, 1-pt divider
```

| Aspect | Spec | Evidence |
|---|---|---|
| Window | AppKit `ChatGPTMainWindow` hosting SwiftUI. Style mask `0x800F`: titled, closable, miniaturisable, resizable, **fullSizeContentView**. | `initWithContentRect:styleMask:` at `0x27788` |
| Titlebar | `toolbarStyle = 3` (**.unified**), `titlebarAppearsTransparent = YES`; the SwiftUI toolbar is bridged through `sceneBridgingOptions`. | `0x27820–0x27830` |
| Inset or full-bleed | **Full-bleed** `NavigationSplitView`, `.balanced` style | stubs at `0x17b1d0` |
| Sidebar column | min 200, **ideal 250**, max 500. A native sidebar material with a tint over it (dark: white 10 %). | `navigationSplitViewColumnWidth(200, 250, 500)` at `0x17b770` |
| Top bar | **52** (compact 40). Leading padding 12 / 6, trailing 10 / 4. The **offset beside the traffic lights is 117 with one button and 137 with two** (`TrafficLightButtonAdjustment {singleButton, doubleButton}`), otherwise 32. | `ConversationNavigationBarContent.measuredBody`; `0x76fd7c` |
| Top-bar contents | Leading: sidebar toggle (`sidebar-mac` glyph) and new chat (`compose-mac`). Centre: title, **model picker**, or title + model picker. Trailing: more menu and upsell pill. *(Inferred from types and glyphs.)* | `ConversationNavigationBarTitleType` |
| Toolbar button | 34 × 28 (compact 28 × 24), icon box 20 (16), icon font 18 (15), continuous rounded rect. Icon ink 60 % at rest, 77 % active, 25 % when disabled or the window is inactive. Background fg 6 % on hover, 10 % pressed. | `MacToolbarButtonStyle.makeBody`; `ConversationNavigationBarButtonLabel._normalFontSize` |
| Sidebar sections | gizmo, history, gptStore, appDirectory, places, projectsHome, imageGen, imageLibrary, fileLibrary, scheduledAutomations, upsell. Header rows ≥ 34. | `HistoryViewModel.SidebarItem`; `HistoryHeaderCell._minimumRowHeight` |
| **Composer (Mac)** | Max width 992, outer padding 0 / 16 / 16, **min height 60, radius 16** (a capsule until it grows past 60). Fill fg **5 %**, stroke fg **10 %**, **no shadow**. Outer inset 4, inner 2 / 4 / 4. Text insets 9 top / 10 bottom / 16 trailing, max text height 200. Button spacing 8, min button 24, **send 30**. Placeholder 50 %. Info banner 12 above. Liquid Glass variants exist behind a flag (gradient 0.05 / 0.3, `Glass.regular`). | `MessageInputStyle.init` (Mac `DeviceDependent` closures); `MessageInputPrimaryButtonPartStyle.fontSize` |
| Launcher (⌥Space) | Floating `NSPanel`: level 8, shadow, clear, movable by background. **Width 440, radius 24**; list icons 24; hover fg 6 %. Default position bottom-left, centre, bottom-right or last. | `LauncherPanel`, `LauncherView`, `LauncherDefaultPosition` |

### 2.4 Agent surfaces (agent mode, Codex tasks, deep research, canvas)

| State | Shown as | Evidence |
|---|---|---|
| Streaming | A zero-width space plus **"⬤"** (U+2B24) at the end of the streaming text | `TypingIndicator.symbol` (bytes `e2 80 8b e2 ac a4`) |
| Loading | **DotBall**: a Metal-shader dot that kicks, flies, bounces three times, rolls back and collapses (timings internal) | `DotBall` module, `DotBallKickConfiguration`, `DotBall_DotBall.bundle/default.metallib` |
| Working | `ShimmeringTextView`: easeInOut sweep, **1.8 s** period, band about 0.33 *(inferred)* | `ShimmeringTextView` convenience init |
| Codex task running | `CodexTaskProgressView`, **17 pt** (scales with Dynamic Type), driven by its start date | |
| Done / unread | `CodexUnreadTaskIndicatorView`, an **8-pt dot** | |
| Waiting | Row labels **"Awaiting approval"** and **"Needs input"**. Approval cards: "Codex wants to run a command", "Codex wants to change files", "Codex needs your approval". Buttons: Allow for this chat / Always approve / Always allow host. | `codex_task_row_awaiting_approval`, `codex_realtime_*_approval_title` (`CompressedStrings/en.json.lzfse`) |
| Other states | Queued, Steering conversation, Reviewing, Approved / Denied / Stopped / Timed out, "Pursuing goal", "%@ of %@ tasks completed", "N agents" | `codex_remote_*` |
| Agent (browser) mode | An arrowhead cursor overlay with a "thought" caption; an "Approve for me" approval row | `AgentArrowheadStaticOverlayView`, `BrowserUseApprovalMessageRowPart` |
| Deep research / reasoning | Waiting / task / finished parts; an expandable reasoning status row (queries, results, code, images) | `MessageToolDeepResearchTask*Part`, `NewReasoningSessionStatusRow` |
| Canvas | Focus mode is a split view: 220 min side pane, **1-pt divider** | `SplitView.init` at `0x66e07c`; `SplitView.dividerSize = 1` |
| Lottie | `codex-looking-around` (60 fps, 247 frames, about 4.1 s), `sora-loading-*`, `commerce-completion` | dotLottie inside Assets.car |
| Custom glyphs | 392, including `agent`, `subagent`, `codex`, `host-terminal`, `queue`, `steer`, `skills`, `hooks`, `sidebar-mac`, `compose-mac` | `OpenAI/Symbols/*` vector glyphs |

**Signature:**
- **Quiet neutral greys**: canvas `#212121`, ink `#0D0D0D`, alpha overlays, and blue only for links.
- A transparent unified titlebar over a 992 column.
- The **"⬤" streaming dot**, now the DotBall.
- A **soft composer**: radius 16, 5 % fill, 10 % hairline, no shadow.

---

## 3. Dia

| | |
|---|---|
| Copy analysed | **1.55.1 (89833)**. Downloaded from the official download page: `diabrowser.com/download` → `https://releases.diabrowser.com/release/Dia-latest.dmg`, stored at `re-apps/dia/download/Dia-latest.dmg` (SHA-256 `3c1d8444…1ff7b4`). App copied to `re-apps/dia/app/Dia.app`. |
| Signature | Developer ID Application: The Browser Company of New York Inc., **Team S6N382Y83G**. Notarized; `spctl` accepted; signed 30 Oct 2026; bundle `company.thebrowser.dia`. |
| Method | **Static only; never launched.** The arm64 binary is stripped, but it keeps Swift class and field names. Each field's offset pointer was traced to the functions that read and write it, and those were disassembled. Asset catalogs come from the many resource bundles. The chat panel is a Svelte web app bundled at `Resources/web-chat-resources/`, and its CSS custom properties give exact tokens. No prompt-injection content was found; the bundled agent prompts were not read. Scratch output is in `/tmp/re-dia-out/`. |
| Labels | **E** = exact literal from the binary or resources. **I** = inferred. |
| Bundle abbreviations | `WT` = `BoostBrowser_WindowTreatment.bundle`, `SA` = `BoostBrowser_SharedAssets.bundle`, `BA` = `ARCClients_BaseAssets.bundle`, `CSS0` / `CSS4` = `web-chat-resources/dist/app/immutable/assets/0.Crjtp9Ln.css` / `4.Diw_TXEN.css`. `fn 0x…` = an address in `Contents/MacOS/Dia`. |

### 3.1 Colour sets (asset catalogs, all E)

| Role | Asset | Light | Dark |
|---|---|---|---|
| Window ground tint | WT `WindowBackground/BaseTint` | `#FFFFFF` 80 % | `#000000` 40 % |
| Window tint gradient | WT `WindowTint/BaseGradient` | `#FFFFD7` → `#FFD9FB` @ 30 % | `#516CD3` → `#FFD9FB` @ 18 % |
| Window overlay gradient | WT `WindowBackground/OverlayGradient` | `#E2E0FF` → `#FAECFF` @ 30 % | same |
| Tint ladder | WT `BaseTint/primary…quaternary` | white 65 / 50 / 35 / 5 % | black 50 / 35 / 20 / 5 % |
| Content behind panes | WT `WindowContent/BaseTint` | `#FFFFFF` 80 % | `#121212` 60 % |
| **Signature theme gradient** | SA `Themes/Default/Background/Gradient/Stop1…6` | `#FFFFFF` → `#FFFADE` → `#F0A775` → `#A869A3` → `#865FEF` → `#4160FF` | — |
| Window textures | `ARC_WindowThemeUI.bundle`: `grain`, `sand`, `denim`, `tweed` | | |
| Sidebar border | `BoostBrowser_Window` `SidebarBorderColor` | white 30 % | white 30 % |
| Sidebar item / hover | BA `SidebarItemBackground` / `…Hovered` | `#0E0F10` 5 % / 10 % | `#FAFBFF` 10 % / 15 % |
| Sidebar separator | BA `SidebarSeparator` | black 15 % | white 15 % |
| Tab selected / unselected / hover / pressed | TabUI `TabBackground*` | `#FFFFFF` / black 6 % / white 55 % / white 70 % | `#000000` / white 6 % / 16 % / 31 % |
| Tab title selected / unselected | TabUI `TabTitle*` | black 100 / 68 % | white 100 / 78 % |
| Selected-tab shadow | TabUI `TabSelectedShadow` | black 12 % | white 15 % |
| Panel / card | AssistantPanelUIBase `Background` / `TransparentBackground` | `#FEFFFF` / white 85 % | `#2D2D2D` / `#181818` 80 % |
| Panel border | AssistantPanelUIBase `Border` | `#0F182C` 8 % | `#787D86` 32 % |
| Panel shadow | `Shadow/Default` | black 12 % | black 12 % |
| Text ladder | SA `Primitives/Primary0…1300` | black 100 / 95 / 90 / 85 / 80 / 75 / 60 / 53 / 46 / 30 / 22 / 18 / 12 / 9 / 5 % | white, same alphas |
| Foreground tiers (older set) | BA `ForegroundPrimary/Secondary/Tertiary` | `#0E0F10` 90 % / black 50 % / 30 % | white 80 / 50 / 30 % |
| **Accent (Dia marigold)** | SA `Primitives/DiaOrange`, `Accent/Strong`, `/Medium`, `/Link` | `#D47100`, `#FCBF49` 90 %, `#FCBF49` 60 %, `#A96243` | `#FCBF49`, `#FCBF49`, `#FCBF49` 20 %, `#FFA883` |
| Command bar, Assistant mode | BoostCommandBar `Focus/Assistant`, `Hover/`, `Input/Cursor/`, `PrimaryText/` | ring `#FCBF49` 70 %, hover 8 %, caret `#FCBF49`, text `#4F3400` | 70 %, 12 %, `#FCBF49`, `#FFF8EB` |
| Command bar, Search mode | `Focus/Search`, `Input/Cursor/Search` | `#B4B9C2` 70 %, caret `#6395FC` | `#787D86` 70 %, `#4A77D4` |
| Assistant control chip | SA `AssistantControlBackground` / `Hovered` | `#FDEED8` / `#FCDDB1` | `#31210A` / `#624214` |
| Typing indicator | SA `TypingIndicator/*` | bg `#E6E6E6` 95 %, dots `#B0B2B4` | white 12 % / 25 % |
| Attachment glow | SA `Attachments/FancyAttachmentOutline1…3` | `#DF7AE1` 40 %, `#EC9B61` 30 %, `#F3E28C` 50 % | |
| Skill colours | SkillModels `BrandColors/Code / Search / Write` | `#4DA839` / `#8048A6` / `#ECB43E` | `#6EDB60` / `#CF92F8` / `#F8D651` |
| Status | SA `Badge`, `SecurityVulnerability` | `#EB4648`, `#FF3B30` | |
| Focus ring / loading border | BA `FocusRing`, `LoadingPageBorder` | `#458AFF`, `#0C50FF` | —, `#2AB6F6` |

The code also defines a semantic palette in fn `0x101036a2c`, `SharedAssets.ColorPalette.*` (E names): surfaceDimmer, surfaceToken(Hovered/Text), surfaceHovered, surfaceBrighter, surfaceHighlighted, containerElevated, containerAccentText, textSecondary, textInverseSecondary, shadowSoft and shadowProminent. Its values are computed per appearance; only some alphas (0.04, 0.08, 0.18) are visible.

### 3.2 Shape, type and motion

| Token | Value | E/I | Evidence |
|---|---|---|---|
| Window corner radius | **16** on macOS 26+, otherwise 11 | E | fn `0x105be2fdc` (`isOSVersionAtLeast(26,0,0)` → 16.0 / 11.0) |
| **Pane (web card) radius** | **window radius − 6 = 10** (5 before macOS 26), so the corners are concentric | E | fn `0x105be3014` (`fadd −6`) → `WorkspacePresentationViewController.paneCornerRadius`; card `setCornerRadius:` in fn `0x105a7d458` |
| **Content inset** | **6 on all sides** | E | `contentInsets = fmov v0.2d,#6` at `0x1056be7a8`; layout fn `0x105bc7708` |
| Split gap | 3 per side, 6 between panes | E/I | fn `0x105bc7708` |
| Card corner curve | `continuous` | E | `setCornerCurve:` in fns `0x105a7d458` and `0x105a7e054` |
| Card hairline | 1 pt; black 6 % (light) | E | fns `0x105a7d600` and `0x105a7f66c` |
| **Focused-pane ring** | 2 pt border, **radius = card radius + 3** (outset, continuous), theme colour shifted 0.12, at **50 %** alpha | E | fn `0x105a7e054` |
| Platter behind panes | theme colour at 0.45 and 0.65 alpha | E/I | fn `0x1056bdd34` |
| Tab highlight radius | 10 | E | `TabUI.TabBackgroundView` init `0x1043b07b8` |
| Favourites dock items | radius 10, stroke 3, height 41 | E | `TabSurface.TabDockView` `0x10532e6e4` |
| Assistant panel | **radius 20**, clipped, own background, no system material by default | E | `AssistantPanelRootView` init `0x104accecc` |
| Glow / halo | radius 18; halo speed 1; fade-out 0.2 s. Breathing light: intensity 4, falloff 2, 60 s loop | E | `PowerUp.HaloView`, `EdgeLightView`, `BreathingAreaLightView` |
| Minimum window | 500 × 446 | E | fn `0x105bb5aa0` |
| Side panel | minimum 240; maximum ⅔ of window width minus the assistant sidebar | E | fn `0x105bc860c` |
| Vertical tab sidebar | saved width, or **190** | E/I | `fcsel 190.0` at `0x105bc7c64` |
| Top band | a **42** constant plus 3–6 padding (36 in another branch) | E values, I meaning | `0x105bc80f8`, `0x105bc7e54` |
| Native UI fonts | ABC Favorit (and Mono), Söhne Breit, GT Ultra, Pitch, Inter, Inconsolata, … | E | `ARCClients_FontsManager.bundle` |
| Chat fonts | **ABC Oracle Book** text, **Exposure 550** display, Inconsolata code, New York Small | E | `CSS0` `@font-face` |
| Chat type scale | h1 22/500, h2 17/600, h3 16/600, body 15, bubble 14, code 14, label 13, thinking 12/500, timestamp 11 | E | `CSS0` `--dia-fs-*` |
| Chat radii | bubble 17, card 10, attachment 20, code 12, dialog 20, pill 999, tooltip 6 | E | `CSS0` `--dia-radius-*` |
| Chat spacing | inset 8/16/20; bubble padding 24 × 16 (compact 16 × 14); gaps 10/12/14 | E | `CSS0` `--dia-space-*` |
| Springs (chat) | slow 1.113 s, fast 0.696 s; ζ = 0.95 spring sampled into CSS `linear()` (121 steps); a second spring ζ = 0.68 | E | `CSS0`; `nodes/4.BdEmGkhD.js` |
| Native springs | `ARCUI.SpringAnimationStyle`: firm, firmSlow, firmExtraSlow, firmFast, springy, springyFast, springyExtraFast (each dampingRatio + response). **Values not recovered.** | E names | |
| Tooltip | 28 tall, radius 6, 0.1 s fade + 2 pt slide; shadow `0 0 0 .5px #0000001a, inset 0 0 0 1px #fff, 0 4px 8px #0000001a` | E | `CSS0` `.dia-tooltip` |

### 3.3 Composition

```
╭──────────────────────── window, R = 16 (macOS 26) / 11 ────────────────────────╮
│ ●●●  [tab strip + own window controls · 42-pt band constant + 3–6 pad]          │ ← tinted, textured,
│ 6 ┌──────── pane, r = R − 6 = 10 ─────────┐3│3┌── pane r = 10 ───┐ 6 │ assistant│   translucent ground
│   │ 1 px hairline black 6 %               │ │ │ focused: 2 px     │   │ panel r20│   (Metal gradient +
│   │ web content                           │ │ │ ring, r + 3, 50 % │   │ min 240  │    grain)
│   └───────────────────────────────────────┘ │ └───────────────────┘   │ ≤ ⅔ W    │
│ 6                                                                     6          │
╰──────────────────────────────────────────────────────────────────────────────────╯
 Sidebar mode: vertical tabs, saved width or 190 · minimum window 500 × 446
```

| Aspect | Finding | E/I |
|---|---|---|
| Inset or full-bleed | **Inset cards, as in Arc.** Each pane is a 10-radius card on a tinted, translucent, Metal-rendered gradient ground with a 6-pt moat. The pane corners are concentric with the window corners. | E |
| Titlebar | Title hidden, titlebar transparent. The standard buttons are hidden on at least one path, and the tab strip owns a `windowControls` view (`TabStripContainerViewController`; BA `DimmedWindowControls` `#000` / `#F3F3EA`). | E/I |
| Tab treatment | Two layouts: `tabStrip` (horizontal, top) or `sidebar` (vertical). Tab-layout presentation is anchored, floating or hidden. The selected tab is a **solid white (light) or black (dark) chip with a 12 % shadow**; unselected tabs are 6 % washes. | E |
| Splits and focus | Panes are sized by width fractions with a minimum width, snap to the midpoint and reorder by drag. **Only the focused pane gets the outset 2-pt ring.** | E |
| Omnibox / command bar | A floating command bar with Assistant (marigold), Search (blue caret) and Go modes. Toolbar: attach, capture, voice, model, response mode and send. | E |

### 3.4 AI surfaces

```
╭──── AssistantPanelRootView r20, border #0F182C 8 % / #787D86 32 % ────╮
│ thread column 596 + 32 gutters, top 2.5 rem                            │
│                  ┌ user bubble r17, pad 24×16, ≤ 80 % wide ┐           │
│                  └ user-colour gradient 40 % → 30 %        ┘           │
│ ╭ activity bubble r14, min-h 34, pad 8×12, accent hairline ╮          │
│ │ ● ● ●  Working…   (dots wave 1.1 s; text shimmer 1.5 s)   │          │
│ ╰───────────────────────────────────────────────────────────╯          │
│ ┌ browser tab ⟳ rotating conic border #9288FF→#D3CEFF 2 px 2.03 s ┐    │
│ [ command bar, Assistant mode: #FCBF49 ring and caret ]                │
╰────────────────────────────────────────────────────────────────────────╯
```

| State | Treatment | Evidence |
|---|---|---|
| Panel | Native `AssistantPanelRootView` (radius 20, border, gradient, contact shadow) hosting a **transparent web view** (Svelte). The panel can be an overlay or a sidebar; the preferred layout is sidebar or PiP. | panel fields; `CSS0` (`data-surface=chat` with transparent bg); `AssistantPanelLayoutMode` |
| **Working / waiting** | An "activity bubble": min height 34, padding 8 × 12, radius 14 (17 compact), accent hairline. Labels **"Working"** and **"Waiting for you"**. Three 6-pt dots wave over 1.1 s (offsets 0.1 / 0.2 s, lift −3 px, opacity 0.4 → 0.85). It enters at scale 0.65 with a 12 px rise over 900 ms. | `CSS4` `.svelte-3qgw9a`; `nodes/4.BdEmGkhD.js` |
| Thinking | Shimmer swept across the text (250 % background, 1.5 s, `steps(90)`). With Reduce Motion, the text sits at 70 % ink instead. | `CSS0` `.dia-shimmer` |
| Agent working in a tab | Rotating **conic-gradient border trace** (`#9288FF` → `#D3CEFF`, 2 px, 2.03 s per turn); title shimmer 3.6 s; cursor glow `#635BFF` (blur 7 px, 1.15 s pulse); tab activity dots 3.45 px with a 1.25 s pulse. | `CSS4` `.browser-tab.running`, `.cursor-glow`, `.dots.svelte-mxvxlb` |
| Done | Check-mark draw and pop animations; collapsible sections un-blur from 14 px and scale up from 0.5. | `CSS4` `check-draw` / `check-pop` |
| Native light effects | Metal shaders: edgeLight, halo, breathingAreaLight, chromaPowerUp, rippleShimmer, colorSweep, spotlight, a page-loading indicator, and the thinking orb plus logo particles (names only). | `PowerUp.bundle/default.metallib`, `NavigationBar.bundle/default.metallib` |

**Signature:**
- A **warm pastel gradient window** with texture, around **6-pt concentric-inset cards**.
- AI state drawn **as light**: shimmering text, a rotating gradient border, halo and edge glow.
- **Marigold `#FCBF49`** reserved for assistant mode.

**Not recovered:**
- the native widths of the assistant sidebar, command bar and tab strip (beyond the 42 / 36 / 190 constants);
- the `SpringAnimationStyle` numbers;
- the panel shadow geometry;
- the shader maths.

---

## 4. Zed

| | |
|---|---|
| Source | `git clone --depth 1` of `github.com/zed-industries/zed` into `/Volumes/Lacie/Workspace/oss/re-apps/zed/src`, commit **`bc6fc117403d`** (2 Nov 2026). Read only; not built. Zed ships as GPL source, so no binary was needed. |
| Stack | Rust + GPUI (Metal). AppKit is used only for the window (`crates/gpui_macos/src/window.rs`). |
| Paths | All evidence paths below are relative to `src/`. "TV" means `crates/agent_ui/src/conversation_view/thread_view.rs`. |
| Correction to common belief | The default **UI font is 16 px** (`assets/settings/default.json:71`). The buffer font is 15 px. The window rem = `ui_font_size` (`crates/theme_settings/src/settings.rs:612`). |

### 4.1 Colour tokens: One Dark / One Light (`assets/themes/one/one.json`)

| Token | One Dark | One Light | Evidence (Dark line / Light line) |
|---|---|---|---|
| `background` (window chrome) | `#3B414D` | `#DCDCDD` | :18 / :437 |
| `title_bar.background` | `#3B414D` | `#DCDCDD` | :41 / :460 |
| `status_bar.background` | `#3B414D` | `#DCDCDD` | :40 / :459 |
| `surface` / `elevated_surface` / `panel.background` | `#2F343E` | `#EBEBEC` | :16-17, :49 / :435-436, :468 |
| `tab_bar.background` / `tab.inactive_background` | `#2F343E` | `#EBEBEC` | :44-45 / :463-464 |
| `editor.background` / `tab.active_background` / `toolbar.background` | `#282C33` | `#FAFAFA` | :58, :46, :43 / :477, :465, :462 |
| `terminal.background` | `#282C34` | `#FAFAFA` | :71 / :490 |
| `border` (also `pane_group_border` by fallback) | `#464B57` | `#C9C9CA` | :10 / :429; `schema.rs:503-507` |
| `border.variant` | `#363C46` | `#DFDFE0` | :11 / :430 |
| `border.focused` / `border.selected` | `#47679E` / `#293B5B` | `#7D82E8` / `#CBCDF6` | :12-13 / :431-432 |
| `panel.focused_border` (null in JSON, so fallback) | `#2870BD` | `#0588F0` | `crates/theme/src/default_colors.rs:252` / `:98` |
| `text` / `text.muted` / `text.placeholder` = `disabled` / `text.accent` | `#DCE0E5` / `#A9AFBC` / `#878A98` / `#74ADE8` | `#242529` / `#58585A` / `#7E8086` / `#5C78E2` | :30-34 / :449-453 |
| `element` bg / hover / active = selected | `#2E343E` / `#363C46` / `#454A56` | `#EBEBEC` / `#DFDFE0` / `#CACACA` | :19-23 / :438-442 |
| `ghost_element` hover / active = selected | `#363C46` / `#454A56` (rest is transparent) | `#DFDFE0` / `#CACACA` | :25-29 / :444-448 |
| success = created | `#A1C181` (bg `#A1C1811A`, border `#38482F`) | `#669F59` | :140-142 / :557-559 |
| warning = modified | `#DEC184` (bg `#DEC1841A`, border `#5D4C2F`) | `#A48819` | :146-148 / :563-565 |
| error = deleted | `#D07277` (bg `#D072771A`, border `#4C2B2C`) | `#D36151` | :116-118 / :533-535 |
| info | `#74ADE8` (bg `#74ADE81A`, border `#293B5B`) | `#5C78E2` | :128-130 / :545-547 |
| `hidden` (unfocused inactive tab text) | `#878A98` | `#7E8086` | :119 / :536 |
| `players[0]` cursor / selection | `#74ADE8` / `#74ADE83D` | `#5C78E2` / `#5C78E23D` | :151-153 |
| agent player colour (`players.agent()`, the last player) | `#A1C181` | `#669F59` | :186 / :603; `crates/theme/src/styles/players.rs:130` |
| scrollbar thumb | `#C8CCD44C` | `#383A414C` | :52 / :471 |

**Luminance order (dark):**
- Chrome (`#3B414D`) is lighter than panels (`#2F343E`), which are lighter than the editor and terminal (`#282C33`).
- So the **work surface is the darkest plane**, framed by lighter chrome.
- The sidebar or panel sits *between* the chrome and the content in tone.

### 4.2 Shape, type and motion

| Token | Value | Evidence |
|---|---|---|
| UI font | `.ZedSans` = **IBM Plex Sans** 16, weight 400 | `default.json:59-71`; `crates/gpui/src/text_system.rs:1268` |
| Buffer font | `.ZedMono` = **Lilex** 15, line height 1.618 (24.27) | `default.json:31-54`; `buffer_line_height.rs:17` |
| Terminal font | buffer font, line height 1.3. Left gutter = 1 cell; no top padding | `default.json:2170`; `terminal_element.rs:1253-1279` |
| Agent composer and user messages | buffer font at **12 px** (`agent_buffer_font_size`) | `default.json:79`; `message_editor.rs:2089` |
| Label sizes | Large 16 · Default 14 · Small 12 · XSmall 10 | `crates/ui/src/styles/typography.rs:137-145` |
| Headline sizes | XS 14.08 · S 16 · M 18 · L 20.32 · XL 22.88; line height 25.6 | `typography.rs:181-199` |
| Icon sizes | Indicator 10 · XS 12 · Small 14 · Medium 16 · XL 48 | `components/icon.rs:73-96` |
| Button heights | Large 32 · Medium 28 · **Default 22** · Compact 18. Horizontal padding 8 (L/M) or 4; gap 4 | `button/button_like.rs:465-471, 816-823` |
| Spacing | `DynamicSpacing` Base00…Base48 = n px at Default density. Compact = n − 4, Comfortable = n + 4 (Base04 = 2/4/6, Base08 = 4/8/10, Base16 = 14/16/18) | `crates/ui/src/styles/spacing.rs:29-44` |
| Radius scale | xs 2 · sm 4 · md 6 · lg 8 · xl 12 · 2xl 16 | `gpui_macros/src/styles.rs:1228-1272` |
| Radii in use | Button 4. **Tab 0.** ListItem 0 (4 when rounded). Popover, menu, tooltip and modal 8. User message and tool card 6. Indicator dot 6 × 6 (round) | `button_like.rs:811`; `tab.rs:145-166`; `styled_ext.rs:6-12`; TV:7372, 10031 |
| Elevation 1 (panels) | no shadow | `crates/ui/src/styles/elevation.rs:42-91` |
| Elevation 2 (popover, menu) | (0, 2, 3, black .12) + (0, 1, 0, .06 dark / .03 light) | same |
| Elevation 3 (modal, toast) | (0, 2, 3, .12) + (0, 3, 6, .08) + (0, 6, 12, .04) + (0, 1, 0, .12) | same |
| Modal offset | 80 from the top | `workspace/src/modal_layer.rs:317` |
| Durations | Instant 50 · **Fast 150** · Slow 300 ms | `crates/ui/src/styles/animation.rs:8-12` |
| Toast entrance | 150 ms ease-out-quint, y offset 40 → 0, α 0.4 → 1. Auto-dismiss 10 s | `animation.rs:52-78`; `toast_layer.rs:15-16` |
| "Breathing" pulse | `pulsating_between(min, max)`: t = sin(2πδ), breath = (t³ + t)/2, over **2 s**. Thread title while generating: α 0.4–0.8. "Loading…" / "Editing N files…": 0.3–0.7 | `gpui/src/elements/animation.rs:542-553`; `ai/thread_item.rs:357-364` |
| Spinner | braille Dots ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏, **10 frames / 1 s**, muted. Sand variant: 35 frames / 2 s | `label/spinner_label.rs:43-57` |
| Rotating LoadCircle | 2 s linear, `repeat_synced` | `traits/animation_ext.rs:26-38` |

### 4.3 Main-window composition

```
x=0          300 301                                                       W
┌────────────┬┬─────────────────────────────────────────────────────────────┐
│●●● ⌕Search ││ myrepo ⌄  ⎇ main          … facepile …          [avatar ⌄]  │ 34  title_bar #3B414D
├────────────┤├─────────────────────────────────────────────────────────────┤ 1 px border #464B57
│ threads    ││ AGENT PANEL (left dock) │ PANE                    │ PROJECT  │
│ sidebar    ││ flex ≈ ½ of the rest    │┌ tab bar 32 #2F343E ───┐ │ PANEL    │
│ 300        ││ bg #2F343E              ││ active tab = editor   │ │ 240      │
│ (200–800)  ││                         ││ bg, no bottom rule    │ │ #2F343E  │
│ #2F343E    ││                         │├ toolbar ~35 ──────────┤ │          │
│ rows 34/53 ││                   1 px  ││ EDITOR #282C33        │ │1 px      │
│            ││         border + 6 px   ││ full-bleed; split     │ │          │
│            ││         resize strip    ││ divider 1 px #464B57  │ │          │
├────────────┤├─────────────────────────────────────────────────────────────┤ 1 px border
│ ◧ 🕘  + Add││ [◧][panels] diagnostics            Ln 1, Col 1  Rust [btns]  │ 30  status #3B414D
└────────────┴┴─────────────────────────────────────────────────────────────┘
```

| Aspect | Spec | Evidence |
|---|---|---|
| Inset or full-bleed | **Full-bleed.** No margins, radius or gaps. Planes are separated only by 1 px `border` (the workspace has `border_t_1` and `border_b_1`) | `crates/workspace/src/workspace.rs` (~:9895-9906) |
| Title bar | height **max(1.75 rem, 34) = 34**. Background `title_bar.background`. No bottom border of its own; the workspace top border supplies it | `crates/ui/src/utils/constants.rs:17-19`; `platform_title_bar.rs:309` |
| Traffic lights | `traffic_light_position = (9, 9)`; the AppKit container height is button height + 2 × 9 | `crates/zed/src/zed.rs:397`; `gpui_macos/src/window.rs:711-760` |
| Inset after the traffic lights | `TRAFFIC_LIGHT_PADDING` = **78** on the macOS 26 SDK (71 before; "+1px for window border"). Fullscreen 8. When the threads sidebar is open, the lights sit over the sidebar header and the title bar drops to `pl_2` = 8 | `constants.rs:10`; `platform_title_bar.rs:270-283` |
| Title-bar contents | Left: **project name** (ghost button, 12 px, opens recent projects) and **branch** (ghost button, GitBranch icon, muted). Middle: collaborator facepile. Right: update, sign-in, avatar menu | `crates/title_bar/src/title_bar.rs:297-398, 783-1262` |
| Tab bar | **32** tall, bg `tab_bar.background`. Tabs have **radius 0**, padding x 4, a 12 slot at the start and a 14 slot at the end (close on hover), 14 px label. The **active tab takes the editor colour and has no bottom border**, so it merges into the content. Inactive tabs keep the bar colour with a bottom rule | `crates/ui/src/components/tab_bar.rs:100-148`; `tab.rs:8-9, 79-176` |
| Unfocused pane | Tab text fades (active becomes `text.muted`, inactive becomes `hidden`). Content is not dimmed (`inactive_opacity 1.0`, `border_size 0`) | `workspace/src/item.rs:143-155`; `default.json:88-94`; `pane_group.rs:1477-1527` |
| Split divider | **1 px** in `pane_group_border` (#464B57), 4 px hit box; minimum pane 80 / 100 | `pane_group.rs:22-24, 1161, 1328-1341` |
| Agent-follow border | 2 px in the agent player colour at α 0.7 | `workspace.rs:9433-9468` |
| Docks | `panel.background` with a 1 px border on the inner edge. No shadow. 6 px resize strip | `workspace/src/dock.rs:25, 1313-1358` |
| Default docks | Agent panel left, flexible. Threads sidebar left, 300. Project panel right, 240. Terminal bottom, 320 | `default.json:880-2079` |
| Status bar | padding 4, gap 8, height **30** (4 + 22 + 4). Holds panel toggles (14 px icons; a toggled one is accent), diagnostics, cursor position and language | `workspace/src/status_bar.rs:150-290` |
| Notifications | bottom-right, 12 from the edge, 448 wide, elevation 3, padding 12. Toasts are bottom-centre | `workspace.rs:7118-7135`; `notifications/src/status_toast.rs:83-96` |

### 4.4 Agent surfaces: agent panel, thread view, threads sidebar

```
┌───────────────────────────────────────────────────────────────┐
│ [✦ Zed Agent] Refactor auth (14 muted)        [+][⤢][⋯]       │ 32  toolbar, bg #2F343E, border_b
├───────────────────────────────────────────────────────────────┤
│ bg panel #2F343E           content column max 850, centred    │
│   ┌─────────────────────────────────────────────────────┐     │ user box: py12 px8, r6,
│   │ Fix the login bug   (Lilex 12)                      │     │ bg #282C33, 1 px #464B57, shadow_md
│   └─────────────────────────────────────────────────────┘     │
│     Assistant markdown 14 px, no bubble (px20 py6, gap 12)    │
│     ⌕ Read src/auth.rs     inline tool: 13 px muted, ml 20    │
│     ┌ header ≈#313741 ──────────────────────────────┐         │ tool card: mx20 my6 r6,
│     │ ✎ auth.rs                          ⌄ (hover)   │         │ border #464B57CC, bg #282C33
│     │ diff …                                         │         │
│     ├────────────────────────────────────────────────┤         │
│     │ [✓ Allow ⌘Y] [✕ Deny ⌘⌥Z]   [Only this time ▾] │         │ permission row p4 g8
│     └────────────────────────────────────────────────┘         │
│   ⠹  1m 02s  ↓ 3.2k tokens      (py8 px22)                    │ generating row
│                   ┌ ⌄ Current: Add tests…      2 left ✕ ┐     │ plan bar, r_t 6, docked on the composer
├───────────────────┴─────────────────────────────────────┴─────┤ 1 px border_t
│ bg #282C33 (editor) py8 · column ≤ 850 · px8                   │ composer: 4–8 lines, Lilex 12
│ Message the Zed Agent, @ to include context, / for commands [⤢]│
│ [+][⇢][⚡][🧠]          ◔ 42%  Write ▾  Claude Sonnet ▾  [➤]  │ 22 px buttons; send = Filled + accent
└───────────────────────────────────────────────────────────────┘
```

| Surface | Spec | Evidence |
|---|---|---|
| Panel toolbar | **32** tall (the tab height), bg `tab_bar.background`, bottom border. Agent selector and thread title (14, muted) on the left; +, maximise and ⋯ on the right | `agent_panel.rs:6216-6255` |
| Content column | every entry centred within **max 850** | TV:7272-7280; `default.json:1204-1208` |
| Assistant messages | **no bubble**: bare markdown 14 px, padding x 20 / y 6, gap 12 | TV:7533-7544 |
| User message | bordered box: padding y 12 / x 8, **radius 6**, bg = editor, 1 px `border`, `shadow_md`. Hover border = `border.focused` @ 0.8. While editing, an edit toolbar floats at top −14 | TV:7355-7452 |
| Tool card | margin y 6, margin x 20, radius 6, border @ 0.8, bg = editor. Header bg = element ⊕ fg @ 2.5 %. **Dashed border when failed, rejected or cancelled** | TV:10031-10051, 9879-9881 |
| Inline tool (read, search, fetch) | no card: 13 px muted line with a kind icon. Expanded body has a left rule | TV:11423-11502 |
| Terminal card | header with cwd (XS mono); elapsed time shown after 10 s; LoadCircle 2 s; Stop in error colour; output max height 296 | `ui/terminal_tool_header.rs:143-232`; `entry_view_state.rs:30` |
| **Working** | no "Generating…" text. A row (py 8, px 22) holds a **braille spinner** (100 ms/frame, muted), elapsed time after 30 s, and "↓ N tokens" after 250 tokens. In the sidebar, the **thread title breathes α 0.4–0.8 over 2 s** and the icon slot shows a rotating LoadCircle | TV:8503-8603; `thread_item.rs:300-364` |
| **Waiting** (needs permission) | Inline in the card: **Allow** (✓ success colour), **Deny** (✕ error colour) and an "Only this time ▾" menu, with keybinding hints (⌘Y / ⌘⌥Y / ⌘⌥Z). A floating "Awaiting Confirmation (N)" bar above the composer uses the Sand spinner and a LoadingLabel. In the sidebar, a **Warning** icon (`#DEC184`) | TV:10882-10987, 4725-4766; `default-macos.json:296-299` |
| **Done** | Turn footer at **opacity 0.4, 1.0 on hover**: tokens • duration, 👍 / 👎, copy. In the sidebar, done-and-unread shows an **accent dot** (`#74ADE8`); seen threads show the agent icon in muted ink | TV:7979-8133; `thread_item.rs:300-364` |
| Error | Callout: padding 8, top border, bg error @ 0.08, XCircle, Retry (Filled) and Copy. Failed tool: `Close` icon in error colour with a dashed card | `components/callout.rs:128-162`; TV:12715-12863 |
| Plan / todo | docked on the composer's top edge (radius-top 6). "Current: … · N left". Rows are 12 px: TodoProgress (accent, rotating 2 s), TodoComplete (success, struck through), pending (muted) | TV:3958-4069, 4831-4986 |
| Composer | full-width band with bg = **editor**, top border, padding y 8. **No card or radius.** The editor auto-sizes between **4 and 8 lines**, Lilex 12 / 19.4. Toolbar: + context, follow, fast, thinking · context ring (16 px, warning at ≥ 85 %) · profile · mode · model ▾ · **Send** (Filled, accent icon) which becomes **Stop** (Tinted Error) while running. An empty thread lets the composer fill the panel | TV:5475-5869, 6572-6616, 8470-8498 |
| Threads sidebar | Full window height, left of the whole workspace, title bar included. **300** wide (200–800), `panel.background`. Its header is **34** (the title-bar height) with left padding **78** for the traffic lights and a "⌕ Search threads…" field. Project group header 31 (14 px; full ink when active). Thread row: padding y 4 / x 6, **radius 0**, 16 px icon slot, 14 px title, 12 px muted second line (project • branch • +N −N • 5m), **height 34 (one line) or 53 (two lines)**. Selected = `ghost_element.selected`; keyboard focus = a 2 px right-edge bar in `panel.focused_border` | `crates/sidebar/src/sidebar.rs:2295-2516, 7387-7557`; `ui/ai/thread_item.rs:270-529`; `multi_workspace.rs:2205-2215` |

**Signature:**
- **Flat planes and 1 px hairlines** with no cards on the fixed layout.
- An **inverted-luminance frame**: lighter chrome (34 / 30) around the darkest work well.
- The **open tab**, which fuses with the editor.
- In the agent UI, **chat without bubbles**: only the user prompt is a bordered box, tools are quiet hairline cards, and activity is shown as a braille spinner and a breathing title instead of banners.

---

## 5. Otty

| | |
|---|---|
| Copy analysed | **1.6.4**, downloaded from the official site. `otty.sh` → "Download for Mac (Apple Silicon)" → `https://downloads.otty.sh/macos/Otty.dmg`. Stored at `re-apps/otty/download/Otty.dmg` (SHA-256 `620362f1…0aa9e26`); app copied to `re-apps/otty/app/Otty.app`. |
| Signature | Developer ID Application: Abner Lee, **Team 9HWK5273G4**. Notarized; `spctl` accepted; signed 25 Oct 2026; bundle `io.appmakes.otty`. |
| Prior write-up | `/Volumes/Lacie/Workspace/oss/otty-reversed/Docs/` covers **1.0.4**. Everything below either comes from the 1.6.4 binary and bundle or is marked as carried over from 1.0.4. |
| Stack | AppKit-first Swift with a few SwiftUI views, a Rust core over a C FFI, and a Metal grid (`Grid.metallib`). Settings is a WKWebView (`settings-ui.html`). |
| Capture | The copied app was launched once with the system in light appearance; it opened on the **Paper** theme. Capture: `re-apps/otty/captures/otty-default.png`, 1000 × 600 at 1×. The app was quit afterwards. |

### 5.1 Theme model: a TOML theme with author-commented defaults, embedded in the binary

The 1.6.4 binary embeds every bundled theme as TOML (`strings MacOS/Otty`, lines ~2671–3700).

**Nord** is the "reference dark theme". Its header says **"the values below match the defaults the app would derive on its own when each key is omitted"**, which makes it the default-value table:

| Key | Default (from the Nord reference) | Notes |
|---|---|---|
| `[token]` foreground / secondary / tertiary | three text tiers (Nord: `#E5E9F0` / `#C0C7D3` / `#7B8294`) | "cascade down to UI text colors" |
| `[token] hover-bg` / `active-bg` | `rgba(255,255,255,0.06)` / accent @ 0.18 | |
| `[token] radius` / `shadow` | **6** / `0 8px 24px rgba(0,0,0,0.35)` | |
| `[token] font-ui` / `font-mono` / `font-size` | `-apple-system, SF Pro` / `JetBrains Mono, SF Mono, Menlo` / **13** | JetBrains Mono and Office Code Pro are bundled in `Resources/fonts/` |
| `[panel]` | `background` = chrome backdrop, `surface` = elevated, `border` = `rgba(255,255,255,0.06)` | "Chrome backdrop and elevated surfaces shared by the sidebar, titlebar, tab bar, and floating dialogs" |
| `[window]` | `material none`, **radius 12**; `[window.unfocused] opacity 0.92` | materials: none / vibrancy-thin / -regular / -thick / glass |
| `[titlebar]` | 13 pt, weight 500, **height 40**; unfocused text drops to the tertiary tier | |
| `[sidebar]` | **width 220**, `border-right: 1px solid` (Nord `#434C5E`) | shared by the tabs panel and the details panel |
| `[tab]` (sidebar rows) | transparent; radius **6**; 13 pt / 400; **padding 10**; indicator colour = tertiary | |
| `[tab.hover]` / `[tab.active]` | `rgba(255,255,255,0.05)` / `surface` fill, weight 500, `shadow 0 1px 2px rgba(0,0,0,0.25)`, indicator = accent | active-unfocused drops the shadow and dims the text |
| `[tab-bar]` (top-tabs layout) | height **36**, padding 8, bottom border 6 % | `[tab-bar.tab]` radius 8, height 28 |
| `[container]` (terminal card) | radius **0**, margin **0**, padding **8** | "margin=0 lands flush with the titlebar bottom"; "padding overrides the built-in 8pt grid gutter" |
| `[divider]` | `rgba(255,255,255,0.08)`, **1 px** | |

**Paper** is the light default; the capture confirms it pixel for pixel.

| Token | Value | Measured in the capture |
|---|---|---|
| terminal bg | `#FCFBF9` | `#FCFBF9` ✓ |
| sidebar bg | `#F5F4F0` | `#F5F4F0` ✓ |
| sidebar seam | `1px solid #E0DFD5` | x = 220: `#E0DFD5` ✓ |
| active tab | `#FFFFFF`, `1px solid #E0DFD5`, `shadow 0 1px 2px rgba(0,0,0,.02)`, radius 4 | white card, x 8–212 × y 60–96 ✓ |
| hover tab | `#EBEAE5` | |
| text | fg `#1A1A1A`, secondary `#8C8A80`, tertiary `#C1BEB5`, accent `#2B5A38` | |
| UI font | `Inter, -apple-system` | |
| `[tab-bar]` | height 44, padding 8; tab radius **14**, height 32 ("elevated floating-pill look") | |

**Floating Card** is the theme that produces Otty's best-known look. Its author comments:

> "The terminal viewport becomes a floating rounded card. margin insets it from the window edges … so vibrancy wraps around the card. padding shrinks the default 8pt grid gutter so the card hugs the text more tightly … radius + shadow + border = Tailwind `rounded-lg border border-neutral-200 shadow-md`."

| Key | Value |
|---|---|
| `[container]` | radius **15**, `shadow 0 1.5px 6px rgba(0,0,0,0.18)`, margin **[4,16,16,16]**, padding **[8,16,8,16]**, `border 1px solid #e5e5e5` |
| `[window]` | `material glass` |
| `[sidebar]` | transparent, `border-right none`, so "the card appears to float freely over the frosted window" |
| `[tab.active]` | `rgba(255,255,255,0.9)`, weight **700**, `1px #e5e5e5`, `shadow 0 1px 2px rgba(0,0,0,.05)`, radius 6 |

**Glass Dark** (vibrancy-regular):

| Key | Value |
|---|---|
| sidebar | `#2528325D` |
| tab | radius 8; active `rgba(255,255,255,.16)` with border `.18`; hover `.10` |
| token radius / shadow | 12 / `0 22px 60px rgba(0,0,0,.34)` |
| accent | `#B4D979` |

**Acrylic Dark** (Windows Fluent):
- Its comments set out the design rule outright: on macOS, "ONE material under the whole window … the sidebar, the details panel and the title strip are one unbroken surface rather than separate fills that meet at a visible seam".
- On Windows, "TWO COLUMNS, not one surface".

Settings web UI tokens in 1.6.4 (`Resources/settings-ui.html`, CSS custom properties; these changed from 1.0.4):

| Token | Dark | Light |
|---|---|---|
| bg-window | `#1C1C1E` | `#EFEFF1` |
| bg-sidebar | `#29292B` | `#F8F8F9` |
| bg-card | `#262628` | `#FAFAFA` |
| bg-content | `#1C1C1E` | `#FFFFFF` |
| bg-element | `#343436` | `#FFFFFF` |
| bg-hover | `rgba(255,255,255,.05)` | `rgba(0,0,0,.04)` |
| border-subtle | `rgba(255,255,255,.06)` | `rgba(0,0,0,.05)` |
| border-active | `rgba(255,255,255,.15)` | `rgba(0,0,0,.15)` |
| card-border | — | `.5px solid rgba(0,0,0,.09)` |
| card-shadow | — | `0 1px 2px rgba(0,0,0,.035)` |

The settings UI also has **per-agent identity colours** (dark / light): Claude `#E08A66`/`#C4643F`, Codex `#4CC3D1`/`#1B8A9A`, Cursor `#C9D1D9`/`#24292F`, Kimi `#6E9CF7`/`#2F63D0`, OpenCode `#E3B341`/`#A87B00`, Pi `#B392F0`/`#8250DF`.

### 5.2 Native metrics (1.0.4 write-up, symbol-confirmed; still present by name in 1.6.4)

| Element | Value | Evidence |
|---|---|---|
| Chrome buttons | frame 28 × 24; hover plate radius 6, `labelColor @ 0.08`; SF Symbol 13 pt | `TitlebarView.chromeButtonH`, `PanelToggleButton` (07 §1) |
| Title label | system 13, `secondaryLabelColor`, centred in the titlebar | 07 §1 |
| Sidebar width | min 140, max 500 | `WindowContainerView.minPanelWidth/maxPanelWidth` |
| Tabs-panel row | ≈ 34 tall, radius ≈ 7, padding-x ≈ 14. Active = card with a 1 px border; there is also a left accent-bar option (`indicator = "bar"`). On hover, the trailing shell name swaps to "×". | `TabsPanelView`, `TabsPanelRowView` (07 §1b) |
| Split divider | 1 px; 2 px on hover (0.16 s); unfocused-pane alpha **0.6** | `DividerView`, `HairlineSplitView` (07 §9) |
| Pane drag handle | a capsule 16 wide, radius 2, revealed on hover | `PaneDragHandleView` |
| Drop zones | fill accent @ 0.35, stroke accent @ 0.9 at 2 px, radius 4 | `DropZoneOverlayView` |
| Motion | relayout 0.20 easeInEaseOut; row reflow 0.18 easeOut; hover reveal 0.15; composer in 0.18 easeOut / out 0.14 easeIn; toast 0.20 (success hold 1.8 s); indeterminate bar 0.8 s sweep; cursor glide 100 ms, entrance pop 220 ms | 07 §14 |

### 5.3 Composition

```
 ┌──────────────────────┬──────────────────────────────────────────────────────┐
 │ ● ● ●                │                         ~                            │ title strip, ~40 tall (Paper:
 │                      │                    13 pt secondary, centred          │  same ground as the terminal)
 │ TABS            ≡    │  ~                                                    │
 │╭────────────────────╮│  /\ - ᵣ -マ »  █                                      │
 ││ ~             zsh  ││                                                       │
 │╰────────────────────╯│     terminal = [container] padding 8 (gutter)        │
 │ 220 (140–500)        │                                                       │
 │ #F5F4F0              │ #FCFBF9                                               │
 └──────────────────────┴──────────────────────────────────────────────────────┘
          1 px #E0DFD5 seam; rows inset 8, white card + 1 px border = active
```

- **Inset or full-bleed:** Full-bleed by default (`[container] margin 0, radius 0`). The floating card is opt-in through the theme (`Floating Card`, margin 4/16/16/16, radius 15).
- **Titlebar:**
  - The strip has no fill of its own. It inherits the terminal or panel ground, so in Paper it sits on the terminal colour over the content column and the sidebar colour over the sidebar.
  - Traffic lights stay in their standard AppKit position (centre ≈ x 16 / y 16 at 1×).
  - The **title is centred over the content column**.
- **Sidebar:**
  - "TABS" section header, an uppercase caption in tertiary ink with a sort/group button.
  - Rows inset 8, each 36 tall including the border.
  - The trailing shell name ("zsh") is in mono tertiary ink and becomes "×" on hover.
- **Composer:**
  - `ComposeOverlay` slides up from the bottom of the pane: default height 240, minimum 120, opening in 0.18 s ease-out.
  - It **pushes the terminal up** (`applyPaneBottomInset`, a cubic CADisplayLink shift) instead of covering it.
  - It can pop out into a floating panel.

### 5.4 Agent surfaces (1.6.4)

| Surface | Spec | Evidence |
|---|---|---|
| Agent integration | Hooks for Claude, Codex, Copilot, Cursor, Grok, Kimi, OpenCode, Pi, Reasonix, CodeBuddy and Antigravity. Vendor marks are bundled as SVG. | `Resources/agent-integration/`, `Resources/agent-icons/marks/*.svg` |
| States | `awaiting`, `processing`, `failed`, `unread` (activity model), plus `TabBadge` kinds awaiting / caffeinate / completed / error / sudo. Users can switch badges for **Processing**, **Task Completes** and **Awaiting Input**. "Show Unread Tab" is bound to ⌘⇧U. | strings near `agentLine`/`statusLine`/`tail` (activity row model); `en.json settings.agents.badge_*`, `menu.unread_tab` |
| Working | A `RingSpinner`/`RingSpinnerView` badge on the tab row, or the indeterminate bar | `_TtC4Otty11RingSpinner` |
| Waiting | The tab badge plus a notification. `detect-awaiting-input` also catches prompts that come without hooks. | config keys `privilege-badge-agent-awaiting-input`, `detect-awaiting-input` |
| Activity row model | `title · project · place · agentLine · statusLine · tail · kind · agent · program · updated`. Each row says what the agent last said, not only its state. | 1.6.4 strings |
| History | `HistoryTranscriptView` (SwiftUI) with turn cards and markdown | 1.0.4 §12 |

**Signature:**
- The **one-material chrome**: the sidebar, title strip and margin are one surface.
- The **optional floating rounded card** around the terminal, with radius 15 and a soft shadow.
- In the light default, a warm paper palette (`#FCFBF9` / `#F5F4F0`) with **white-card active rows**.

---

## 6. Cross-app synthesis

### 6.1 Side-by-side (dark mode unless noted)

| | Warp | ChatGPT Classic | Dia | Zed | Otty (default) | **Axolotty now** |
|---|---|---|---|---|---|---|
| Content | full-bleed (1 px workspace pad) | full-bleed split view | **inset cards**, 6 moat, r = R − 6 = 10 | full-bleed, hairlines | full-bleed (card is opt-in: r 15, margin 4/16/16/16) | full-bleed |
| Top band | **35** (34 + 1 hairline) | **52** / 40 compact | 42 constant + 3–6 | **34** | ~40 (theme default 40) | **40** |
| Traffic lights | re-laid: 14 pt, gap 6, x 12, centreY + 1 | system | hidden, own controls | position (9, 9) | system (≈ 16, 16) | system, centred on the 40 band |
| First content x after the lights | **80** (64 + 16) | **117 / 137** | — | **78** (macOS 26) | toggle and + at 80 / 108 (closed) | toggle, then + |
| What the band says | centred **search / command field** (≤ 320 × 24, r 4, fg 5 %) + tools + inbox | **title / model picker** + new chat | tabs | **project ▾ + branch** + avatar | **title centred over the content column** | nothing (toggle, +) |
| Sidebar width | **248** (200 – 50 %) | **250** (200 – 500) | 190 (saved) | **300** (200 – 800) | **220** (140 – 500) | **248** (200 – 360) |
| Sidebar tone vs content | **lighter**: bg + fg 5 % | **lighter**: material + white 10 % | translucent ground | **lighter**: `#2F343E` over `#282C33` | its own panel colour (Paper light: `#F5F4F0` beside `#FCFBF9`) | **darker**: bg · black 0.24 |
| Seam | none (tone only) | system split | 6-pt moat | 1 px `#464B57` | 1 px | 1 device px `borderSubtle` |
| Row height / radius | 2-line, pad 8, r **4** | header rows ≥ 34 | tab r 10 | **34 / 53**, r **0** | ≈ 34–36, r 4–6 | **28**, r **8** |
| Selected row | fg 10 % + **1 px fg 15 % border** | fg 10 % | **solid chip + 12 % shadow** | ghost selected (`#454A56`) | **white card + 1 px border + 2 % shadow** (Nord: surface + `0 1 2 .25`) | neutral plate fg 0.09 |
| Second line in row | cwd / branch | — | — | project • branch • ±N • age | — (shell name trailing) | none (folder lives in the prompt) |
| Pane divider | 1 px fg 15 % | 1 px | 6 gap | 1 px `border` | 1 px 8 % (2 on hover) | 1 px `borderSubtle` (2 on hover) |
| Pane header | **34**, title centred, ⋮ ✕ | — | — | tab bar **32** (open-tab) | none (title strip) | **none** |
| Unfocused pane | not dimmed (default) | — | focused pane gets a **2-pt ring at r + 3, 50 %** | not dimmed; **tab text fades** | alpha 0.6 (1.0.4) | dim overlay 0.28 |
| UI font | Roboto 12 | SF (semantic, line height 1.35) | ABC Favorit / Oracle | IBM Plex Sans 16 (labels 14 / 12) | SF 13 | SF 13 |
| Radii (small / card / modal) | 4 / 8 / 8 | 8 / 12 / 28 | 6 / 10 / 20 | 4 / 6 / 8 | 4–6 / 8 / 12 | 6–8 / 10 / 14 |

### 6.2 How each app shows working, waiting and done

| State | Warp | ChatGPT | Dia | Zed | Otty | Common pattern |
|---|---|---|---|---|---|---|
| **Working** | ClockLoader in ANSI magenta; **"Warping…" shimmer, 3 s** | **shimmer 1.8 s**; ⬤ / DotBall; 17-pt progress ring | dots wave 1.1 s; **shimmer 1.5 s**; conic border trace 2.03 s | braille spinner 100 ms/frame; **title breathes α 0.4–0.8 over 2 s**; LoadCircle 2 s | RingSpinner badge | **Motion on the text** (shimmer or breathing) in a 1.5–3 s period, plus a small spinner |
| **Waiting** | StopFilled, **yellow**; "Agent waiting for instructions…" | **"Awaiting approval" / "Needs input"** | **"Waiting for you"** | **Warning** icon `#DEC184`; **inline Allow / Deny** + ⌘Y | awaiting badge + notification | **Amber**, and **words** that say what is wanted |
| **Done** | Check, green | **8-pt unread dot** | check draws and pops | **accent dot** when unread; agent icon muted when seen | completed badge; "Show Unread Tab" | **Dot while unseen**, then quiet |
| **Failed** | Triangle, red | status error | — | ✕ in error colour; **dashed card** | error badge | Red glyph |

### 6.3 What the premium set agrees on

1. **The work surface is the darkest plane, and the chrome is lighter.** In dark mode:
   - Warp's sidebar is bg + fg 5 %.
   - Zed runs chrome `#3B414D`, then panels `#2F343E`, then editor `#282C33`.
   - ChatGPT's sidebar carries a white 10 % tint over `#212121`.

   No dark-mode peer puts the sidebar *below* the content. Axolotty does (black 0.24), and that is why its sidebar reads as a recess instead of a surface.
2. **The top band always carries context.**
   - Warp: a search/command field.
   - Zed: project and branch.
   - ChatGPT: title and model.
   - Otty: the title centred over the content column.

   Axolotty's 40-pt band holds only two buttons. It is the largest empty area in the window and the main reason the layout "isn't impressive".
3. **Full-bleed wins for tools; insets are a brand move.**
   - Warp, Zed, ChatGPT and Otty's default are full-bleed.
   - Dia, and Otty's opt-in theme, inset the content as a card. They then need a tinted or textured ground to be worth the lost pixels.
4. **Selection has a body.**
   - Warp: fill plus a 1-px border.
   - Otty: a white card with a border and shadow.
   - Dia: a solid chip with a shadow.

   Axolotty's flat fg 0.09 plate is the weakest selection in the set.
5. **Split panes get a label.** Warp has a 34 header and Zed a 32 tab bar on each pane. With several agents side by side, Axolotty's panes are indistinguishable once each terminal is cleared.
6. **Small radii in the chrome.**
   - Rows: Warp 4, Zed 0, Otty 4–6.
   - Large radii go only to floating things: Dia's panel 20, ChatGPT's launcher 24 and composer 16.

   Axolotty's row radius of 8 is at the soft end.
7. **Waiting is spoken, not only coloured.** Every agent app pairs amber with a phrase ("Waiting for you", "Awaiting approval", "Needs input"), and Zed and ChatGPT add inline Allow / Deny.
8. **Motion constants.**
   - Hover: instant in, 100–150 ms out (Otty 0.15, Zed Fast 150).
   - Shimmer: 1.5–3 s period. Breathing: 2 s.
   - Spinners: 0.8–1 s per turn.
   - Panels: 0.18–0.2 s, or springs with damping ≥ 0.8.

   Axolotty's tick, swift and spring values already sit inside this envelope.

### 6.4 The element that makes each app recognisable

- **Warp:** the *block*, plus a 35-pt tab strip with a centred search field. Agents get brand-coloured circles with a cut-out status badge.
- **ChatGPT:** neutral greys, the 992 column, the ⬤ / DotBall, and a 16-radius soft composer (5 % fill, 10 % hairline).
- **Dia:** a warm pastel gradient ground under 6-pt concentric card insets, and AI shown as light (shimmer, conic border, halo) in marigold `#FCBF49`.
- **Zed:** flat planes with 1-px hairlines, the inverted-luminance frame, the open tab, and chat without bubbles.
- **Otty:** one material behind all the chrome, the optional floating rounded card, and the warm Paper palette with white-card active rows.

---

## 7. Implications for Axolotty (AppKit)

The list below runs from highest leverage to lowest. Each item keeps Axolotty's principles ("the terminal is the window", "say a thing once", opaque surfaces) unless it says otherwise.

### 7.1 Raise the sidebar a tone instead of sinking it

- **Change:**
  - Dark: sidebar = bg + fg **0.045–0.05**. That is Warp `neutral_1` / `fg_overlay_1`, and the same step as Zed's panel over its editor.
  - Light: keep bg + fg 0.035, or use Otty Paper's warm offset (`#F5F4F0` against `#FCFBF9`).
- **Keep:** the one device-pixel seam. Warp drops it entirely and relies on the tone step; try both at 1×.
- **AppKit:** a layer-backed `NSView` with `layer.backgroundColor` from a dynamic `NSColor(name:dynamicProvider:)` resolved through `DesignTokens`. Keep it opaque: no `NSVisualEffectView`, because Otty and ChatGPT are the only ones relying on material, and Axolotty chose opacity.

### 7.2 Give the 40-pt band one piece of context

All four peers put something there. Options, in order of fit with "say a thing once":

- **(a) Command field (Warp).**
  - A centred field "Jump to session, agent, folder…", at most 320 wide, 24 tall, radius 4 (6 to fit Axolotty's scale), fill fg 0.05 (0.10 on hover), secondary-ink placeholder and a trailing `⌘K` hint in tabular digits.
  - Clicking opens the existing palette in place.
  - **AppKit:** an `NSToolbarItem` in the empty `.unifiedCompact` toolbar, listed in `NSToolbar.centeredItemIdentifiers` (macOS 13+), so AppKit centres it over the window and keeps the band draggable.
- **(b) Focused pane's project · branch (Zed).**
  - The project name as a ghost button, plus a branch glyph with the branch name, in 12 pt secondary ink.
  - Place it at the content column's leading edge, x = sidebar width + 12.
  - This does not repeat the row title, because the row shows the session, not the branch.

Keep the band at 40 (between Warp's 35 and ChatGPT's 52). After the lights, the first control should sit near Zed's 78 or Warp's 80.

### 7.3 Make selection a body, not a tint

Two measured recipes:

- **Warp:** fill fg **0.10** + inside stroke **1 device px fg 0.15** + radius 4.
- **Otty (Nord reference):** fill `surface` (bg + fg 0.10) + `shadow 0 1 2 rgba(0,0,0,.25)`. In light mode, use white + 1 px `#E0DFD5`-like border + a 2 % shadow. This is the stronger "card" look.

**AppKit:**
- On the selection layer, set `borderWidth = 1 / backingScaleFactor` and `borderColor` to fg 0.15.
- For the card variant, set `shadowPath` from the same `ContinuousRect`, with `shadowOpacity`, `shadowRadius 1`, `shadowOffset (0, −1)`.
- Keep the spring that moves the plate between rows.
- Consider **row radius 6** (between Warp's 4 and the current 8) and **row height 30–32** for one-line rows. Zed uses 34 for one line and 53 for two. If a second line is ever added (branch • ±diff • age, as Zed and Warp do), use 12 pt tertiary ink.

### 7.4 Label the panes only when there is more than one

Warp has a 34 header and Zed a 32 tab bar, but a single-pane window needs neither.

- **Spec:** in a split, each pane gets a **28-pt header strip** on the terminal ground. It holds the program or agent icon (16 slot), the title in 12 pt (full ink when the pane is focused, 0.50 when not; this is Zed's "fade the label, not the content"), the state badge, and a trailing close button on hover.
- **Dim:** reduce the content dim from 0.28 to about **0.12–0.15**. Neither Warp nor Zed dims unfocused panes at all, and the header carries focus instead.
- **AppKit:** an `NSView` above the `MTKView` / `CAMetalLayer` in the pane container, with the grid's top padding reduced by the header height so the row count stays stable. The header also gives a drag-to-rearrange handle (Otty's `PaneDragHandleView` idea).

### 7.5 Say what a waiting agent wants, in the row

Peers pair amber with words. Axolotty already sends the agent's question to the band chip and to toasts. The row itself needs:

- **Row title while waiting:** full ink, plus a trailing **"Needs input"** or **"Approve?"** in 11 pt amber. This replaces the hover-only close slot while waiting.
- **Inline Allow / Deny:** `✓ Allow` in the success colour, `✕ Deny` in the error colour, `⌘Y` and `⌘⌥Z` hints (Zed's exact keybinds). Already on the roadmap (§8.1); Zed and ChatGPT confirm the pattern.
- **Working cue:** add **text motion on the row title** as well as the spinner badge. Either Zed's breathing (α 0.4 → 0.8, 2 s, sine-cubic) or a ChatGPT/Warp shimmer (1.8–3 s band sweep).
  - **AppKit shimmer:** a `CAGradientLayer` as the `mask` of the title's layer (three stops, clear → white → clear, band about 0.33 of the width), animating `startPoint` / `endPoint` (or `locations`) with `CABasicAnimation`, `repeatCount = .infinity`, duration 1.8–3.0, easeInEaseOut.
  - **AppKit breathing:** a `CAKeyframeAnimation` on `opacity`.
  - **Reduce Motion:** when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is set, fall back to static 0.72 ink (Dia uses 70 % ink).

### 7.6 Agent identity: consider Warp's brand disc

Warp sets each vendor mark on a **24-pt brand-colour circle**:
- Claude `#D97757`, Gemini `#4285F4`, OpenAI `#000000`, Copilot `#8534F3`, Amp `#F34E3F`.
- Circle 76 %, glyph 43 %, status badge 57 % at the bottom right, cut out of the circle by a ring in the row's background colour.

Axolotty draws the bare mark at 14 in a 16 slot. A **16-pt disc** in the brand colour with the mark in white at 9–10 pt would read at 1× from across the sidebar. Otty's settings use similar per-agent hues (Claude `#E08A66` / `#C4643F`, Codex `#4CC3D1` / `#1B8A9A`).

- **AppKit:** a `CAShapeLayer` circle, with the `BrandMarks` path scaled into it. The existing badge moat logic carries over.

### 7.7 If an inset or "floating" look is wanted (Dia and Otty Floating Card)

This only applies if the owner wants to depart from "the terminal is the window".

- **Geometry:** inset each pane **6** from the window and its neighbours. Pane radius = window radius − 6 = **10** on macOS 26 (Dia's window radius is 16), with `cornerCurve = .continuous`, a 1 px hairline at black 6 % (light) or fg 8 % (dark), and the ground one tone off the terminal.
- **Focus:** the focused pane gets an **outset 2-pt ring, radius r + 3, at 50 % alpha**.
- **Cost:** about 12 pt of grid width per pane.
- **AppKit:**
  - The pane container layer: `cornerRadius = 10`, `cornerCurve = .continuous`, `masksToBounds = true`. The `CAMetalLayer` clips correctly inside it.
  - The focus ring is a sibling `CAShapeLayer` stroking an outset `ContinuousRect`, so it can animate on focus change with the `tick` duration.
  - The window corner radius is the system's; read it from the window's theme frame rather than hard-coding 16.

### 7.8 Composer (if Axolotty adds one over CLI agents)

- **Warp:** "Rich Input" docks over a CLI agent: max height 236, padding 10 / 8, opens on its own when the agent blocks.
- **Otty:** `ComposeOverlay` **pushes the grid up** instead of covering it: default 240, min 120, in over 0.18 s easeOut, out over 0.14 s easeIn.
- **Zed:** the composer is a flat band, 4–8 lines, 12-pt mono.
- **ChatGPT:** gives the style. Radius 16, fill fg 5 %, stroke fg 10 %, no shadow, min height 60, send button 30.

**AppKit:** an `NSTextView` in a bottom-pinned container. Animate a constraint (`NSAnimationContext.runAnimationGroup` with `allowsImplicitAnimation`), and resize the terminal grid once, at the end, not per frame (the grids already freeze during sidebar motion).

### 7.9 Quick constants table for implementation

| Token | Proposed | Source |
|---|---|---|
| Sidebar ground (dark) | bg + fg 0.05 | Warp `neutral_1`; Zed panel over editor |
| Sidebar width | keep 248 (200–360) | Warp 248, ChatGPT 250 |
| Row (one line) | 30–32 tall, radius 6, gap 2 | Warp r4 / Zed 34 / Otty r6 |
| Selected row | fg 0.10 + 1 px fg 0.15 stroke (or surface + `0 1 2 .25`) | Warp `pane_row_background`; Otty Nord `[tab.active]` |
| Hover row | fg 0.05 | Warp, Otty, ChatGPT (5–6 %) |
| Band | 40; centred field ≤ 320 × 24, r 6, fg 0.05 / 0.10 | Warp title-bar search |
| Pane header (splits only) | 28; title 12; unfocused 0.50 ink | Warp 34 / Zed 32 |
| Unfocused-pane dim | 0.12–0.15 (from 0.28) | Warp and Zed 0; Otty 0.6 alpha |
| Divider | 1 device px fg 0.10–0.15; 2 on hover | Warp fg 15 %; Otty 8 % → 2 px |
| Waiting | amber glyph + "Needs input" 11 pt + Allow / Deny | Zed, ChatGPT, Dia |
| Working | spinner badge + title shimmer 1.8–3 s or breathing 0.4–0.8 over 2 s | ChatGPT, Warp, Zed |
| Done (unseen) | 6–8 pt dot (accent or neutral) | ChatGPT 8 pt, Zed accent dot |
| Floating radius | palette 14, toasts 10, popovers 8 | ChatGPT 12 / 14, Zed 8 |

---

## Appendix: provenance and side effects

**Artifacts.** Files are under `/Volumes/Lacie/Workspace/oss/re-apps/`:
- `chatgpt/{download,app}`, `dia/{download,app}`, `otty/{download,app,captures}`, `warp/{src,captures}`, `zed/src`.
- Scratch output: `/tmp/re-native-draft/`, `/tmp/re-native-scripts/`, `/tmp/re-dia-*`, `/tmp/re-chatgpt-*`, `/tmp/warp_strings.txt`, `/tmp/otty164_*`.

**Launches.** Only **Otty 1.6.4** was launched, once:
- `open -n …/re-apps/otty/app/Otty.app` at about **17:15:16 (+07, 2 Nov 2026)**, with the **real HOME `/Users/congtran`**. It was quit by AppleScript seconds later.
- ChatGPT, Dia and Zed were never launched.
- Warp was not launched or reconfigured. Its already-open window was captured once with `screencapture -l`.

**Files the Otty launch created or modified outside the work directories.** Found by birth and modification times; not cleaned up, at the coordinator's instruction:
- **Created** (born 17:15): `~/.config/otty/` (`config.toml`, `themes/*.ottytheme`, `fonts/README.md`, `recipes/.migrated-from-statedb`), `~/Library/Application Support/io.appmakes.otty/` (`state.db*`, `completions.db*`, `sessions`, `Crash`), `~/Library/Preferences/io.appmakes.otty.plist`, `~/Library/Caches/io.appmakes.otty/`, `~/Library/HTTPStorages/io.appmakes.otty/`.
- **Modified at 17:15:16:**
  - `~/.zshrc` (an "otty shell integration" block, now lines 354–360 at the end of the file).
  - `~/.bashrc` (the whole 382-byte file is that block).
  - `~/.bash_profile` (an "otty bash-profile shim" block, lines 8–12).
  - `~/.config/fish/config.fish` (block at lines 93–99).

  Each block does nothing unless `$OTTY_SHELL_INTEGRATION` is set. `.bashrc` and `.bash_profile` were first created on 25 Aug 2026, so their blocks probably predate this launch, and Otty rewrote them. It is unknown whether `.zshrc` already had the block: the backup from 29 Sep does not, and the backup `.zshrc.bak.1783575994` does. chezmoi does not manage `.bashrc`, and its source for `.zshrc` and `config.fish` lacks the blocks.
- **Also touched in that window:** `~/Library/Application Support/zoxide/db.zo`, by the shell Otty spawned.

**Browser.** Official download pages were opened in the user's Brave through `agent-browser --session renative` (shared with other agents). No downloads went through the browser.
