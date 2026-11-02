import AppKit
import AxClient
import AxModel
import AxProtocol
import QuartzCore

/// One session's panes: terminal views laid out by the session's split tree,
/// hairline dividers, and animated relayout (design spec §3.2).
///
/// Relayout runs its own critically-damped spring on a display link so every
/// pane moves on one clock, and grids stay frozen until the motion ends (one
/// SIGWINCH per pane, never a reflow per frame).
final class PaneContainerView: NSView, TerminalViewDelegate {
    let host: HostSession
    let sessionID: SessionID
    private let model: AppModel

    private(set) var views: [PaneID: TerminalView] = [:]
    private(set) var tree: SplitTree
    private(set) var zoomed: PaneID?
    private(set) var focused: PaneID
    private var pendingFocus: PaneID?
    private var dividers: [DividerView] = []
    private var drag: (divider: SplitTree.Divider, start: SplitTree)?
    private let readout = Readout()
    private var link: CADisplayLink?
    private var transition: Transition?
    var onFocusChange: ((PaneID) -> Void)?

    private struct Transition {
        var start: CFTimeInterval
        var from: [PaneID: NSRect]
        var to: [PaneID: NSRect]
        let spring = Axo.Motion.standard
        let duration = Axo.Motion.standard.settleTime
    }

    static let gap: CGFloat = Axo.Metric.dividerVisible

