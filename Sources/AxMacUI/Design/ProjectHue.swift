import AppKit

/// A project's identity colour: one of six hues at a fixed OKLCH lightness
/// and chroma, so no project is louder than another (a plain HSL wheel makes
/// yellow glow and blue sink). Picked by a stable hash of the project root, so
/// a project keeps its colour across launches, machines and clients.
///
/// The hues keep out of the arcs that already mean something: red (failed),
/// amber (waiting) and the magenta accent. Chroma is held low so a tile reads
/// as identity, never as state.
///
/// - ink (text in the hue): L 0.78 C 0.09 dark, L 0.52 C 0.10 light
/// - tile (a solid mark): L 0.72 C 0.12 dark, L 0.56 C 0.13 light. At these
///   values the six tiles sit 20+ RGB units apart, so two projects are told
///   apart at 1× (the old 22 % wash left them 8 apart, which is noise).
nonisolated enum ProjectHue {
    /// Hue angles (OKLCH degrees): olive, green, teal, cyan, blue, indigo.
    static let hues: [Double] = [105, 150, 190, 220, 245, 280]

    static func index(for key: String) -> Int {
        // FNV-1a: stable across runs (Swift's Hasher is seeded per process).
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01B3
        }
        return Int(h % UInt64(hues.count))
    }

    /// The glyph colour (full strength) for `key` in the given appearance.
    static func ink(_ key: String, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let hue = hues[index(for: key)]
        return dark ? oklch(0.78, 0.09, hue) : oklch(0.52, 0.10, hue)
    }

    /// The solid tile colour for `key`.
    static func tile(_ key: String, dark: Bool) -> (r: Double, g: Double, b: Double) {
        let hue = hues[index(for: key)]
        return dark ? oklch(0.72, 0.12, hue) : oklch(0.56, 0.13, hue)
    }

    /// A dynamic NSColor for the glyph.
    @MainActor static func color(_ key: String) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = ink(key, dark: appearance.isDark)
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    /// OKLCH → gamma-encoded sRGB, clamped (Björn Ottosson's OKLab matrices).
    static func oklch(_ l: Double, _ c: Double, _ hDeg: Double) -> (r: Double, g: Double, b: Double) {
        let h = hDeg * .pi / 180
        let a = c * cos(h), bb = c * sin(h)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * bb
        let m_ = l - 0.1055613458 * a - 0.0638541728 * bb
        let s_ = l - 0.0894841775 * a - 1.2914855480 * bb
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let b = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func enc(_ x: Double) -> Double {
            let v = min(1, max(0, x))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return (enc(r), enc(g), enc(b))
    }
}

/// A project's mark: a solid squircle in the project's hue with its initial
/// knocked out in frame ink (or a folder glyph when the name has no letter).
/// 20 pt in the sidebar, where projects are the objects; 16 pt in the header.
/// Type and radius scale with the side.
///
/// The initial is drawn, not laid out as a label: a label centres its line
/// box, which carries descender space, so a capital sits a pixel high. Here
/// the ink bounds of the glyph are centred and snapped to device pixels.
final class ProjectTile: NSView {
    private let folder = Symbol("folder.fill", size: 9, weight: .semibold, color: Axo.Color.frame)
    private var font: NSFont { NSFont.systemFont(ofSize: (bounds.height * 0.6).rounded(), weight: .bold) }
    private var letter: String?
    private var key = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(folder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func set(name: String, key: String) {
        let l = name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() }
        guard l != letter || key != self.key else { return }
        self.key = key
        letter = l
        folder.isHidden = l != nil
        restyle()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
        needsDisplay = true
    }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        let c = ProjectHue.tile(key, dark: dark)
        Axo.Motion.still {
            // The fill is the view's own layer background, so the drawn
            // initial (the layer's contents) sits above it.
            layer?.backgroundColor = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
        }
    }

    override func layout() {
        super.layout()
        Axo.Motion.still {
            layer?.cornerRadius = (bounds.height * 0.28).rounded()
            layer?.cornerCurve = .continuous
        }
        folder.frame = bounds
        needsDisplay = true
    }

    /// The tile as a menu image (16 pt), resolved when the menu draws it.
    static func image(name: String, key: String) -> NSImage {
        let letter = name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
        return NSImage(size: NSSize(width: 16, height: 16), flipped: true) { r in
            let dark = (NSAppearance.currentDrawing()).isDark
            let c = ProjectHue.tile(key, dark: dark)
            NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4.5, yRadius: 4.5).fill()
            let font = NSFont.systemFont(ofSize: 10, weight: .bold)
            let s = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: Axo.Color.frame])
            let g = s.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
            let x = ((r.width - g.width) / 2 - g.minX).rounded()
            s.draw(with: NSRect(x: x, y: ((r.height + font.capHeight) / 2).rounded(), width: r.width, height: 0), options: [])
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let letter else { return }
        // Drawing runs under this view's appearance, so the dynamic colour resolves itself.
        let font = font
        let s = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: Axo.Color.frame])
        // Ink bounds in a y-up text space: origin is on the baseline.
        let g = s.boundingRect(with: .zero, options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
        let scale = window?.backingScaleFactor ?? LayerScale.current
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        // Horizontal: centre the glyph's ink. Vertical: centre the cap height,
        // so the baseline sits (side + cap) / 2 down from the top.
        let x = snap((bounds.width - g.width) / 2 - g.minX)
        let baseline = snap((bounds.height + font.capHeight) / 2)
        s.draw(with: NSRect(x: x, y: baseline, width: bounds.width, height: 0), options: [])
    }
}
