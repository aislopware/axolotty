import AppKit
import AxModel
import AxRender
import QuartzCore

/// What a pane is running, as one SF Symbol and an optional tint. Agents get
/// their own mark (brand-tinted only where the brand colour is part of how
/// people recognise it); everything else is neutral ink, grouped by kind so
/// the column reads at a glance: shell, editor, git, build, server, data, docs.
nonisolated struct ProgramIdentity: Equatable {
    var symbol: String
    /// sRGB tint; nil = the row's ink.
    var tint: RGB?
    /// A vendor mark drawn from its own vectors ("claude", "codex", "gemini");
    /// wins over `symbol`.
    var brand: String?

    init(symbol: String, tint: RGB? = nil, brand: String? = nil) {
        self.symbol = symbol
        self.tint = tint
        self.brand = brand
    }

    /// The title a row shows next to this icon: what the icon already says is
    /// not said again. Agents paint their own state into the terminal title
    /// ("✳ Fix login", a braille spinner) and often lead with their name
    /// ("Codex · Fix login"); the badge and the vendor mark carry both. The
    /// full title stays in the hover card and VoiceOver, and still finds the row in the palette.
    func rowTitle(_ full: String) -> String {
        let names: [String] = switch brand {
        case "claude": ["claude code", "claude"]
        case "codex": ["openai codex", "codex"]
        case "gemini": ["gemini cli", "gemini"]
        default: []
        }
        return brand == nil ? full : AgentTitle.trimmed(full, names: names)
    }

    var mark: BrandMark? {
        switch brand {
        case "claude": .claude
        case "codex": .codex
        case "gemini": .gemini
        default: nil
        }
    }

    static let shell = ProgramIdentity(symbol: "terminal", tint: nil)

    /// `program` is the foreground basename; `app` the name an agent reported
    /// through the status protocol (wins when the agent runs under node/bun).
    static func of(agent: AgentKind?, app: String, program: String) -> ProgramIdentity {
        if let a = agent ?? AgentKind(statusApp: app) { return of(a) }
        return of(program: program.lowercased())
    }

    static func of(_ a: AgentKind) -> ProgramIdentity {
        switch a {
        case .claude: ProgramIdentity(symbol: "asterisk", brand: "claude")
        case .gemini: ProgramIdentity(symbol: "sparkle", brand: "gemini")
        case .codex: ProgramIdentity(symbol: "hexagon", brand: "codex")
        case .cursor: ProgramIdentity(symbol: "cube", tint: nil)
        case .amp: ProgramIdentity(symbol: "bolt", tint: nil)
        case .aider: ProgramIdentity(symbol: "wand.and.sparkles", tint: nil)
        case .goose: ProgramIdentity(symbol: "bird", tint: nil)
        case .opencode, .crush: ProgramIdentity(symbol: "curlybraces", tint: nil)
        default: ProgramIdentity(symbol: "sparkles", tint: nil)
        }
    }

    static func of(program p: String) -> ProgramIdentity {
        let kinds: [(Set<String>, String)] = [
            (["nvim", "vim", "vi", "hx", "helix", "nano", "emacs", "micro", "kak"], "pencil.line"),
            (["git", "lazygit", "tig", "gitui", "gh", "jj"], "arrow.triangle.branch"),
            (["ssh", "mosh", "et", "telnet"], "network"),
            (["htop", "btop", "top", "glances", "bottom", "btm"], "gauge.with.dots.needle.33percent"),
            (["node", "bun", "deno", "npm", "pnpm", "yarn", "npx", "bunx"], "shippingbox"),
            (["python", "python3", "ipython", "uv", "ruby", "irb", "lua", "ghci", "iex"],
             "chevron.left.forwardslash.chevron.right"),
            (["swift", "cargo", "make", "just", "go", "xcodebuild", "zig", "cmake", "ninja", "gradle", "mvn"], "hammer"),
            (["docker", "podman", "kubectl", "k9s", "helm"], "cube"),
            (["psql", "mysql", "sqlite3", "redis-cli", "mongosh", "duckdb", "pgcli"], "cylinder"),
            (["less", "man", "bat", "more", "glow"], "book"),
            (["tail", "journalctl", "stern", "lnav"], "doc.text"),
        ]
        for (names, symbol) in kinds where names.contains(p) { return ProgramIdentity(symbol: symbol, tint: nil) }
        return .shell
    }
}

