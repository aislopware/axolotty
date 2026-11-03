import AppKit
import AxModel
import QuartzCore
import SwiftUI

/// Layers 2 and 3 of the design system (see Tokens.swift and
/// .research/design-system.md). Call sites use these, never literals.
enum Axo {
    // MARK: Colour (semantic, theme-derived, appearance-dynamic)

    enum Color {
        static func rgb(_ c: RGB, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: alpha)
        }

        /// A colour that resolves against the installed token set for the
        /// drawing appearance.
        static func token(_ name: String, _ pick: @escaping @Sendable (DesignTokens) -> Ink) -> NSColor {
            NSColor(name: NSColor.Name("axo.\(name)")) { pick(DesignTokens.current(dark: $0.isDark)).ns }
        }

        // Planes
        static let ground = token("ground") { Ink(rgb: $0.ground) }
        static let sidebar = token("sidebar") { Ink(rgb: $0.sidebar) }
        static let frame = token("frame") { Ink(rgb: $0.frame) }
        static let elevated = token("elevated") { Ink(rgb: $0.elevated) }

        // States (ink over the plane)
        static let hover = token("hover") { $0.hover }
        static let selected = token("selected") { $0.selected }
        static let selectedHover = token("selectedHover") { $0.selectedHover }
        static let pressed = token("pressed") { $0.pressed }

        // Hairlines
        static let border = token("border") { $0.border }
        static let borderSubtle = token("borderSubtle") { $0.borderSubtle }
        static let borderStrong = token("borderStrong") { $0.borderStrong }

        // Text
        static let text = token("text") { $0.text }
        static let textSecondary = token("textSecondary") { $0.textSecondary }
        static let textTertiary = token("textTertiary") { $0.textTertiary }
        static let textDisabled = token("textDisabled") { $0.textDisabled }

        // Accent and solid
        static let accent = token("accent") { $0.accent }
        static let accentInk = token("accentInk") { $0.accentInk }
        static let accentWash = token("accentWash") { $0.accentWash }
        static let brand = token("brand") { $0.brand }
        static let raised = token("raised") { Ink(rgb: $0.raised) }
        static let solid = token("solid") { $0.solid }
        static let solidInk = token("solidInk") { $0.solidInk }
        static let scrim = token("scrim") { $0.scrim }

        static func status(_ a: Activity) -> NSColor {
            token("status.\(a.rawValue)") { $0.status(a) ?? Ink(rgb: $0.ground, alpha: 0) }
        }

        static func statusWash(_ a: Activity) -> NSColor {
            token("statusWash.\(a.rawValue)") { t in t.status(a).map { $0.a(t.dark ? 0.16 : 0.12) } ?? Ink(rgb: t.ground, alpha: 0) }
        }

