# Premium agent-orchestrator apps: reverse-engineered design ground truth

Date: 2026-11-02. Every value below comes from shipped bundles or vendor source. None is estimated from a screenshot unless it is marked as such.

**Root.** All paths are relative to `/Volumes/Lacie/Workspace/oss/re-apps/` unless noted.

**Captures** are in `.research/wow/orchestrators/`:
- `*-launch.png`: first-launch windows. Every app except opencode stopped at sign-in or onboarding.
- `site-*.png`: official product imagery, used only to rank the apps.

---

## 0. Provenance, signatures and launch log

### Provenance

Every download came from the vendor's own site or GitHub releases. Each went into its own new `download/` directory, was mounted read-only, and was copied to `app/`. All passed `spctl` as "Notarized Developer ID".

| App | Version | Bundle ID | Team ID (Developer ID) | Runtime | Official source | Analysed from |
|---|---|---|---|---|---|---|
| Conductor | 0.92.0 | com.conductor.app | 27XN666UJ7 (Charlie Holtz) | **Tauri** (WKWebView) | `cdn.crabnebula.app/download/melty/conductor/latest/platform/dmg-aarch64`, the link behind the "Download" dialog on conductor.build | 2,951 assets recovered from the Mach-O (§0.1), CSS pretty-printed to `conductor/pretty/` |
| opencode desktop | 2.2.5 | ai.opencode.desktop | 5NZ4Q7NXJ4 (Anomaly Innovations) | Electron (no longer Tauri) | `opencode.ai/files/bin/2.2.5/opencode-desktop-mac-arm64.dmg` | `opencode/src` (sst/opencode @ff90ed9, packages at 2.2.5) plus `opencode/extracted` |
| Paradev (formerly Superset) | 2.0.3 | com.superset.desktop | 2HVBK29S3C (Satya Patel) | Electron | `github.com/ParadevAI/Paradev/releases/download/desktop-v2.0.3/Superset-2.0.3-arm64.dmg` | `paradev/src` (@344c299f, `apps/desktop` 2.0.3) plus `paradev/extracted` |
| Factory (Droid desktop) | 1.1.0 | com.electron.factory | SW6TL4V6Q5 (The San Francisco AI Factory) | Electron | `downloads.factory.ai/factory-desktop/releases/1.1.0/darwin/arm64/Factory-1.1.0-arm64.dmg` | `factory/extracted` |
| Emdash | 1.2.10 | com.emdash.stable | 2AZ6648627 (Arne Strickmann) | Electron | `github.com/generalaction/emdash/releases/download/v1.2.10/emdash-arm64.dmg` | `emdash/src` (@5922811) plus `emdash/extracted` |
| Sculptor (Imbue) | 0.49.0 | com.electron.sculptor | LDDYAR29MP (Imbue, Inc.) | Electron | `imbue-sculptor-releases.s3.amazonaws.com/slim/Sculptor.dmg`, the target of imbue.com/sculptor → tryimbue.link | `sculptor/extracted` |
| Nimbalyst (formerly Crystal) | 0.81.7 | com.nimbalyst.electron | 3GYP4YJ3DH (Gregory Hinkle) | Electron | `github.com/Nimbalyst/nimbalyst/releases/download/v0.81.7/Nimbalyst-macOS-arm64.dmg` | `nimbalyst/extracted`; asar extraction was partial (one unpacked CLI binary missing), but the renderer is complete |

All seven ship macOS builds, so none was skipped. Factory is the only one whose name differs from its product: the app is "Factory" and the agent inside it is "Droid".

### 0.1 Tauri asset recovery (Conductor)

Tauri brotli-compresses each frontend asset into the binary as a phf map of `(&str key, &[u8] value)`. The script `_tools/tauri_assets.py`:
- maps the Mach-O segments;
- decodes 36-bit chained-fixup pointers;
- walks `__DATA*` sections for `(key_ptr, key_len, val_ptr, val_len)` tuples whose key looks like `/path`;
- runs `brotli -d` on each value.

It recovered 2,951 assets, including `index.html`, `assets/index-C0NH49rF.css` (the theme), `assets/renderApp-BBRm1hiD.js` (12 MB, the app) and `assets/main-DkBMmrtL.js`. Nothing was executed.

**Citation convention.** Conductor CSS is cited by line in `conductor/pretty/index-C0NH49rF.css` (a prettier-formatted copy of the shipped file). JS is cited as `renderApp-BBRm1hiD.js:<line>` plus a unique snippet, because lines in the minified file run to megabytes.

### 0.2 Launch log (required by the coordinator)

All of these launches happened before the coordinator's no-launch rule arrived. Each used the **real HOME (`/Users/congtran`)**: `open -n <copied .app>`, a `screencapture`, then SIGTERM and `pkill` on that app's path only. Times are from the app-support directory birth times.

| App | Launched | Quit | What it created or changed under ~ (as observed) |
|---|---|---|---|
| Conductor | ~17:10:50 | ~17:11:40 | `~/Library/{Application Support,Caches,WebKit}/com.conductor.app`. The window stayed blank on the canvas colour. |
| opencode | 17:11:50 | ~17:12:07 | `~/.config/opencode/service.json`, `~/.local/state/opencode/service.json`, plus `~/.local/share/opencode/{shell/*,log/opencode.log,opencode.db*}`, `~/Library/Application Support/ai.opencode.desktop`, `~/Library/Preferences/ai.opencode.desktop.plist`. It also created an empty `~/Documents/Default Project`, which **I removed (rmdir)** before the rule arrived. |
| Emdash | 17:12:21 | ~17:12:37 | `~/Library/Application Support/emdash`, `com.emdash.stable.plist` |
| Sculptor | 17:12:40 | ~17:12:58 | `~/.sculptor/`, `~/Library/Application Support/Sculptor`, `com.electron.sculptor.plist` |
| Nimbalyst | 17:13:06 | ~17:13:24 | `~/Library/Application Support/@nimbalyst`, `com.nimbalyst.electron.plist` |
| Factory | 17:13:26 | ~17:13:44 | `~/.factory/` (host.json, logs, bin/libsqlite3 dylib, cache, certs, state, telemetry), `~/Library/{Application Support,Logs}/Factory`, `com.electron.factory.plist` |
| Superset / Paradev | 17:13:48 | ~17:14:06 | At **17:13:48** its agent-setup wrote hooks into `~/.claude/settings.json`, `~/.codex/hooks.json`, `~/.cursor/hooks.json`, `~/.gemini/{settings.json,config/hooks.json}`, `~/.factory/settings.json`, `~/.grok/{config.toml,hooks/superset-notify.json}`, `~/.kimi-code/`, `~/.vibe/`, `~/.mastracode/`, `~/.config/{amp,devin,muse}/`, `~/.omp/agent/extensions/superset-hooks.ts` and `~/.pi/agent/extensions/superset-hooks.ts`. It added skills to `~/.claude/skills/superset/` and `~/.agents/{skills/superset-*,commands/superset}`, and created `~/.superset/`, `~/Library/{Application Support,Logs}/Superset` and `com.superset.desktop.plist`. The installer source is `paradev/src/packages/agent-setup/src/agent-wrappers-*.ts`. It merges only `hooks` and has its own remover functions. |

