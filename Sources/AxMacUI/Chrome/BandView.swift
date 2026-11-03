import AppKit
import AxModel

/// The band: the header above the sheets, painted in frame ink. It says what
/// nothing else on screen says (design-system §1.3: the sidebar answers
/// *which*), so it changes with the sidebar:
///
///     sidebar open:                  ⑂ branch +12 −3              ◌ Working 4:12
///     sidebar hidden: [tile] project › [icon] title   ⑂ branch     ◌ Working 4:12
///     … on a far Mac: [⌨] MacBook Pro › [tile] project › [icon] title …
///
/// - With the sidebar open, the selected row already names the project and
///   the session, so the band starts on the terminal's text column with the
///   facts the row lacks: the git branch (12, tertiary) and the diff chip.
/// - With it hidden, the identity comes back in front: the project's 16 pt
///   tile and name (13 semibold, full ink), a compact chevron, the program
///   icon and the session title (13, secondary).
///   A session on another Mac starts with that Mac, as the sidebar's section
///   does: its kind of Mac and name (13, secondary), so the hidden sidebar
///   never leaves the person guessing where their keys go.
/// - Trailing, the state: working shows the dashed circle and the elapsed
///   time; waiting or failed show the chip with the agent's own words. One
///   cue per state.
///
/// No rule below and no fill of its own. Drags the window.
final class BandView: NSView {
    private let hostGlyph = Symbol("laptopcomputer", size: 11, weight: .medium, color: Axo.Color.textTertiary)
    private let hostName = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private let hostChevron = Symbol("chevron.compact.right", size: 10, weight: .semibold, color: Axo.Color.textTertiary)
    private let tile = ProjectTile()
    private let project = Label("", font: Axo.Font.title, color: Axo.Color.text)
    private let chevron = Symbol("chevron.compact.right", size: 10, weight: .semibold, color: Axo.Color.textTertiary)
    private let icon = ProgramIcon(frame: .zero)
    private let title = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private let branchGlyph = Symbol("arrow.triangle.branch", size: 10, weight: .medium, color: Axo.Color.textTertiary)
    private let branch = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    let diff = DiffChip()
    private let stateMark = StatusGlyphView(frame: .zero)
    private let elapsed = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    let chip = Chip()
    var leadingInset: CGFloat = 12 { didSet { needsLayout = true } }
    var trailingInset: CGFloat = 56 { didSet { needsLayout = true } }
    /// False while the sidebar shows the selected session (its row says it).
    var showsIdentity = true {
        didSet {
            guard showsIdentity != oldValue else { return }
            applyIdentity(animated: window != nil)
            needsLayout = true
        }
    }
    private var hasContext = false
    /// The session is on another Mac (its name leads the path).
    private var isFar = false

    private var activity: Activity = .idle
    private var since: Double = 0
    private var subagents = 0
    private var tick: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        diff.isHidden = true
        for v in [hostGlyph, hostName, hostChevron, tile, project, chevron, icon, title, branchGlyph, branch, diff, stateMark, elapsed, chip] as [NSView] {
            addSubview(v)
        }
        chip.isHidden = true
        title.lineBreakMode = .byTruncatingTail
        project.lineBreakMode = .byTruncatingTail
        hostName.lineBreakMode = .byTruncatingTail
        branch.lineBreakMode = .byTruncatingMiddle
        setPath(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit { tick?.invalidate() }

    override var mouseDownCanMoveWindow: Bool { true }
    override var isFlipped: Bool { true }

    struct Context {
        var project: String
        var session: String
        var identity: ProgramIdentity
        var activity: Activity
        /// When the session entered `activity` (seconds since 1970; 0 unknown).
        var since: Double
        var branch: String?
        /// Subagents working under the agent ("Working 4:12 · 2 subagents").
        var subagents = 0
        /// The Mac it runs on, when that is not this one: its name and SF Symbol.
        var host: (name: String, symbol: String)?
    }

    /// Shows a session's context, or the app name alone when nothing is open.
    func update(_ c: Context?, key: Bool) {
        isFar = c?.host != nil
        setPath(c)
        guard let c else { return }
        if let h = c.host {
            hostName.stringValue = h.name
            hostGlyph.image = NSImage(systemSymbolName: h.symbol, accessibilityDescription: nil)
            hostName.textColor = key ? Axo.Color.textSecondary : Axo.Color.textTertiary
        }
        project.stringValue = c.project
        icon.identity = c.identity
        icon.lit = key
        title.stringValue = c.session
        title.textColor = key ? Axo.Color.textSecondary : Axo.Color.textTertiary
        project.textColor = key ? Axo.Color.text : Axo.Color.textSecondary
        branch.stringValue = c.branch ?? ""
        for v in [branchGlyph, branch] as [NSView] { v.isHidden = (c.branch ?? "").isEmpty }
        activity = c.activity
        since = c.since
        subagents = c.subagents
        stateMark.activity = c.activity == .working ? .working : .idle
        let working = c.activity == .working
        stateMark.isHidden = !working
        elapsed.isHidden = !working
        refreshElapsed()
        if working, tick == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshElapsed() }
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !working {
            tick?.invalidate()
            tick = nil
        }
        needsLayout = true
    }