extension HostState {
    /// The pane that speaks for a session's icon: the most urgent agent pane,
    /// else the focused pane.
    func identityPane(of sid: SessionID) -> PaneInfo? {
        let mine = panes(of: sid)
        let agents = mine.filter { $0.agent != nil || !($0.status.headline?.app.isEmpty ?? true) }
        if let a = agents.max(by: { $0.activity < $1.activity }) { return a }
        return sessions[sid].flatMap { panes[$0.focus] } ?? mine.first
    }

    func identity(of sid: SessionID) -> ProgramIdentity {
        guard let p = identityPane(of: sid) else { return .shell }
        let app = p.status.headline.map { p.status.app(of: $0.id) } ?? ""
        return ProgramIdentity.of(agent: p.agent, app: app, program: p.program)
    }
}

/// A session's icon (16 pt slot): the program's glyph, with its state on it.
///
/// All state is a badge at the lower right (whole pixels at 1×), cut out of
/// the glyph with a 1 pt moat so it reads on any plate, and the glyph itself
/// never changes: the agent stays recognisable while it works. Dots are 6 pt
/// so a 14 pt vendor mark keeps three quarters of itself.
///
/// - working: an 8 pt magenta spinner (2 pt arc over a 28 % track, 0.9 s a
///   turn), or a determinate arc when the program reports progress
/// - waiting: amber dot · failed: red dot · done-unseen: green dot
/// - marked unread (and otherwise idle): an accent dot
/// - idle: the glyph alone
///
/// SF Symbols draw in the row's ink; vendor marks (Claude, Codex, Gemini) draw
/// from their own vectors and colours at 14/16 of the slot, the optical size
/// at which a filled mark matches a 12 pt medium symbol.
final class ProgramIcon: NSView {
    private let host = NSView()
    private let image = NSImageView()
    private let brand = CALayer()
    private let badge = CALayer()
    private let track = CAShapeLayer().crisp()
    private let arc = CAShapeLayer().crisp()
    private let cut = CAShapeLayer().crisp()

    var identity = ProgramIdentity.shell { didSet { if identity != oldValue { rebuildBrand(); restyle() } } }
    var activity: Activity = .idle { didSet { if activity != oldValue { restyle() } } }
    /// "Mark as Unread": a dot in the accent while nothing else claims the badge.
    var unread = false { didSet { if unread != oldValue { restyle() } } }
    /// Determinate progress (0…1) turns the spinner into an arc.
    var progress: Double? { didSet { if progress != oldValue { restyle() } } }

    /// Lit rows (selected, hovered) take full ink; rest rows the secondary ink.
    var lit = false { didSet { if lit != oldValue { restyle() } } }
    var glyphSize: CGFloat = 12 { didSet { if glyphSize != oldValue { restyle() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        host.wantsLayer = true
        image.imageScaling = .scaleNone
        host.addSubview(image)
        host.layer?.addSublayer(brand)
        addSubview(host)
        layer?.addSublayer(badge)
        for l in [track, arc] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineWidth = 2
            layer?.addSublayer(l)
        }
        cut.fillRule = .evenOdd
        setAccessibilityElement(false)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private var badged: Bool { activity != .idle || unread }
    private var spinning: Bool { activity == .working }

    /// Rebuilds the vendor mark's layers (path + fills) for the current size.
    private func rebuildBrand() {
        brand.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let mark = identity.mark, let path = mark.path else { return }
        let side = (glyphSize + 2).rounded()  // 14 in a 16 slot
        let k = side / 24
        // Layer space is y-up; the mark is y-down.
        var t = CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: 0, ty: side)
        guard let scaled = path.copy(using: &t) else { return }
        let rule: CAShapeLayerFillRule = mark.evenOdd ? .evenOdd : .nonZero
        brand.frame = CGRect(x: 0, y: 0, width: side, height: side)
        for fill in mark.fills {
            let shape = CAShapeLayer().crisp()
            shape.frame = brand.bounds
            shape.path = scaled
            shape.fillRule = rule
            switch fill {
            case let .solid(c):
                shape.fillColor = CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
                brand.addSublayer(shape)
            case let .linear(from, to, stops):
                let g = CAGradientLayer().crisp()
                g.frame = brand.bounds
                g.type = .axial
                g.startPoint = CGPoint(x: from.x / 24, y: 1 - from.y / 24)
                g.endPoint = CGPoint(x: to.x / 24, y: 1 - to.y / 24)
                g.colors = stops.map { CGColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a) }
                g.locations = stops.map { NSNumber(value: Double($0.offset)) }
                shape.fillColor = CGColor.black
                g.mask = shape
                brand.addSublayer(g)
            }
        }
        needsLayout = true
    }

