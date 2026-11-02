> **Superseded (2026-11-02) for the visual layer.** Glass, `NSSplitViewController`, the system sidebar material and the NSPanel palette were removed. The shipped tokens, components and layout are documented in [design-system.md](design-system.md). The behavioural sections below still apply where design-system.md does not override them.

# Axolotty: UI design spec (v1, 2026-11-02)

Target: Swift 6.4, AppKit, macOS 26+ (built against macOS 27.2 SDK), Metal terminal grid (prebuilt libghostty, see `stack-2026-11-02.md`).
Sources: Otty 1.0.4 reverse (`otty-reversed/Docs/05–08`), diri @9935656 (`diri/crates/diri-ui/src/tokens.rs` etc.), slop-desk `DESIGN.md`, aislopware-brand, the macOS 27.2 SDK headers, Ghostty `src/config/Config.zig`.
All numbers are in points. "Verified" means checked against a header or source; anything marked **(measure)** has to be read at runtime.

## 0. Principles (the five rules everything below follows)

1. **The terminal is the window.** The window ground is the terminal background. No floating terminal "card" and no moat. Panes sit flush on that ground and are separated by a single hairline. One lifted surface layer exists, the navigation layer (Apple's Liquid Glass rule: glass belongs to navigation and controls *above* content, never to the content itself).
2. **Glass only floats.** The sidebar gets system glass from `NSSplitViewItem(sidebarWithViewController:)`. The palette, toasts and find bar use `NSGlassEffectView`. The terminal, the band and the status bar are opaque ground. Glass is never stacked on glass. (slop-desk lesson: glass over flat tones reads as a grey slab. Here every glass surface floats over live terminal text, which gives it something to refract.)
3. **Quiet chrome, loud state.** The chrome uses only white or black opacities and semantic label colours. Colour is reserved for the brand pink (cursor, focus, "working") and the four agent states.
4. **One clock.** Every layout motion is a critically-damped spring from one closed ladder (§3). Every fade is one of three curves. No literal durations at call sites.
5. **Native first.** NSSplitViewController, NSOutlineView `.sourceList`, NSToolbar `.toggleSidebar`, system traffic lights, SF Symbols, and system accessibility flags. Custom drawing is only for the terminal, dots, the dividers and the selection plate.

## 1. Window anatomy

### 1.1 Window
- `NSWindow` style mask `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `tabbingMode = .disallowed` (the sidebar replaces native tabs), `isOpaque = true`, `backgroundColor = Ground`.
- `toolbar = NSToolbar` with `toolbarStyle = .unifiedCompact` and items `[.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, agentChip, newSession]`. The toolbar exists to place the native sidebar toggle and to give the traffic lights a fixed centre line. **Do not move the traffic lights** (slop-desk saw them flicker on every retitle).
- Default size 1180×760. Minimum 720×440. Frame autosaved per window.
- Window corner radius is system-drawn. Measured on Tahoe by slop-desk: no toolbar ≈16, `.unifiedCompact` ≈21, `.unified` ≈26 **(measure on 27.2)**. Inner corners follow `inner = outer − inset`. On 27 use `NSViewCornerRadius.containerConcentric(min)` through an override of `cornerConfiguration` plus `viewDidChangeEffectiveCornerRadii` (verified, `NSViewCornerConfiguration.h`, macOS 27 only).
- Appearance follows the terminal theme: `window.appearance = theme.bg.luminance < 0.5 ? .darkAqua : .aqua`. Glass and semantic ink then resolve against the theme actually in use. The default theme follows the system appearance (Night or Day, §4).

### 1.2 Layout (sidebar open; key window)

```
 ┌────────────────────────────────────────────────────────────────────────────────────────┐ ─┐
 │╭──────────────────────────╮ ⌂ axolotty / fix-render — ~/oss/axolotty   [● Working 2m] [+]│  │ Band = toolbar height
 ││ ● ● ●              [⊟]   │                                                           │  │ (target 40; measure)
 ││                          │┌──────────────────────────────┬────────────────────────────┐│ ─┘
 ││ ▾ axolotty            2  ││ $ claude                     │ $ cargo test               ││
 ││ ◜ fix-render      ⌘1 3m  ││ ✻ Thinking…                  │ running 214 tests          ││
 ││ ● review-pr          ✕   ││                              │                            ││  panes flush on Ground,
 ││   zsh                    ││          (focused)           1│        (dimmed 0.72)       ││  1px divider, 9pt hit
 ││ ▸ slopscale           1● ││                              │                            ││
 ││ ▸ dotfiles               │├──────────────────────────────┴────────────────────────────┤│
 ││                          ││ $ git log --oneline                                       ││
 ││                          ││                                                           ││
 ││ ＋ New Session     ⌕     │└───────────────────────────────────────────────────────────┘│
 │╰──────────────────────────╯ ⎇ main · ~/oss/axolotty               ◜ 1 working  ● 1 waiting │ Status bar 24
 └────────────────────────────────────────────────────────────────────────────────────────┘
   └ sidebar: system Liquid Glass, floating, system inset ┘
```

Sidebar collapsed: the band starts after the traffic-light lane. `[⊟]` stays in the toolbar at the same window x (the native `.toggleSidebar` item), and the session title takes over the band. There is no horizontal tab strip: ⌘1–9, ⌘⇧[ ⌘⇧] and ⌘⇧O cover switching (diri and Otty both made tabs optional; we omit them).

### 1.3 Metrics

| Token | Value | Notes / source |
|---|---|---|
| `Grid` | 4 (layout snaps to 8) | Otty and slop-desk use 8 |
| `Band.height` | `window.frame.height − contentLayoutRect.height`, target 40 | Otty's `pillTitlebarY` formula. Controls are centred on the traffic-light centre line |
| `Sidebar.width` default / min / max | 248 / 200 / 360 | diri 248/200/400, Otty 140–500. `NSSplitViewItem.minimumThickness/maximumThickness` |
| `Sidebar` collapse | `canCollapseFromWindowResize = true` below 720 window width | system animation |
| `Sidebar.topReserve` | `Band.height` | the traffic lights live inside the sidebar glass |
| `Row.workspace` | 28 high. 10pt chevron, 12 semibold `secondaryLabel`, trailing count or attention badge | |
| `Row.session` | 30 high. Indent 12. Leading status slot 16 (dot 7). Gap 6. Title 13. Trailing meta 11 | diri 28–30, slop-desk 32 |
| `Row` selection plate | radius 8, inset 8 from the sidebar edges, `Fill.selected` | Tahoe selected sidebar row ≈8 |
| `Sidebar.footer` | 36. "＋ New Session" 13 + trailing `line.3.horizontal.decrease` filter button | diri footer 32 |
| `IconButton` | 28×28 hit area, 24×24 plate radius 7, SF Symbol 13pt `.regular` | Otty 28×24, radius 6 |
| `Pane.padding` | x 16, top 6, bottom 8, plus `window-padding-balance = true` | Ghostty default 2. diri 24/12 |
| `Divider` | visible 1, hit 9 (±4). Hover 2 at `Separator.strong`. Drag 2 in accent | Otty `DividerView` 1→2. diri seam reach 2 |
| `Pane.min` | 160 × 100, which is also ≥ 20 cols × 4 rows | diri |
| `StatusBar.height` | 24, padding x 12, 11pt `secondaryLabel`, `.monospacedDigit()` | toggle: View ▸ Status Bar |
| `AgentChip` | capsule, height 22, padding x 8, dot 6 + 11 medium label | in the band, trailing |
| `Palette` | width `clamp(win.w − 64, 420, 600)`, top `clamp(win.h/6, 48, 120)` below the band, radius 16, inner padding 6 | diri 460 / r16 / top h/6 |
| `Palette.field` | 44 high. Glyph `magnifyingglass` 15. Text 16 regular | |
| `Palette.row` | 32 high, radius 10 (= 16 − 6), 20pt leading glyph slot, max 9 visible | diri 36, Otty 28 |
| `Palette.section` / `footer` | 24 (11 semibold tertiary) / 28 (keycap hints) | |
| `Keycap` | 20 high, min width 20, radius 5, 11 medium **SF Pro** (never mono) | slop-desk keycap lesson |
| `Toast` | width 320, padding 12, radius 14, min height 44, stack gap 8, max 3. Anchored top-right of the content column at (−12, Band + 8) | diri 330 / r16 / top-right |
| `FindBar` | capsule height 32, width 300, 8 from the focused pane's top-right | |
| `DropZone` | radius 6, fill accent 0.18, stroke accent 0.8 1.5pt | Otty 0.35 / 0.9 / 2 / r4, softened |

### 1.4 Regions
- **Sidebar** (`NSOutlineView`, `style = .sourceList`, `rowSizeStyle = .custom`, `floatsGroupRows = false`): a workspace (a folder or repo) contains sessions, and each session holds a pane tree. Drag to reorder sessions within or across workspaces. The footer filter offers an **Attention first** sort (Otty 1.6's "Inbox": waiting, then error, then running). Context menu: Rename, Duplicate, Move to Workspace ▸, Reveal in Finder, Copy Path, Close. The selection plate is a custom single `CALayer` that springs between rows (`Motion.snap`): set `selectionHighlightStyle = .none` and draw the plate yourself.
- **Band**: leading shows the breadcrumb `workspace / session`. Then `—` and the cwd in 13 regular `secondaryLabel`, middle-truncated. Trailing holds the agent chip (only while the focused pane runs an agent) and `＋` (new session). Split buttons appear on band hover: fade in 0.12 s, dwell 0.4 s, fade out 0.2 s (Otty `PanelToggleButton`). Empty band areas drag the window.
- **Panes**: a custom `PaneContainerView` driven by a Codable `PaneTree` (Otty's model). Do not use NSSplitView for panes: it cannot animate tree changes.
- **Status bar**: leading `arrow.triangle.branch` + branch · cwd. Trailing is the agent roll-up (`◜ 1 working ● 1 waiting`). Each segment is a button: waiting jumps to the next waiting pane (⌘⇧U). During a live resize a centred `120 × 32` readout fades in, then out 0.6 s after the resize ends.
- **Command palette**: ⌘⇧P, a borderless `NSPanel` child window (`canBecomeKey`). Sections: Sessions, Commands, Workspaces, Recent directories. Fuzzy match with highlighted runs in `labelColor` semibold.
- **Open Quickly** (⌘⇧O): the same panel scoped to sessions, workspaces and directories (zoxide-style frecency).
- **Toasts**: in-app only, shown when the event's session is not visible. When the app is inactive, post a `UNUserNotificationCenter` notification instead and badge the Dock with the waiting count.

### 1.5 Agent status UI (four surfaces, one state model)

`AgentState = idle | working | waiting | done(unseen) | error(unseen)`. Inputs: Claude Code / Codex hooks and Otty's **OSC 26** (`CodeAgent=…;Status=running|awaiting-approval|awaiting-input|error|finished|idle;TaskProgress=n/m`), mapped as running→working, awaiting-*→waiting, finished→done. When `TaskProgress` is present, the working ring becomes a determinate arc. A session's state is the highest-priority state among its panes: **waiting > error > working > done > idle**. `done` and `error` clear when that pane is focused.

| Surface | idle | working | waiting | done (unseen) | error (unseen) |
|---|---|---|---|---|---|
| Sidebar leading slot | nothing (plain shell: no glyph) | 8pt ring, 2pt stroke, 270° arc in `Status.working`, rotating 1.2 s linear | 7pt dot `Status.waiting`, halo pulse | 7pt dot `Status.done` | 7pt dot `Status.error`; the row also tints its trailing meta `Status.error` |
| Band agent chip | hidden | `◜ Claude · 2m14s` | `● Needs input`, chip fill `waiting @ 0.16` | `● Done · 4m` (fades after 6 s) | `● Failed` |
| Pane | n/a | n/a | inner 1.5pt stroke `waiting @ 0.7`, fades in 0.2 s, removed on focus | n/a | n/a |
| Workspace row (collapsed) | n/a | n/a | amber count capsule (16 high, 11 semibold) | small green dot | small red dot |

Colour is never the only signal. Each state also differs by **shape** (ring, dot, or halo) and by **text** (chip, tooltip, VoiceOver label `"review-pr, agent waiting for input"`).

## 2. Design tokens

### 2.1 Colour: chrome (neutrals carry a trace of the brand hue, OKLCH H 333, C ≤ 0.008)

| Token | Dark | Light | Use |
|---|---|---|---|
| `Ground` (= terminal bg) | `#151214` | `#FCF9FB` | window bg, band, panes, status bar |
| `Surface` | `#1E1B1D` | `#FFFFFF` | opaque fallback for glass (Reduce Transparency) |
| `Surface.elevated` | `#262326` | `#FFFFFF` | palette and toast fallback, drag ghost |
| `Text.primary` | `labelColor` (≈`#EAE6E9`) | `labelColor` (≈`#221E21`) | titles |
| `Text.secondary` | `secondaryLabelColor` (≈`#A8A3A7`) | ≈`#5E595D` | cwd, meta |
| `Text.tertiary` | `tertiaryLabelColor` (≈`#777376`) | ≈`#898488` | section headers, hints |
| `Fill.hover` | white 0.06 | black 0.045 | rows, buttons (diri 0.06) |
| `Fill.selected` | white 0.10 | black 0.07 | selection plate (diri 0.10) |
| `Fill.pressed` | white 0.14 | black 0.10 | button plates only |
| `Separator` | white 0.08 | black 0.09 | divider, rules (Otty 0.06–0.08) |
| `Separator.strong` | white 0.16 | black 0.16 | divider hover, Increase Contrast |
| `Dim` | `Ground` at 0.28 over the pane | `Ground` at 0.22 | unfocused pane (§5) |
| `Accent` | `#DE7BCF` | `#B24CA5` | focus, cursor, links, drag line. Light uses L 0.58 for 4.7:1 on white |
| `Accent.wash` | accent 0.16 | accent 0.12 | drop zone, chip fills |

Hex values for semantic colours are reference only. Always use the `NSColor` semantic so vibrancy works on glass. Store chrome tokens as dynamic `NSColor(name:dynamicProvider:)`. Never cache a `CGColor` across appearance changes; re-resolve in `viewDidChangeEffectiveAppearance`.

### 2.2 Colour: agent states (dark, light). Contrast is measured against Ground. Non-text, so the target is ≥ 3:1

| State | Dark | Light | OKLCH (dark) | Contrast D / L |
|---|---|---|---|---|
| `Status.working` (= brand) | `#DE7BCF` | `#B24CA5` | 0.72 0.16 333 | 6.9 / 4.5 |
| `Status.waiting` | `#F5AE39` | `#CA8000` | 0.80 0.15 75 | 9.7 / 3.0 |
| `Status.done` | `#55C975` | `#00943E` | 0.75 0.16 150 | 8.9 / 3.8 |
| `Status.error` | `#EA6A64` | `#C43F3E` | 0.68 0.16 25 | 6.0 / 4.9 |
| `Status.info` | `#36ACFF` | `#0076CC` | 0.72 0.16 245 | 7.5 / 4.5 |

Pink (H 333) and red (H 25) are 52° apart and are also told apart by shape (ring vs dot).

### 2.3 Typography (SF Pro via `NSFont.systemFont`; SF Mono via `NSFont.monospacedSystemFont`)

| Role | Size / weight | Where |
|---|---|---|
| `title` | 13 semibold | band session name, toast title |
| `body` | 13 regular (selected row: medium) | sidebar rows, palette rows, band cwd |
| `field` | 16 regular | palette search |
| `caption` | 11 regular, `.monospacedDigit` | meta, status bar, elapsed |
| `caption.strong` | 11 semibold | section headers (sentence case, no tracking), chip, badge |
| `keycap` | 11 medium SF Pro | chords |
| **Terminal** | **SF Mono 13 regular, bold = semibold**. Cell height = font line height + 10 % (`adjust-cell-height = 10%`). Ligatures off. Fallbacks: `.SF NS Mono`, `Menlo`, `Apple Symbols`, `Apple Color Emoji` | Ghostty macOS default size 13. diri: SF Mono 13 with the same fallbacks |

HIG (macOS) confirms these: body 13/16, Callout 12/15, Subheadline 11/14, minimum 10, text contrast ≥ 4.5:1 up to 17pt. Ship JetBrains Mono as the bundled alternative (Otty's default). Font size range 9–24; ⌘+/⌘− step 1, ⌘0 resets.

### 2.4 Elevation (only for opaque fallbacks and the drag ghost; glass draws its own depth **(measure)**)

| Token | Shadow (y / blur / α dark / α light) | Rim |
|---|---|---|
| `e.toast` | 8 / 24 / 0.28 / 0.12 | 0.5pt `Separator` inside |
| `e.palette` | 16 / 48 / 0.38 / 0.16 | 0.5pt white 0.10 (dark) / black 0.08 (light) |
| `e.ghost` (pane being dragged) | 12 / 32 / 0.32 / 0.14 | none, opacity 0.85 |

### 2.5 Materials

| Surface | API | Settings |
|---|---|---|
| Sidebar | system, via `NSSplitViewItem(sidebarWithViewController:)` | add no `NSVisualEffectView` (it blocks the glass). Set `automaticallyAdjustsSafeAreaInsets = true` on the **content** item (macOS 26, verified), so Ground runs full-bleed under the floating sidebar and panes lay out in `safeAreaRect` |
| Palette, toasts, find bar | `NSGlassEffectView` (verified: `contentView`, `cornerRadius`, `tintColor`, `style .regular/.clear`; `effectIsInteractive` is 27+) | `.regular`, never `.clear` (Apple restricts that to visually rich backgrounds). Content goes in `contentView`, never a sibling view. `tintColor = Surface.elevated` α 0.55 (dark) / 0.65 (light) so text stays legible over busy terminal output |
| Toast stack | `NSGlassEffectContainerView`, `spacing = 8` | lets neighbouring toasts merge and morph |
| Terminal (opt-in "Translucent") | `NSVisualEffectView` `.underWindowBackground`, `.behindWindow`, `.active` under a Ground layer at α 0.92 | diri glass terminal α 11/12. Off by default |
| Menus, popovers, alerts | system | |
| Reduce Transparency / Increase Contrast | the system already makes glass frostier, or black/white with a border (WWDC25-219). Keep that, and additionally drop our tint to α 0. Our own non-glass translucency (Translucent terminal, `Dim`) goes opaque | `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` |

## 3. Motion

### 3.1 Ladder

Springs are critically damped unless noted. Use `NSAnimationContext.animate(_ animation: SwiftUI.Animation, changes:completion:)` for view properties (macOS 15+, verified in the SwiftUI interface). Use `CASpringAnimation(perceptualDuration:bounce:)` for layers (verified). Conversion with mass 1: stiffness = (2π/response)², damping = 4π·ζ/response, bounce = 1 − ζ.

| Token | response, bounce | mass / stiffness / damping | Use |
|---|---|---|---|
| `Motion.snap` | 0.25, 0 | 1 / 631.7 / 50.3 | selection plate slide, divider snap, toggle thumbs, scroll settle |
| `Motion.standard` | 0.35, 0 | 1 / 322.3 / 35.9 | pane split, close, equalize, zoom; sidebar row reflow |
| `Motion.panel` | 0.42, 0 | 1 / 223.8 / 29.9 | custom panels and the status bar show/hide (the sidebar uses the system animation) |
| `Motion.pop` | 0.32, 0.12 | 1 / 385.5 / 34.6 | palette open (scale 0.97→1), toast enter |
| `Fade.in` | 0.16 s, ease-out `(0, 0, 0.58, 1)` | n/a | reveals |
| `Fade.out` | 0.12 s, ease-in `(0.42, 0, 1, 1)` | n/a | dismissals (exits are always faster than entrances) |
| `Fade.hover` | 0.10 s in / 0.18 s out, ease-out | n/a | hover fills (the slower exit gives a soft linger, diri `HOVER_LINGER 0.11`) |

### 3.2 What animates

| Transition | Spec | Reduce Motion |
|---|---|---|
| Sidebar collapse/expand | system `toggleSidebar(_:)` / `animator().isCollapsed`. Band content shifts with `Motion.panel` | system behaviour |
| Pane split | Sibling frames go to their new rects with `Motion.standard`. The new pane fades in `Fade.in` after a 60 ms delay, from the split edge with a 12pt offset | instant layout, 0.12 s crossfade |
| Pane close | the closing pane fades out `Fade.out` with scale 0.98; siblings expand with `Motion.standard` | instant |
| **PTY resize rule** | During any animated relayout, keep each surface's grid size and draw it top-left anchored and clipped. Commit the final cols×rows once at completion (one SIGWINCH). Never reflow per frame | same |
| Session switch | swap instantly, plus a 0.10 s crossfade from a snapshot of the old pane tree. The selection plate slides with `Motion.snap` | swap, no plate slide |
| Palette open / close | open: `Motion.pop` scale 0.97→1 plus opacity 0→1 over 0.16 s, anchored top-centre. Close: `Fade.out` with scale 0.98 | opacity only, 0.10 s |
| Toast in / out | in: from y −8, opacity 0 → 1 with `Motion.pop`. Out: x +16 and opacity → 0 with `Fade.out`; the remaining toasts restack with `Motion.standard`. Hold times: info and success 4 s, warning 7 s, error 8 s, +1.5 s with a detail line; actions raise it to ≥ 8 s; hover pauses (diri) | opacity only |
| Find bar | `Fade.in` with y −4 | opacity |
| Focus change (dim) | the unfocused pane's dim alpha animates 0.16 s ease-in-out (diri and Otty switch instantly; a short fade is calmer) | instant |
| Divider hover | 1→2pt and colour, 0.16 s ease-in-out (Otty) | instant |
| Waiting halo | a ring at the dot scales 1→2.2 while opacity 0.5→0, 1.6 s ease-out, repeating | static 1pt ring at 0.5 |
| Working ring | rotation 360° per 1.2 s, linear, repeating (`CABasicAnimation transform.rotation`) | static 270° arc |
| ⌘-held keycaps | after holding ⌘ for 0.4 s, keycaps fade in with `Fade.in` in place of the row meta | same, no fade |

### 3.3 Cursor (drawn in the Metal pass; with libghostty, use a cursor overlay or a custom shader on `iCurrentCursor` / `iPreviousCursor`, which are verified in Config.zig)

- **Glide**: on a same-row move ≤ 8 cols or a move ≤ 2 rows, interpolate position over 80 ms with ease-out-quad `1 − (1 − t)²`. Larger jumps snap. Suppress the glide while output is streaming (more than 1 move per frame, or during the PTY-burst window). Otty uses 100 ms ≤ 8 cols; diri uses 80 ms ≤ 8 cols / 2 rows.
- **Entrance**: on focus gain, a block cursor pops at scale `1 + 0.14 · (1 − t)³` over 220 ms (Otty). Bar and underline use 0.4 on their long axis.
- **Blink** (default on, styled after diri): starts after 500 ms idle. Fade 150 ms, high hold 500 ms, low hold 300 ms, floor opacity 0.25 (it dims rather than vanishing). It stops after 10 cycles to save power and restarts on any keystroke.
- **Shape**: bar 2pt in Accent by default. The text under a block cursor uses Ground. In an unfocused pane or window the cursor is a hollow block at 1pt.
- **Reduce Motion**: no glide and no entrance. Blink becomes a hard toggle at the same period (or off if the user disables blinking).
- **Smooth scroll**: when `hasPreciseScrollingDeltas`, apply pixel offsets. When the gesture ends, settle to a row boundary with `Motion.snap`.

## 4. Terminal themes (OKLCH-designed. ANSI hues: red 22, yellow 88, green 150, cyan 200, blue 255, magenta 333 = brand. Contrast vs bg in parentheses)

**Axolotty Night** (dark, default under dark appearance). bg `#151214`, fg `#EBE6EA` (15.1). cursor `#DE7BCF`, cursor-text `#151214`. selection-background `#433140`, selection-foreground `cell-foreground` (fg on selection 9.7).

| | black | red | green | yellow | blue | magenta | cyan | white |
|---|---|---|---|---|---|---|---|---|
| normal | `#393438` | `#EF7E7C` (7.0) | `#6CC581` (8.8) | `#E4C062` (10.7) | `#6FA7EE` (7.5) | `#DF88D0` (7.6) | `#5DCBD1` (9.7) | `#D4CFD3` |
| bright | `#857E83` (4.7) | `#FDA19E` | `#8FE1A1` | `#F5D983` | `#92C1FD` | `#F3A7E5` | `#85E3E8` | `#F7F4F6` |

**Axolotty Day** (light). bg `#FCF9FB`, fg `#2A2429` (14.5). cursor `#BF4AB0`, cursor-text `#FCF9FB`. selection-background `#F0D9EB`, selection-foreground `cell-foreground` (fg on selection 11.5).

| | black | red | green | yellow | blue | magenta | cyan | white |
|---|---|---|---|---|---|---|---|---|
| normal | `#2A2429` | `#C13C3B` (5.1) | `#11813C` (4.8) | `#9A6A17` (4.5) | `#226BC0` (5.1) | `#AB3E9D` (5.1) | `#208089` (4.5) | `#D3CFD3` |
| bright | `#797277` (4.5) | `#A92227` | `#067132` | `#875814` | `#1654A9` | `#912C86` | `#176A72` | `#EDEAEC` |

Rules: in Night, normal colours sit at L 0.72–0.82 (the brand's equal-lightness family) and brights sit 0.08 L higher. In Day, normals sit at L 0.53–0.56 for ≥ 4.5:1 and brights sit 0.07 L *darker*, so bold still pops on paper. In both, bright-black is ≥ 4.5:1, which keeps shell autosuggestions legible. Ghostty keys: `palette = N=#hex`, `background`, `foreground`, `cursor-color`, `cursor-text`, `selection-background`, `selection-foreground = cell-foreground`, `minimum-contrast = 1.1`, `unfocused-split-opacity = 0.72`, `unfocused-split-fill = <bg>`, `split-divider-color` (Separator flattened over bg: Night `#282527`, Day `#E5E3E4`).

## 5. Interaction

### 5.1 Keyboard (macOS conventions first; every binding is user-rebindable)

| Area | Action | Keys |
|---|---|---|
| App | Command Palette / Open Quickly / Settings | ⌘⇧P / ⌘⇧O / ⌘, |
| Window | New window / Close window / Minimize / Full screen / Toggle sidebar / Toggle status bar | ⌘N / ⌘⇧W / ⌘M / ⌃⌘F / ⌃⌘S / ⌘⌥/ |
| Workspace | Open folder as workspace / New workspace | ⌘O / ⌘⇧N |
| Session | New session (in current workspace) / Reopen closed / Select 1–8, last | ⌘T / ⌘⇧T / ⌘1–⌘8, ⌘9 |
| Session | Previous / next session | ⌘⇧[ ⌘⇧] (also ⌃⇧⇥ ⌃⇥) |
| Agent | Next waiting or unseen agent / Previous | ⌘⇧U / ⌘⌥⇧U |
| Pane | Split right / Split down | ⌘D / ⌘⇧D |
| Pane | Close pane (the last pane closes the session; never the window) | ⌘W |
| Pane | Focus previous / next pane | ⌘[ / ⌘] |
| Pane | Focus pane by direction / Resize pane by direction | ⌘⌥←↑→↓ / ⌃⌘←↑→↓ |
| Pane | Zoom pane / Equalize | ⌘⇧↩ / ⌃⌘= |
| Terminal | Copy / Paste / Select all | ⌘C / ⌘V / ⌘A |
| Terminal | Find / Next / Previous / Use selection for find | ⌘F / ⌘G / ⌘⇧G / ⌘E |
| Terminal | Clear buffer (Terminal.app convention; so the palette is **not** ⌘K) | ⌘K |
| Terminal | Jump to previous / next prompt (needs shell integration) | ⌘↑ / ⌘↓ |
| Terminal | Top / bottom of buffer | ⌘Home / ⌘End |
| Terminal | Font bigger / smaller / reset | ⌘+ / ⌘− / ⌘0 |
| Overlay | Dismiss / Confirm / Move selection | ⎋ / ↩ / ↑↓ (also ⌃P ⌃N) |

Every action appears in the menu bar (File, Edit, View, Session, Pane, Window) so shortcuts are discoverable and validated through `validateMenuItem`.

### 5.2 Focus
- A terminal pane is first responder unless an overlay is open. Tab and ⇧Tab always go to the shell. The sidebar never keeps key focus after a click: activating a row restores the session's last focused pane. Arrow-key navigation of the sidebar happens through ⌘⇧O instead. VoiceOver can still reach the sidebar through the accessibility hierarchy.
- Overlays become key while open. ⎋ or a click outside returns focus to the pane that was focused before (store a weak reference when opening).
- Clicking an unfocused pane only focuses it: the click is not forwarded as a mouse report to the TUI. Text selection by dragging still works on the first click. Focus-follows-mouse is off by default.
- When the window becomes key, restore the last focused pane. When it resigns key, every cursor turns hollow and the band and status text drop to `tertiaryLabel`. Pane dimming does not change.

### 5.3 Inactive-pane dimming
- Applies only when a session has ≥ 2 panes. Unfocused panes get a `Ground` overlay at 0.28 (Night) or 0.22 (Day), so effective opacity is ≈ 0.72 (Ghostty default 0.7, diri 0.72). The change animates 0.16 s.
- Increase Contrast: dim drops to 0.12, and the focused pane gains a 1pt inner `Accent` stroke at 0.6.

### 5.4 Hover and press

| Element | Rest | Hover | Press / active |
|---|---|---|---|
| Sidebar row | clear | `Fill.hover`; trailing meta becomes a `xmark` 9pt in a 16pt circle plate | selected plate `Fill.selected`, title medium |
| Icon button | symbol `secondaryLabel` | 24pt plate `Fill.hover`, symbol `labelColor` | plate `Fill.pressed` plus a 2pt downward symbol bounce |
| Divider | 1pt `Separator` | 2pt `Separator.strong`, resize cursor | 2pt `Accent` with a live ratio readout |
| Palette row | clear | `Fill.hover` (mouse only after the pointer actually moves; keyboard wins otherwise, as in Otty `mouseActive`) | selected `Fill.selected` |
| Link in terminal (OSC 8 / URL) | n/a | with ⌘ held: 1pt underline in `Accent` plus a pointing-hand cursor. A path pill appears after 0.15 s | n/a |
| Band | n/a | split buttons fade in (dwell 0.4 s) | n/a |

## 6. Brand: Axolotty

**Colour: gill pink `#DE7BCF`, OKLCH 0.72 0.16 333.**
- **No hue is ≥ 50° from all five existing hues** (15, 55, 150, 240, 290). The largest possible minimum distance is 47°, at H 103.
- The four candidates:
  - **Yellow H 103**: 47° from its nearest neighbour, but it is out of sRGB gamut at C 0.16 (ceiling 0.151) and it reads as caution, which slopty's README already rejected for lime.
  - **Teal H 195**: 45° away, also out of gamut (ceiling 0.123), and it reads teal, which slopscale already rejected.
  - **Pink H 333**: 43° from lavender and 42° from coral, the only gap where C 0.16 fits (ceiling 0.27).
  - **Pink H 340**: only 35° from coral.
- Pink H 333 is the only in-gamut choice, and its OKLab ΔE to its neighbours is 0.113 (lavender) and 0.115 (coral). The family already accepts 0.109 (coral vs orange, 40° apart), so the 50° rule is effectively already 40° in practice.
- Recommend **H 333**, and write the family rule as "≥ 40° and ΔE ≥ 0.10".
- On ink plate `#1C1F26` it reaches 6.2:1. On paper it reaches 2.4:1, which is fine for a logo but not for text.

**Mark: the axolotl face** on the nine-dot grid, as a glyph like slopty's (the letter A belongs to the org):

```
# . #      wide-set eyes: the axolotl's signature
. . .
. # .      the mouth, which is the live dot: it pulses while any agent works
```

It lights 3 of 9 dots, with the unlit dots at 0.3, all circles, never all nine. Like slopty's cursor, the mouth dot carries `id="mouth"`. The app animates it in the Dock or menu-bar extra while agents are `working`, holds it steady under Reduce Motion, and shows it amber when an agent is waiting. Alternative if the face reads as "∵" at 16 px: the gill fork **Y** `#.# / .#. / .#.`. App icon: the mark on the ink plate as an Icon Composer document, with the system applying glass (as slopty does).

## 7. Implementation notes and open checks
- `Band.height`, window corner radius, the glass view's own shadow, and the `NSGlassEffectView` tint under Increase Contrast are all **(measure)** on macOS 27.2 with a one-window probe before freezing tokens.
- `NSViewCornerConfiguration` is macOS 27 only. On 26, fall back to fixed radii (16 / 10 / 14 / 8).
- Read the accessibility flags from `NSWorkspace.shared` (`accessibilityDisplayShouldReduceMotion`, `…ReduceTransparency`, `…IncreaseContrast`). Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` and re-resolve live.
- Keep all tokens in one `Axo` namespace (`Axo.Color`, `Axo.Metric`, `Axo.Motion`, `Axo.Type`). Lint call sites for raw literals, as slop-desk's `design-token-leaks` check did.
