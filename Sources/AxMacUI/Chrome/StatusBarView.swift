import AppKit
import AxModel

/// The status bar: `⎇ branch · cwd` leading, the agent roll-up trailing. Each
/// roll-up segment jumps to the next such pane. No rule: it shares the
/// terminal's ground, and spacing alone parts it from the panes.
final class StatusBarView: NSView {
    private let branchIcon = NSImageView()
    private let leading = NSTextField(labelWithString: "")
    private let working = RollupButton()
    private let waiting = RollupButton()
    private let failed = RollupButton()
    var onJump: ((Activity) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        branchIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        branchIcon.contentTintColor = Axo.Color.textTertiary
        leading.font = Axo.Font.meta
        leading.textColor = Axo.Color.textTertiary
        leading.lineBreakMode = .byTruncatingMiddle
        for (b, a) in [(working, Activity.working), (waiting, .blocked), (failed, .error)] {
            b.activity = a
            b.target = self
            b.action = #selector(jump(_:))
            addSubview(b)
        }
        addSubview(branchIcon)
        addSubview(leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    @objc private func jump(_ sender: RollupButton) { onJump?(sender.activity) }

    func update(branch: String?, cwd: String, counts: (blocked: Int, error: Int, working: Int, done: Int), key: Bool) {
        branchIcon.isHidden = branch == nil
        var text = BandView.abbreviate(cwd)
        if let branch { text = branch + (cwd.isEmpty ? "" : "  ·  ") + text }
        leading.stringValue = text
        leading.textColor = key ? Axo.Color.textTertiary : Axo.Color.textDisabled
        working.count = counts.working
        waiting.count = counts.blocked
        failed.count = counts.error
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        var x: CGFloat = 12
        if !branchIcon.isHidden {
            branchIcon.frame = NSRect(x: x, y: mid - 6, width: 12, height: 12)
            x = branchIcon.frame.maxX + 5
        }
        var right = bounds.width - 12
        for b in [failed, waiting, working] where !b.isHidden {
            let s = b.fittingSize
            b.frame = NSRect(x: right - s.width, y: mid - s.height / 2, width: s.width, height: s.height)
            right = b.frame.minX - 6
        }
        let ls = leading.fittingSize
        leading.frame = NSRect(x: x, y: mid - ls.height / 2, width: max(0, min(ls.width, right - x - 8)), height: ls.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
}

/// One roll-up segment: a status glyph and "2 working".
final class RollupButton: NSControl {
    var activity: Activity = .working {
        didSet { glyph.activity = activity }
    }

    /// Compact: the glyph and the number; the noun moves to the tooltip.
    var compact = false { didSet { let c = count; count = c } }

    var count = 0 {
        didSet {
            isHidden = count == 0
            let noun = switch activity {
            case .working: "working"
            case .blocked: "waiting"
            case .error: "failed"
            case .done: "done"
            case .idle: ""
            }
            label.stringValue = compact ? "\(count)" : "\(count) \(noun)"
            toolTip = compact ? "\(count) \(noun)" : nil
            setAccessibilityLabel("\(count) \(noun)")
        }
    }

    private let glyph = StatusGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let label = NSTextField(labelWithString: "")
    private let plate = Plate(radius: Axo.Radius.sm)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(plate.layer)
        label.font = Axo.Font.meta
        label.textColor = Axo.Color.textSecondary
        addSubview(glyph)
        addSubview(label)
        isHidden = true
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize { NSSize(width: 4 + 16 + 2 + ceil(label.fittingSize.width) + 8, height: 20) }

    override func layout() {
        super.layout()
        Axo.Motion.still { plate.layer.frame = bounds; plate.layer.radius = Axo.Radius.sm }
        glyph.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let s = label.fittingSize
        label.frame = NSRect(x: glyph.frame.maxX + 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { plate.refresh(effectiveAppearance) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { plate.set(.hover, appearance: effectiveAppearance) }
    override func mouseExited(with event: NSEvent) { plate.set(.rest, appearance: effectiveAppearance) }
    override func mouseDown(with event: NSEvent) { plate.set(.pressed, appearance: effectiveAppearance, animated: false) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.set(inside ? .hover : .rest, appearance: effectiveAppearance)
        if inside { sendAction(action, to: target) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Reads the current git branch for a directory (walks up to `.git`, follows
/// `gitdir:` files for worktrees). Cached; runs off the main thread.
enum GitBranch {
    private static var cache: [String: (branch: String?, at: Date)] = [:]

    static func cached(_ dir: String) -> String?? {
        guard let hit = cache[dir], Date().timeIntervalSince(hit.at) < 5 else { return nil }
        return .some(hit.branch)
    }

    static func lookup(_ dir: String) async -> String? {
        if let hit = cached(dir) { return hit }
        let branch = await Task.detached(priority: .utility) { read(dir) }.value
        cache[dir] = (branch, Date())
        return branch
    }

    nonisolated static func read(_ dir: String) -> String? {
        var url = URL(filePath: dir, directoryHint: .isDirectory)
        let fm = FileManager.default
        for _ in 0 ..< 32 {
            let git = url.appending(path: ".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path(percentEncoded: false), isDirectory: &isDir) {
                var gitDir = git
                if !isDir.boolValue, let s = try? String(contentsOf: git, encoding: .utf8),
                   let line = s.split(separator: "\n").first, line.hasPrefix("gitdir:")
                {
                    let p = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                    gitDir = p.hasPrefix("/") ? URL(filePath: p) : url.appending(path: p)
                }
                guard let head = try? String(contentsOf: gitDir.appending(path: "HEAD"), encoding: .utf8) else { return nil }
                let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if h.hasPrefix("ref: refs/heads/") { return String(h.dropFirst(16)) }
                return String(h.prefix(7))
            }
            let parent = url.deletingLastPathComponent()
            if parent.path(percentEncoded: false) == url.path(percentEncoded: false) { break }
            url = parent
        }
        return nil
    }
}