    init(host: HostSession, session: SessionInfo, model: AppModel) {
        self.host = host
        self.model = model
        sessionID = session.id
        tree = session.tree
        zoomed = session.zoomed
        focused = session.focus
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        for id in tree.panes { _ = makeView(id) }
        addSubview(readout)
        readout.isHidden = true
        relayout(animated: false, added: [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.isPaused = transition == nil
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Stops mirroring every pane (the container is leaving the cache).
    func tearDown() {
        link?.invalidate()
        link = nil
        stripTick?.invalidate()
        stripTick = nil
        for v in views.values {
            v.delegate = nil
            host.connection.detach(v.pane)
            v.removeFromSuperview()
        }
        views = [:]
    }

    // MARK: Views

    private func makeView(_ id: PaneID) -> TerminalView {
        let v = TerminalView(pane: id, connection: host.connection, prefs: model.prefs,
                             colors: TerminalColors(theme: model.theme))
        v.delegate = self
        views[id] = v
        addSubview(v, positioned: .below, relativeTo: dividers.first ?? readout)
        return v
    }

    private func retire(_ v: TerminalView, animated: Bool) {
        views[v.pane] = nil
        v.delegate = nil
        host.connection.detach(v.pane)
        guard animated, !Axo.Motion.reduced, let layer = v.layer else {
            v.removeFromSuperview()
            return
        }
        let b = layer.bounds
        var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)
        t = CATransform3DScale(t, 0.98, 0.98, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Axo.Motion.fadeOut.duration)
        CATransaction.setAnimationTimingFunction(Axo.Motion.fadeOut.curve)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { v.removeFromSuperview() } }
        layer.opacity = 0
        layer.transform = t
        CATransaction.commit()
    }

    /// Applies the host's view of the session.
    func sync(_ session: SessionInfo, animated: Bool) {
        let ids = Set(session.tree.panes)
        let canAnimate = animated && window != nil
        var added = Set<PaneID>()
        for (id, v) in views where !ids.contains(id) { retire(v, animated: canAnimate) }
        for id in session.tree.panes where views[id] == nil {
            _ = makeView(id)
            added.insert(id)
        }
        let changed = (drag == nil && session.tree != tree) || session.zoomed != zoomed || !added.isEmpty
        if drag == nil { tree = session.tree }
        zoomed = session.zoomed
        let hadFocus = window?.firstResponder is TerminalView && (window?.firstResponder as? TerminalView)?.superview === self
        if views[focused] == nil {
            focused = views[session.focus] != nil ? session.focus : tree.panes.first ?? focused
            if hadFocus || window?.firstResponder === window { focus(focused) }
        }
        if let p = pendingFocus, views[p] != nil {
            pendingFocus = nil
            focus(p)
        }
        if changed { relayout(animated: canAnimate, added: added) }
        updateChrome(animated: canAnimate)
    }

    /// Re-reads theme colours and fonts.
    func refreshAppearance() {
        let colors = TerminalColors(theme: model.theme)
        for v in views.values {
            v.colors = colors
            v.updateRenderer()
        }
        updateChrome(animated: false)
    }

    // MARK: Layout

    private func targetFrames() -> [PaneID: NSRect] {
        if let z = zoomed, views[z] != nil { return [z: bounds] }
        let r = Rect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
        return tree.frames(in: r, gap: Double(Self.gap)).mapValues {
            NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
    }

    override func layout() {
        super.layout()
        if transition != nil {
            transition?.to = targetFrames()
        } else {
            apply(targetFrames())
        }
        layoutDividers()
    }

    private func apply(_ frames: [PaneID: NSRect]) {
        for (id, v) in views {
            if let f = frames[id] {
                v.isHidden = false
                v.frame = backingAlignedRect(f, options: .alignAllEdgesNearest)
            } else {
                v.isHidden = true
            }
        }
    }

    private func relayout(animated: Bool, added: Set<PaneID>) {
        let target = targetFrames()
        guard animated, !Axo.Motion.reduced, bounds.width > 0 else {
            transition = nil
            apply(target)
            for v in views.values { v.gridFrozen = false }
            layoutDividers()
            for id in added { entrance(id, target: target, crossfadeOnly: true) }
            return
        }
        var from: [PaneID: NSRect] = [:]
        for (id, to) in target {
            guard let v = views[id] else { continue }
            if added.contains(id) || v.isHidden {
                from[id] = to
            } else {
                from[id] = v.frame
                v.gridFrozen = true
            }
        }
        apply(from)
        transition = Transition(start: CACurrentMediaTime(), from: from, to: target)
        for d in dividers { d.isHidden = true }
        for id in added { entrance(id, target: target, crossfadeOnly: false) }
        link?.isPaused = false
    }

    /// New panes fade in after 60 ms, sliding 12 pt away from the split edge.
    private func entrance(_ id: PaneID, target: [PaneID: NSRect], crossfadeOnly: Bool) {
        guard let layer = views[id]?.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = crossfadeOnly ? 0.12 : Axo.Motion.fadeIn.duration
        fade.timingFunction = Axo.Motion.fadeIn.curve
        fade.fillMode = .backwards
        if !crossfadeOnly, !Axo.Motion.reduced {
            fade.beginTime = CACurrentMediaTime() + 0.06
            if let axis = parentAxis(of: id, in: tree) {
                let slide = CABasicAnimation(keyPath: axis == .horizontal ? "transform.translation.x" : "transform.translation.y")
                slide.fromValue = -12
                slide.toValue = 0
                slide.duration = Axo.Motion.standard.settleTime
                slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                slide.beginTime = fade.beginTime
                slide.fillMode = .backwards
                layer.add(slide, forKey: "entrance.slide")
            }
        }
        layer.add(fade, forKey: "entrance.fade")
    }

    private func parentAxis(of id: PaneID, in t: SplitTree) -> SplitTree.Axis? {
        guard case let .split(ax, _, a, b) = t else { return nil }
        if case .leaf(id) = a { return ax }
        if case .leaf(id) = b { return ax }
        return parentAxis(of: id, in: a) ?? parentAxis(of: id, in: b)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let tr = transition else {
            link.isPaused = true
            return
        }
        let t = CACurrentMediaTime() - tr.start
        if t >= tr.duration {
            finishTransition()
            return
        }
        let k = CGFloat(tr.spring.value(at: t))
        var frames: [PaneID: NSRect] = [:]
        for (id, to) in tr.to {
            let f = tr.from[id] ?? to
            frames[id] = NSRect(x: f.minX + (to.minX - f.minX) * k, y: f.minY + (to.minY - f.minY) * k,
                                width: f.width + (to.width - f.width) * k, height: f.height + (to.height - f.height) * k)
        }
        apply(frames)
    }

    private func finishTransition() {
        transition = nil
        link?.isPaused = true
        apply(targetFrames())
        for v in views.values { v.gridFrozen = false }
        layoutDividers()
        for d in dividers {
            d.isHidden = false
            d.alphaValue = 0
        }
        Axo.Motion.fade(in: true) { for d in self.dividers { d.animator().alphaValue = 1 } }
    }

    // MARK: Dividers

    private func layoutDividers() {
        let list: [SplitTree.Divider] = zoomed == nil
            ? tree.dividers(in: Rect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height)),
                            gap: Double(Self.gap))
            : []
        while dividers.count > list.count { dividers.removeLast().removeFromSuperview() }
        while dividers.count < list.count {
            let d = DividerView(list[dividers.count])
            let index = dividers.count
            d.onDrag = { [weak self] phase, delta in self?.dividerDrag(index, phase, delta) }
            addSubview(d, positioned: .below, relativeTo: readout)
            dividers.append(d)
        }
        let hit = Axo.Metric.dividerHit
        for (d, info) in zip(dividers, list) {
            d.divider = info
            let r = info.rect
            d.frame = info.axis == .horizontal
                ? NSRect(x: r.x + r.width / 2 - hit / 2, y: r.y, width: hit, height: r.height)
                : NSRect(x: r.x, y: r.y + r.height / 2 - hit / 2, width: r.width, height: hit)
            d.isHidden = transition != nil
            d.needsLayout = true
            d.window?.invalidateCursorRects(for: d)
        }
    }

