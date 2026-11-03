import AppKit
import AxModel

// The design system has three token layers (see .research/design-system.md):
//
//   1. Primitives: scales with no meaning (space, radius, type sizes, ink
//      alphas, durations). Nothing outside Design/ reads them directly.
//   2. Semantic tokens: what a value is *for* (ground, sidebar, elevated,
//      hover, border, text.secondary, accent…). Colours are derived from the
//      active terminal theme, Warp-style: every plane is the theme's
//      background moved toward its foreground or toward black by a fixed
//      step, so the chrome always belongs to the terminal it frames.
//   3. Component tokens: per-component metrics built from 1 and 2.
//
// Call sites use layers 2 and 3 only, never literals.

/// Layer 1: primitives.
nonisolated enum Prim {
    /// 4-pt grid with the 2/6 half-steps dense UI needs.
    enum Space {
        static let s0: CGFloat = 0, s1: CGFloat = 2, s2: CGFloat = 4, s3: CGFloat = 6, s4: CGFloat = 8
        static let s5: CGFloat = 10, s6: CGFloat = 12, s7: CGFloat = 16, s8: CGFloat = 20, s9: CGFloat = 24
        static let s10: CGFloat = 32, s11: CGFloat = 40, s12: CGFloat = 48
    }

    /// Radius ladder. Nested corners are concentric: outer = inner + padding.
    enum Radius {
        static let r1: CGFloat = 4, r2: CGFloat = 6, r3: CGFloat = 8, r4: CGFloat = 10, r5: CGFloat = 12, r6: CGFloat = 14
    }

    /// Ink alphas: foreground over the plane it sits on.
    enum Ink {
        static let a1 = 0.035, a2 = 0.05, a3 = 0.065, a4 = 0.085, a5 = 0.10, a6 = 0.12, a7 = 0.16, a8 = 0.24
        static let a9 = 0.36, a10 = 0.52, a11 = 0.72
    }

    /// Type sizes (SF applies its optical tracking itself in AppKit text).
    enum Size {
        static let t1: CGFloat = 10, t2: CGFloat = 11, t3: CGFloat = 12, t4: CGFloat = 13, t5: CGFloat = 15
        static let t6: CGFloat = 17, t7: CGFloat = 20
    }
}

/// A colour as data: sRGB plus alpha. Resolved to NSColor/CGColor on use.
nonisolated struct Ink: Hashable, Sendable {
    var rgb: RGB
    var alpha: Double = 1

    func a(_ alpha: Double) -> Ink { Ink(rgb: rgb, alpha: alpha) }
    var ns: NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: CGFloat(alpha))
    }
    var cg: CGColor { ns.cgColor }

    /// The colour this ink shows over an opaque `plane`.
    func over(_ plane: RGB) -> RGB { plane.mix(rgb, alpha) }

    static let black = Ink(rgb: RGB(0, 0, 0))
    static let white = Ink(rgb: RGB(255, 255, 255))
}

/// One shadow layer.
nonisolated struct Shadow: Hashable, Sendable {
    var y: CGFloat
    var blur: CGFloat
    var alpha: Float
}