        /// Unfocused-pane dim (ground over the pane).
        static func dimAlpha(dark: Bool, increaseContrast: Bool) -> CGFloat {
            increaseContrast ? 0.12 : (dark ? 0.28 : 0.22)
        }
    }

    // MARK: Space and radius (semantic names over the primitive scales)

    enum Space {
        static let xs = Prim.Space.s2
        static let sm = Prim.Space.s3
        static let md = Prim.Space.s4
        static let lg = Prim.Space.s6
        static let xl = Prim.Space.s7
    }

    enum Radius {
        /// Key caps, inline chips.
        static let xs = Prim.Radius.r1
        /// Buttons, fields, list rows.
        static let sm = Prim.Radius.r2
        /// Rows inside floats, cards.
        static let md = Prim.Radius.r3
        /// Toasts, menus, popovers.
        static let lg = Prim.Radius.r5
        /// The palette and dialogs.
        static let xl = Prim.Radius.r6

        /// The concentric inner radius for content inset by `padding`.
        static func inner(_ outer: CGFloat, padding: CGFloat) -> CGFloat { max(Prim.Radius.r1 - 2, outer - padding) }
    }

    // MARK: Type (SF; 500 marks "this one", 600 is for titles only)

    enum Font {
        static let caption = NSFont.systemFont(ofSize: Prim.Size.t2, weight: .regular)
        static let captionStrong = NSFont.systemFont(ofSize: Prim.Size.t2, weight: .medium)
        static let captionTitle = NSFont.systemFont(ofSize: Prim.Size.t2, weight: .semibold)
        static let meta = NSFont.monospacedDigitSystemFont(ofSize: Prim.Size.t2, weight: .regular)
        static let small = NSFont.systemFont(ofSize: Prim.Size.t3, weight: .regular)
        static let smallStrong = NSFont.systemFont(ofSize: Prim.Size.t3, weight: .medium)
        static let body = NSFont.systemFont(ofSize: Prim.Size.t4, weight: .regular)
        static let bodyStrong = NSFont.systemFont(ofSize: Prim.Size.t4, weight: .medium)
        static let title = NSFont.systemFont(ofSize: Prim.Size.t4, weight: .semibold)
        static let field = NSFont.systemFont(ofSize: Prim.Size.t6, weight: .regular)
        static let keycap = NSFont.systemFont(ofSize: Prim.Size.t2, weight: .medium)
        /// List section headers (palette): 11 semibold.
        static let section = NSFont.systemFont(ofSize: Prim.Size.t2, weight: .semibold)
        /// Menu-style shortcut text (`⌘1`, `⇧⌘N`): tabular digits so columns align.
        static let shortcut = NSFont.monospacedDigitSystemFont(ofSize: Prim.Size.t3, weight: .regular)
        static let terminalSize: CGFloat = 13
        static let terminalRange: ClosedRange<CGFloat> = 9 ... 24

        /// The terminal face: `family` when it is installed, else SF Mono.
        static func terminal(size: CGFloat, family: String = "") -> NSFont {
            if !family.isEmpty, let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
                return f
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }

        static func terminalBold(size: CGFloat, family: String = "") -> NSFont {
            if !family.isEmpty {
                let fm = NSFontManager.shared
                if let f = fm.font(withFamily: family, traits: .boldFontMask, weight: 9, size: size),
                   fm.traits(of: f).contains(.boldFontMask) {
                    return f
                }
                // No bold face: the renderer emboldens the regular one.
                return terminal(size: size, family: family)
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        }

        /// Installed fixed-pitch families, by name (the system's own first).
        static var monospacedFamilies: [String] {
            let fm = NSFontManager.shared
            return fm.availableFontFamilies.filter { fam in
                guard !fam.hasPrefix("."), let f = fm.font(withFamily: fam, traits: [], weight: 5, size: 13) else { return false }
                return f.isFixedPitch || fm.traits(of: f).contains(.fixedPitchFontMask)
            }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    // MARK: Component metrics (layer 3)

    enum Metric {
        // Window and shell
        static let windowDefault = NSSize(width: 1180, height: 760)
        static let windowMin = NSSize(width: 720, height: 440)
        static let bandHeight: CGFloat = 40
        static let sidebarWidth: CGFloat = 248
        static let sidebarMin: CGFloat = 200
        static let sidebarMax: CGFloat = 360

        // Controls
        static let controlSmall: CGFloat = 22
        static let control: CGFloat = 28
        static let controlLarge: CGFloat = 32
        static let iconButton: CGFloat = 28
        static let iconGlyph: CGFloat = 14
        static let chipHeight: CGFloat = 22
        static let keycapHeight: CGFloat = 18

        // Sidebar
        static let statusSlot: CGFloat = 16
        static let dot: CGFloat = 7
        static let footerHeight: CGFloat = 36

        // Panes
        // Terminal text inset inside a pane (Ghostty/Terminal/Otty range; leftover
        // rows fall to the bottom, never the top).
        // 14 / 10 / 8 clears the sheet's corner curve.
        static let panePaddingX: CGFloat = 14
        static let panePaddingTop: CGFloat = 10
        static let panePaddingBottom: CGFloat = 8
        /// Each pane is a sheet set in the frame: radius 10 at a 6 pt inset keeps
        /// it concentric with the ~16 pt window corner (Dia's geometry; Codex's
        /// card is 12 at 4, Claude insets 8).
        static let sheetRadius: CGFloat = 10
        static let sheetInset: CGFloat = 6
        /// The frame showing between split sheets; nothing is drawn in it at rest.
        static let dividerVisible: CGFloat = 6
        static let dividerHit: CGFloat = 9
        static let paneMin = CGSize(width: 160, height: 100)

        // Palette: radius 14 = padding 6 + row radius 8 (concentric).
        static let paletteWidth: CGFloat = 600
        static let paletteMinWidth: CGFloat = 420
        /// Gap below the band.
        static let paletteTop: CGFloat = 80
        /// The list area kept for "no matches" (and the minimum list).
        static let paletteEmptyHeight: CGFloat = 64
        static let paletteRadius = Radius.xl
        static let palettePadding = Space.sm
        static let paletteFieldHeight: CGFloat = 48
        static let paletteRow: CGFloat = 34
        static let paletteRowRadius = Radius.inner(Radius.xl, padding: Space.sm)
        static let paletteSectionHeight: CGFloat = 26
        static let paletteMaxRows = 9

        // Toasts
        static let toastWidth: CGFloat = 340
        static let toastRadius = Prim.Radius.r4
        static let toastGap = Space.md
        static let toastMax = 3

        // Tooltip
        static let tooltipRadius = Radius.sm
    }

    // MARK: Elevation

    enum Elevation {
        /// Flat: on the plane, no ring. Rest: cards and segmented thumbs.
        /// Float: palette, toasts, popovers, tooltips.
        case flat, rest, float
    }

    // MARK: Motion — chosen by frequency; exits one step faster than entrances.

    enum Motion {
        /// A spring from the ladder. Critically damped when `bounce` is 0.
        struct Spring: Sendable {
            let response: Double
            let bounce: Double

            /// Runs until it settles (a spring's duration is not its response).
            func animation(_ keyPath: String) -> CASpringAnimation {
                let a = CASpringAnimation(perceptualDuration: response, bounce: bounce)
                a.keyPath = keyPath
                a.duration = a.settlingDuration
                return a
            }

            /// For `NSAnimationContext.animate(_:changes:)` (true springs on view properties).
            var swiftUI: SwiftUI.Animation { .spring(duration: response, bounce: bounce) }

            /// Progress 0→1 at `t` seconds from rest (overshoots when bouncy).
            func value(at t: Double) -> Double {
                guard t > 0 else { return 0 }
                let w0 = 2 * Double.pi / response
                let zeta = 1 - bounce
                if zeta >= 1 { return 1 - (1 + w0 * t) * exp(-w0 * t) }
                let wd = w0 * (1 - zeta * zeta).squareRoot()
                return 1 - exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
            }

            /// Time after which the motion is within 0.1 % of rest.
            var settleTime: Double {
                var t = 0.0, quiet = 0.0
                while t < 4 {
                    t += 1.0 / 240
                    quiet = abs(1 - value(at: t)) < 0.001 ? quiet + 1.0 / 240 : 0
                    if quiet > 0.05 { return t }
                }
                return t
            }
        }

        /// A timed beat: duration plus curve, for colour, opacity and small moves.
        struct Beat: Sendable {
            let duration: Double
            let curve: CAMediaTimingFunction

            func animation(_ keyPath: String) -> CABasicAnimation {
                let a = CABasicAnimation(keyPath: keyPath)
                a.duration = reduced ? min(duration, 0.1) : duration
                a.timingFunction = curve
                return a
            }
        }

        nonisolated(unsafe) static let easeOut = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        nonisolated(unsafe) static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        nonisolated(unsafe) static let standardCurve = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)

        /// Colour and opacity (hover out, state changes).
        static let tick = Beat(duration: 0.15, curve: standardCurve)
        static let tickOut = Beat(duration: 0.10, curve: standardCurve)
        /// Pointer-opened popovers, toasts, the palette: a short rise.
        static let swift = Beat(duration: 0.20, curve: easeOut)
        /// Layout: panes, folds.
        static let glide = Beat(duration: 0.26, curve: easeOut)
        /// A surface the person summoned (palette, menu): in from 98 %, 4 pt off.
        static let rise = Beat(duration: 0.16, curve: easeOut)
        /// One turn of a working spinner.
        static let spin: CFTimeInterval = 0.9

        static let snap = Spring(response: 0.25, bounce: 0)
        static let standard = Spring(response: 0.35, bounce: 0)
        static let panel = Spring(response: 0.40, bounce: 0)
        static let pop = Spring(response: 0.30, bounce: 0.10)

        /// Legacy names (fade beats) kept for terminal/pane fades.
        static let fadeIn = (duration: swift.duration * 0.8, curve: easeOut)
        static let fadeOut = (duration: tickOut.duration + 0.02, curve: easeIn)

        static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// Animates animator-proxy changes with a true spring (instantly under Reduce Motion).
        static func animate(_ spring: Spring, _ changes: () -> Void, completion: (() -> Void)? = nil) {
            guard !reduced else {
                changes()
                completion?()
                return
            }
            NSAnimationContext.animate(spring.swiftUI, changes: changes, completion: completion)
        }

        /// Animator-proxy changes on a beat.
        static func run(_ beat: Beat, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
            NSAnimationContext.beginGrouping()
            let ctx = NSAnimationContext.current
            ctx.duration = reduced ? min(beat.duration, 0.1) : beat.duration
            ctx.timingFunction = beat.curve
            ctx.allowsImplicitAnimation = true
            if let completion { ctx.completionHandler = { MainActor.assumeIsolated { completion() } } }
            changes()
            NSAnimationContext.endGrouping()
        }

        static func fade(in: Bool, _ changes: () -> Void, completion: (@MainActor @Sendable () -> Void)? = nil) {
            run(`in` ? swift : tickOut, changes, completion: completion)
        }

        /// Brings in a summoned surface on `rise`: it fades up while growing
        /// from 98 % about its top edge at `anchorX` (where it came from),
        /// settling the last 4 pt. Under Reduce Motion, the fade alone.
        static func rise(_ view: NSView, anchorX: CGFloat) {
            view.alphaValue = 0
            run(rise) { view.animator().alphaValue = 1 }
            guard !reduced, let layer = view.layer else { return }
            let top = layer.bounds.minY
            var t = CATransform3DMakeTranslation(anchorX, top, 0)
            t = CATransform3DScale(t, 0.98, 0.98, 1)
            t = CATransform3DTranslate(t, -anchorX, -top - 4, 0)
            let a = rise.animation("transform")
            a.fromValue = t
            a.toValue = CATransform3DIdentity
            layer.add(a, forKey: "rise")
        }

        /// Runs layer changes without implicit animations.
        static func still(_ changes: () -> Void) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            changes()
            CATransaction.commit()
        }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension NSView {
    /// One device pixel in points.
    var hairline: CGFloat { 1 / max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }

    /// The design tokens for this view's appearance.
    var tokens: DesignTokens { DesignTokens.current(dark: effectiveAppearance.isDark) }
}