Notes on this log:
- **Shell rc files.** The `.zshrc` and `.bashrc` mtimes I saw were **17:15:16**, after Superset had been killed, and their only tool-added block is "otty shell integration". I did not check `.bash_profile`, and I could not attribute the 17:15:16 write to Superset. The parent is handling all cleanup.
- **Revert script.** I wrote `_tools/revert_superset.py` (a quarantine-and-strip revert) **but never ran it**, on the coordinator's instruction. Nothing under ~ was touched by it.
- **No further launches** were made after the instruction. Everything below is static.

---

## 1. Ranking by visible design quality

The ranking is judged from the shipped token systems, the component code, and the vendors' own product imagery (`site-*.png`).

| Rank | App | Score | Why |
|---|---|---|---|
| 1 | **Conductor** | 9 | One warm, hand-tuned palette across ~120 semantic tokens with dark, light and low-contrast-dark variants. It has a real signature: an animated 4×4 status matrix that echoes its dot-matrix logo. Every row state is encoded twice, as a matrix pattern and a 1.5px git-status stripe, never as a badge. The workspace sheet is recessed into the chrome with motion-driven caps. Fonts are SF Pro and Geist Mono with optical tracking per size. It has the most restraint per pixel of any app here. |
| 2 | **opencode desktop** | 8 | It has the best elevation system: `0.5px` rings plus two-layer shadows, with separate light and dark recipes. The 8px-inset, 10px-radius raised panel on a "deep" ground is the cleanest composition here. The titlebar tabs carry a 7px status dot, and permission requests dock under the composer. The pixel-font logotype is its signature. It loses a point because it is chat-first, with neutral grey plus one blue and little warmth. |
| 3 | **Paradev (Superset)** | 7 | It is the closest product to Axolotty: terminal-first, with agent presets, split panes and a sidebar of workspaces. Its warm palette (#151110) is near-identical to Conductor's. Pane focus is honest: a 2px `primary/15` ring only when split, and dimmed headers on inactive panes. It loses points for density stacking and some generic shadcn defaults. The product imagery leans on uppercase mono section labels. |
| 4 | Factory | 7 | It has a disciplined two-layer token system with warm "tungsten" neutrals, one safety-orange accent, near-square 2–4px corners, Geist, and 100ms ease-out hover. It is let down by two coexisting token generations and a web-app shell. Everything is behind login. |
| 5 | Emdash | 6 | Systematic Radix-like p3 neutrals, and the best shape-coded agent states (a diamond for waiting, a dot-grid for working). It is otherwise stock shadcn: a green primary and a 40px bar. |
| 6 | Sculptor | 5 | Stock Radix Themes with a monochrome grey accent and nothing of its own. |
| 7 | Nimbalyst | 3 | The stock Tailwind gray-50 and blue-500 palette and a cluttered onboarding modal. |

Deep dives below cover Conductor, opencode and Paradev. Factory, Emdash, Sculptor and Nimbalyst are summarised in §5 from a parallel static pass.

---

## 2. Conductor 0.92.0: the bar to beat

### 2.1 Tokens

Source: `conductor/pretty/index-C0NH49rF.css`. Light is `:root, .light` at L18247–18363 and dark is `.dark` at L18364–18500. The anti-flash colours are in `conductor/extracted/index.html` (`--background: hsl(24 10% 7%)`).

| Role | Token | Dark | Light |
|---|---|---|---|
| Content sheet (canvas) | `--background` | **#141110** | #fff |
| Sheet surface (right panel, terminals) | `--sheet-surface` | #1c1917 | #fdfcfc |
| Chrome / sidebar ground | `--sidebar-background` | **#211e1c** | #fafaf9 |
| Card / popover | `--card`, `--popover` | #2c2826 | #fff |
| Muted (composer fill) | `--muted` / `--composer-background` | #211e1c | #fafaf9 / #fafaf980 |
| Border | `--border` | #ffffff1a (white 10 %) | #eae8e6 |
| Separator (sheet edge) | `--separator` | #2c2826 | #eae8e6 |
| Sidebar border | `--sidebar-border` | #ffffff1a | #14100f1a |
| Text primary | `--foreground` | #eae8e6 | #2c2826 |
| Text, sidebar | `--sidebar-foreground` | #ffffffe6 (90 %) | #14100fb3 (70 %) |
| Text, sidebar muted | `--sidebar-muted-foreground` | #fff9 (60 %) | #14100f99 |
| Text muted | `--muted-foreground` | #a5a09c | #8e8885 |
| Text faint | `--faint` | #766f6b | #a5a09c |
| Sidebar hover / selected plate | `--sidebar-accent` | #ffffff0d (white 5 %) | #14100f0d |
| Primary button | `--primary` / `-foreground` | #f3f2f1 on #2c2826 | #413030 on #f3f2f1 |
| Brand "copper" (unread, special, done) | `--unread`, `--special`, `--border-highlight` | #cca694 | #a4847f / #cca694 |
| Highlight (needs-you tint) | `--highlight` / `-foreground` | #2a1e1d / #f3ece7 | #faf7f5 / #594545 |
| Success / positive | `--success`, `--git-green` | #4ade80 | #16a249 |
| Destructive | `--destructive` | #f87272 | #dc2828 |
| In progress (merge queue) | `--status-in-progress` | #ffdc2e | #e0bb00 |
| Checks pending | `--checks-pending` | #d29922 | #9a6700 |
| Info / link blue | `--info`, `--sidebar-blue` | #3c83f6 / #61a6fa | #0da2e7 / #2463eb |
| Diff add / remove bg | `--git-new-line-bg`, `--git-removed-line-bg` | oklab(72.1% −.169 .102 / .1), oklab(58.1% .208 .116 / .1) | same |
| Terminal ANSI 0–15 | `--terminal-*` | e.g. black #47423e, red #f87272, green #4ade80, yellow #ffea80, blue #61a6fa, magenta #e852ff, cyan #3ed8ef | L18326–18341 |

**Low-contrast dark** (`html.dark.low-contrast-dark`, L18083): bg #1f1c1a, sheet #24211e, sidebar #292623, fg #c5c2be.

**Sheet-canvas recipes** (L18059–18081): `--muted = mix(fg 5 %, sidebar-bg)`, `--accent = mix(fg 8 %, sidebar-bg)`.

Every neutral sits on the same warm hue (≈24–30°, low chroma). Nothing is pure grey.

**Scales** (theme layer L107–300 and L582–600):

| Scale | Values |
|---|---|
| Fonts | `--font-sans: "SF Pro", system-ui` (L583); `--font-mono: "Geist Mono"`; `kbd` in Geist Mono 12 |
| Type | 3xs 10/12 +0.04em; 2xs 11/14 +0.02em; xs 12/16 +0.01em; sm 14/20 0 (body); md 15/22 −0.005em; base 16/24 −0.01em; lg 18 −0.016em; xl 20 −0.02em; 2xl 24 −0.024em. That is optical tracking per size. Weights include **450**. |
| Spacing | Tailwind 4px base |
| Radius | `--radius: .5rem` (8, L18362). md = 6, xl 12, 2xl 16; sidebar plates `rounded-md` = 6 |
| Shadows | Almost none. `drop-shadow-xs 0 1px 1px #0000000d`, sm `0 1px 2px #00000026`. Depth comes from tone steps, not shadows. |
| Motion | default 150ms `cubic-bezier(.4,0,.2,1)`; composer resize 200ms `cubic-bezier(.25,1,.5,1)` (L18661); command dialog in translateY(−12px)→0 (L18120); loadout 220ms `cubic-bezier(.23,1,.32,1)`; pressed tabs `active:scale-[0.97]` over 150ms ease-out (`renderApp-BBRm1hiD.js:3263`) |
| Scrollbar | 8px, thumb fg 20 %, radius 5 |

### 2.2 Main-window composition

The constants come from `renderApp-BBRm1hiD.js`:
- **Sheet layout:** `ZCs` / `PQ` at :1594, the top bar `Lle` at :1594, and the panel group at :3187–3190.
- **Sidebar width:** `b9e=256` at `main-DkBMmrtL.js:122`, with `AIa=192` and `IIa=480` at `renderApp:3190`.

```
 sidebar-background #211e1c (chrome: sidebar + top bar + right panel)
┌────────────────────────┬─────────────────────────────────────────┬──────────────────────────┐
│ ●●●  [⊟] ← →           │ h-10 (40) top bar, drag region          │ #8376 ↗ │▲ Ready to merge│Merge│
│ h-8 pt-2 header        │ tabs: session · session · + ···  ⟳ 🔗 ◫ │──────────────────────────│
│────────────────────────┤┌───────────────────────────────────────┐│ All files│Changes 74│Checks │
│ Home / Create / Search ││ workspace SHEET  bg #141110           ││ (h-7 px-2.5 text-xs pills)│
│ (nav rows px-1.5 py-1.5││  1px separator on top and sides,      ││ file rows:                │
│  icon 12 in 16 slot)   ││  square corners, no shadow            ││ path… name.tsx +53 −46 ▣  │
│────────────────────────┤│                                       ││                           │
│ Pinned                 ││  chat transcript                      ││ right panel 35 % (min 30) │
│ My workspaces  12/600  ││                                       ││ = .sheet-canvas, bg       │
│ ▏▦ Landing page copy 10h│  ┌ composer bg-muted r12 ───────────┐ ││ #1c1917 for terminals     │
│   row: py-2 pl-5 r6    ││  │ min-h 152, pad 16/16/12/18       │ ││                           │
│ width 256 (192–480)    ││  └──────────────────────────────────┘ ││                           │
└────────────────────────┴┴───────────────────────────────────────┴┴──────────────────────────┘
          main-content 70 % (min 30) │ right-panel 35 % (min 30); ratios from react-resizable-panels
```

- **Recessed sheet, not a floating card.** The content area (`PQ`, `data-workspace-sheet`) is the *darker* surface (#141110) set into a lighter chrome (#211e1c).
  - Its edge is a **1px `--separator` (#2c2826) on the top and on the sides**: `strip` with `border-t` inset 11px, plus `cap-left` / `cap-right` at `w-3` with `border-l` / `border-r`.
  - It has **no radius and no shadow**.
  - The margin is `ml-3` (12) only while the left sidebar is collapsed (`group-data-[state=expanded]/sidebar-wrapper:ml-0`), and `mr-3` only while the right panel is closed (`ZCs`, :1594).
  - In light mode the same structure is a white sheet on #fafaf9. The caps exist so the sheet's edges can animate independently when panels open (`data-sheet-motion-part`, a spring at `Qai=1e3/120`, :3190).
- **Top bar.** `h-10` (40), `sheet-canvas`, `pl-2` (or clearing the traffic lights with `calc(2.5rem + 66px + 4px)` when the sidebar is closed), `pr-2` to `pr-4`. It is a drag region.
  - `--traffic-lights-clearance: 66px` (L587).
  - The sidebar header row is `h-8 pt-2 pl-[calc(1rem+66px+4px)]` (:3190).
- **Sidebar.**
  - `border-r` in `sidebar-border` over `bg-sidebar-background/60`. It is translucent when `html.sidebar-transparency` is on, giving native vibrancy through `.sidebar-vibrancy-passthrough` (L18044).
  - Width 256, min 192, max 480. Resized via a handle and persisted as `left_panel_width`.
- **Section header** ("My workspaces"): `text-xs font-semibold text-sidebar-muted-foreground/70`. The chevron is `size-3` and visible only on hover (:3190, `function Rtr`).
- **Nav rows** (Home, Create, Search): `flex items-center px-1.5 py-1.5 gap-2 rounded-md hover:bg-sidebar-accent`.
  - Icon slot `size-4` with a 12px glyph in muted ink and label in muted ink.
  - The shortcut appears only on hover (`opacity-0 group-hover:opacity-100`), in a block `px-1.5 pt-1.5 pb-1.5 gap-0.5 border-b` (:3189).

### 2.3 Workspace row anatomy (`otr`, `renderApp-BBRm1hiD.js:3190`)

```
 ▏ ▦  Landing page copy        ◉◉ 10h
 │ │  └ 13–14 px, weight 450, muted 60 %; unread → 600 + 90 % ink; name "scrambles" in on change
 │ └ 16×16 leading visual (mt-0.5 mr-0.5): status matrix, or the repo icon
 └ git stripe: absolute left-0, h-[18px] w-[1.5px] rounded-full, colour = git state (RWt, :3187)
```

**Row container:**
- Classes: `block group relative rounded-md py-2 pr-1.5 text-sidebar-foreground`.
- Indent: `pl-5` (20) by default. In a section it is `ml-[13px] pl-5`, pinned rows use `pl-3`, and flush rows `pl-1.5`.
- Selected: `bg-sidebar-accent text-sidebar-accent-foreground` (white 5 %). Hover: `hover:bg-sidebar-accent`.
- Inner line: `flex items-center gap-1.5 h-5`, which makes the row 20 + 16 = **36px**.

**Name** (`r7a`): `font-450 text-sidebar-muted-foreground` at rest, becoming `font-semibold text-sidebar-accent-foreground` when unread. The **title is muted until the workspace has something new**; this is how Conductor shows "unread" without a dot.

**Name animation** (`s7a`): a text-scramble with `speed .8, scramble 3, range [97,122]` (a–z). Renames visibly decode in place.

**Trailing** (`l7a`):
- Relative time in `text-3xs` (10px) at `sidebar-muted-foreground/70`.
- Diff stats `+N −M` in `text-2xs`.
- Avatars (max 3, `-space-x-1`), a "Draft" pill, and a port-forward icon in `sidebar-blue`.

**Git stripe colours** (`IWt`, :3187):

| State | Colour |
|---|---|
| failed / checks-failing | destructive |
| merged | purple-500 |
| merge-queued | status-in-progress |
| ready-to-merge | git-green |
| merge-conflict | highlight-muted |
| checks-pending | checks-pending, with `animate-slow-pulse` (2.4s ease-in-out) |

**Row tone in the All-Workspaces table** (`PSa` / `KP`, :1594): the whole row gets a wash.

| State | Wash | Ink |
|---|---|---|
| in_sync | `bg-positive-muted` | success |
| queued | `bg-status-in-progress/15` | status-in-progress |
| out_of_sync | `bg-highlight` (#2a1e1d) | highlight-foreground |
| merged | `bg-purple-400/15` | purple |

### 2.4 Signature: the workspace status matrix (`wSa` / `OWt`, :3187; CSS L18500–18640)

**Geometry:**
- A 16×16 SVG holding a **4×4 grid of 1.5px squares on a 3px pitch**, starting at 2.5 (`$z=1.5`, `kai=3`, `WN=2.5`, `Eai=10.5`).
- A 7×7 variant at 1.5px pitch is used for the "merged" checkerboard.
- Cells are `bg-current` (or `bg-foreground`) and default to opacity 0.

**States** map to choreography:

| State | Animation |
|---|---|
| working | `workspace-matrix-pulse`: each cell has its own duration and phase, `2π/r` s where `r = (1.25 + ((n·29+7)%17)/17)·1`; a 13-stop opacity curve 0.333→1→0 (L18551). It reads as live "thinking". |
| waiting (background tasks) | `workspace-matrix-wave-opacity` 1.9635s (= π/1.6) linear, phase by column (L18607) |
| setting-up | the same wave at 1.5708s (= π/2), only on the 12 perimeter cells (`mSa`) |
| checks-pending | `workspace-matrix-sweep` |
| automation run | `workspace-matrix-twinkle`, plus a 7-step `steps(7)` arrow marching across |
| needs attention | an overlay path that alternates opacity 1→0.1 over 1s (`workspace-matrix-attention`) |
| failed / checks-failing | a fixed error pattern in `text-destructive` |
| merged | a checkerboard 7×7 pattern |

- **Reduced motion:** every animation stops. A designated subset of cells is shown statically: `data-reduced-highlight`, `data-waiting-static` (row 2), `data-setup-corner` (the four corners).
- **Hover:** the tooltip lists the states joined by "; " (`ser`), e.g. "Working; Ready to merge; Unread".

**Status vocabulary** (`rSa`, `wMe`, :3187):

| Status | Tone |
|---|---|
| unstarted, setting-up, working, cancelling, waiting, merge-queued, draft-pr, checks-pending, open-pr, local, branch, needs-user-input | muted |
| needs-plan-response, needs-user-permission ("Needs permission"), merge-conflict | **warning** |
| failed, checks-failing | negative |
| ready-to-merge | positive |
| merged | merged (purple) |

### 2.5 Agent surfaces

- **Session tabs** (top bar): `h-8 rounded-none text-muted-foreground` with `data-[active]:border-b-2 border-b-highlight-muted`, a **2px copper underline** (:1709).
- **Right-panel tabs** (All files, Changes, Checks, Review): `h-7 rounded-md px-2.5 text-xs font-[450]`, active `!bg-accent`, press `scale(.97)` over 150ms (:3263).
- **Header rows:** `px-[18px] py-2` with a label in `text-xs font-medium text-muted-foreground` (:1594).
- **PR / CI header** (:1594): a state machine produces `{title, state, action}`:
  - States: `in_sync`, `out_of_sync`, `loading`, `queued`, `merged`.
  - Titles include "Ready to merge", "N checks pending…", "Unable to merge", "No PR open" and "PR is in draft".
  - Actions are ghost `xs` buttons in muted ink: "Merge", "Create PR".
  - The tone comes from `KP` (see the table in §2.3).
- **Diff:** `diffs-container` uses `--diffs-dark-bg: var(--background)`. Added and removed lines are tinted at 10 % (oklab), with a 60 % border and a 20 % highlight. File rows read `path… name.tsx +53 −46` in the git colours.
- **Composer** (`NVt`, :2459):
  - Base: `relative bg-muted rounded-lg border`. The outer wrapper is `rounded-xl`, so the composer is 12px with an 8px inner.
  - Full size: `min-h-38` (152) with padding `pt-4 pr-4 pb-3 pl-4.5`. Minimised: `px-4 py-3`.
  - Primary actions sit absolute at `h-7` with gap 6. Mode controls sit at `left-[7px]`.
  - ProseMirror `min-height: 3rem`, with a 200ms min-height transition (L18648).
  - **Plan mode** tints the fill to `mix(plan-border 12 %, muted)`.
  - **"Ultracode"** draws a **rainbow gradient border** via the padding-box / border-box trick (`$ca`: red→orange→yellow→green→cyan→fuchsia).
- **Approval / waiting:** a banner **attached to the top of the composer** (`jYi`, :2459): `rounded-t-lg border px-4 py-2`.
  - A warning uses `background: var(--warning)` (#413030 dark) with `border-warning-border`, transitioning over 200ms.
  - The sidebar row's matrix switches to the attention overlay, and its status reads "Needs permission".
  - **The question lives next to where you answer it**, not in a modal.
- **Empty and new workspace:** the sign-in fallback card is `max-w-xl rounded-xl border p-6 gap-4`, with an icon tile `size-10 rounded-lg border bg-muted`. Onboarding uses video tiles (`ConductorOnboarding1–3.mp4`).

---

## 3. opencode desktop 2.2.5: the cleanest frame

### 3.1 Tokens

There are two layers: legacy `--background-*` / `--surface-*` / `--text-*` (`opencode/src/packages/ui/src/styles/theme.css`) and v2 (`…/styles/tokens/theme.css` and `colors.css`). v2 drives the shell.

| Role | v2 token | Dark | Light | Source |
|---|---|---|---|---|
| Deep ground (window, titlebar) | `--v2-background-bg-deep` | grey-1100 **#161616** | grey-100 #fafafa | tokens/theme.css L152 / L7 |
| Panel (raised sheet) | `--v2-background-bg-base` | grey-1000 **#242424** | grey-50 #fff | L151 / L6 |
| Layers 01 / 02 / 03 | `bg-layer-0x` | #2e2e2e / #3a3a3a / #5c5c5c | #fafafa / #f2f2f2 / #eee | L153–155 |
| Text base / muted / faint | `text-text-*` | grey-200 #f2f2f2 / grey-500 #aeaeae / grey-600 #808080 | grey-1100 #161616 / #5c5c5c / #808080 | L162–164 / L20–22 |
| Border muted / base / strong | `border-border-*` | white 8 / 10 / 20 % | black 8 / 10 / 20 % | L180–182 / L40–42 |
| Focus | `border-border-focus` | blue-500 #7698fd | same | L184 |
| Accent (dot, primary) | `bg-accent` | blue-600 #3b5cf6 | same | L159 |
| Warning / danger / success / info fg | `state-fg-*` | yellow-500 / red-500 / green-500 / blue-500 | | L195–206 |
| Agent modes | `agent-{plan,build,explore}-*` | pink-400 / blue-400 / yellow-400 solids; border at 50 %, bg at 10 % | | L208–216 |
| Hover / pressed overlay | `overlay-simple-overlay-*` | white 6 / 10 % | black 4 / 8 % | L186–187 / L46–47 |
| Legacy text strong / base / weak / weaker | `--text-*` | white .936 / .618 / .422 / .284 | #171717 / #6f6f6f / #8f8f8f / #c7c7c7 | theme.css L436–439 / L165–168 |

**Elevation**, the best recipe in the set (tokens/theme.css L106–129 light, L220–257 dark):

| Level | Light | Dark |
|---|---|---|
| raised | `0 2 4 black4, 0 1 2 −1 black8, 0 0 0 .5 black12` | `0 2 4 black30, 0 1 2 black30, 0 0 0 .5 white16, 0 −.5 0 white6` (a top rim light) |
| floating | `0 8 16 black4, 0 4 8 black8, 0 0 0 .5 black12` | the same with black30 / black30, white16 ring, white6 top rim |
| overlay | `0 16 32 …, 0 8 16 …, ring .5` | the same pattern |

**Scales:**

| Scale | Values (theme.css L1–92) |
|---|---|
| Type | Inter (sans) and IBM Plex Mono. Sizes 13 / 14 / 16 / 20; weights 400 / 500 / **670** (bold); line heights 130 / 150 / 180 %; tracking tight −0.16, tightest −0.32. Titlebar tabs use **13px at weight 530** active and 440 inactive (`app/src/shell/titlebar/titlebar.css` ~L100). |
| Radius | xs 2, sm 4, md 6, lg 8, xl 10. The panel is **10**, the composer and permission dock 12. |
| Motion | the panel spring `{duration .3, bounce 0}`, scaled by √(distance) (`app/src/shell/panel-motion.ts:20,32`); fade-in 150ms ease-out (:370) |

### 3.2 Composition

The values come from:
- `app/src/shell/shell.tsx:205–262` (the shell);
- `app/src/session/session-frame.tsx:20` (the panel);
- `app/src/shell/titlebar/titlebar.css:70–81` (the titlebar);
- `app/src/shell/state/layout.tsx:29` and `shell.tsx:56` (widths).

```
 bg-deep #161616 (dark) / #fafafa (light) = window + titlebar
┌──────────────────────────────────────────────────────────────────────────┐
│ ●●●  ⊞ ⌕  [✎ Session ●]  [Session]  +                 h 44 titlebar      │
│ ┌──────────────────────────────────────────────────────────────────────┐ │ ← 8px inset
│ │ PANEL bg-base #242424 / #fff, radius 10, elevation-raised            │ │   (--shell-inline-inset)
│ │ (0.5px ring + 2-layer shadow + dark-mode top rim)                    │ │
│ │                                                                      │ │
│ │          ┌ composer r12 bg-base ring .5 ────────────────┐            │ │
│ │          │ Ask anything, / for commands, @ for context  │            │ │
│ │          │ +  Model ⌄                                ⬆ │            │ │
│ │          └──────────────────────────────────────────────┘            │ │
│ └──────────────────────────────────────────────────────────────────────┘ │ ← 8px bottom inset
└──────────────────────────────────────────────────────────────────────────┘
 vertical-tabs mode: tab rail 276 wide on bg-deep at left; session sidebar default 344
```

- **Panel:** inset 8 / 8 / 8 (`--shell-inline-inset`, `--shell-top-inset`, `--shell-bottom-inset`). The inset strip above the panel is a window-drag region.
- **Tabs:**
  - The tab background is the deep ground; hover and active use overlay gradients.
  - The status lives at the close-button position: a **7px dot**, accent blue for running and `state-fg-warning` for attention. It swaps instantly with the close button on hover (`tab-nav.css:12–40`).
  - Vertical tabs with a project are 45 tall: a 16px avatar column, gap 6, 13px text, and two compact lines.
- **Traffic lights** are centred on the session-header centre line, 32px from the top (`sidebar-toggle.tsx:35–41`).

### 3.3 Agent surfaces

- **Permission dock** (`app/src/session/requests/session-permission-dock.tsx`; `session-ui/src/components/message-part.css:1378–1450`):
  - It docks **above the composer, in the composer's lane**: radius **12**, `elevation-raised`, `bg-base` (dark `bg-layer-01`).
  - Body padding is `12 12 0` with gap 16. Rows are a `20px 1fr` grid with a gap of 8. The warning icon uses `icon-warning-base`.
  - The title is 14 medium and the hint 14 regular in muted ink. Patterns are `code` with gap 6.
  - Footer buttons, in order: **Deny** (ghost), **Allow always** (neutral), **Allow once** (submit, the primary).
- **Composer:**
  - `group/composer relative w-full overflow-clip rounded-xl bg-v2-background-bg-base`.
  - Trays (queue, limits) tuck *under* it with `-mb-3 rounded-xl` and an inset 0.5px ring (`session/composer/queue-panel.tsx`, `go-limit-tray.tsx`).
- **User bubble:** `bg-layer-02`, padding 8×12, radius 10. Consecutive messages reduce the joined corners by 6 (`message-part.css:177–183`).
- **Empty / new session:**
  - A centred pixel-font **"opencode" logotype** at 8 % ink, the composer below it, then the project chip and path (`opencode-launch.png`).
  - The new-session view is itself a `rounded-[10px] bg-base shadow-raised` panel (`new-session/view.tsx`).

**Signature:** the deep-ground and raised-panel frame with the 0.5px ring, plus the pixel logotype.

---

## 4. Paradev (Superset) 2.0.3: the terminal-first sibling

### 4.1 Tokens

Source: `paradev/src/apps/desktop/src/renderer/globals.css`, dark L24–73 and light L76–122. A JS theme store can override them; these are the shipped defaults.

| Role | Token | Dark | Light |
|---|---|---|---|
| Canvas (terminal / content) | `--background` | **#151110** | #f9f9fa |
| Sidebar | `--sidebar` | **#1a1716** | #ececec |
| Tertiary / active | `--tertiary`, `--tertiary-active` | #1a1716 / #252220 | oklch(.95 .003 40) / oklch(.9 .003 40) |
| Card / popover | `--card` | #201e1c | white |
| Muted / accent / border | `--muted`, `--accent`, `--border` | #2a2827 | oklch(.97) / oklch(.922) |
| Text / muted text | `--foreground`, `--muted-foreground` | #eae8e6 / #a8a5a3 | oklch(.145) / #4a4847 |
| Hover / selected fill | `--fill-hover`, `--fill-selected` | fg **7 % / 10 %** (oklab mix) | fg 4 % / 6 % |
| Accent (sidebar primary, highlight) | `--sidebar-primary`, `--highlight` | **#e07850** (terracotta) | oklch(.646 .222 41) |
| Destructive / warning / success | | #cc4444 / #e5c07b / #5fb37f | |
| Ring | `--ring` | #3a3837 | oklch(.708) |

**Scales:**

| Scale | Values |
|---|---|
| Radius | `--radius .625rem` (10). sm 6, md 8, lg 10, xl 14 (L57 and L151–154). |
| Fonts | UI is the Tailwind system sans (no override). The terminal is **JetBrains Mono → Nerd Font symbols → Menlo, 14px, line-height 1, ligatures on, minimum contrast 1** (`renderer/lib/terminal/appearance/index.ts:92–110`). |
| Motion | `packages/ui/src/motion.css`: shimmer 2s linear, `thinking-pulse` 1.8s (opacity .35↔.9), `block-fade` 320ms. Pane focus and header transitions are 150ms. |
| Scrollbar | 12px, thumb `rgb(63 63 70/.5)` |

### 4.2 Composition

The values come from `routes/_authenticated/_dashboard/layout.tsx:185–260`, `stores/workspace-sidebar-state.ts:4–11` and `stores/sidebar-state.ts:14–16`.

```
 full-bleed, no inset card
┌──────────────────────┬──────────────────────────────────────────────────┬───────────────┐
│ ●●●                  │ tab bar h-12 (48) bg-muted/45, inset bottom 1px  │ Changes/Files │
│ sidebar #1a1716      │ ╭claude╮ codex  cursor  opencode  + ⌄            │ right sidebar │
│ 280 (225–400,        │─┘      └────────────────────────────────────────│ 250 (200–500) │
│  rail 52, snaps <120)│ presets bar h-10 (agent icons)                    │ +393 −42 · 5  │
│ ─ DESKTOP 5 ─        │┌ pane header h-7 bg-muted/30 ─┐┌ pane ─────────┐│ files → main  │
│ ▪ new workspace  …   ││ terminal (xterm, JBMono 14)  ││ inactive:     ││               │
│ • fix crash  +46 −1  ││ active+split: 2px            ││ header 60 %   ││               │
│ row h-7 mx-2 r8 13px ││ primary/15 ring              ││ opacity       ││               │
│                      │└──────────────────────────────┘└───────────────┘│               │
└──────────────────────┴──────────────────────────────────────────────────┴───────────────┘
 panes: min 260 × 160 (packages/panes/…/Tab/constants.ts:1)
```

- **Workspace sidebar:** default 280, min 225, max 400. It collapses to a 52px rail, snapping below 120. The right "Changes / Files" sidebar is 250 (200–500).
- **Row** (`DashboardSidebarExpandedWorkspaceRow.tsx:190–228, 342–445`):
  - Container `relative mx-2 rounded-md text-sm transition-colors`, selected or active `bg-fill-selected`, hover `bg-fill-hover`.
  - Inner `h-7` (28) with `pr-2`. Indent is `pl-2` at the top level, `pl-6` nested and `pl-10` grouped.
  - Title `text-[13px] leading-tight`: `text-foreground` when active, `text-foreground/80` at rest.
  - Trailing `h-5 gap-2` holds the host glyph. On hover it swaps to a `font-mono text-[10px] tabular-nums` shortcut and `size-5` archive/close buttons.
- **Lead indicator** (`DashboardSidebarWorkspaceLeadIndicator.tsx`, `StatusIndicator.tsx:8–36`) is a **6px dot** (`size-1.5`):

  | State | Indicator |
  |---|---|
  | permission | yellow-500 with an `animate-ping` halo |
  | failed | red-500 with a ping |
  | working | amber-500, static |
  | review | green-500, static |
  | setting up | `WaveSpinner` |
  | PR state | PR icon |
  | idle | `muted-foreground/50` dot |

- **WaveSpinner** (`packages/ui/src/atoms/WaveSpinner/WaveSpinner.tsx`): **a 3×3 grid of 3px cells, gap 1, 11px overall, radius .5**. A diagonal wave at 50ms per frame over 24 frames (1.2s), with a 3-frame fade and a 2-frame diagonal delay.

### 4.3 Agent surfaces

- **Tab bar** (`packages/panes/…/TabBar/TabBar.tsx:259`; `TabItem.tsx:129–132`): `h-12 bg-muted/45 dark:bg-muted/35 shadow-[inset_0_-1px_0_var(--border)]`. These are Chrome-style tabs:
  - Active: `rounded-t-md border border-border/70 border-b-transparent bg-background` (it merges into the pane).
  - Inactive: `text-muted-foreground/70`, hover `bg-muted/40`.
  - Each agent tab carries the vendor mark (claude, codex, cursor, opencode).
- **Presets bar** (`V2PresetsBar.tsx:233`): `h-10 bg-background px-2 gap-1.5`. One-click agent launchers with icons, plus a settings icon at `size-6`.
- **Pane** (`Pane.tsx:317–320`; `PaneHeader.tsx:66–69`):
  - `border-2`, set to `border-primary/15` **only when it is the active pane inside a split** (otherwise transparent), over 150ms.
  - Header `h-7 bg-muted/30 border-b border-border/20`. **Inactive headers sit at `opacity-60`**, returning to 1 on hover or focus.
  - Drop zones: `rounded-sm border-2 border-primary/70 bg-primary/10`.
- **Approval:** agents run in real terminals, so the permission prompt is the agent's own TUI. The app's job is to signal it:
  - a yellow pinging dot on the row and pane;
  - an agent-finished card in the corner ("claude finished · worked for 7s", "+46 −1", Preview), from the product imagery;
  - hooks installed into each CLI feed state to `~/.superset/hooks/notify.sh`.
- **Diff:** stats such as "+393 −42 · 5 files → main" in the right panel, in green and red mono.
- **Empty state** (`WorkspaceEmptyState.tsx:110–135`): centred `max-w-xl`, the logo at `h-8` with `mb-7`, then an action list `max-w-md gap-0.5`, then a GitHub star pill.

**Signature:** the warm near-black terminal canvas with terracotta #e07850, Chrome-style agent tabs carrying vendor marks, and the 3×3 wave spinner.

---

## 5. Secondary apps (static pass; citations are byte offsets in the bundles)

### Factory 1.1.0

Bundles: `factory/extracted/.vite/renderer/main_window/assets/index-Ck6ZClam.css` and `index-CnTEWDNp.js`.

**Tokens:**

| Role | Dark | Light |
|---|---|---|
| Canvas | `--surface-1` #161413, v2 page #060505 | #f2f0f0 |
| Sidebar | surface-2 #1d1b1a | #e4e2e1 |
| v2 selected | #26211f | – |
| Text, v2 | #fdfcfb / #b5ada7 / #80756f | – |
| Accent | **#ff5a00** (dim #210b00) | same |

- **Scales:**
  - Radius v2: control **2**, surface **4**.
  - Spacing: a 2px base. Control heights 24 / 28 / 32 / 36; a row is 40.
  - Type: **Geist** and Geist Mono. Sizes 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 56; weights 300, 400, 500 only.
- **Motion:** 180ms ease-out; panels 220ms `cubic-bezier(.16,1,.3,1)`; row hover `background-color 100ms ease-out`, `none` when selected (JS @7764506).
- **Composition:** header 40, traffic-light inset 68, chat column ≤768, side panel 280. Full-bleed with tonal steps and 1px borders.
- **Sidebar row:** padding 8, gap 8, radius 4.
- **Permission flow:** `permissionRequested` / `permissionResolved` / `permissionTimeout` events, with an inline option list that keyboard indices can select.

### Emdash 1.2.10

Source: `emdash/src/packages/theme/src/__generated__/semantic.css`.

**Tokens:**

| Role | Dark | Light |
|---|---|---|
| bg | ≈#111 | ≈#fcfcfc |
| Sidebar | ≈#181818 | ≈#f1f1f1 |
| Row hover / active | #282828 / #303030 | – |

- **Scales:** Inter Variable and JetBrains Mono Variable; sizes 10–24 with base 14; radius 6.8 (0.85-scaled shadcn).
- **Composition** (`apps/emdash-desktop/src/renderer/lib/layout/workspace-layout.tsx:5–19`): titlebar `h-10` with `border-b`; sidebar 20 % (min 200, max 30 %).
- **Sidebar row** (`…/sidebar/sidebar-primitives.tsx:84`): `h-8 px-3 rounded-lg`, 13px.
- **Agent glyphs** (`packages/ui/src/react/components/agent-status/agent-status.tsx:84–135`):

  | State | Glyph |
  |---|---|
  | working | 3×3 dot-grid shimmer over 1200ms |
  | awaiting input | 45° amber diamond, 12px |
  | completed | green ring |
  | error | red square with a dot |

### Sculptor 0.49.0

Bundles: `sculptor/extracted/.vite/build/renderer/assets/main-xDrMfjoX.css` and `main-BIQJ5tyw.js`.

- **Theme:** Radix Themes with a grey accent, translucent panels and radius "medium".
- **Tokens:** gray-1 #111, gray-2 #191919 (sidebar), gray-12 #eee.
- **Motion:** 100 / 200 / 300 / 500ms with `cubic-bezier(.16,1,.3,1)`.
- **Layout:** titlebar 40, sidebar 240. Compact rows are min 28 tall with radius 4; active is `accent-a3`.

### Nimbalyst 0.81.7

Bundles: `nimbalyst/extracted/out/renderer/assets/index-D0rwru8L.css` and `index-BXnfbVdN.js`.

- **Tokens:** stock Tailwind: #fff / #f9fafb, text #111827 / #6b7280, primary #3b82f6. Dark values are computed at runtime and are not recoverable statically.
- **Layout:** sidebar 250, AI chat 350.
- **Session-state vocabulary** (a 14px Material Symbol in a 20px slot): waiting-for-input and pending-prompt pulse in warning colour; processing spins in primary; unread is an 8px primary dot.

---

## 6. Cross-app synthesis

1. **The sidebar is lighter than the content in dark mode, in five of seven apps.**

   | App | Sidebar | Content |
   |---|---|---|
   | Conductor | #211e1c | #141110 |
   | Paradev | #1a1716 | #151110 |
   | Factory | #1d1b1a | #161413 |
   | Emdash | #181818 | #111 |
   | Sculptor | #191919 | #111 |

   opencode inverts the axis by making the *panel* the lighter, raised layer (#242424 on #161616). Either way, **the working surface is the one with the strongest contrast to its neighbour, and chrome is a step toward mid-grey**. Axolotty does the opposite: its sidebar is the background mixed with black at 0.24, darker than the terminal. That is the single biggest reason it reads as "a terminal with a list" rather than "an app".

2. **Warm neutrals win at the top.**
   - Conductor (#141110, hue ≈24°), Paradev (#151110) and Factory (#161413, "tungsten") all use warm brown-blacks with one accent: copper #cca694, terracotta #e07850 and orange #ff5a00 respectively.
   - The cool or neutral apps (Emdash, Sculptor, Nimbalyst) rank lower.

3. **Depth comes from a tone step plus a 1px or 0.5px edge, almost never from a drop shadow.**
   - Conductor: a 1px `--separator` on a recessed sheet, with zero shadow.
   - opencode: a 0.5px ring plus two soft shadows, plus a −0.5px top rim light in dark mode.
   - Paradev: an inset 1px box-shadow under the tab bar.

4. **Working is drawn as a tiny dot-matrix, not as a spinner arc.**

   | App | Working indicator |
   |---|---|
   | Conductor | 4×4 matrix of 1.5px cells on a 3px pitch, per-cell phase |
   | Paradev | 3×3 grid of 3px cells, gap 1, diagonal wave, 50ms × 24 frames |
   | Emdash | 3×3 dot grid, 1.2s |

   The pattern is independent of colour, scales cleanly at 1x, and reads as "alive" without rotating.

5. **"Needs you" is the only state that earns warm colour plus motion.**
   - Conductor: needs-user-permission, needs-plan-response and merge-conflict are **warning**; everything else is muted.
   - Paradev: only permission and failed **ping**; working is a static amber dot.
   - opencode: a warning dot on the tab.
   - Working is never the loudest thing on screen.

6. **The rest title is muted, and full ink means news.**
   - Conductor: rest at 60 % white and weight 450; unread at 90 % white and weight 600.
   - Paradev: rest at 80 %, active at 100 %.
   - Unread is carried by weight and ink, not by a dot.

7. **Row metrics converge on 28–36 tall, inset 8, radius 6–8 and a 16px leading slot.**

   | App | Row height | Inset / indent | Radius | Leading slot | Selected fill |
   |---|---|---|---|---|---|
   | Conductor | 36 (py-2 + h-5) | pl-5 | 6 | 16 | white 5 % |
   | Paradev | 28 (h-7) | mx-2 | 8 | 16 (6px dot) | fg 10 % (hover 7 %) |
   | Emdash | 32 | – | 8 | – | – |
   | Sculptor | 28 | – | 4 | – | – |
   | Factory | 40 | – | 4 | – | – |

8. **Top bar: 40 to 48 tall.**
   - 40: Conductor, Factory, Emdash, Sculptor.
   - 44: the opencode titlebar.
   - 48: the Paradev tab bar.
   - The traffic-light clearance is 66 (Conductor) to 68 (Factory).

9. **Approval lives in the composer lane.**
   - Conductor attaches a warning banner to the top of the composer (`rounded-t-lg`, `--warning` fill).
   - opencode docks a 12px-radius raised card above the composer with **Deny / Allow always / Allow once**.
   - Terminal-first apps (Paradev, Emdash) leave the prompt in the TUI and only signal it.

10. **Focus in splits is a whisper.**
    - Paradev: a 2px `primary/15` ring, only when split; inactive pane headers at 60 % opacity.
    - Conductor: no pane rings at all.

11. **Every premium app has one recognisable, functional motif.**

    | App | Motif |
    |---|---|
    | Conductor | the status matrix, matching its logo |
    | opencode | the pixel logotype and raised panel |
    | Paradev | vendor-marked agent tabs |
    | Factory | the orange tungsten |

    Axolotty currently has none.

---

## 7. Exact implications for Axolotty

Each item maps to a file in `Sources/AxMacUI`, and every value is copied from the evidence above.

### 7.1 Flip the sidebar tone and recess the terminal

Highest impact; this changes principle 2 of `design-system.md`.

**Dark sidebar ground.**
- Change from "bg mixed with black 0.24" to **bg mixed toward fg at ≈0.06–0.07**. That is Conductor's ratio (#141110 → #211e1c) and Paradev's (#151110 → #1a1716 is about 0.03; Conductor's is about 0.06).
- Recommended: `sidebarBG = mix(bg, fg, 0.055)`, with chrome (band plus sidebar) sharing that ground.

**Make the terminal a recessed sheet** (Conductor-style), not a card:
- Draw a **1 device-pixel hairline in a `separator` tone** at `mix(bg, fg, 0.10)`. Conductor uses #2c2826, which is about fg at 10 %.
- The hairline runs along the sheet's **top edge** (under the band) and its **leading edge** (against the sidebar).
- The sheet has no radius and no shadow. The band sits on the chrome ground, not on the terminal ground.
- When the sidebar is hidden, inset the sheet `12pt` from the window's leading edge, as Conductor's `ml-3` does. When it is shown, the sheet is flush.

**The alternative (opencode-style)** is to inset the terminal 8pt on all sides, with radius 10, on a deeper ground, using the 0.5pt ring and two-layer shadow.

| | Light | Dark |
|---|---|---|
| Ring | 0.5pt at black 12 % | 0.5pt at white 16 % |
| Shadows | `0 2 4 black4` + `0 1 2 −1 black8` | `0 2 4 black30` + `0 1 2 black30` |
| Rim | – | −0.5pt top rim at white 6 % |

- That costs 16pt of terminal width and is less "the terminal is the window". **Prefer Conductor's recessed sheet.** It keeps full-bleed terminal rows and still makes chrome and content two objects.
- **Light mode:** the sheet stays the theme bg, the sidebar is `mix(bg, fg, 0.02)` (Conductor uses #fff and #fafaf9), and the separator is `mix(bg, fg, 0.085)`.

### 7.2 Replace the 8pt spinner badge with a status matrix glyph

This touches `Components/ProgramIcon.swift`.

- **Geometry:** keep the 16pt slot. Draw a **4×4 grid of 1.5pt squares on a 3pt pitch from origin 2.5**, as in Conductor.
  - At 1x that is not whole-pixel. Use **4×4 cells of 2px on a 3px pitch from 2** (a 2+1 grid, 11px), or Paradev's **3×3 cells of 3px with a 1px gap = 11px**, which is whole-pixel at 1x and 2x.
  - Recommendation: **3×3 × 3px + 1px gap**, `cornerRadius 0.5`, ink = full foreground.
- **Placement:** use it as the *badge-free* state glyph for agents only while working, swapping with the vendor mark, or as a 9pt badge at the lower right. Keep the vendor mark identity, per `axolotty-ui-feedback`.
- **Working:** a diagonal wave, `FRAME 50ms × 24 frames = 1.2s`, with a 3-frame fade and a 2-frame delay per diagonal (Paradev numbers). Or Conductor's per-cell phase: duration `2π/r` with `r = 1.25 + ((n·29+7) % 17)/17`.
- **Waiting (needs you):** amber. Use the cell pattern of Conductor's `workspace-matrix-attention` (1s alternate, opacity 1 → 0.1), or a static amber diamond (Emdash). This is the **only** state with warm colour plus motion.
- **Failed:** a fixed red pattern. **Done (unseen):** no glyph change; make the title full ink and semibold instead (rule 7.3).
- **Reduce Motion:** show a fixed subset of cells (Conductor's `data-reduced-highlight`), not nothing.

### 7.3 Row typography carries "news"

This touches `Sidebar/SidebarRows.swift`.

- **Title at rest:** 13pt, **weight 450** if available (otherwise regular), at **ink 0.60** in dark (Conductor's `--sidebar-muted-foreground` #fff9) and 0.60 in light (#14100f99). Axolotty uses 0.72 today.
- **Unread or needs you:** **semibold at ink 0.90** (#ffffffe6). Selected: the plate plus 0.90 ink. Drop the separate "done" dot, since weight is the signal.
- **Row metrics:**
  - Keep 28 tall (Paradev `h-7`) with radius 8. Plate inset 8 (`mx-2`).
  - Selected plate fg **10 %**, hover fg **7 %** (Paradev). Conductor uses white 5 % on a lighter ground. Axolotty's 0.09 / 0.055 is close; move to 0.10 / 0.07 once the sidebar is lighter.
- **Git or PR stripe** (optional, when worktree sessions land): `1.5pt × 18pt` at x 0, capsule-shaped, coloured by PR state (green ready, purple merged, red failing, amber pending with a 2.4s ease-in-out pulse). This is Conductor's `RWt`.

### 7.4 Section header and trailing meta

- **Project header:** Conductor's section label is 12pt semibold at sidebar-muted 0.6 × 0.7 ≈ **0.42 ink**. Axolotty's 13 semibold at full ink is the loudest thing in the sidebar, which is why the screenshot looks heavy. Use **12pt semibold at 0.50 ink** and keep the hue tile.
- **Trailing time:** 10pt (`text-3xs`) at ink 0.42, tabular, shown only when the row is not hovered. On hover, swap in the close button and the shortcut, as Paradev does (`font-mono 10px tabular-nums`; Axolotty uses SF tabular).

### 7.5 Band and top bar

- Keep **40** (it matches Conductor, Factory, Emdash and Sculptor). The traffic-light clearance is **66** (Conductor `--traffic-lights-clearance`).
- When the sidebar is hidden, start content at `40 + 66 + 4`, Conductor's `pl-[calc(2.5rem+66px+4px)]`.
- **Session tabs**, if any: a **2pt underline in the brand accent** for the active tab (Conductor `border-b-2 border-b-highlight-muted`), 13pt at weight 530 active and 440 inactive (opencode). Put the status dot (7pt) at the close-button position and swap it with the close button on hover (opencode `tab-nav.css`).

### 7.6 Split panes and focus

This touches `Design/Tokens.swift`.

- Replace the unfocused-pane ground overlay (0.28 dark) with Paradev's two cues: the **pane header or title at 0.60 opacity when inactive**, and a **2pt ring in accent at 15 %** only on the active pane, and only when the tab is split. Keep the hollow cursor.
- Keep the single 1-device-pixel pane divider; it matches Conductor's separator.

### 7.7 Approval surface (roadmap item 1)

- Attach the waiting prompt to the **bottom edge of the waiting pane**, the terminal's "composer lane". Model it on opencode's dock:
  - radius 12 on the top corners only, 0.5pt ring plus raised shadow;
  - padding 12 / 12 / 0, a `20pt | 1fr` grid with a gap of 8;
  - 14pt medium title with an amber warning icon, 14pt muted body;
  - buttons right-aligned, in the order **Deny** (ghost), **Always** (neutral), **Allow** (primary: solid fg with inverted ink).
- Alternatively, use Conductor's banner: `rounded-t-8`, warning fill (dark #413030, light #faf7f5), border #594545 or #e9d9ce, ink #f3ece7 or #594545, with a 200ms background transition.

### 7.8 Palette and type

- If Axolotty ships its own default theme, base it on the **Conductor dark ramp**:

  | Role | Value |
  |---|---|
  | bg | #141110 |
  | sheet | #1c1917 |
  | chrome | #211e1c |
  | card | #2c2826 |
  | fg | #eae8e6 |
  | muted | #a5a09c |
  | faint | #766f6b |

  Use one accent: copper #cca694 (Conductor) or terracotta #e07850 (Paradev). Both are warm and neither collides with amber "waiting".
  - Axolotty's current magenta accent fights the warm ground. If kept, desaturate it.
- **Type tracking per size** (Conductor): 11pt +0.02em, 12pt +0.01em, 13–14pt 0, 15pt −0.005em, 17pt −0.016em (the palette field). SF Pro's automatic tracking does most of this; for the 17pt palette field, apply −0.016em explicitly.

### 7.9 Signature for Axolotty

None of the apps uses a living agent vendor mark. The candidate:
- the project hue tile, plus **the vendor mark that "breathes" through the 3×3 matrix while working**;
- a warm recessed terminal sheet;
- one copper accent used only for focus (caret, active tab underline).

That is a direct, native-crisp answer to Conductor's matrix, and it keeps Axolotty's "icons carry identity; colour carries meaning" rule intact.

---

## Files created or modified outside `/Volumes/Lacie/Workspace/oss/re-apps` and `/tmp`

- `/Volumes/Lacie/Workspace/oss/aislopware/axolotty/.research/wow/re-orchestrators.md` (this report).
- `/Volumes/Lacie/Workspace/oss/aislopware/axolotty/.research/wow/orchestrators/`:
  - `conductor-launch.png`, `opencode-launch.png`, `emdash-launch.png`, `sculptor-launch.png`, `nimbalyst-launch.png`, `factory-launch.png`;
  - `site-conductor.png`, `site-paradev.png`, `site-emdash.png`, `site-sculptor.png` (blank), `site-nimbalyst.png`.
- `~/Documents/Default Project`: an empty directory created by the opencode launch, which **I removed**.
- **Side effects of the app launches** under `~` and `~/Library`: listed in §0.2. They were not cleaned by me; the parent is handling them.
- **Brave:** the CDP session `reorch` navigated to the vendor pages; reads only.