/// Layer 2: semantic tokens, derived from one terminal theme.
nonisolated struct DesignTokens: Sendable {
    let dark: Bool
    let theme: TerminalTheme

    // Planes. The window is a frame; terminals are screens set in it.
    // - ground: the terminal's own background, the fill of every pane sheet.
    // - frame: the band, the sidebar and the gutters between sheets, one tone.
    //   In dark it is the ground's own hue five lightness points down (the
    //   Dracula ramp: frame 10, ground 15, raised 20, floats 25), so each
    //   terminal is the lit screen in a darker bezel. A ground too dark to go
    //   lower takes a lighter frame instead. In light the sheet is white and
    //   the frame a cool grey under it.
    // - elevated: floats (palette, toasts, menus), one notch above the ground.
    let ground: RGB
    let frame: RGB
    let elevated: RGB
    /// Inputs and resting cards on the frame: the ramp's raised step.
    let raised: RGB
    /// The sidebar is the frame (kept as its own name for its call sites).
    var sidebar: RGB { frame }

    // Ink states over any plane.
    let hover: Ink
    let selected: Ink
    let pressed: Ink
    let selectedHover: Ink

    // Hairlines (drawn one device pixel wide).
    let border: Ink
    let borderSubtle: Ink
    let borderStrong: Ink
    /// Every sheet's edge, one device pixel: in dark the selection tone (the
    /// ramp's own hue, so the edge is a lighter step of the bezel, not a grey
    /// line on it); in light the contact edge a white sheet needs on grey.
    let sheetEdge: Ink

    // Text tiers.
    let text: Ink
    let textSecondary: Ink
    let textTertiary: Ink
    let textDisabled: Ink

    // Accent: keyboard focus, caret, the busy mark, links, an active drag.
    let accent: Ink
    let accentInk: Ink
    let accentWash: Ink
    /// The axolotl's pink: the mark only.
    let brand: Ink

    // The neutral solid (primary action): inverted ink.
    let solid: Ink
    let solidInk: Ink

    let scrim: Ink

    /// Elevated surfaces: inner ring, outer contact ring, top rim, drop shadows.
    let ring: Ink
    let outerRing: Ink
    let rim: Ink
    let restShadow: Shadow
    let floatShadows: [Shadow]

    init(theme t: TerminalTheme) {
        theme = t
        dark = t.isDark
        let bg = t.background, fg = t.foreground, sel = t.selectionBackground
        let black = RGB(0, 0, 0), white = RGB(255, 255, 255)
        let hue = bg.hsl
        // A neutral ground (no hue to keep) tints its text tiers toward the
        // foreground instead.
        let tinted = hue.s > 0.04, isDark = t.isDark
        let tier = { (l: Double, s: Double) -> Ink in
            tinted ? Ink(rgb: RGB(h: hue.h, s: s, l: l)) : Ink(rgb: fg, alpha: isDark ? l : 1 - l)
        }
        ground = bg
        if dark {
            let deep = hue.l >= 0.11
            frame = deep ? bg.lightness(hue.l - 0.05) : bg.mix(fg, 0.06)
            raised = bg.lightness(hue.l + 0.05)
            elevated = bg.lightness(hue.l + 0.10)
            // Plates are the selection tone itself, so they keep the ramp's hue.
            hover = Ink(rgb: sel, alpha: 0.42)
            selected = Ink(rgb: sel, alpha: 0.78)
            selectedHover = Ink(rgb: sel, alpha: 0.92)
            pressed = Ink(rgb: sel.lightness(sel.hsl.l + 0.04))
            border = Ink(rgb: sel, alpha: 0.70)
            borderSubtle = Ink(rgb: sel, alpha: 0.45)
            borderStrong = Ink(rgb: sel.lightness(sel.hsl.l + 0.10))
            sheetEdge = Ink(rgb: sel, alpha: 0.55)
            text = Ink(rgb: fg)
            // 7.2 / 5.3 / 4.0 on the frame, 6.3 / 4.7 / 3.5 on the ground.
            textSecondary = tier(0.70, 0.25)
            textTertiary = tier(0.62, 0.25)
            textDisabled = tier(0.55, 0.25)
            scrim = Ink(rgb: black, alpha: 0.42)
            ring = Ink(rgb: sel, alpha: 0.85)
            outerRing = Ink(rgb: black, alpha: 0.55)
            rim = Ink(rgb: white, alpha: 0.05)
            restShadow = Shadow(y: 1, blur: 2, alpha: 0.30)
            floatShadows = [Shadow(y: 1, blur: 2, alpha: 0.32), Shadow(y: 12, blur: 32, alpha: 0.42)]
        } else {
            frame = bg.luminance > 0.97 ? RGB(h: hue.h, s: 0.06, l: 0.962) : bg.mix(fg, 0.05)
            raised = white
            elevated = white
            hover = Ink(rgb: sel, alpha: 0.45)
            selected = Ink(rgb: sel, alpha: 0.80)
            selectedHover = Ink(rgb: sel, alpha: 0.95)
            pressed = Ink(rgb: sel.lightness(sel.hsl.l - 0.04))
            border = Ink(rgb: fg, alpha: Prim.Ink.a6 + 0.01)
            borderSubtle = Ink(rgb: fg, alpha: Prim.Ink.a4)
            borderStrong = Ink(rgb: fg, alpha: Prim.Ink.a8 - 0.04)
            sheetEdge = border
            text = Ink(rgb: fg)
            // 7.1 / 4.7 on the frame; disabled is for marks that say "off".
            textSecondary = tier(0.38, 0.20)
            textTertiary = tier(0.48, 0.14)
            textDisabled = tier(0.64, 0.12)
            scrim = Ink(rgb: black, alpha: 0.14)
            ring = Ink(rgb: fg, alpha: 0.10)
            outerRing = Ink(rgb: black, alpha: 0)
            rim = Ink(rgb: white, alpha: 0)
            restShadow = Shadow(y: 1, blur: 2, alpha: 0.06)
            floatShadows = [Shadow(y: 1, blur: 2, alpha: 0.07), Shadow(y: 12, blur: 32, alpha: 0.12)]
        }
        let acc = Palette.accent(dark: dark)
        accent = Ink(rgb: acc)
        accentInk = Ink(rgb: acc.contrast(with: white) >= acc.contrast(with: bg) ? white : bg)
        accentWash = Ink(rgb: acc, alpha: dark ? 0.18 : 0.12)
        brand = Ink(rgb: Palette.brand(dark: dark))
        solid = Ink(rgb: fg)
        solidInk = Ink(rgb: bg)
    }

    func status(_ a: Activity) -> Ink? { Palette.activity(a, dark: dark).map { Ink(rgb: $0) } }

    // MARK: Registry

    /// The token sets the two appearances resolve against. The window's
    /// appearance follows the theme, so dark ↔ the night theme in use.
    nonisolated(unsafe) private static var sets: (dark: DesignTokens, light: DesignTokens) =
        (DesignTokens(theme: .night), DesignTokens(theme: .day))

    static func current(dark: Bool) -> DesignTokens { dark ? sets.dark : sets.light }

    /// Re-derives the set for `theme`'s appearance (call on theme change, then
    /// refresh the view tree: dynamic colours re-resolve on the next draw).
    @MainActor static func install(_ theme: TerminalTheme) {
        if theme.isDark { sets.dark = DesignTokens(theme: theme) } else { sets.light = DesignTokens(theme: theme) }
    }
}

extension NSView {
    /// Re-resolves every design colour below this view (theme change without an
    /// appearance change: `updateLayer`/`draw` and layout run again).
    func refreshDesign() {
        needsDisplay = true
        needsLayout = true
        if let d = self as? any DesignRefreshable { d.designDidChange() }
        for v in subviews { v.refreshDesign() }
    }
}

/// Views that cache resolved colours in layers implement this.
@MainActor protocol DesignRefreshable: AnyObject {
    func designDidChange()
}