    private var farViews: [NSView] { [hostGlyph, hostName, hostChevron] }
    private var identityViews: [NSView] { (isFar ? farViews : []) + [tile, project, chevron, icon, title] }

    /// The path fades rather than pops when the sidebar comes and goes.
    private func applyIdentity(animated: Bool) {
        let on = hasContext && showsIdentity
        let views = identityViews
        if on { for v in views { v.isHidden = false } }
        // A path never laid out has nothing to fade: its views sit at zero size, where
        // their images spill past the band's top edge until the fade would end.
        guard animated, !Axo.Motion.reduced, on || !project.frame.isEmpty else {
            for v in views {
                v.alphaValue = 1
                v.isHidden = !on && hasContext
            }
            return
        }
        if on { for v in views { v.alphaValue = 0 } }
        NSAnimationContext.runAnimationGroup { ctx in
            let beat = on ? Axo.Motion.swift : Axo.Motion.tickOut
            ctx.duration = beat.duration
            ctx.timingFunction = beat.curve
            for v in views { v.animator().alphaValue = on ? 1 : 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                guard !(self.hasContext && self.showsIdentity) else { return }
                for v in views where self.hasContext {
                    v.isHidden = true
                    v.alphaValue = 1
                }
            }
        }
    }

    private func setPath(_ c: Context?) {
        let on = c != nil
        hasContext = on
        for v in [tile, chevron, icon, title] as [NSView] { v.isHidden = !on || !showsIdentity }
        for v in farViews { v.isHidden = !on || !showsIdentity || !isFar }
        project.isHidden = on && !showsIdentity
        if !on {
            project.stringValue = "Axolotty"
            project.textColor = Axo.Color.textSecondary
            for v in [branchGlyph, branch, diff, stateMark, elapsed] as [NSView] { v.isHidden = true }
            tick?.invalidate()
            tick = nil
            needsLayout = true
        }
    }

    /// A shell reports the resolved path (/private/tmp/…) of a place
    /// opened through its macOS link (/tmp/…): said the way it was opened.
    static func unlinked(_ p: String) -> String {
        for top in ["/private/tmp", "/private/var", "/private/etc"] where p == top || p.hasPrefix(top + "/") {
            return String(p.dropFirst("/private".count))
        }
        return p
    }