    private func restyle() {
        let isBrand = identity.mark != nil
        if !isBrand {
            image.image = NSImage(systemSymbolName: identity.symbol, accessibilityDescription: nil)
            image.symbolConfiguration = .init(pointSize: glyphSize, weight: .medium)
            if let t = identity.tint {
                image.contentTintColor = NSColor(srgbRed: CGFloat(t.r) / 255, green: CGFloat(t.g) / 255, blue: CGFloat(t.b) / 255,
                                                 alpha: lit ? 1 : 0.88)
            } else {
                image.contentTintColor = lit ? Axo.Color.text : Axo.Color.textSecondary
            }
        } else if (brand.sublayers ?? []).isEmpty || abs(brand.bounds.width - (glyphSize + 2).rounded()) > 0.5 {
            rebuildBrand()
        }
        image.isHidden = isBrand
        Axo.Motion.still {
            brand.isHidden = !isBrand
            brand.opacity = lit ? 1 : 0.92
            badge.isHidden = !badged || spinning
            if badged, !spinning {
                badge.backgroundColor = effectiveAppearance.resolve(
                    activity == .idle ? Axo.Color.accent : StatusGlyphView.dotColor(activity))
            }
            track.isHidden = !spinning
            arc.isHidden = !spinning
            track.strokeColor = effectiveAppearance.resolve(Axo.Color.status(.working).withAlphaComponent(0.28))
            arc.strokeColor = effectiveAppearance.resolve(Axo.Color.status(.working))
            arc.removeAnimation(forKey: "spin")
            arc.strokeStart = 0
            if let p = progress {
                arc.strokeEnd = max(0.06, min(1, p))
            } else {
                arc.strokeEnd = 0.35
                if spinning, !Axo.Motion.reduced {
                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = 2 * Double.pi
                    spin.duration = 0.9
                    spin.repeatCount = .infinity
                    spin.isRemovedOnCompletion = false
                    arc.add(spin, forKey: "spin")
                }
            }
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        host.frame = b
        image.frame = host.bounds
        // Whole pixels at the lower right corner of the 16 slot: dot 6, spinner 8.
        let d: CGFloat = spinning ? 8 : 6
        let f = CGRect(x: b.maxX - d, y: b.maxY - d, width: d, height: d)
        Axo.Motion.still {
            let side = brand.bounds.width
            // Centred, on whole points (host layer is y-up).
            brand.frame.origin = CGPoint(x: ((b.width - side) / 2).rounded(), y: ((b.height - side) / 2).rounded())
            badge.frame = f
            badge.cornerRadius = d / 2
            // The spinner rings the same disc; it starts at 12 o'clock.
            let ring = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d).insetBy(dx: 1, dy: 1), transform: nil)
            for l in [track, arc] {
                l.bounds = CGRect(x: 0, y: 0, width: d, height: d)
                l.position = CGPoint(x: f.midX, y: f.midY)
                l.path = ring
            }
            arc.setAffineTransform(arc.animation(forKey: "spin") == nil ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity)
            if badged {
                // Knock a 1 pt moat out of the mark around the badge.
                let p = CGMutablePath()
                p.addRect(host.bounds.insetBy(dx: -4, dy: -4))
                let moat = f.insetBy(dx: -1, dy: -1)
                p.addEllipse(in: CGRect(x: moat.minX, y: b.height - moat.maxY, width: moat.width, height: moat.height))
                cut.path = p
                cut.frame = host.bounds
                host.layer?.mask = cut
            } else {
                host.layer?.mask = nil
            }
        }
    }
}