    private func dividerDrag(_ index: Int, _ phase: DividerView.DragPhase, _ delta: CGFloat) {
        guard index < dividers.count else { return }
        let d = dividers[index].divider
        switch phase {
        case .began:
            drag = (d, tree)
            showReadout(d)
        case .changed:
            guard let start = drag?.start, let anchor = drag?.divider else { return }
            let next = start.resizing(anchor.anchor, axis: anchor.axis, by: Double(delta) / max(anchor.span, 1))
            guard fits(next) else { return }
            tree = next
            apply(targetFrames())
            layoutDividers()
            if let now = dividers.first(where: { $0.divider.anchor == anchor.anchor && $0.divider.axis == anchor.axis }) {
                showReadout(now.divider)
            }
        case .ended:
            let wasDragging = drag != nil
            drag = nil
            Axo.Motion.fade(in: false, { self.readout.animator().alphaValue = 0 }) { self.readout.isHidden = true }
            if delta.isNaN {
                host.perform(.equalize(sessionID))
            } else if wasDragging {
                host.perform(.setTree(sessionID, tree))
            }
        }
    }

    /// Every pane keeps at least `Pane.min`.
    private func fits(_ t: SplitTree) -> Bool {
        let r = Rect(x: 0, y: 0, width: Double(bounds.width), height: Double(bounds.height))
        return t.frames(in: r, gap: Double(Self.gap)).values.allSatisfy {
            $0.width >= Axo.Metric.paneMin.width && $0.height >= Axo.Metric.paneMin.height
        }
    }

    private func showReadout(_ d: SplitTree.Divider) {
        let a = Int((d.ratio * 100).rounded())
        readout.text = "\(a) : \(100 - a)"
        let size = readout.fittingSize
        let c = NSPoint(x: d.rect.x + d.rect.width / 2, y: d.rect.y + d.rect.height / 2)
        readout.frame = NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        if readout.isHidden {
            readout.isHidden = false
            readout.alphaValue = 0
            Axo.Motion.fade(in: true) { self.readout.animator().alphaValue = 1 }
        }
    }

    // MARK: Chrome

    func updateChrome(animated: Bool) {
        let multi = views.count > 1 && zoomed == nil
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let alpha = Axo.Color.dimAlpha(dark: model.theme.isDark, increaseContrast: contrast)
        let root = host.session(sessionID).flatMap { host.state?.workspace($0.workspace)?.root } ?? ""
        var anyWorking = false
        for (id, v) in views {
            let dim = model.prefs.dimUnfocusedPanes && multi && id != focused
            v.setDimmed(dim, alpha: alpha, animated: animated)
            v.setFocusRing(contrast && multi && id == focused)
            v.showsStrip = multi
            v.setProgress(host.pane(id)?.progress, tone: host.pane(id)?.progressTone)
            v.linkContext = (host.pane(id)?.pwd ?? "", host.isLocal)
            v.readsSecret = host.pane(id)?.readsSecret == true
            v.endedCode = host.pane(id)?.exitStatus
            v.onRestart = { [weak self] in self?.restart(id) }
            guard multi, let p = host.pane(id) else { continue }
            anyWorking = anyWorking || p.activity == .working
            v.strip.update(stripModel(p, root: root, focused: id == focused))
            v.strip.onZoom = { [weak self] in
                guard let self else { return }
                self.focus(id)
                self.host.perform(.setZoom(self.sessionID, id))
            }
            v.strip.onClose = { [weak self] in
                guard let self else { return }
                self.host.perform(.closePane(id))
            }
            v.strip.onActivate = { [weak self] in self?.focus(id) }
        }
        setStripTick(anyWorking)
        seeFinishInFront()
    }

    /// An ended pane's slot gets the same command again (a new pane id).
    private func restart(_ id: PaneID) {
        let new = PaneID()
        pendingFocus = new
        host.perform(.restartPane(id, new: new))
    }

    private var seenFinish: (PaneID, Double)?

    /// A finish that happens in front of the person (the focused pane of the
    /// key window of the active app) is seen as it happens: no badge, no
    /// lingering green, for something they watched end.
    private func seeFinishInFront() {
        guard let p = host.pane(focused), p.activity == .done || p.activity == .error,
              NSApp.isActive, window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor
        else { return }
        if let s = seenFinish, s.0 == p.id, s.1 == p.activitySince { return }
        seenFinish = (p.id, p.activitySince)
        host.connection.send(.seen(p.id))
    }

