import AppKit
import AxModel

/// A project's identity colour: one of Dracula Pro's own accents (Alucard's
/// in light), picked by a stable hash of the project root, so a project keeps
/// its colour across launches, machines and clients.
///
/// Yellow and red stay out: they say "waiting" and "failed" everywhere else.
/// Cyan and green also mean working and done, but only as a spinner or a dot
/// on a program's icon, never as a folder, so the two never meet.
nonisolated enum ProjectHue {
    /// Purple, pink, orange, cyan, green.
    static let night = ["#9580FF", "#FF80BF", "#FFCA80", "#80FFEA", "#8AFF80"]
    static let day = ["#644AC9", "#A3144D", "#A34D14", "#036A96", "#14710A"]

    static func index(for key: String) -> Int {
        // FNV-1a: stable across runs (Swift's Hasher is seeded per process).
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01B3
        }
        return Int(h % UInt64(night.count))
    }

    /// The project's colour for `key` in the given appearance.
    static func ink(_ key: String, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let c = RGB(hex: (dark ? night : day)[index(for: key)])!
        return (Double(c.r) / 255, Double(c.g) / 255, Double(c.b) / 255)
    }

    /// A dynamic NSColor for the project's mark.
    @MainActor static func color(_ key: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = ink(key, dark: appearance.isDark)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }
}

/// A project's mark: a filled folder in the project's colour, no plate.
/// A letter on a coloured squircle is every workspace switcher's avatar;
/// the folder says what a project is here (a directory on some Mac), and
/// its colour says which one. Sized to the view's side: 20 in the sidebar,
/// 16 in the band and menus.
final class ProjectTile: NSView {
    private let glyph = NSImageView()
    private var key = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(name: String, key: String) {
        guard key != self.key else { return }
        self.key = key
        glyph.contentTintColor = ProjectHue.color(key)
    }

    static func symbol(side: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: (side * 0.72).rounded(), weight: .regular))
    }

    override func layout() {
        super.layout()
        if glyph.image?.size.width != Self.symbol(side: bounds.height)?.size.width {
            glyph.image = Self.symbol(side: bounds.height)
        }
        // Centred on whole points, so its edges stay crisp at 1x.
        let s = glyph.image?.size ?? .zero
        glyph.frame = NSRect(x: ((bounds.width - s.width) / 2).rounded(), y: ((bounds.height - s.height) / 2).rounded(),
                             width: s.width, height: s.height)
    }

    /// The mark as a menu image (16 pt), resolved when the menu draws it.
    static func image(name: String, key: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let dark = NSAppearance.currentDrawing().isDark
            let c = ProjectHue.ink(key, dark: dark)
            guard let base = symbol(side: 16) else { return false }
            let tinted = NSImage(size: base.size, flipped: false) { b in
                base.draw(in: b)
                NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).set()
                b.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            tinted.draw(in: NSRect(x: ((r.width - s.width) / 2).rounded(), y: ((r.height - s.height) / 2).rounded(),
                                   width: s.width, height: s.height))
            return true
        }
    }
}
