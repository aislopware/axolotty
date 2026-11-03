import AppKit
import AxClient
import AxModel
import AxProtocol

/// The sidebar: hosts (when more than one) → workspaces → sessions, with live
/// agent status, a springing selection plate, drag-to-reorder and context menus.
/// Updates are diffed per parent so rows fade in and out instead of reloading.
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let model: AppModel
    private let outline = SidebarOutlineView()
    private let scroll = NSScrollView()
    private var roots: [SidebarNode] = []
    private var nodes: [SidebarNode.Kind: SidebarNode] = [:]
    private var tokens: [SignalToken] = []
    private var tick: Timer?
    private var keycapTimer: Timer?
    private var flagsMonitor: Any?
    private var showKeycaps = false
    private var suppressSelection = false

    /// The session the window shows; the sidebar mirrors it.
    private(set) var selected: (host: UUID, session: SessionID)?
    var onSelect: ((HostSession, SessionID) -> Void)?
    var onNewSession: (() -> Void)?
    /// A new session in a project, optionally typing a command into it (an agent preset).
    var onCreate: ((HostSession, WorkspaceID, AgentKind?) -> Void)?
    /// "New Worktree…" on a project, and "Remove Worktree…" on a worktree session.
    var onNewWorktree: ((HostSession, WorkspaceID) -> Void)?
    var onCloseSession: ((HostSession, SessionID) -> Void)?
    var onRemoveWorktree: ((HostSession, SessionID) -> Void)?
    let footer = SidebarFooter()

    private static let sessionType = NSPasteboard.PasteboardType("dev.axolotty.session")

    private var collapsed: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "collapsedWorkspaces") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "collapsedWorkspaces") }
    }

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        tick?.invalidate()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    override func loadView() {
        let root = NSView()
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.rowSizeStyle = .custom
        outline.floatsGroupRows = false
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = 0
        outline.indentationMarkerFollowsCell = false
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.backgroundColor = .clear
        outline.onHoverChange = { [weak self] old, new in
            guard let self else { return }
            for (row, on) in [(old, false), (new, true)] where row >= 0 && row < self.outline.numberOfRows {
                let v = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false)
                (v as? SessionCell)?.hovering = on
                (v as? WorkspaceCell)?.hovering = on
            }
        }
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.registerForDraggedTypes([Self.sessionType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap
        outline.setAccessibilityLabel("Sessions")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Axo.Metric.footerHeight),
        ])
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: Axo.Space.md, right: 0)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(model.anyChange.observe { [weak self] host, change in
            switch change {
            case .connected, .deltas, .disconnected: self?.reload()
            case .latency, .setup: self?.refreshHost(host)
            case .event: break
            }
        })
        tokens.append(model.hostsChanged.observe { [weak self] in self?.reload() })
        reload()
        // Elapsed times ("working 3m") tick over.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVisibleRows() }
        }
        // Holding ⌘ for 0.4 s swaps row meta for ⌘n keycaps.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.commandHeld(e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command)
            return e
        }
    }

    private func commandHeld(_ held: Bool) {
        keycapTimer?.invalidate()
        if held {
            keycapTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setKeycaps(true) }
            }
        } else {
            setKeycaps(false)
        }
    }

    private func setKeycaps(_ on: Bool) {
        guard showKeycaps != on else { return }
        showKeycaps = on
        refreshVisibleRows()
    }

    // MARK: Model → outline

    private struct Spec {
        var kind: SidebarNode.Kind
        var children: [Spec]
    }

    /// Projects and their sessions; under a section per machine once there
    /// is more than one (a machine still connecting shows its section empty).
    private func specs() -> [Spec] {
        func projects(_ host: HostSession) -> [Spec] {
            guard let st = host.state else { return [] }
            return st.workspaces.map { w in
                let sessions = w.sessions.filter { st.sessions[$0] != nil }
                return Spec(kind: .workspace(host.id, w.id),
                            children: sessions.map { Spec(kind: .session(host.id, $0), children: []) })
            }
        }
        guard model.hosts.count > 1 else { return model.hosts.flatMap(projects) }
        return model.hosts.map { Spec(kind: .host($0.id), children: projects($0)) }
    }

    private var collapsedHosts: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "collapsedHosts") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "collapsedHosts") }
    }

    private func hostKey(_ id: UUID) -> String? { model.host(id).map { $0.isLocal ? "local" : $0.endpoint.description } }

    private func node(_ kind: SidebarNode.Kind) -> SidebarNode {
        if let n = nodes[kind] { return n }
        let n = SidebarNode(kind)
        nodes[kind] = n
        return n
    }

    /// Diffs the outline against the document, animating inserts and removals.
    func reload() {
        guard isViewLoaded else { return }
        let new = specs()
        suppressSelection = true
        outline.beginUpdates()
        roots = diff(parent: nil, old: roots, new: new)
        outline.endUpdates()
        var live = Set<SidebarNode.Kind>()
        func collect(_ s: [Spec]) {
            for x in s {
                live.insert(x.kind)
                collect(x.children)
            }
        }
        collect(new)
        nodes = nodes.filter { live.contains($0.key) }
        restoreExpansion(roots)
        syncSelection(animated: true)
        suppressSelection = false
        refreshVisibleRows()
    }

    private func diff(parent: SidebarNode?, old: [SidebarNode], new: [Spec]) -> [SidebarNode] {
        var current = old
        let changes = new.map(\.kind).difference(from: old.map(\.kind))
        for change in changes {
            switch change {
            case let .remove(offset, _, _):
                current.remove(at: offset)
                parent?.children = current
                if parent == nil { roots = current }
                outline.removeItems(at: [offset], inParent: parent, withAnimation: .effectFade)
            case let .insert(offset, kind, _):
                let n = node(kind)
                if let spec = new.first(where: { $0.kind == kind }) { n.children = build(spec.children) }
                current.insert(n, at: offset)
                parent?.children = current
                if parent == nil { roots = current }
                outline.insertItems(at: [offset], inParent: parent, withAnimation: .effectFade)
            }
        }
        // Recurse into nodes that existed before (new ones were built whole).
        for (n, spec) in zip(current, new) where old.contains(where: { $0 === n }) {
            n.children = diff(parent: n, old: n.children, new: spec.children)
        }
        parent?.children = current
        return current
    }

    private func build(_ specs: [Spec]) -> [SidebarNode] {
        specs.map { s in
            let n = node(s.kind)
            n.children = build(s.children)
            return n
        }
    }

    private func restoreExpansion(_ list: [SidebarNode]) {
        let closed = collapsed
        let closedHosts = collapsedHosts
        for n in list {
            switch n.kind {
            case let .host(h):
                let shouldExpand = !(hostKey(h).map(closedHosts.contains) ?? false)
                if shouldExpand, !outline.isItemExpanded(n) { outline.expandItem(n) }
                if !shouldExpand, outline.isItemExpanded(n) { outline.collapseItem(n) }
                restoreExpansion(n.children)
            case let .workspace(_, w):
                let shouldExpand = !closed.contains(w.raw.uuidString)
                if shouldExpand, !outline.isItemExpanded(n) { outline.expandItem(n) }
                if !shouldExpand, outline.isItemExpanded(n) { outline.collapseItem(n) }
            case .session:
                break
            }
        }
    }

    /// A machine's section only (its round trip moves every heartbeat).
    private func refreshHost(_ host: HostSession) {
        guard let n = nodes[.host(host.id)] else { return }
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        configure(cell, n)
    }

    /// Updates titles, glyphs and meta of the rows on screen.
    func refreshVisibleRows() {
        let range = outline.rows(in: outline.visibleRect)
        guard range.length > 0 else { return }
        for row in range.location ..< range.location + range.length {
            guard let n = outline.item(atRow: row) as? SidebarNode,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
            else { continue }
            configure(cell, n)
        }
    }

    // MARK: Selection

    func select(host: UUID, session: SessionID) {
        selected = (host, session)
        guard isViewLoaded else { return }
        // Reveal: expand the workspace that holds it.
        if let hn = nodes[.host(host)], !outline.isItemExpanded(hn) { outline.expandItem(hn) }
        if let h = model.host(host), let ws = h.session(session)?.workspace, let wn = nodes[.workspace(host, ws)],
           !outline.isItemExpanded(wn)
        {
            outline.expandItem(wn)
        }
        syncSelection(animated: true)
        refreshVisibleRows()
    }

    /// Nothing of the list is on screen (the window waits on a host).
    func deselect() {
        selected = nil
        guard isViewLoaded else { return }
        syncSelection(animated: true)
        refreshVisibleRows()
    }

    private func syncSelection(animated: Bool) {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let s = selected, let n = nodes[.session(s.host, s.session)] else {
            outline.deselectAll(nil)
            outline.movePlate(animated: animated)
            return
        }
        let row = outline.row(forItem: n)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        } else {
            outline.deselectAll(nil)
        }
        outline.movePlate(animated: animated)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        outline.movePlate(animated: true)
        guard !suppressSelection, let n = outline.item(atRow: outline.selectedRow) as? SidebarNode,
              case let .session(h, sid) = n.kind, let host = model.host(h)
        else { return }
        selected = (h, sid)
        refreshVisibleRows()
        onSelect?(host, sid)
    }

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode else { return }
        switch n.kind {
        case .host, .workspace:
            if outline.isItemExpanded(n) { outline.animator().collapseItem(n) } else { outline.animator().expandItem(n) }
        case let .session(h, sid):
            // Re-clicking the selected row still returns focus to its terminal.
            if let host = model.host(h), selected?.session == sid { onSelect?(host, sid) }
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? SidebarNode, case let .workspace(_, w) = n.kind {
            collapsed.insert(w.raw.uuidString)
        }
        if let n = notification.userInfo?["NSObject"] as? SidebarNode, case let .host(h) = n.kind, let k = hostKey(h) {
            collapsedHosts.insert(k)
        }
        outline.movePlate(animated: false)
        refreshVisibleRows()
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? SidebarNode, case let .workspace(_, w) = n.kind {
            collapsed.remove(w.raw.uuidString)
        }
        if let n = notification.userInfo?["NSObject"] as? SidebarNode, case let .host(h) = n.kind, let k = hostKey(h) {
            collapsedHosts.remove(k)
        }
        outline.movePlate(animated: false)
        refreshVisibleRows()
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let n = item as? SidebarNode else { return false }
        if case .session = n.kind { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let n = item as? SidebarNode, case .session = n.kind else { return false }
        return true
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let n = item as? SidebarNode else { return SidebarMetric.sessionRow }
        if n.isSession { return SidebarMetric.sessionRow }
        if case .host = n.kind {
            return SidebarMetric.hostRow + (roots.first === n ? SidebarMetric.firstGap : SidebarMetric.hostGap)
        }
        // Projects are parted by space, never rules; the first under a
        // machine's label sits close to it.
        let parent = outline.parent(forItem: n) as? SidebarNode
        let first = (parent?.children.first ?? roots.first) === n
        return SidebarMetric.headerRow + (first ? SidebarMetric.firstGap : SidebarMetric.headerGap)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        SidebarRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        let cell: NSView
        switch n.kind {
        case .host:
            cell = outlineView.makeView(withIdentifier: .init("host"), owner: nil) ?? {
                let c = HostCell()
                c.identifier = .init("host")
                return c
            }()
        case .workspace:
            cell = outlineView.makeView(withIdentifier: .init("workspace"), owner: nil) ?? {
                let c = WorkspaceCell()
                c.identifier = .init("workspace")
                return c
            }()
        case .session:
            cell = outlineView.makeView(withIdentifier: .init("session"), owner: nil) ?? {
                let c = SessionCell()
                c.identifier = .init("session")
                return c
            }()
        }
        configure(cell, n)
        return cell
    }

    private func configure(_ cell: NSView, _ n: SidebarNode) {
        guard let host = model.host(n.hostID) else { return }
        let h = host
        switch n.kind {
        case .host:
            guard let c = cell as? HostCell else { return }
            let s = Self.hostStatus(host)
            // Why a far Mac is slow, and that it isn't this app.
            let relay = host.relay.map { r in
                "\(host.name) · \(s.meta) through Tailscale's relay in \(TailnetDirectory.relayPlace(r)), not a direct path. Tailscale keeps looking for one."
            }
            c.set(name: host.isLocal ? "This Mac" : host.name, symbol: Self.hostSymbol(host), meta: s.meta,
                  retrying: s.retrying, waiting: s.waiting, relay: relay)
            let said = s.meta.isEmpty ? "connected" : s.meta + (host.relay == nil ? "" : " through a relay")
            c.setAccessibilityLabel(host.isLocal ? "This Mac" : "\(host.name), \(said)")
            // A Mac out of reach steps back; its name stays to be found.
            c.alphaValue = host.phase == .connected || s.retrying || s.waiting ? 1 : 0.5
        case let .workspace(_, wid):
            guard let c = cell as? WorkspaceCell, let st = host.state, let w = st.workspace(wid) else { return }
            c.title.stringValue = w.name
            c.expanded = outline.isItemExpanded(n)
            c.active = selected.flatMap { h.session($0.session)?.workspace } == wid && selected?.host == n.hostID
            c.rollup.activity = w.sessions.map { st.activity(of: $0) }.max() ?? .idle
            c.canAdd = host.phase == .connected
            c.onAdd = { [weak self] anchor in
                var items = AgentPresets.items(local: host.isLocal) { agent in self?.onCreate?(host, wid, agent) }
                // A worktree needs a repository; a remote root is not checked from here.
                if !host.isLocal || (!w.root.isEmpty && Self.inRepository(w.root)) {
                    items.append(nil)
                    items.append(PopMenu.Item(title: "New Worktree…", image: Self.branchImage) { self?.onNewWorktree?(host, wid) })
                }
                PopMenu.show(items, from: anchor, align: .trailing)
            }
            c.needsLayout = true
            c.setAccessibilityLabel("\(w.name), \(w.sessions.count) sessions")
        case let .session(_, sid):
            guard let c = cell as? SessionCell, let st = host.state else { return }
            let activity = st.activity(of: sid)
            let title = st.sessionTitle(sid)
            let identity = st.identity(of: sid)
            c.title.stringValue = identity.rowTitle(title)
            c.icon.identity = identity
            // Indeterminate (-1) keeps the spinner; only a percentage draws an arc.
            // OSC 9;4 first, else the agent's own OSC 7501 `progress=`.
            let panes = st.panes(of: sid)
            c.icon.progress = (panes.compactMap(\.progress).first(where: { $0 >= 0 })
                ?? panes.compactMap { $0.status.headline?.progress }.first).map { Double($0) / 100 }
            c.activity = activity
            c.selected = selected?.session == sid && selected?.host == n.hostID
            let number = sessionNumber(host: n.hostID, sid)
            c.shortcut.stringValue = number.map { "⌘\($0)" } ?? ""
            let changed = panes.map(\.activitySince).max() ?? 0
            c.age.stringValue = changed > 0 ? Self.elapsed(Date().timeIntervalSince1970 - changed) : ""
            c.showShortcut = showKeycaps
            c.onClose = { [weak self, weak host] in if let host { self?.onCloseSession?(host, sid) } }
            var label = title
            if let phrase = StatusGlyphView.phrase(activity) { label += ", \(phrase)" }
            c.setAccessibilityLabel(label)
            // Detail lives in the hover card, not on the row.
            if let pane = st.sessions[sid].flatMap({ st.panes[$0.focus] }) {
                c.card = hoverCard(title: title, activity: activity, since: secondsInState(st, sid, activity),
                                   pane: pane, git: GitFacts.cached(host, pane.pwd))
                let pwd = pane.pwd
                c.onHover = !pwd.isEmpty ? { [weak self, weak outline = self.outline, weak host] in
                    Task { @MainActor in
                        guard let host else { return }
                        _ = await GitFacts.lookup(host, pwd)
                        guard let self, let outline else { return }
                        let row = outline.row(forItem: n)
                        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
                        self.configure(cell, n)
                    }
                } : nil
            } else {
                c.card = nil
            }
            c.hovering = outline.hoverRow == outline.row(forItem: n) && outline.hoverRow >= 0
            c.needsLayout = true
        }
    }

    /// Title; state and time in it; what the agent asks or says; folder;
    /// branch with ahead/behind and the working tree's diff.
    /// Git facts come from caches filled on hover (read where the tree is).
    private func hoverCard(title: String, activity: Activity, since: Double?, pane: PaneInfo,
                           git: GitReport?) -> HoverCard
    {
        var card = HoverCard(title: title)
        if let state = Self.stateLine(activity, since: since) { card.facts.append(.init(.dot(activity), state)) }
        let subagents = pane.status.subagentsWorking
        if subagents > 0 {
            card.facts.append(.init(.symbol("person.2"), subagents == 1 ? "1 subagent working" : "\(subagents) subagents working"))
        }
        if let h = pane.status.headline {
            if h.state == .blocked {
                card.facts.append(.init(.symbol("hand.raised"), h.ask))
            } else if !h.message.isEmpty {
                card.facts.append(.init(.symbol("text.bubble"), h.message))
            }
        }
        if !pane.pwd.isEmpty {
            card.facts.append(.init(.symbol("folder"), BandView.abbreviate(pane.pwd), truncation: .byTruncatingMiddle))
            if let line = HoverCard.branchLine(git?.branch, changes: git?.changes) {
                card.facts.append(.init(.symbol("arrow.triangle.branch"), attributed: line, truncation: .byTruncatingMiddle))
            }
        }
        return card
    }

    /// Seconds in the current state, for the hover card (never on the row).
    private func secondsInState(_ st: HostState, _ sid: SessionID, _ a: Activity) -> Double? {
        let since = st.panes(of: sid).filter { $0.activity == a }.map(\.activitySince).min() ?? 0
        return since > 0 ? Date().timeIntervalSince1970 - since : nil
    }

    static func stateLine(_ a: Activity, since: Double?) -> String? {
        let word: String
        switch a {
        case .idle: return nil
        case .working: word = "Working"
        case .blocked: word = "Waiting for input"
        case .done: word = "Finished"
        case .error: word = "Failed"
        }
        guard let since else { return word }
        let e = Self.elapsed(since)
        return e == "now" ? word : "\(word) · \(e)"
    }

    static func elapsed(_ s: Double) -> String {
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        return "\(Int(s / 86400))d"
    }

    /// ⌘1…⌘8 count sessions in sidebar order; ⌘9 is the last one (as in
    /// Safari), so it labels a row only when that row is not already ⌘1…⌘8.
    func sessionNumber(host: UUID, _ sid: SessionID) -> Int? {
        let order = model.sidebarOrder
        guard let i = order.firstIndex(where: { $0.0.id == host && $0.1 == sid }) else { return nil }
        if i < 8 { return i + 1 }
        return i == order.count - 1 ? 9 : nil
    }

    // MARK: Drag to reorder

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let n = item as? SidebarNode, case let .session(h, sid) = n.kind else { return nil }
        let p = NSPasteboardItem()
        p.setString("\(h.uuidString)|\(sid.raw.uuidString)", forType: Self.sessionType)
        return p
    }

    private func dragged(_ info: any NSDraggingInfo) -> (UUID, SessionID)? {
        guard let s = info.draggingPasteboard.string(forType: Self.sessionType) else { return nil }
        let parts = s.split(separator: "|").map(String.init)
        guard parts.count == 2, let h = UUID(uuidString: parts[0]), let sid = SessionID(parts[1]) else { return nil }
        return (h, sid)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation
    {
        guard let (h, _) = dragged(info), let n = item as? SidebarNode else { return [] }
        switch n.kind {
        case let .workspace(wh, _) where wh == h:
            if index == NSOutlineViewDropOnItemIndex { outline.setDropItem(n, dropChildIndex: n.children.count) }
            return .move
        case let .session(sh, _) where sh == h:
            guard let parent = outline.parent(forItem: n) as? SidebarNode, let i = parent.children.firstIndex(of: n)
            else { return [] }
            outline.setDropItem(parent, dropChildIndex: i)
            return .move
        default:
            return []
        }
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int)
        -> Bool
    {
        guard let (h, sid) = dragged(info), let n = item as? SidebarNode, case let .workspace(_, wid) = n.kind,
              let host = model.host(h), let st = host.state, let w = st.workspace(wid)
        else { return false }
        // Indexes in the document ignore the dragged session's own slot.
        var target = max(0, index)
        if let from = w.sessions.firstIndex(of: sid), from < target { target -= 1 }
        host.perform(.moveSession(sid, workspace: wid, index: target))
        return true
    }

    // MARK: Machines

    /// The section's right side: round trip when healthy, else the state.
    static func hostStatus(_ h: HostSession) -> (meta: String, retrying: Bool, waiting: Bool) {
        if let step = h.settingUp, h.phase != .connected {
            let doing = switch step {
            case .checking: "Setting up: checking the Mac"
            case .copying: "Setting up: copying Axolotty"
            case .starting: "Setting up: starting the server"
            }
            return (doing, true, false)
        }
        switch h.phase {
        case .connected:
            guard !h.isLocal, let rtt = h.rtt else { return ("", false, false) }
            let ms = Double(rtt.components.attoseconds) / 1e15 + Double(rtt.components.seconds) * 1000
            return (ms < 1 ? "<1 ms" : "\(Int(ms.rounded())) ms", false, false)
        case .connecting, .offline:
            if h.nobodyListens, !h.isLocal { return ("Not running", false, true) }
            // Tailscale says the machine is away: nothing is working, nothing to do.
            if h.waitsForTheMac { return ("Offline", false, false) }
            return h.phase == .connecting ? ("Connecting", true, false) : ("Reconnecting", true, false)
        case .failed(.needsLogin(_)): return ("Sign in", false, true)
        case .failed(.notInstalled): return ("Not set up", false, true)
        case .failed(.incompatible(_)): return ("Needs update", false, true)
        case .failed(.denied): return ("Not allowed", false, true)
        }
    }

    /// The kind of Mac, from its name: a laptop unless it says otherwise.
    static func hostSymbol(_ h: HostSession) -> String {
        let n = (h.isLocal ? (Host.current().localizedName ?? "") : h.name).lowercased()
        if n.contains("mini") { return "macmini" }
        if n.contains("studio") { return "macstudio" }
        if n.contains("imac") { return "desktopcomputer" }
        if n.contains("mac pro") { return "macpro.gen3" }
        return "laptopcomputer"
    }

    // MARK: Context menu

    /// Whether `dir` is inside a git repository (a `.git` here or above).
    static func inRepository(_ dir: String) -> Bool {
        !dir.isEmpty && FileManager.default.fileExists(atPath: LinkOpener.projectRoot(dir) + "/.git")
    }

    static let branchImage: NSImage? = {
        let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        img?.isTemplate = true
        return img
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0, let n = outline.item(atRow: row) as? SidebarNode, let host = model.host(n.hostID) else { return }
        func add(_ title: String, _ handler: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runMenuClosure(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuClosure(handler)
            menu.addItem(item)
        }
        if case .host = n.kind {
            // The same one thing as the veil and the sheet: set up or update
            // when that is what keeps it down, reconnect, or nothing for a
            // Mac that is only asleep (setting one up would fail).
            if let r = host.linkRemedy {
                if let target = r.setUp {
                    add(host.isBehind ? "Update Axolotty There" : "Set Up Axolotty over SSH") { [weak self] in
                        self?.model.setUp(target)
                    }
                } else {
                    add(r.title) { host.retry() }
                }
            } else if host.phase == .connected, host.isBehind, host.settingUp == nil, let target = host.setUpTarget {
                add("Update Axolotty There") { [weak self] in self?.model.setUp(target) }
            }
            if !host.isLocal {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                add("Disconnect") { [weak self] in self?.model.forget(host) }
            }
            return
        }
        guard let st = host.state else { return }
        switch n.kind {
        case .host:
            break
        case let .session(_, sid):
            add("Rename…") { [weak self] in self?.rename(host, sid) }
            if st.sessions[sid]?.worktree != nil {
                add("Remove Worktree…") { [weak self] in self?.onRemoveWorktree?(host, sid) }
            }
            menu.addItem(.separator())
            add("Close Session") { [weak self] in self?.onCloseSession?(host, sid) }
        case let .workspace(_, wid):
            if let root = st.workspace(wid)?.root, !root.isEmpty {
                if let far = host.far {
                    // The far folder in the editor over SSH, as ⌘-click opens a path there.
                    if LinkOpener.opensFar(far), let editor = LinkOpener.editorName(remote: true) {
                        add("Open in \(editor)") {
                            if !LinkOpener.openFar(HostPath(path: root, isFolder: true), on: far) { NSSound.beep() }
                        }
                    }
                } else {
                    if let editor = LinkOpener.editorName(remote: false) {
                        add("Open in \(editor)") { LinkOpener.openFolder(root) }
                    }
                    add("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: root)]) }
                }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            add("Close Workspace") { [weak self] in self?.confirmCloseWorkspace(host, wid) }
        }
    }

    @objc private func runMenuClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuClosure)?.body()
    }

    // MARK: Actions


    func rename(_ host: HostSession, _ sid: SessionID) {
        guard let window = view.window, let st = host.state else { return }
        TextPrompt.run(in: window, title: "Rename Session", value: st.sessions[sid]?.name ?? st.sessionTitle(sid),
                       placeholder: "Session name") { name in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            host.perform(.renameSession(sid, name: trimmed.isEmpty ? nil : trimmed))
        }
    }

    private func confirmCloseWorkspace(_ host: HostSession, _ wid: WorkspaceID) {
        guard let window = view.window, let w = host.state?.workspace(wid) else { return }
        let alert = NSAlert()
        alert.messageText = "Close “\(w.name)”?"
        alert.informativeText = w.sessions.isEmpty ? "The workspace is empty."
            : "This ends \(w.sessions.count) session\(w.sessions.count == 1 ? "" : "s") and every program running in them."
        alert.addButton(withTitle: "Close Workspace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { host.perform(.closeWorkspace(wid)) }
        }
    }
}

/// A closure carried by a menu item.
final class MenuClosure: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
}

/// A sheet with one text field.
enum TextPrompt {
    static func run(in window: NSWindow, title: String, value: String, placeholder: String,
                    done: @escaping (String) -> Void)
    {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.placeholderString = placeholder
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { done(field.stringValue) }
        }
    }
}
