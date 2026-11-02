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

    public static let night = TerminalTheme(
        name: "Axolotty Night",
        background: RGB(hex: "#151214")!, foreground: RGB(hex: "#EBE6EA")!,
        cursor: RGB(hex: "#DE7BCF")!, cursorText: RGB(hex: "#151214")!,
        selectionBackground: RGB(hex: "#433140")!, selectionForeground: nil,
        ansi: hex([
            "#393438", "#EF7E7C", "#6CC581", "#E4C062", "#6FA7EE", "#DF88D0", "#5DCBD1", "#D4CFD3",
            "#857E83", "#FDA19E", "#8FE1A1", "#F5D983", "#92C1FD", "#F3A7E5", "#85E3E8", "#F7F4F6",
        ]))

    public static let day = TerminalTheme(
        name: "Axolotty Day",
        background: RGB(hex: "#FCF9FB")!, foreground: RGB(hex: "#2A2429")!,
        cursor: RGB(hex: "#BF4AB0")!, cursorText: RGB(hex: "#FCF9FB")!,
        selectionBackground: RGB(hex: "#F0D9EB")!, selectionForeground: nil,
        ansi: hex([
            "#2A2429", "#C13C3B", "#11813C", "#9A6A17", "#226BC0", "#AB3E9D", "#208089", "#D3CFD3",
            "#797277", "#A92227", "#067132", "#875814", "#1654A9", "#912C86", "#176A72", "#EDEAEC",
        ]))
}

/// Brand and state colours shared by every UI (design spec §2.2).
public enum Palette {
    public static func activity(_ a: Activity, dark: Bool) -> RGB? {
        switch a {
        case .idle: nil
        case .working: RGB(hex: dark ? "#DE7BCF" : "#B24CA5")
        case .blocked: RGB(hex: dark ? "#F5AE39" : "#CA8000")
        case .done: RGB(hex: dark ? "#55C975" : "#00943E")
        case .error: RGB(hex: dark ? "#EA6A64" : "#C43F3E")
        }
    }

    public static func accent(dark: Bool) -> RGB { RGB(hex: dark ? "#DE7BCF" : "#B24CA5")! }
}