    private func stripModel(_ p: PaneInfo, root: String, focused: Bool) -> PaneStripView.Model {
        let app = p.status.headline.map { p.status.app(of: $0.id) } ?? ""
        let identity = ProgramIdentity.of(agent: p.agent, app: app, program: p.program)
        var question: String?
        if p.activity == .blocked {
            question = p.status.headline?.ask ?? "Needs input"
        } else if p.activity == .error {
            question = "Failed"
        }
        return PaneStripView.Model(identity: identity, name: identity.rowTitle(p.displayTitle),
                                   path: Self.relative(p.pwd, to: root), activity: p.activity,
                                   since: p.activitySince, question: question,
                                   // A receipt belongs to an agent: none once the pane is a plain shell again.
                                   lastRun: p.agent != nil || !app.isEmpty ? p.lastRun : nil, focused: focused)
    }

    /// The cwd as the strip says it: relative to the project ("Sources/AxModel"),
    /// "~/…" outside it, nothing at the project root (the header says that).
    static func relative(_ path: String, to root: String) -> String {
        guard !path.isEmpty else { return "" }
        if !root.isEmpty, path == root { return "" }
        if !root.isEmpty, path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return BandView.abbreviate(path)
    }

    private var stripTick: Timer?

    private func setStripTick(_ on: Bool) {
        if on, stripTick == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.views.values.forEach { $0.strip.tickElapsed() } }
            }
            RunLoop.main.add(t, forMode: .common)
            stripTick = t
        } else if !on {
            stripTick?.invalidate()
            stripTick = nil
        }
    }

    // MARK: Focus

    func focus(_ id: PaneID) {
        guard let v = views[id] else { return }
        // Already inside this pane (its find field): coming back to the window keeps it there.
        if let r = window?.firstResponder as? NSView, r !== v, r.isDescendant(of: v) { return }
        if window?.firstResponder !== v { window?.makeFirstResponder(v) } else { terminalDidBecomeFocused(v) }
    }

    func restoreFocus() { focus(focused) }

    /// Freezes every pane's grid while an outer animation moves this container
    /// (sidebar spring, sidebar drag): the PTY is resized once, at the end.
    func setGridsFrozen(_ frozen: Bool) {
        for v in views.values { v.gridFrozen = frozen }
    }

    var focusedView: TerminalView? { views[focused] }

    func terminalDidBecomeFocused(_ view: TerminalView) {
        focused = view.pane
        view.takeSize()
        if host.session(sessionID)?.focus != view.pane { host.perform(.focusPane(sessionID, view.pane)) }
        host.connection.send(.seen(view.pane))
        updateChrome(animated: true)
        onFocusChange?(view.pane)
    }

    func terminalIsFocusedPane(_ view: TerminalView) -> Bool { view.pane == focused }

    // MARK: Pane actions (responder chain)

    @objc func splitRight(_ sender: Any?) { split(.horizontal) }
    @objc func splitDown(_ sender: Any?) { split(.vertical) }

    private func split(_ axis: SplitTree.Axis) { split(axis, recipe: SpawnRecipe()) }

    /// Splits the focused pane, running `recipe` in the new one, and focuses it.
    func split(_ axis: SplitTree.Axis, recipe: SpawnRecipe) {
        let new = PaneID()
        pendingFocus = new
        host.perform(.split(sessionID, target: focused, new: new, axis: axis, before: false, recipe: recipe))
    }

    @objc func closePane(_ sender: Any?) {
        if tree.count == 1, let s = host.session(sessionID) {
            model.closed.append(AppModel.ClosedSession(host: host.id, workspace: s.workspace,
                                                       cwd: host.pane(focused)?.pwd ?? "", name: s.name))
        }
        host.perform(.closePane(focused))
    }

    @objc func focusNextPane(_ sender: Any?) { cycle(1) }
    @objc func focusPreviousPane(_ sender: Any?) { cycle(-1) }

    private func cycle(_ step: Int) {
        let order = tree.panes
        guard let i = order.firstIndex(of: focused), order.count > 1 else { return }
        if zoomed != nil { host.perform(.setZoom(sessionID, nil)) }
        focus(order[(i + step + order.count) % order.count])
    }

    @objc func toggleZoom(_ sender: Any?) {
        guard tree.count > 1 || zoomed != nil else { return }
        host.perform(.setZoom(sessionID, zoomed == nil ? focused : nil))
    }
}

/// The live ratio shown while dragging a divider.

