import AppKit
import AxModel

/// The band: the context header above the sheets, painted in frame ink. It
/// answers *what is this, and how is it doing*, where the eyes already are
/// (design-system §1.3: the sidebar answers *which*). Shown with the sidebar
/// open or closed; with it open the text starts on the terminal's text column.
///
///     [tile] project  ›  [icon] session title   ⑂ branch        ◌ Working 4:12
///
/// - Leading, the path: the project's 16 pt tile and name (13 semibold, full
///   ink), a compact chevron, the program icon (carrying its state badge) and
///   the session title (13, secondary ink), then the git branch (12, tertiary).
/// - Trailing, the state: working shows a cyan spinner and the elapsed
///   time; waiting or failed show the chip with the agent's own words. One
///   cue per state.
///
/// No rule below and no fill of its own. Drags the window.
final class BandView: NSView {
    private let tile = ProjectTile()
    private let project = Label("", font: Axo.Font.title, color: Axo.Color.text)
    private let chevron = Symbol("chevron.compact.right", size: 10, weight: .semibold, color: Axo.Color.textTertiary)
    private let icon = ProgramIcon(frame: .zero)
    private let title = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)
    private let branchGlyph = Symbol("arrow.triangle.branch", size: 10, weight: .medium, color: Axo.Color.textTertiary)
    private let branch = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    let diff = DiffChip()
    private let spinner = StatusGlyphView(frame: .zero)
    private let elapsed = Label("", font: Axo.Font.meta, color: Axo.Color.textSecondary)
    let chip = Chip()
    var leadingInset: CGFloat = 12 { didSet { needsLayout = true } }
    var trailingInset: CGFloat = 56 { didSet { needsLayout = true } }

    private var activity: Activity = .idle
    private var since: Double = 0
    private var subagents = 0
    private var tick: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        diff.isHidden = true
        for v in [tile, project, chevron, icon, title, branchGlyph, branch, diff, spinner, elapsed, chip] as [NSView] {
            addSubview(v)
        }
        chip.isHidden = true
        title.lineBreakMode = .byTruncatingTail
        project.lineBreakMode = .byTruncatingTail
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
        var projectKey: String
        var session: String
        var identity: ProgramIdentity
        var activity: Activity
        /// When the session entered `activity` (seconds since 1970; 0 unknown).
        var since: Double
        var branch: String?
        /// Subagents working under the agent ("Working 4:12 · 2 subagents").
        var subagents = 0
    }

    /// Shows a session's context, or the app name alone when nothing is open.
    func update(_ c: Context?, key: Bool) {
        setPath(c)
        guard let c else { return }
        tile.set(name: c.project, key: c.projectKey)
        project.stringValue = c.project
        icon.identity = c.identity
        icon.activity = c.activity
        icon.lit = key
        title.stringValue = c.session
        title.textColor = key ? Axo.Color.textSecondary : Axo.Color.textTertiary
        project.textColor = key ? Axo.Color.text : Axo.Color.textSecondary
        branch.stringValue = c.branch ?? ""
        for v in [branchGlyph, branch] as [NSView] { v.isHidden = (c.branch ?? "").isEmpty }
        activity = c.activity
        since = c.since
        subagents = c.subagents
        spinner.activity = c.activity == .working ? .working : .idle
        let working = c.activity == .working
        spinner.isHidden = !working
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

    private func setPath(_ c: Context?) {
        let on = c != nil
        for v in [tile, chevron, icon, title] as [NSView] { v.isHidden = !on }
        if !on {
            project.stringValue = "Axolotty"
            project.textColor = Axo.Color.textSecondary
            for v in [branchGlyph, branch, diff, spinner, elapsed] as [NSView] { v.isHidden = true }
            tick?.invalidate()
            tick = nil
            needsLayout = true
        }
    }

    static func abbreviate(_ path: String) -> String {
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
        func centre(_ v: NSView, x: CGFloat, size: NSSize) -> CGFloat {
            v.frame = NSRect(x: x, y: (mid - size.height / 2).rounded(), width: size.width, height: size.height)
            return v.frame.maxX
        }

        // Trailing state cluster first: the path truncates against it.
        var right = bounds.width - trailingInset
        if !chip.isHidden {
            let c = chip.fittingSize
            chip.frame = NSRect(x: right - c.width, y: (mid - c.height / 2).rounded(), width: c.width, height: c.height)
            right = chip.frame.minX - Axo.Space.md
        } else if !elapsed.isHidden {
            let e = elapsed.intrinsicContentSize
            elapsed.frame = NSRect(x: right - ceil(e.width), y: (mid - e.height / 2).rounded(), width: ceil(e.width), height: e.height)
            spinner.frame = NSRect(x: elapsed.frame.minX - Axo.Space.xs - 16, y: (mid - 8).rounded(), width: 16, height: 16)
            right = spinner.frame.minX - Axo.Space.md
        }

        var x = leadingInset
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
        let bs = branch.isHidden ? .zero : branch.intrinsicContentSize
        let room = max(0, right - x)
        let tw = min(ceil(ts.width), room)
        x = centre(title, x: x, size: NSSize(width: tw, height: ts.height))
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