    static func abbreviate(_ path: String) -> String {
        let path = unlinked(path)
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "Working 4:12" (m:ss under an hour, h:mm:ss past it); "Working" alone
    /// while the start time is unknown.
    private func refreshElapsed() {
        guard activity == .working else { return }
        var text = "Working"
        if since > 0 {
            let s = max(0, Int(Date().timeIntervalSince1970 - since))
            let (h, m, sec) = (s / 3600, s / 60 % 60, s % 60)
            text += h > 0 ? String(format: " %d:%02d:%02d", h, m, sec) : String(format: " %d:%02d", m, sec)
        }
        if subagents > 0 { text += subagents == 1 ? " · 1 subagent" : " · \(subagents) subagents" }
        guard elapsed.stringValue != text else { return }
        let grew = text.count != elapsed.stringValue.count
        elapsed.stringValue = text
        if grew { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2

        // Trailing state cluster first: the path truncates against it.
        var right = bounds.width - trailingInset
        if !chip.isHidden {
            let c = chip.fittingSize
            chip.frame = NSRect(x: right - c.width, y: (mid - c.height / 2).rounded(), width: c.width, height: c.height)
            right = chip.frame.minX - Axo.Space.md
        } else if !elapsed.isHidden {
            let e = elapsed.intrinsicContentSize
            elapsed.frame = NSRect(x: right - ceil(e.width), y: (mid - e.height / 2).rounded(), width: ceil(e.width), height: e.height)
            stateMark.frame = NSRect(x: elapsed.frame.minX - Axo.Space.xs - 16, y: (mid - 8).rounded(), width: 16, height: 16)
            right = stateMark.frame.minX - Axo.Space.md
        }

        var x = leadingInset
        if hasContext, !showsIdentity {
            layoutFacts(from: x - Axo.Space.lg, right: right)
            return
        }
        if !hostName.isHidden {
            x = centre(hostGlyph, x: x, size: NSSize(width: 16, height: 16)) + Axo.Space.xs
            let hs = hostName.intrinsicContentSize
            // The Mac's name gives way before the project's.
            x = centre(hostName, x: x, size: NSSize(width: min(ceil(hs.width), max(40, (right - x) * 0.25)), height: hs.height))
            x = centre(hostChevron, x: x + Axo.Space.xs, size: NSSize(width: 12, height: 16)) + Axo.Space.xs
        }
        if !tile.isHidden {
            x = centre(tile, x: x, size: NSSize(width: 16, height: 16)) + Axo.Space.sm
        }
        let ps = project.intrinsicContentSize
        // The project keeps its whole name unless the band is very narrow.
        let pw = min(ceil(ps.width), max(48, (right - x) * 0.4))
        x = centre(project, x: x, size: NSSize(width: pw, height: ps.height))
        guard !icon.isHidden else { return }
        x = centre(chevron, x: x + Axo.Space.xs, size: NSSize(width: 12, height: 16)) + Axo.Space.xs
        x = centre(icon, x: x, size: NSSize(width: 16, height: 16)) + Axo.Space.sm

        // Title and branch share what is left; the branch gives way first.
        let ts = title.intrinsicContentSize
        let room = max(0, right - x)
        let tw = min(ceil(ts.width), room)
        x = centre(title, x: x, size: NSSize(width: tw, height: ts.height))
        layoutFacts(from: x, right: right)
    }

    /// Places `v` vertically centred at `x`; returns its trailing edge.
    private func centre(_ v: NSView, x: CGFloat, size: NSSize) -> CGFloat {
        v.frame = NSRect(x: x, y: (bounds.height / 2 - size.height / 2).rounded(), width: size.width, height: size.height)
        return v.frame.maxX
    }

    /// The branch and the diff after `x`; the branch gives way first.
    private func layoutFacts(from x: CGFloat, right: CGFloat) {
        var x = x
        let bs = branch.isHidden ? .zero : branch.intrinsicContentSize
        let left = right - x - Axo.Space.lg
        let showBranch = !branch.isHidden && left >= 14 + Axo.Space.xs + 40
        branchGlyph.alphaValue = showBranch ? 1 : 0
        branch.alphaValue = showBranch ? 1 : 0
        // The diff chip sits after the branch (or the title), and goes before the branch does.
        let ds = diff.isHidden ? .zero : diff.fittingSize
        let diffW = diff.isHidden ? 0 : ds.width + Axo.Space.sm
        if showBranch {
            x = centre(branchGlyph, x: x + Axo.Space.lg, size: NSSize(width: 14, height: 16)) + Axo.Space.xs
            x = centre(branch, x: x, size: NSSize(width: max(0, min(ceil(bs.width), left - 14 - Axo.Space.xs - diffW)), height: bs.height))
        }
        if !diff.isHidden {
            let dx = x + (showBranch ? Axo.Space.sm : Axo.Space.lg)
            diff.alphaValue = dx + ds.width <= right ? 1 : 0
            _ = centre(diff, x: dx, size: ds)
        }
    }
}
