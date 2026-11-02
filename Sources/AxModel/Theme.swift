import Foundation

/// An 8-bit sRGB colour. Pure data so the model stays platform-free.
public struct RGB: Hashable, Codable, Sendable, CustomStringConvertible {
    public var r, g, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses `#rrggbb` or `rrggbb`.
    public init?(hex: String) {
        let s = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    public var hex: String {
        let digits = Array("0123456789abcdef")
        return "#" + [r, g, b].map { String([digits[Int($0 >> 4)], digits[Int($0 & 0xF)]]) }.joined()
    }

    public var description: String { hex }

    /// RGBA8 with R in the lowest byte (the GPU instance format).
    public var packed: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | 0xFF00_0000 }

    /// WCAG relative luminance.
    public var luminance: Double {
        func lin(_ c: UInt8) -> Double {
            let s = Double(c) / 255
            return s <= 0.04045 ? s / 12.92 : Foundation.pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public func contrast(with other: RGB) -> Double {
        let a = luminance, b = other.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// From HSL (degrees, 0…1, 0…1).
    public init(h: Double, s: Double, l: Double) {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        func q(_ v: Double) -> UInt8 { UInt8(max(0, min(255, ((v + m) * 255).rounded()))) }
        self.init(q(r1), q(g1), q(b1))
    }

    /// Hue (degrees), saturation and lightness (0…1).
    public var hsl: (h: Double, s: Double, l: Double) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let mx = max(rf, gf, bf), mn = min(rf, gf, bf), d = mx - mn
        let l = (mx + mn) / 2
        guard d > 0 else { return (0, 0, l) }
        let s = d / (1 - abs(2 * l - 1))
        var h: Double = switch mx {
        case rf: 60 * ((gf - bf) / d).truncatingRemainder(dividingBy: 6)
        case gf: 60 * ((bf - rf) / d + 2)
        default: 60 * ((rf - gf) / d + 4)
        }
        if h < 0 { h += 360 }
        return (h, s, l)
    }

    /// The same hue and saturation at lightness `l`.
    public func lightness(_ l: Double) -> RGB {
        let c = hsl
        return RGB(h: c.h, s: c.s, l: l)
    }

    /// Linear interpolation in sRGB (good enough for washes and dims).
    public func mix(_ other: RGB, _ t: Double) -> RGB {
        func m(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGB(m(r, other.r), m(g, other.g), m(b, other.b))
    }
}

/// A terminal colour theme (Ghostty-compatible keys).
public struct TerminalTheme: Hashable, Codable, Sendable {
    public var name: String
    public var background: RGB
    public var foreground: RGB
    public var cursor: RGB
    public var cursorText: RGB
    public var selectionBackground: RGB
    /// nil: keep each cell's own foreground on selection.
    public var selectionForeground: RGB?
    /// ANSI 0–15.
    public var ansi: [RGB]

    public var isDark: Bool { background.luminance < 0.5 }

    /// The full 256-colour palette: ANSI 16 + the xterm 6×6×6 cube + 24 greys.
    public var palette256: [RGB] {
        var p = ansi
        let steps: [UInt8] = [0, 95, 135, 175, 215, 255]
        for r in steps { for g in steps { for b in steps { p.append(RGB(r, g, b)) } } }
        for i in 0 ..< 24 {
            let v = UInt8(8 + i * 10)
            p.append(RGB(v, v, v))
        }
        return p
    }

    private static func hex(_ s: [String]) -> [RGB] { s.map { RGB(hex: $0)! } }

    // Night and Day are built the way Dracula Pro is (Dracula, MIT): every
    // accent is HSL at saturation 100 and lightness 75 on Dracula's hues,
    // brights at lightness 80, and the grounds a ramp at hue 248 with
    // saturation 15. Day takes Alucard's accents from the public spec on a
    // white sheet, which carries red and yellow past AA. ANSI 0 and 8 are the
    // selection and comment tones, so black text and bright-black hints stay
    // visible on the ground.
    public static let night = TerminalTheme(
        name: "Axolotty Night",
        background: RGB(hex: "#22212C")!, foreground: RGB(hex: "#F8F8F2")!,
        cursor: RGB(hex: "#9580FF")!, cursorText: RGB(hex: "#22212C")!,
        selectionBackground: RGB(hex: "#454158")!, selectionForeground: nil,
        ansi: hex([
            "#454158", "#FF9580", "#8AFF80", "#FFFF80", "#9580FF", "#FF80BF", "#80FFEA", "#F8F8F2",
            "#7970A9", "#FFAA99", "#A2FF99", "#FFFF99", "#AA99FF", "#FF99CC", "#99FFEE", "#FFFFFF",
        ]))

    public static let day = TerminalTheme(
        name: "Axolotty Day",
        background: RGB(hex: "#FFFFFF")!, foreground: RGB(hex: "#1F1F1F")!,
        cursor: RGB(hex: "#644AC9")!, cursorText: RGB(hex: "#FFFFFF")!,
        selectionBackground: RGB(hex: "#DBD6ED")!, selectionForeground: nil,
        ansi: hex([
            "#1F1F1F", "#CB3A2A", "#14710A", "#846E15", "#644AC9", "#A3144D", "#036A96", "#CFCFDE",
            "#635D97", "#D74C3D", "#198D0C", "#9E841A", "#7862D0", "#BF185A", "#047FB4", "#E6E6E6",
        ]))
}

/// Brand and state colours shared by every UI (design spec §2.2).
public enum Palette {
    public static func activity(_ a: Activity, dark: Bool) -> RGB? {
        switch a {
        case .idle: nil
        case .working: RGB(hex: dark ? "#80FFEA" : "#036A96")
        case .blocked: RGB(hex: dark ? "#FFFF80" : "#846E15")
        case .done: RGB(hex: dark ? "#8AFF80" : "#14710A")
        case .error: RGB(hex: dark ? "#FF9580" : "#CB3A2A")
        }
    }

    /// Focus, the caret, links, the primary action: Dracula's purple.
    public static func accent(dark: Bool) -> RGB { RGB(hex: dark ? "#9580FF" : "#644AC9")! }

    /// The mark's own colour (the axolotl is pink); never chrome.
    public static func brand(dark: Bool) -> RGB { RGB(hex: dark ? "#FF80BF" : "#BF185A")! }
}
