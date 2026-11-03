import AppKit

/// A project's mark: a filled folder in the secondary ink, no plate. A
/// letter on a coloured squircle is every workspace switcher's avatar; the
/// folder says what a project is here (a directory on some Mac). It takes no
/// accent: those say a program's state (cyan working, green done, yellow
/// waiting, red failed), and a 14 pt folder in one of them drowns the 6 pt
/// badge beside it. Sized to the view's side: 20 in the sidebar, 16 in the
/// band and menus.
final class ProjectTile: NSView {
    private let glyph = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.imageScaling = .scaleNone
        glyph.contentTintColor = Axo.Color.textSecondary
        addSubview(glyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
    static let menuImage: NSImage = {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            guard let base = symbol(side: 16) else { return false }
            let tinted = NSImage(size: base.size, flipped: false) { b in
                base.draw(in: b)
                Axo.Color.textSecondary.set()
                b.fill(using: .sourceAtop)
                return true
            }
            let s = tinted.size
            tinted.draw(in: NSRect(x: ((r.width - s.width) / 2).rounded(), y: ((r.height - s.height) / 2).rounded(),
                                   width: s.width, height: s.height))
            return true
        }
    }()
}
