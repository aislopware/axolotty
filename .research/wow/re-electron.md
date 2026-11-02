# Premium AI desktop apps: shipped design systems, reverse-engineered

**Date:** 2026-11-02.

**Purpose:** ground truth for the Axolotty redesign. The owner's verdict on the current build is that the layout "still isn't impressive". Every value here comes from the shipped bundles, not from screenshots.

**Baseline compared against:** `.impeccable/baseline/now-dark.png` and `.research/design-system.md`.

## Provenance

| App | Version | Signature (codesign, spctl) | Source | Runtime |
|---|---|---|---|---|
| OpenAI **Codex** (ships as `ChatGPT.app`, bundle id `com.openai.codex`) | 26.1027.61615 (build 24141) | Developer ID Application: **OpenAI OpCo, LLC (2DC432GLL2)**; Notarized Developer ID, accepted; deep verify OK; signed 2026-11-02 | `https://persistent.oaistatic.com/codex-app-prod/ChatGPT.dmg` (the link on openai.com/codex); DMG sha256 `189e8425…4c3e` | **Not stock Electron.** It runs on "Owl", OpenAI's own Chromium **156.0.8078.79** runtime (`Codex Framework.framework`), which exposes an Electron-compatible API (`owl_electron_*` symbols; package `openai-codex-electron`). The UI is a web bundle in `app.asar` → `webview/`. |
| Anthropic **Claude** desktop (includes the Code tab) | 4.4212.0 (universal) | Developer ID Application: **Anthropic PBC (Q6L2SF6YDW)**; Notarized, accepted; deep verify OK; signed 2026-10-29 | `https://downloads.claude.ai/releases/darwin/universal/4.4212.0/Claude-cbfe3c56….dmg` (resolved from claude.com/download → `claude.ai/api/desktop/darwin/universal/dmg/latest`); DMG sha256 `2d5ec616…9e93` | Electron. Shell in `app.asar`; the UI is bundled locally in `ion-dist.asar`. |
| **Cursor** | 3.27.22 (arm64) | Developer ID Application: **Hilary Stout (VDXQ22DGB9)** (Anysphere's long-standing ToDesktop signing identity; bundle id `com.todesktop.230313mzl4w4u92`); Notarized, accepted; deep verify OK; signed 2026-10-27 | `https://api2.cursor.sh/updates/download/golden/darwin-arm64/cursor/3.27` → `downloads.cursor.com/production/b1aa50cb…/darwin/arm64/Cursor-darwin-arm64.dmg` (the link on cursor.com/download); DMG sha256 `fd9288d6…9580` | Electron (VS Code fork). Unpacked `Resources/app/`, no `app.asar`. |

**Where things are on disk:**
- Apps: `/Volumes/Lacie/Workspace/oss/re-apps/<app>/app/`.
- Extracted bundles: `/Volumes/Lacie/Workspace/oss/re-apps/<app>/extracted/`.
- Cursor is analysed in place at `cursor/app/Cursor.app/Contents/Resources/app/`.
- Pretty-printed scratch copies of the Codex CSS (used only to read it): `/tmp/re-scratch/codex/`.

**How to read the citations:**
- Bundles are minified onto one line, so citations give the **byte offset** as `file@offset`. Reproduce one with `rg -b -o '<needle>' <file>`.
- Where a value was only located in the prettified copy, it is cited as "pretty L<n>".

**Path keys:**

| Key | Path |
|---|---|
| CX | `re-apps/codex/extracted/app/webview/assets/` |
| CLI | `re-apps/claude/extracted/ion-dist/` |
| CLA | `re-apps/claude/extracted/app/` |
| CU | `re-apps/cursor/app/Cursor.app/Contents/Resources/app/` |

---

## 1. OpenAI Codex (ChatGPT.app 26.1027.61615)

### 1.1 How the palette is built

Codex does not ship a fixed palette. A theme is **four inputs**, and every surface, border, hover and ink is computed from them in `CX/app-theme-290d1105c702.js`:

```
dark : accent #339cff  contrast 60  ink #ffffff  surface #181818   (diffAdded #40c977, diffRemoved #fa423e, skill #ad7bf9)
light: accent #339cff  contrast 45  ink #1a1c1f  surface #ffffff   (diffAdded #00a240, diffRemoved #ba2623, skill #924ff7)
```

- **Source:** the `d={dark:{accent…` defaults at `app-theme-290d1105c702.js@293`, the dark derivation `function v(e)` at @7682, the light derivation `function g`, the sidebar ground `function b` at @9604, and the constants `B={dark:.16,light:.04}` at @11040.
- **Same model as ours.** This is exactly Axolotty's approach, deriving tokens from bg and fg as Warp does. Codex adds a single **contrast** scalar that scales every alpha.
- **Normalisation:** contrast is normalised as `c = contrast/100` at the default, giving 0.60 dark and 0.45 light.
- **How the table below was made:** I reimplemented the formulas in my own script (`/tmp/re-scratch/scripts/codex_theme.py`, which does not run their code) to resolve the defaults.

| Role | Formula (dark) | **Dark** | Formula (light) | **Light** |
|---|---|---|---|---|
| Main surface (thread/editor ground) | `surface` | **#181818** | `surface` | **#ffffff** |
| Surface-under (opaque sidebar/canvas) | surface mixed with black by 0.16 | **#141414** | surface mixed with ink by 0.04 | **#f6f6f6** |
| Editor-opaque, also "surface-tertiary" (the shell/sidebar tint over vibrancy) | surface to ink, 0.07 | **#282828** | surface to white, 0.12 | **#ffffff** |
| Panel (`--color-background-panel`) | surface to ink, .03+c·.03 = .048 | **#232323** | surface to white | **#ffffff** |
| Control (inputs) | surface to ink, .06+c·.05 | **#2d2d2d** | | **#ffffff** |
| Elevated primary (menus, composer) | surface to ink, .08+c·.08 = .128 | **#363636** (at 96 %) | | **#ffffff** (at 96 %) |
| Border | ink α .06+c·.04 | **ink 8.4 %** (≈#2b2b2b on surface) | ink α | **7.8 %** (≈#ededee) |
| Border heavy (strong) | ink α .12+c·.06 | **15.6 %** (≈#3c3c3c) | | **11.7 %** |
| Border light (subtle) | ink α .03+c·.02 | **4.2 %** (≈#222222) | | **4.9 %** |
| Hover (`button-secondary-hover` = `primary-ghost-hover`) | ink α .06+c·.03 | **7.8 %** | | **5.3 %** |
| Pressed (`secondary-active`) | ink α .09+c·.05 | **12 %** | | **3.9 %** |
| Tertiary hover / active | ink α | **6.8 % / 10 %** | | **9.8 % / 19.6 %** |
| Text primary | `--gray-fixed-150` (only when the theme is the default) | **#dfdfdf** (not pure white) | ink | **#1a1c1f** |
| Text secondary | ink α .65+c·.10 | **71 %** (≈#bcbcbc) | | **69.5 %** (≈#606163) |
| Text tertiary | ink α .42+c·.13 | **49.8 %** (≈#8b8b8b) | ink α .45+c·.10 | **49.5 %** (≈#8e8f90) |
| Icon primary / secondary / tertiary | ink α .82+c·.14 / .65+c·.1 / .45+c·.1 | **90 % / 71 % / 51 %** | | 100 % / 69.5 % / 49.5 % |
| Accent | `accent` | **#339cff**; the text/icon accent is #83c3ff (accent toward white by .30+c·.15) | | **#339cff** |
| Accent wash (selection, user-message bubble, find match) | black to accent, .20+c·.08 | **#0d273f**; hover #0e2a45, active #0f2e4a | surface to accent, .11+c·.04 | **#e5f2ff** / #e2f1ff / #e0f0ff |
| Primary button | surface to black, .38+c·.12 | **#0d0d0d** with ink text (an inverted dark pill) | ink | **#1a1c1f** with white text |
| Focus ring | accent-to-white at α .76 | **#83c3ff @ 76 %** | | **#339cff** |

**Status hues** come from fixed ramps. Codex's ramps are pure sRGB hex, not OKLCH. Sources: `fd9b7fd80db1.css@153455` (green-300) and @156180 (blue-300); the semantic mapping is at pretty L7240–7300.

| Role | Dark | Light |
|---|---|---|
| success text / icon | green-300 **#40c977** | green-500 **#00a240** |
| warning text | orange-300 **#ff8549** | orange-500 **#e25507** |
| error text | red-300 **#ff6764** | red-500 **#e02e2a** |
| error border | red-400 at 40 % | red-500 at 15 % |
| success background | green-400 at 16 % | green-500 at 7 % |
| diff added / removed line | `diffAdded` at 23 % / `diffRemoved` at 23 % | the same hues at 15 % |
| decoration modified | orange-300 | orange-700 |
| scrollbar | `--app-color-border` | `--app-color-border` |

**Static grey ramp.** `--gray-0…1000` uses `light-dark()` pairs; for example gray-0 is #fff / #0d0d0d, and gray-900 is #181818 / #ededed (`fd9b7fd80db1.css@150231`). The "gray-fixed" ramp is the same values with no flip.

### 1.2 Shape, type and motion (`CX/fd9b7fd80db1.css`)

**Radius.** Each radius is a base × `--corner-radius-scale` (1); source @143324. Codex uses `corner-shape: superellipse(1.5)` where the engine supports it (the tooltip and menu rules), so Codex corners are squircles, like ours.

| Token | Value |
|---|---|
| 2xs | 2 |
| xs | 4 |
| sm | 6 |
| md | 8 |
| lg | 10 |
| xl | **12** |
| 2xl | 16 |
| 3xl | 20 |
| 4xl | 24 |
| form dialog | 24 |

**Component radii:**
- Toolbar and action buttons: `--radius-button-toolbar = radius-lg` = 10.
- Menu items: 12 (`--menu-item-radius: var(--radius-xl)` under electron).
- Sidebar rows: 10 (`--radius-token-row:10px`).
- Composer: `calc(4px*5.5)` = **22** (pretty L7541).

**Spacing.** The base unit is `--spacing: .25rem` (4 px). The named spacings:

| Token | Value |
|---|---|
| toolbar action padding | 6 |
| button-toolbar-inline | 8 |
| row x padding | 8 |
| row y padding | 5 (electron body: `--padding-row-y: calc(4px*1.25)`) |
| panel padding | **20** (`--padding-panel-base: calc(4px*5)`) |
| thread gutter | 16 |
| composer gutter | 12 |
| chat gutter | 20 |
| composer bottom inset | 16 |

**Hairline.** `--hairline` is **1px at 1×** and **0.5px at ≥1.5×** (@160796). `--border-width-hairline` is 0.5px. The **main/sidebar seam is a 0.5 px line**: `._MainContentLeftBorder` uses `border-left: var(--border-width-hairline) solid var(--app-shell-sidebar-divider)`, and the divider is `--color-border` (`59ad52d5aa88.css@10199`).

**Type.** The UI is **the system font**: `--font-sans-default: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif` (@141551). "OpenAI Sans" exists only as `--font-openai-sans`, which is not the UI default. Mono is `ui-monospace, "SFMono-Regular", "SF Mono", menlo…`. In the Electron window (@1355059):
- `--text-sm` is **13px**, the body/row size.
- `--text-xs` is **12px**.
- `--font-ui-weight` is **430**, not 400. Codex sets SF slightly heavier than regular.
- Named roles:

  | Role | Size / line-height | Weight | Tracking |
  |---|---|---|---|
  | control label | 13 / 18 | **510** | −0.08px |
  | card title | 22 / 28 | 510 | −0.26 |
  | unread badge | 11 | 590 | −0.15 |
  | tooltip | 13 | 430 | |
  | chat body | 14 (`--text-document`) | | |

**Shadows** (@188813 and the theme block):

| Token | Value |
|---|---|
| xs | `0 1px 2px #0000000d` |
| sm | `0 1px 2px -1px #00000014` |
| md | `0 2px 4px -1px #00000014` |
| lg | `0 4px 8px -2px #0000001a` |
| xl | `0 8px 16px -4px #0000001f` |
| 2xl | `0 16px 32px -8px #00000030` |
| card | `0 4px 16px #0000000d` |
| hairline | `0 0 0 .5px #0000001a` |
| xl-spread (menus) | `0 0 0 .5px border, xl` |
| elevation-stroke | `0 0 0 .5px border-strong` |
| elevation-stroke-subtle | border-strong at 4 % light, 6 % dark |

The dark modal shadow is `0 8px 16px #00000059, 0 2px 8px #0003, inset 0 0 0 1px border-subtle`.

**Motion** (@145445):
- Durations: basic **150 ms**, moderate 200 ms, relaxed 300 ms.
- Easings:
  - enter: `cubic-bezier(.19,1,.22,1)` (expo-out)
  - exit: `(.8,0,.4,1)`
  - move: `(.65,0,.35,1)`
  - enter-snappy: `(.23,1,.32,1)`
  - `--ease-spring-snappy` is a 20-point `linear()` spring
- Spinner: `spin 2s steps(60,end)`.
- Pulsing dot: `token-pulsing-dot 1.25s`, scale 1 to 1.25 (@1370154).
- Framer springs in JS:
  - default `Pkn={type:spring,duration:.35,bounce:.1}` (`app-initial-18b189e867e7.js@3452051`)
  - sidebar enter 0.30 s, exit 0.20 s, on that spring (`app-primary-75d53eef2374.js@447431`)
  - sidebar peek is a 0.12 s tween with ease `[0,0,.58,1]`
- Reduced motion is honoured via `:root[data-reduced-motion]`.

### 1.3 Window composition

**Native window** (`re-apps/codex/extracted/app/.vite/build/early-bootstrap-439-a0f25ba32c465de1.js`):
- Primary window: `titleBarStyle:"hiddenInset"`, `trafficLightPosition: eRP(44, zoom)` → **{x:16, y:round((44·zoom−14)/2) = 15}** (@4286819, @4359079).
- Window background `#00000000` with `vibrancy:"menu"` unless the user turns on opaque windows (`eRj`, @4357404). In opaque mode the background is `#000000` dark / `#f9f9f9` light, and CSS paints `--app-color-background-surface-under`.
- At 1× the launch window measured 1090×760 (`re-apps/codex/shot-launch.png`).

**Two shell layouts, chosen by a Statsig gate.** `dO` checks gate `3085093835` (`app-initial-18b189e867e7.js@3451416`), and the shell CSS module is `CX/59ad52d5aa88.css`.

**A. Classic layout** (gate off; `._Layout` @13917):

```
x=0      16  ●●● (y centre 22)             275 (clamp 240…min(520, 100vw−320))       W
┌──────────────────────────────────────────┬┬──────────────────────────────────────────┐ y=0
│  traffic lights x16 y15                  ││ titlebar/toolbar 46 (--height-toolbar)    │
│  sidebar toggle, back/fwd in the 46 band ││ floating header: ps max(safe,8) pe 8      │
│                                          ││ transparent / --codex-titlebar-tint       │
├──────────────────────────────────────────┤│──────────────────────────────────────────┤ 46
│ SIDEBAR: native vibrancy "menu" under    ││ MAIN SURFACE: --color-surface             │
│ editor-opaque @70 % (dark #282828@.7,    ││ (dark #181818 / light #fff), flat, no     │
│ light #fff@.7); opaque mode #141414 /    ││ radius on macOS; 0.5px hairline seam      │
│ #f6f6f6                                  ││ (--color-border) at the left edge          │
│ rows 30 h, radius 10, px 8, 13px/430     ││ thread column max 48rem, panel pad 20      │
│ icon 16 at a 30-wide slot; label inset 32││ composer radius 22, bottom inset 16        │
└──────────────────────────────────────────┴┴──────────────────────────────────────────┘
```

**B. "Page surface" layout** (gate on; `._PageSurfaceLayout` @19649 and `._PageSurface` @16633). This is the **inset-card** variant:

```
┌───────────────────────────────────────────────────────────────────────────────────────┐ y=0
│ ●●● x16 y15          titlebar 44 (--height-titlebar = 4px·11)                          │
├──────────────────────┬────────────────────────────────────────────────────────────────┤ 44
│ sidebar on the shell │ ╭─ main surface card ────────────────────────────────────────╮ │
│ ground (shell =      │ │ margin-top 44; radius 12 (--radius-xl-base);                │ │4
│ surface-tertiary     │ │ bg --color-surface; shadow = 0 0 0 .5px border-strong@4–6 % │ │
│ @70–85 % over        │ │ + 0 4px 16px #0000000d; inner header corner 12              │ │
│ vibrancy)            │ ╰─────────────────────────────────────────────────────────────╯ │
└──────────────────────┴──────────────────────────────────── 4 px right, 4 px bottom ────┘
```

- **Insets:** `padding-inline-end: var(--spacing)` (4) and `padding-block-end: var(--spacing)` (4). The left edge butts against the sidebar.
- **Sidebar under the corners:** the sidebar's background extends 16 px under the card's rounded corners via `.app-shell-left-panel:after { inset: 0 -16px 0 auto; width: radius-2xl }` (`fd9b7fd80db1.css@1357911`).
- **Sidebar header:** `--sidebar-navigation-header-height: 52px`.

**Sidebar width:** `--spacing-token-sidebar: clamp(240px, var(--codex-sidebar-preferred-width, 275px), min(520px, calc(100vw − 320px)))` (@144403). The JS minimum is 240 (`app-primary@470046`).

**Header contents:** sidebar trigger, back/forward history buttons, the thread title, and trailing actions (open in editor or terminal app, diff/review panel toggles). The app icons for the open-in targets ship in `webview/apps/` (Cursor, Ghostty, iTerm2, Warp, VS Code, Xcode…).

### 1.4 Agent surfaces

**Sidebar task rows** (`.sidebar-navigation` @701505):

| Property | Value |
|---|---|
| height | **30** |
| radius | 10 |
| padding-x | 8 |
| label inset | row h + 2 = **32** |
| child icon indent | (30+16)/2 + 1 = **24** |
| mode switch | 32 tall |

- Selected and hover use the ghost-hover plate (dark ink at 7.8 %, light 5.3 %).
- Rows are grouped by project ("Chats in {project}", collapse/expand, "New local chat in {project}").

**One status indicator per row.** The priority order is `suspended > input > approval > error > recording > activeCall > working > unread > paused > dot > scheduled > goal > pullRequest` (`app-initial@5301559`). Renderers start at `app-initial@9480799`.

| State | Rendering |
|---|---|
| **working** | a 16 px spinner (`icon-xs`) in a **20×20** slot, ink at 70 % (`PLs` @9489418) |
| **unread** | an **8 px** info-blue dot (an icon-xs box scaled 0.5) in a 20×20 slot (`NLs` @9489034). With a count it is a 20 h pill: `rounded-full px-1.5 text-[11px] font-semibold`, info at 18 % behind info text (`MLs` @9488486) |
| **error** | a danger glyph in a 20×20 slot, `text-danger` |
| **Needs approval** | a **text pill**: `rounded-full py-0.5 ps-2 pe-2.5 text-sm(13)`, `bg-chart-green/20 text-chart-green`, max-width 150 (`vLs` @9480799). Codex marks approval in **green**, not amber |
| **Needs input** | the same pill with `bg-blue/15 text-blue`. When an auto-resolution deadline exists, a progress sweep is drawn in the pill (`_statusPillProgress`) |

**In-thread status:**
- `Working for {time}`.
- The composer placeholder becomes "Working…".
- A thread status state machine runs Thinking / Working / Searching / NeedsInput / Paused / Ready.

**Diff/review panel:**
- Own surface `--codex-diffs-surface`, which is main surface mixed 94 % with 6 % ink (`--color-token-diff-surface`).
- Added/removed line wash at 23 % dark / 15 % light.
- Header padding comes from `--codex-diffs-header-padding-x/y`.
- The right panel is a split pane next to the thread (`data-app-shell-workspace-layout="split"`).

**Terminal:** an xterm pane (CSS `CX/241c9f83d2ce.css`) docked in the workspace. It is secondary; the thread is the primary surface.

**Composer:**
- Radius 22 (single-line radius 22 too).
- Elevated-primary-opaque ground.
- Gutter 12.
- Composer buttons 28 (sm 20, gap 4).
- Max width tracks the 48rem thread column plus a 24 px overhang.

**Empty state:** the startup loader is the OpenAI blossom at 56 px with a 2.2 s shimmer (`webview/index.html`). The home view has suggestion rows and a centred composer; the empty-state page height is `26.25rem`.

### 1.5 Icons and brand

- **Icons:** the chrome uses OpenAI's own icon set: about 2,270 SVGs on a 24 grid, filled-outline paths rather than strokes (`CX/*.svg`, rendered at 16 via `--icon-leading-size:16px`).
- **Lucide:** 3,274 `lucide-*.js` chunks are present, but they are the user-pickable project/section icon catalogue, not the chrome set.
- **Brand mark:** the OpenAI blossom, inlined as an SVG mask in `index.html`.

### 1.6 Launch observation (important side effect)

**What happened.** I launched the copied app once, to capture its real chrome. It did not show a login wall: it **silently reused the user's existing Codex CLI login** (`~/.codex/auth.json`) and opened a personalised onboarding screen (`re-apps/codex/shot-launch2.png`). I did not click anything, and I quit it at once.

**What it left behind.** The paths below are outside `re-apps/` and `/tmp`. The times are file birth times; nothing was reverted.

*Codex launch (17:11:25–17:11:52):*
- **Created:**
  - `~/Library/Application Support/{Codex,com.openai.codex,OpenAI}/`
  - `~/Library/Caches/{Codex,com.openai.codex}/`
  - `~/Library/HTTPStorages/com.openai.codex/` and `com.openai.codex.binarycookies`
  - `~/Library/Logs/com.openai.codex/`
  - `~/Library/Preferences/com.openai.codex.plist` and `com.openai.sky.CUAService.plist`
  - `~/.cache/codex-runtimes/`, a Node runtime the app extracted
- **Modified in `~/.codex/`:**
  - **`config.toml` was rewritten at 17:11:37** (new inode). It now has `[desktop] followUpQueueMode="steer"`, an `openai-bundled` marketplace and five bundled plugins enabled, most likely added by this launch.
  - `.codex-global-state.json` (+ `.bak`), `models_cache.json`, `sqlite/codex.db*`, `state_5.sqlite`, `logs_2.sqlite*`, `thread_history_1.sqlite*`, `vendor_imports/skills-curated-cache.json`, `cache/codex_apps_*`, `plugins/`, `skills/.system`, `.tmp/bundled-marketplaces`, `ambient-suggestions/`, `ipc/ipc.sock`, `tmp/arg0*`.
  - Some of the sqlite and log churn may come from the user's own concurrent Codex CLI sessions.

*Cursor launch* (done by the Cursor sub-agent with `--user-data-dir /tmp/cursor-re-profile`, 17:11:58–17:12:28). The flag did not contain everything:
- `~/Library/Application Support/Cursor/Crashpad/`
- `~/Library/Preferences/com.todesktop.230313mzl4w4u92.plist`
- `~/Library/Caches/com.todesktop.230313mzl4w4u92/` and `….ShipIt/` (the updater)
- `~/Library/HTTPStorages/com.todesktop.230313mzl4w4u92/`
- **`~/.cursor/` did not exist before and was created**: `argv.json`, `.gitignore`, `plugins/`, `projects/`, `agents/`, `ai-tracking/`, `computer-use-sidecar/`

*Unattributed:* `~/.cursor/hooks.json` and `~/.codex/hooks.json` were both rewritten at 17:13:48, after both apps had exited. This may be the user's own hook tooling reacting to the new `~/.cursor`.

The Claude desktop copy was **never launched**. The owner should review `~/.codex/config.toml` and `~/.codex/hooks.json`.

**What the capture shows of the chrome:**
- Traffic lights at x 16.
- No visible titlebar band; a full-bleed light canvas.
- Primary button: a 46-tall pill in near-black (#1a1c1f) with white text.
- Option card: radius 12, 1 px light border.

---
## 2. Anthropic Claude desktop (4.4212.0), including Claude Code ("epitaxy")

**Codenames used below:**

| Codename | What it is |
|---|---|
| `cds` | the design system |
| `dframe` / `df-` | the window frame |
| `epitaxy` | the Claude Code desktop components |
| `ion-dist` | the locally bundled web UI |

**Citation files** (one-line bundles, so `@` is a byte offset):

| Key | File |
|---|---|
| MAIN | `CLI/assets/v1/c6a992d55-DOxJvg9D.css` |
| SH | `CLI/assets/v1/shared-styles-BawOO5XW.css` |
| TOK | `CLI/assets/v1/shared-1-COpamMk3.js` (JS token table with light/dark twins, @234637–234761) |
| IDX | `CLI/index.html` |
| EL | `CLA/.vite/build/index.chunk-m4oMImJ-.js` (Electron main) |

I spot-checked these values against the bundle myself: `--df-sidebar-width:288px` (SH@29696), `oWi=12`/`cWi=33/2` (EL@5022226/@5022332), the surface-0…3 mapping, and accent = `role-accent-450`.

### 2.1 Colour tokens

Every colour is a hex value on a **warm grey** ramp. Derived tokens use `hsl(from …/α)` and `color-mix`. Light roles are at MAIN@1436901 (`.cds-root`), dark overrides at MAIN@1457759, and the grey ramp at MAIN@1424408.

| Role | Light | Dark |
|---|---|---|
| surface-0 (deepest) | gray-20 **#f9f9f7** | gray-900 **#0b0b0b** |
| **surface-1 = page / transcript ground** | gray-10 **#fcfcfb** | gray-850 **#151515** |
| surface-2 (panel, terminal, code) | **#ffffff** | gray-830 **#1a1a19** |
| surface-3 (composer, popover) | **#ffffff** | gray-800 **#20201f** |
| Sidebar ground ("web" frame) | mix(surface-0 50 %, surface-1) ≈ **#fbfbf9** (SH@70438) | mix(page 80 %, black) ≈ **#111111** (SH@82258, IDX L36) |
| Boot / window background | **#fcfcfb** | **#151515** (`fR`, EL@3314341) |
| text-primary | **#0b0b0b** | gray-50 **#f0efec** |
| text-secondary | gray-600 **#52514e** | gray-200 **#c3c2b7** |
| text-muted | gray-400 **#898781** | gray-400 **#898781** |
| text-disabled | alpha-4 (35 %) | alpha-4 (35 %) |
| border / strong / stronger | ink **10 % / 20 % / 40 %** | same alphas of white |
| hover (ghost) | **5 %** | **7.5 %** |
| selected (ghost) | **10 %** | **15 %** |
| accent fill | **#2a78d6** (blue-450); hover #3987e5 | same |
| accent text | #184f95 | #6da7ec |
| brand clay | **#d97757**; fill-brand #c6613f | same |
| success fill / text | #009300 / #006300 | #009300 / #0ca30c |
| warning fill / text | **#fab219** / #734500 | #fab219 / #db9300 |
| danger fill / text | **#d03b3b** / #8e2626 | #d03b3b / #ec7e7e |
| pro (accent) | #7161e0 | #7161e0 |
| git added / removed / modified / merged | #1e9e3c / #cd2054 / #98801f / #8e6bd9 | #32d74b / #ff2c56 / #ffd014 / #b796ff |

**Alpha ramp.** alpha-1…9 are neutral-900 at 5, 10, 20, 35, 50, 60, 70, 85 and 95 %. That is #0b0b0b in light and white in dark.

**Inactive window** (MAIN@1421118, SH@66307):
- The accent ramp turns grey (accent fill #7b7974).
- Primary and brand buttons turn gray-450.
- **Sidebar, header and titlebar ink drops to 50 %.**

**Legacy layer.** A `[data-theme=claude]` HSL layer (bg-000…300, text-000…500) still ships at MAIN@25462/@26808, but cds supersedes it.

### 2.2 Shape, type, elevation and motion

**Radius.** Compact, with comfortable in brackets:

| Token | Value |
|---|---|
| radius | 6 (8) |
| composer | 12 (14) |
| card | 10 (12) |
| panel | 10 (12) |
| frame card | 8 |
| sidebar row pill | 6 / 8 |
| checkbox | 4 |

- **Step scale** (MAIN@1477401–1481259):

  | Step | 1 | 2 | 3 | 4 | 5 |
  |---|---|---|---|---|---|
  | radius | 5 | 6 | 7 | 8 | 10 |
  | control height | 20 | 24 | 28 | 32 | 40 |

- **Hairline:** 1px at 1×, 0.5px at 2× (MAIN@1477203).

**Spacing** (compact, comfortable in brackets):

| Token | xs | sm | md | lg | xl |
|---|---|---|---|---|---|
| pad | 4 (6) | 6 (8) | 8 (12) | 12 (16) | 20 (24) |
| gap | 6 (8) | 8 (12) | 12 (16) | 20 (28) | 32 (40) |

`panel-inset` = `panel-gap` = **8**.

**Type.** The fonts are custom variable families: `anthropic-sans` (300–800) for the UI, `anthropic-serif` for "voice", and `anthropic-mono`, which falls back to SF Mono. Setting `data-font=system` switches to the system font.

| Role | Compact | Comfortable |
|---|---|---|
| caption | 11/17 | |
| footnote | 12/15 | |
| code | 12/17 | |
| **body** | **13/19** | 14/20 |
| heading | 14/18 | 15/20 |
| prose | 14/20 | 16/24 |
| title | 20/25 | 22/28 |

- **Weights:** 400 / 500 / **580** / 600.
- **Dark mode drops the weight axis to 360 / 460 / 540 / 560** (MAIN@1457759), so text is thinner on dark grounds.

**Shadows:**

| Shadow | Light | Dark |
|---|---|---|
| sm | `0 1px 2px gray900/6 %, 0 2px 8px gray900/8 %` | colour #0000003d |
| popover | `0 8px 24px #0000001f, 0 2px 6px #00000014` | `0 8px 24px #00000052, 0 2px 6px #0003` |
| frame card | `0 0 0 1px alpha-2, 0 4px 24px gray900/6 %` | `inset 0 0 0 1px #ffffff0f, 0 4px 24px …` |
| frame pop | `0 0 0 .5px #0000000f, 0 4px 12px #0000000f, 0 16px 40px #00000014` | `0 0 0 .5px #ffffff14, 0 4px 12px #0006, 0 16px 40px #00000080` |

**Rings sit outside in light mode and inside (inset) in dark mode.**

**Motion:**
- Durations: fast 60, snap **120**, base 200, sheet 300, slow 450 ms.
- Easings:
  - out: `(.165,.84,.44,1)`
  - snap / frame: **`(.32,.72,0,1)`**
  - out-fast: `(.2,0,0,1)`
  - overshoot: `(.34,1.3,.64,1)`
- The button spring is a `linear()` curve with about 9 % overshoot.
- Reduced motion sets every animation to 0.01 ms.

### 2.3 Window composition

**Native window** (EL):
- `titleBarStyle:"hidden"` with no overlay; min 600×400; default 1200×800 when signed in.
- Opaque window. Vibrancy is used only if the page requests it.
- **Traffic-light origin (17, 17)**. It is computed from a persisted "title-row centre" of **24** (allowed 16–32) and a button radius of 6, with a **74 px** spacer reserved (EL@5022226–5022854).

**Frame variant.** `gM()` returns `"web"` inside the desktop app (`CLI/assets/v1/shared-67-Wjlh-pe3.js@180288`), so the shipped look is a **flush sidebar**. An inset floating-card variant also exists ("desktop": inset 8, radius 8, the card shadow above; SH@32284), but it is only the fallback.

```
x=0                      288                                         W
┌───────────────────────┬┬───────────────────────────────────────────┐ y=0
│ ●●● origin (17,17)    ││ header 48 (h-frame-row = 3rem), draggable; │
│ centre y 24, 74 px    ││ title + actions; traffic-light centre y 24 │
│ spacer; wordmark h20  ││                                            │
│ at (16,14)            ││                                            │ 48
├ sidebar 288 ──────────┤│ 8 ┌─────────────────────────────────────┐ 8│
│ light ≈#fbfbf9        ││   │ panes in a grid; split = 1px border  │  │
│ dark  ≈#111111        ││   │ ground = surface-1                   │  │
│ seam: max(panel-line, ││   │ (#fcfcfb / #151515)                  │  │
│ .5px) border-inline-  ││   │ unfocused pane: opacity .75,         │  │
│ end at 10 % ink       ││   │ saturate .85, over 120 ms            │  │
│ rows 26 / 28 / 32     ││   └─────────────────────────────────────┘  │
│ footer tray, .5px rule││                                            │
└───────────────────────┴┴───────────────────────────────────────────┘
```

- **Content insets:** content padding-inline-start is sidebar + 8, and padding-inline-end is 8 (SH@36079).
- **Sidebar:** width 288 (the skeleton uses `18rem`, IDX L36).
- **Resize handles:** 12 px hit area.
- **Pane grip:** a 32×3 pill at 20 %, shown on hover.
- **Collapsed sidebar:**
  - A 28 px trigger sits at the traffic-light spacer + 8.
  - Hovering opens a **peek popover**: 280 wide, radius 8, the frame-pop shadow.
  - It enters from `translate(0,-6px) scale(.98)`, with opacity over 140 ms and transform over 180 ms on `(.32,.72,0,1)`.

### 2.4 Agent surfaces (Claude Code)

**Session rows** (SH@13282–21766):

| Property | Value |
|---|---|
| height | **26** compact, **28** in the code list, 32 comfortable |
| row font | **13** (14 comfortable) |
| group label | 12, muted ink; secondary on hover |
| icon | 16 in a 24 slot |
| gap between rows | 2 |
| selected | **the hover plate** (5 % / 7.5 %) |
| optional meta line | 12/16, with a 12 px trailing fade mask |
| nested families | an L-shaped 1 px guide with end radius 6 |

**Status dot.** It is **6×6** (SH@27555):

| State | Look |
|---|---|
| awaiting | **#fab219** amber |
| ready | accent #2a78d6 |
| error | #d03b3b |
| **running** | a muted dot that blinks 0.3↔1 over 1.2 s; no spinner |
| unread | muted |
| "clay" | a 24 px breathing orange orb PNG (inferred usage) |

Session states in code: running, pending, awaiting, idle, failed.

**Approval card** (`CLI/assets/v1/c2d1aeb56-DkN4_gZk.js`@~3168; MAIN@221985, @1546506):
- Radius 10/12, padding 12, gap 12, max-height 60vh.
- Ground: surface-panel + ring + shadow-sm.
- It enters over 220 ms `(.215,.61,.355,1)` from opacity .75, translateY −6, scale .97.
- It docks above the composer, with a dock floor of 144 px.

**Transcript:**
- Body 14 / 1.4286.
- Gutter 32 (16 when ≤ 560 px).
- Turn gap about 15, item gap about 10.
- Scroll fades 32 / 48.

**Run indicators:**
- Linear sweep 1.1 s.
- Check draw 180 ms.
- Pill pulse 420 ms to 1.05.
- Status band enters and exits over 120 ms with a 6 px translate.

**Diff:**
- Mono 12/17, file rows 18.
- Git colours above; modified uses accent text.
- A 1 px bordered card.

**Terminal** (xterm, `CLI/assets/v1/c6bf19e8f-BzuTs6yG.js`@55927/@62224; theme in `c5d464fa3-D-Oyr4xs.js`@3147/@4169):
- Menlo 13, block cursor, **`minimumContrastRatio: 3`**, scrollback 10,000.

| | claude-dark | claude-light |
|---|---|---|
| bg | **#1a1a19** | #ffffff |
| cursor | #0099ff | #0073e6 |
| selection | #0099ff4d | #0073e640 |
| red | #ff3a30 | #ff3a30 |
| green | #32d74b | #1e9e3c |
| yellow | #ffd014 | #98801f |
| blue | #0099ff | #0073e6 |
| magenta | #ff2c56 | #cd2054 |
| cyan | #b796ff | #8e6bd9 |
| black / brightBlack | #262626 / #525252 | #1a1a1a / #666666 |
| white / brightWhite | #a6a6a6 / #ededed | #999999 / #d6d6d6 |

**Composer:**
- Radius 12/14.
- Shadow `0 4px 20px black/3.5 %` + a 1 px ring; on focus 7.5 % + a border-strong ring.
- The home composer: radius 20, padding 14, surface-3, max width 672.

**Empty / home state:** a greeting with the clay spark glyph, starting at 18vh from the top.

### 2.5 Icons and brand

- **Icons:** a custom variable **icon font**, `Anthropicons-Variable` (weight axis 400–700; MAIN@4768).
  - Sidebar icons render at weight **433**, chrome icons at **533**, and the selected app-switch icon at 700.
  - Lucide appears only in the artifact-sandbox allow-list. There is no Phosphor.
- **Brand:** the clay #d97757 spark and wordmark (20 tall in the sidebar head).

**Screenshot:** none was taken. The profile was not isolatable without risk; Codex showed that the copies pick up the user's real credentials.

---
## 3. Cursor 3.27.22: the Agents window ("Glass")

**What runs.** The Agents window is a separate renderer, `CU/out/vs/workbench/workbench.glass.main.{js,css}`, opened in its own window titled "Cursor Agents".
- `CU/molten/` is a third shell, "Molten Glass" (`--mg-*` vars). It is the next-generation Agents window, behind the flag `molten_agents_window` (default false, `CU/out/main.js`), and reuses the same `@anysphere/ui` tokens.
- Glass is what ships.

**Launch.** The app was launched once with an isolated profile (`--user-data-dir /tmp/cursor-re-profile`). It opens "Cursor Agents" behind a Log In / Sign Up wall (`re-apps/cursor/shot-01-launch.png`, light mode, 1280×800). The light tokens were read live from the DOM over CDP and match the static values.

**Citation keys:**

| Key | File |
|---|---|
| J | `CU/out/vs/workbench/workbench.glass.main.js` (byte offsets) |
| GC | `re-apps/cursor/extracted/pretty/workbench.glass.main.css` (a prettified copy of the shipped CSS; line numbers) |
| TOK | `re-apps/cursor/extracted/glass-root-tokens.txt` (J from @15797000, split on `;`; line numbers) |
| M | `CU/out/main.js` |

I re-checked these myself: `SSe={defaultPx:260,minPx:210,maxPx:400,storageKey:"glass/leftSidebarWidth"}` (J@26599113), `xqi=40,ma_=44,$Tc=8,l$s=80` (J@29432389), `ebe=20` (M@1854098), and the vibrancy branch (M@453428).

### 3.1 Colour tokens

**Primitives.** Each theme is about 25 primitives in **OKLCH** (dark `dark.js` at J@15615906, light `light.js` at J@15621925). Every semantic token is the base ink mixed toward transparent (recipe `Jas`, J@15584692; TOK 4–582). The hex values are converted from OKLCH, and the light ones match the live DOM.

| Primitive | Dark | Light |
|---|---|---|
| chrome (window canvas, chat surface, terminal) | **#141414** | **#F8F8F8** |
| sidebar | **#181818** | **#F3F3F3** |
| pane (editor) | #181818 | #FCFCFC |
| elevated (cards, composer, menus) | **#212121** | #FCFCFC |
| base (ink) | **#F0F0F0** | #141414 |
| accent | **#599CE7** (focus ring #F0F0F0) | **#2678C1** |
| brand | #F54E00 | #F54E00 |
| success / added | #3FA266 / #70B489 | #007041 |
| warn (= yellow, modified) | **#F1B467** | #A46701 |
| danger / removed | #E34671 / #FC6B83 | #BE1744 |
| diff added / removed line | #3FA26633 / #B8004933 | #01AF6624 / #FF617B38 |

**Tiers** (alpha of the ink, the same recipe in both modes):

| Tier | Values |
|---|---|
| text | **100 / 74 / 60 / 36** |
| icon | 100 / 66 / 52 / 28 |
| fill | 20 / 14 / 8 / 6 / 4 (input 3) |
| stroke | **20 / 12 / 8 / 4** |
| sidebar row hover / active | **6 % / 8 %** (dark #252525 / #292929; light #E6E6E6 / #E1E1E1) |

**Glass layer** (GC 47774–47886):
- Window canvas: `rgba(0,0,0,.42)` dark, `hsla(0,0%,100%,.16)` light, over native vibrancy.
- Sidebar: mixed to 42 % light / 36 % dark when vibrancy is on.
- Chat/editor surfaces: chrome mixed to 84 % light / 72 % dark (88 % dark when panel cards are on).
- Inactive agent tile: opacity .8 dark, .96 light.

### 3.2 Shape, type and motion (TOK 583–758)

**Radius:** xs 2, sm 4, base 6, lg **8**, xl **12**, 2xl 14, 3xl 16, 4xl 18. Every Glass element gets `-electron-corner-smoothing: 60%`, a squircle (GC 47755).

**Spacing:** a 4 px base with quarter steps.

**Control heights:**

| Size | xs | sm | base | lg |
|---|---|---|---|---|
| Height | 20 | 24 | 28 | 32 |

**Type:**
- UI is the system font; mono is Monaco, then ui-monospace or SF Mono. JetBrains Mono is bundled.
- Scale (size / line-height):

  | xs | sm | **base** | lg |
  |---|---|---|---|
  | 11/14 | 12/16 | **13/18** | 14/22 (Glass: 15/24, −0.24) |

- Base tracking is −0.08.
- With `glass-typography-refresh` on macOS, the "normal" weight is **418**, not 400 (J@~46396200).

**Shadows:**
- shadow-primary is black at 20 % (dark) / 6 % (light).
- `box-shadow-sm` is `0 2px 8px` shadow-secondary.
- Dark popup: `0 3px 8px, 0 2px 5px, 0 1px 1px`.
- `lg`/`xl` add an inset `0 0 4px #FFFFFF0D` rim.
- Docked overlays use `0 25px 50px -12px rgba(0,0,0,.25)`.

**Motion** (J@10276504):
- Durations: instant 50, fast 100, normal **150**, slow 200, slower 300 ms.
- Easings: out-quint `(.16,1,.3,1)`, out-strong `(.165,.84,.44,1)`, out-cubic `(.215,.61,.355,1)`, in-out-strong `(.77,0,.175,1)`.
- Floating panels enter over 200 ms and exit over 150 ms, both out-quint.
- Sidebar width animates over 150 ms ease-out, with no transition while dragging.

### 3.3 Window composition

**Native window** (M@451800–453600):
- `titleBarStyle:"hidden"`, `hasShadow`, **`vibrancy:"sidebar"`**, `visualEffectState:"active"`.
- Background #40000000 dark / #00FFFFFF light.

**Bar and traffic lights:**
- Bar height is **40** (44 with `data-chrome-resize`).
- Traffic-light y = `floor((barH−14)/2) + inset`, and x = y + 1. That gives **(14,13)**, or **(22,21)** in inset mode.
- Inset mode applies on macOS 26 with the native compact-toolbar call, which also raises the **window corner from 16 to 20 pt** (`ebe=20`, M@1854098).
- The traffic-light spacer is 80 (+5 in inset mode).

**Floating panels** (server gate `glass_floating_panels`, J@46565428):
- **Gutter 8.**
- Panel radius `max(0, 20 − 8)` = **12**, so it is concentric with the 20 pt window corner. Inner radius 11.
- **1 px inset ring at stroke-secondary (12 %)**.
- Fill `--cursor-bg-elevated`; shadow `0 2px 8px`.
- **Docked fallback:** gutter 0, radius 0, and the sidebar gets a right hairline of 1 px (0.5 px at ≥2 dppx).

**Panel sizes:**
- Sidebar **260** (210–400), stored under `glass/leftSidebarWidth`; UI-kit collapsed width 48.
- Right diff/editor panel takes a 0.5 ratio, minimum 384.
- Chat column max **780**; composer max 840.

```
macOS 26, floating panels on (window corner 20 pt)
┌────────────────────────────────────────────────────────────────────────┐
│ canvas: black 42 % (dark) / white 16 % (light) over NSVisualEffect     │
│ 8 ╭─ sidebar card 260, r12 ─────╮ 8 ╭─ main ─────────────╮ 8 ╭─ diff r12 ╮ 8
│   │ ●●● (22,21)  [85 spacer]    │   │ 40 top bar          │   │ ≥384, 50 % │
│   │ 40 top bar, px 12           │   │ chat column ≤780    │   │            │
│   │ rows 28, inset 6, r8, gap 2 │   │ on chrome surface   │   │            │
│   │ ring 1px @12 %, 0 2 8 shadow│   │ composer r20        │   │            │
│   ╰─────────────────────────────╯   ╰─────────────────────╯   ╰────────────╯
└──────────────────────────────────────── 8 ─────────────────────────────┘
Docked (gate off or pre-26): gutter 0, radius 0, one 1px (0.5 @2x) sidebar hairline.
```

### 3.4 Agent surfaces

**Sidebar row** (UI kit `HIp` J@12451678; Glass overrides GC 37026–37062):

| Property | Value |
|---|---|
| min-height | **28** |
| block padding | 5 |
| row inset | **6** |
| icon–text gap | 6 |
| radius | **8** |
| font | 13 |
| row gap | 2 |
| group gap | 16 |
| group label | 13/18 |
| leading icon | 14 |
| trailing icon | 13 |
| action box | 24 |

- **Plate:** a `::before` fill, hover 6 % and active 8 %. The keyboard highlight is an inset 1 px focus ring.
- **Text:** 74 % at rest; 100 % when hovered, active or highlighted.

**Status icons** (`ui-agent-status-*`, 14 px):

| State | Look |
|---|---|
| draft | `circle-dashed`, quaternary |
| in progress | a determinate **progress ring** (track .14, fill .45) |
| needs attention | `exclamation-circle` in **yellow** |
| error | the error glyph |
| done | `check-circle`, quaternary |

**Agent glyph badge** (`AgentAppearanceGlyph.js`, J@18962800–18965480). This is almost exactly Axolotty's design:
- A 14 px glyph in a 20 px box.
- A **6 px dot** at right 2 / bottom 2: done-unseen = **accent**, needs-attention = yellow, error = red.
- The glyph is masked with a 4 px-radius hole (a 3 px dot plus a **1 px moat**).
- A running sub-agent shows an **8 px spinner** with a 6 px hole.

**Composer:**
- Radius **20**.
- 1 px border at stroke-tertiary (8 %), raised to 12 % on hover or focus. No shadow.
- Elevated fill.
- Editor 36–200 tall.

**Conversation:**
- Text 14/22, block gap 16.
- Bubble max `min(640px,100%)`, radius 12.
- Tool cards: padding 10, gap 6.

**Terminal:**
- Background is chrome (#141414 / #F8F8F8).
- xterm scrollbar 14 wide, 3 px padding, 8 px round thumb.

**Empty states:** a rotating-tips empty tab; the projects sidebar shows a single "New Project" row with a plus icon.

### 3.5 Icons and brand

- **Icons:** the custom icon font `cursor-icons` (`CU/out/media/cursor-icons-16.woff2`, 16 px grid), with Codicons as a fallback. Lucide is effectively absent (7 vendor hits).
- **Brand marks:** glyphs in that font, including `anthropic`, `claude`, `openai`, `gemini`, `github`, `linear` and `cursor-logo`.
- **Splash:** a glass-cube PNG.

**Not resolved:**
- Whether a signed-in user gets floating cards or the docked layout depends on the `glass_floating_panels` gate, which is server-side.
- The panel ring colour is inferred to be stroke-secondary.

---

## 4. Cross-app synthesis

### 4.1 Where all three agree

| Topic | Codex | Claude | Cursor | Consensus |
|---|---|---|---|---|
| UI font | SF, **weight 430** | Anthropic Sans (system optional); dark-mode weights −40 | SF, **weight 418** | The system font, nudged **slightly above Regular** |
| Chrome / row text | 13 | 13/19 | 13/18 | **13** |
| Secondary / caption | 12 / 11 | 12 / 11 | 12 / 11 | **12 / 11** |
| Transcript body | 14 | 14/20 | 14/22 | 14 (n/a to a terminal) |
| Emphasis weight | **510** (labels, titles) | 580 | 500 / 600 | **Medium-ish (500–580), not Semibold** |
| Sidebar row height | 30 | 26 / 28 | 28, gap 2 | **28 (+2 gap)** |
| Row radius | 10 | 6 / 8 | 8 | **8** |
| Row hover / selected (dark) | 7.8 % / same plate | 7.5 % / 15 % | 6 % / 8 % | **6–8 % hover, 8–15 % selected**; selection is neutral, never accent |
| Rest text in rows | primary | muted / secondary | **74 %** (full on hover/active) | Rows rest **below full ink** and lift on hover/selection |
| Text tiers | 100 / 71 / 50 | #f0efec / #c3c2b7 / #898781 | 100 / 74 / 60 / 36 | **100 / ~72 / ~50 / ~35** |
| Dark primary text | **#dfdfdf** | **#f0efec** | **#F0F0F0** | **Never pure white**: 87–94 % |
| Dark main ground | #181818 | #151515 | #141414 / #181818 | **#141414–#181818** neutral |
| Hairline | 1 px at 1×, 0.5 at ≥1.5× | 1 px at 1×, 0.5 at 2× | 1 px, 0.5 at ≥2 dppx | **1 device px**, ~8–12 % ink |
| Accent | **#339cff** | **#2a78d6** | **#599CE7 / #2678C1** | **Blue** for focus, link and "ready"; the brand hue (clay #d97757, Cursor orange #F54E00) is kept off the chrome |
| Finished-unseen | blue info dot | accent "ready" dot | **accent** badge dot | **Accent dot** |
| Needs-you | green pill (approval), blue pill (input) | **amber #fab219** dot | **yellow #F1B467** dot / `!` icon | **Amber/yellow** (2 of 3) |
| Working | 16 px spinner in a 20 slot | muted dot blinking over 1.2 s | progress ring 14; 8 px spinner badge | **Small, low-ink, animated**; never colour |
| Status geometry | one indicator per row, by priority | 6 px dot | **6 px dot, 1 px moat, on the glyph** | One indicator; Cursor's matches Axolotty's to the pixel |
| Radius scale | 4 / 6 / 8 / 10 / **12** / 16 / 20 / 24, superellipse | 5 / 6 / 7 / 8 / 10 (+4 for cards) | 2 / 4 / 6 / 8 / **12** / 14 / 16 / 18, 60 % smoothing | **8 for rows, 12 for cards/panels**, squircle corners |
| Hover / UI motion | 150 ms | 120 ms snap | 150 ms | **120–150 ms** |
| Enter easing | `(.19,1,.22,1)` expo-out | `(.32,.72,0,1)` | `(.16,1,.3,1)` out-quint | **A strong ease-out**; enter 200–300 ms, exit 150–200 ms |
| Reduced motion | honoured | 0.01 ms | 0.01 ms | yes |
| Icons | own SVG set (24 grid, filled outline) | own variable icon **font** (weights 433/533/700) | own icon **font** (16 grid) | **Proprietary, single-family** sets. Lucide is incidental everywhere |
| Unfocused split pane | — | opacity .75 + saturate .85 | tile opacity .8 / .96 | Dim to about **0.75–0.8** |

### 4.2 Where they differ

1. **Card or flush.** This is the big one.
   - **All three have built an inset-card composition, and none ships it as the plain default:**
     - Codex: a "page surface" card at radius 12, inset 4 right and bottom, top at the 44 titlebar. It is behind a Statsig gate.
     - Cursor: floating panels with an 8 gutter, radius 12 and a 20 pt window corner. They are behind a server gate and macOS 26.
     - Claude: a floating "desktop" frame (inset 8, radius 8). It exists only as a fallback.
   - **What ships in practice:**
     - Codex: flush, with a 0.5 px seam.
     - Cursor: docked, with a 1/0.5 px seam.
     - Claude: flush sidebar plus an **8 px content moat** on both sides of the pane grid.
   - **Direction of travel: towards the card.** Two vendors are actively rolling the card out.
2. **Sidebar tone relative to the content.**
   - Codex opaque: sidebar = surface × black 0.16, **darker** than the content (#141414 vs #181818).
   - Claude: page × black 0.20, **darker** (#111 vs #151515).
   - Cursor: the sidebar is **lighter** than the canvas/chat (#181818 vs #141414), and in floating mode the cards are elevated #212121 on a translucent black canvas.
   - Light mode, every app: the steps are tiny (Claude #fbfbf9 vs #fcfcfb; Codex #f6f6f6 vs #fff; Cursor #F3F3F3 vs #F8F8F8).
3. **Glass.**
   - Codex (`vibrancy:"menu"` under a 70 % tint) and Cursor (`vibrancy:"sidebar"`, 36–42 % tint) put **native vibrancy behind the sidebar and canvas**.
   - Claude is opaque.
   - Both glass apps keep an opaque fallback: Codex "opaque windows" paints #141414 / #f6f6f6.
4. **Titlebar band height and traffic lights:**
   - Codex: 46 classic, **44** in page-surface mode; lights at (16, 15).
   - Claude: **48**; lights at (17, 17), centred on y 24.
   - Cursor: **40** (44 resized); lights at (14, 13), or (22, 21) in inset mode.
5. **Sidebar width:** Codex 275 (240–520), Claude **288**, Cursor **260** (210–400).
6. **Approval colour:** Codex uses **green and blue text pills** ("Needs approval", "Needs input"). Claude and Cursor use amber/yellow dots. Codex alone spends words in the row.
7. **Type family:** Claude alone uses a custom family (Anthropic Sans/Serif/Mono) and lowers weights in dark mode. Codex and Cursor stay on SF but nudge the weight up (430 / 418).
8. **Inactive window:** Claude alone does something strong: chrome ink drops to 50 % and the accent turns grey.

---

## 5. Implications for Axolotty: exact numbers to adopt

Axolotty's tokens already land inside the premium consensus on almost every micro value:

| Value | Axolotty | Premium consensus |
|---|---|---|
| row height | 28 + 2 | 28 + 2 |
| row radius | 8 | 8 |
| text tiers | 1 / .72 / .50 / .32 | 100 / 74 / 60 / 36 |
| hover / selected | 5.5 / 9 % | 6–8 % / 8–15 % |
| 1-device-px hairlines | yes | yes |
| 13 pt chrome | yes | yes |
| hover timing | 150 / 100 ms | 120–150 ms |
| state badge | 6 pt dot with a 1 pt moat | Cursor's, to the pixel |

So the "not impressive" verdict is **not a token problem. It is composition.** The capture `now-dark.png` shows:
- a 40 pt empty band that is the same colour as the terminal;
- a sidebar (#121212-ish) separated from the terminal (#141414) by a single hairline;
- a terminal that runs edge to edge.

Every premium app instead gives the working surface its **own object**: a card, or at least a moat, set off by a distinct shell tone. The changes below are ordered by impact.

### 5.1 Make the terminal area a surface on a shell ground (the page-surface model)

Adopt the Codex page-surface / Cursor floating-panel composition, using the numbers both converge on:

```
┌────────────────────────────────────────────────────────────────────┐
│ ●●● (16,15)  ⊟ +      band 44, painted with the SHELL tone          │ 0
├── sidebar 260 (shell tone, no seam) ──┬────────────────────────────┤ 44
│                                       │╭── terminal surface ──────╮│
│                                       ││ radius 12 (squircle)      ││
│                                       ││ fill = theme bg           ││
│                                       ││ ring 1 device px          ││
│                                       ││ shadow 0 4 16 / 5–30 %    ││
│                                       │╰───────────────────────────╯│ 6
└───────────────────────────────────────┴────────────────────── 6 ──┘
```

| Property | Value | Basis |
|---|---|---|
| Card top | **44** (the band sits on the shell, not on the terminal) | Codex `--height-titlebar` 44; Cursor resized bar 44 |
| Card inset | left **0** (it abuts the sidebar), right **6**, bottom **6** | Codex 4/4; Cursor 8 gutters; Claude 8 moat. 6 sits between them and stays on the 2-grid at 1× |
| Card radius | **12**, continuous | Codex `--radius-xl-base`; Cursor 20 − 8 = 12. Inner pane plates and palette rows keep 8 (concentric with a 4–6 inset) |
| Card ring, dark | inside, **1 device px of fg at 6 %** | Codex `elevation-stroke-subtle` 6 %; Claude dark `inset 0 0 0 1px #ffffff0f` |
| Card ring, light | outside, **fg at 6–10 %** | Codex 4 %; Claude `0 0 0 1px` alpha-2 = 10 %; Cursor 12 % |
| Card shadow, light | `0 4 16 / 0.05` | Codex `--shadow-card` #0000000d; Claude `0 4 24 / 6 %` |
| Card shadow, dark | `0 4 16 / 0.30` | It needs more alpha to read on dark |
| Shell tone, dark | **bg mixed with black at 0.16** (Codex exactly), up to 0.20 (Claude). The current 0.24 is darker than either; with a card it can come back to 0.16 | Codex `B.dark=.16`; Claude page × 80 % |
| Shell tone, light | **bg mixed with fg at 0.04** | Codex `B.light=.04` (#f6f6f6 under #fff) |
| Sidebar seam | **delete it.** The card edge is the boundary. Codex removes `_MainContentLeftBorder` in this mode | Matches our own rule of one cue per boundary |
| Splits inside the card | keep the single hairline between panes (Claude 1 px border; Codex 0.5 px) | |
| Unfocused-pane dim | keep the 0.28 overlay | Equivalent to Claude's opacity .75 and Cursor's .8 |
| Sidebar hidden | the card becomes left 6 too, so the inset is symmetric | Codex keeps the start inset when the sidebar collapses |

**Why this beats the alternatives:**
- **It is the composition two of the three vendors are rolling out**, and it solves the visible problem in our capture: three near-identical darks with one hairline.
- **It keeps "the terminal is the window" in spirit.** The card is the terminal's own ground, with no padding moat inside it. Our 12 / 8 / 6 terminal padding stays.
- **It is the only premium answer that does not need glass.** That suits our no-glass principle: Claude proves the opaque path works.

**The flush alternative.** If the owner prefers to stay flush, copy Claude instead:
- keep the sidebar at bg × black 0.20 with a 1 px seam at fg 10 %;
- put an **8 pt moat on both sides of the pane grid**;
- give the band 48 pt.

That is the minimum the premium tier ships.

### 5.2 Band and traffic lights

| Property | Value | Basis |
|---|---|---|
| Band height | **44** | Codex page-surface 44; Cursor resized 44. Our 40 is the low outlier, matched only by Cursor's legacy bar |
| Traffic lights | origin **x 16**, centred vertically: y = (44 − 14) / 2 = **15** | Exactly Codex's formula. Claude's (17, 17) assumes a 48 band |
| Sidebar toggle and "+" | keep the 28-pt targets, centred on y 22 | |
| Band contents | the **session title (13, medium) and per-session actions on the right**: split, open folder in an editor, and so on | Every premium header carries the current object's title plus actions. An empty band reads as unfinished. Codex: title + open-in-app + panel toggles; Claude: title + actions at 48 |
| Our "say it once" rule | keeps the title out of the sidebar row's job, and only the selected session's title goes in the band | Compatible with the above |

### 5.3 Sidebar

| Property | Value | Basis |
|---|---|---|
| Width | **260** default, **210–400** range | Cursor exactly. Codex 275, Claude 288. Our 248 is the narrowest; 260 keeps the most terminal columns while joining the tier |
| Row height, gap, radius | keep **28 / 2 / 8** | Consensus |
| Row inset | **6** (it is 8 today) | Cursor 6. Lets 260 behave like 264 |
| Project-name weight | **medium (NSFont.Weight 0.23, ≈ 500–510), not semibold** | Codex labels and titles are 510; Cursor uses 500. Semibold 600 is heavier than the tier uses for chrome emphasis |
| Optional body weight | system 13 at a variable weight of about **430** | Codex 430, Cursor 418. Use an `NSFontDescriptor` weight trait of about +0.06. Test it at 1×, because the gain is subtle on non-Retina |
| Row rest ink | keep 0.72, full on hover/selected/live | Cursor 74 % → 100 %, the same model |

### 5.4 State colours and badges

| Property | Value | Basis |
|---|---|---|
| **Done-unseen** | change it from neutral to the **accent** dot | Cursor done-unseen = accent; Claude "ready" = accent; Codex unread = blue info dot. A neutral dot is invisible next to idle |
| Waiting | keep **amber**. Dark: Cursor **#F1B467**, Claude #fab219. Light: Cursor #A46701 / Claude text #734500 for contrast on white | |
| Failed | dark red **#E34671** (Cursor) / #d03b3b (Claude); light #BE1744 | |
| Working | keep the 8 pt spinner (Cursor's sub-agent spinner is 8 px with a 6 px hole) | Codex's 16 px spinner suits rows that have no glyph; ours has one |
| Badge geometry | 6 dot, 1 moat, lower right: **no change** | Identical to Cursor's `AgentAppearanceGlyph` |
| Inactive window (new) | drop sidebar and band ink to **50 %** and draw the accent grey | Claude, MAIN@1421118 |

### 5.5 Ink and grounds (dark)

| Property | Value | Basis |
|---|---|---|
| Primary chrome text | **fg at 0.92–0.94**, not 1.0 | Codex #dfdfdf, Claude #f0efec, Cursor #F0F0F0. Leave terminal text to the theme |
| Neutral ground | if the theme bg is user-chosen, nothing changes. The default theme's chrome should sit at **#141414–#181818** neutral | All three |
| Accent (proposal) | keep magenta for caret and focus if it is brand identity. Note that the whole tier uses blue at about L 0.62–0.70 (#339cff, #2a78d6, #599CE7) for focus and ready, and keeps the brand hue off the chrome | |

### 5.6 Motion

- Keep tick 150 / tickOut 100.
- Panel/card enter **240 ms on `cubic-bezier(.16,1,.3,1)`**; exit **160 ms**. Cursor uses 200/150 and Codex 300/200.
- The sidebar spring is **0.35 s with 0.10 bounce**. That is Codex's default `Pkn` exactly; our panel spring is 0.40 with no bounce.
- The hover-card / palette pop is fine. Claude's peek is translate −6, scale .98, 140 ms opacity / 180 ms transform, which matches our palette's 98 % and 160 ms.

### 5.7 What not to copy

- Codex's **text pills in rows** ("Needs approval"). Our rule of one glyph, no words at rest is the Cursor/Claude majority.
- **Glass.** 2 of 3 use vibrancy, but both carry opaque fallbacks, and the card model gives the depth without it.
- Claude's **custom typeface**. That is brand budget. SF at medium for emphasis does the job, as it does for Codex and Cursor.
