import AppKit
import AxModel
import QuartzCore

/// The content column: the band (the context header) and the stage on the
/// frame tone; the session's panes are sheets inset into the stage.
final class SessionViewController: NSViewController {
    private let model: AppModel
    let band = BandView()
    private let stage = FlippedView()
    private let empty = EmptyStateView()

    private struct Key: Hashable {
        var host: UUID
        var session: SessionID
    }

    private var containers: [Key: PaneContainerView] = [:]
    private var recent: [Key] = []
    private static let cacheLimit = 4
    private(set) var current: PaneContainerView?
    /// Set by the shell: the titlebar strip's height, and how far the band's
    /// text must start to clear the traffic lights and the sidebar toggle.
    var bandHeight: CGFloat = Axo.Metric.bandHeight { didSet { if bandHeight != oldValue { view.needsLayout = true } } }
    var leadingClearance: CGFloat = 16 { didSet { if leadingClearance != oldValue { view.needsLayout = true } } }
    /// The stage's leading inset: 0 beside the open sidebar (its plates already
    /// stop 8 short of its edge), the sheet inset when the sidebar is hidden.
    var stageLeading: CGFloat = 0 { didSet { if stageLeading != oldValue { view.needsLayout = true } } }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = GroundView()
        root.addSubview(stage)
        root.addSubview(band)
        root.addSubview(empty)
        stage.wantsLayer = true
        empty.isHidden = true
        view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let top = bandHeight
        let inset = Axo.Metric.sheetInset
        band.frame = NSRect(x: 0, y: 0, width: b.width, height: top)
        // The header's text starts on the terminal's first column.
        band.leadingInset = max(leadingClearance, (stageLeading + Axo.Metric.panePaddingX).rounded())
        band.trailingInset = inset + Axo.Space.md
        band.showsIdentity = stageLeading > 0
        stage.frame = NSRect(x: stageLeading.rounded(), y: top, width: max(0, b.width - stageLeading.rounded() - inset),
                             height: max(0, b.height - top - inset))
        current?.frame = stage.bounds
        empty.frame = stage.frame
    }

    func setGridsFrozen(_ frozen: Bool) { current?.setGridsFrozen(frozen) }

    // MARK: Sessions

    func show(_ host: HostSession, _ session: SessionInfo, animated: Bool) {
        let key = Key(host: host.id, session: session.id)
        let container = containers[key] ?? {
            let c = PaneContainerView(host: host, session: session, model: model)
            containers[key] = c
            return c
        }()
        recent.removeAll { $0 == key }
        recent.insert(key, at: 0)
        evict()
        empty.isHidden = true
        guard container !== current else {
            container.sync(session, animated: true)
            return
        }
        if animated, current != nil, !Axo.Motion.reduced {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.10
            stage.layer?.add(fade, forKey: "switch")
        }
        current?.removeFromSuperview()
        container.frame = stage.bounds
        container.autoresizingMask = [.width, .height]
        stage.addSubview(container)
        current = container
        container.sync(session, animated: false)
        container.linkChanged(animated: false)
        container.restoreFocus()
    }

    var emptyView: EmptyStateView { empty }

    func showEmpty(_ state: EmptyState) {
        current?.removeFromSuperview()
        current = nil
        empty.set(state)
        empty.isHidden = false
        // Keys 1–n launch from the empty sheet.
        if state == .noSessions { view.window?.makeFirstResponder(empty) }
    }

    /// Applies document changes to every cached container.
    func sync(_ host: HostSession) {
        for (key, c) in containers where key.host == host.id {
            if let s = host.session(key.session) {
                c.sync(s, animated: c === current)
            } else if c !== current {
                drop(key)
            }
        }
    }

    /// A host's link went down or came back: its cached sessions veil or clear.
    func linkChanged(_ host: HostSession) {
        for (key, c) in containers where key.host == host.id { c.linkChanged(animated: c === current) }
    }

    /// Drops every session of hosts no longer here (forgotten).
    func dropHosts(except live: Set<UUID>) {
        for key in containers.keys where !live.contains(key.host) { drop(key) }
    }

    func container(_ host: HostSession, _ sid: SessionID) -> PaneContainerView? {
        containers[Key(host: host.id, session: sid)]
    }

    private func evict() {
        while recent.count > Self.cacheLimit, let last = recent.last {
            drop(last)
        }
    }

    private func drop(_ key: Key) {
        recent.removeAll { $0 == key }
        guard let c = containers.removeValue(forKey: key) else { return }
        if c === current {
            current = nil
            c.removeFromSuperview()
        }
        c.tearDown()
    }

    /// Theme or font changed: every container re-reads it.
    func refreshAppearance() {
        for c in containers.values { c.refreshAppearance() }
        view.needsDisplay = true
    }
}

/// The window ground: the terminal background, full-bleed.
final class GroundView: NSView {
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = Axo.Color.frame.cgColor
    }
}

/// Shown when a host has no sessions or is unreachable.
/// What the content area says when it has no session to show. One glyph,
/// one line, and the actions that resolve it (never "press ⌘T": the button
/// is the instruction; its shortcut is in its tooltip and the menu).
