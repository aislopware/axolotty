import AppKit
import AxClient
import AxModel
import AxProtocol
import QuartzCore

/// The command palette (⇧⌘P) and Go to Session (⌘J): one float surface drawn
/// in the window's overlay layer (no child window, so its corners, ring and
/// shadow all come from the one design-system shape). Fuzzy-matched sections,
/// keyboard first. Selection is a neutral plate, never the accent.
final class PaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode { case commands, agents, worktree, hosts }

    private let model: AppModel
    private weak var owner: MainWindowController?
    private var mode: Mode = .commands
    private let surface = PaletteSurface()
    private var field: SearchField { surface.field }
    private var table: PaletteTableView { surface.table }
    private var rows: [Row] = []
    private weak var previousResponder: NSResponder?
    private var mouseActive = false
    private(set) var isVisible = false

    /// New Session in Worktree: the project, what its repository offers, and
    /// what the session starts (nil: a shell; ⇥ cycles).
    private struct WorktreeTarget {
        var host: HostSession
        var workspace: WorkspaceID
        /// Where git runs and the new session's starting point.
        var dir: String?
        var source: WorktreeSource?
        var agents: [AgentKind?]
        var agent: Int
        var chosen: AgentKind? { agents[agent] }
    }
    private var worktree: WorktreeTarget?

    /// Connect to Host: the person's Macs on the tailnet, and what answered
    /// on each (a round trip when Axolotty is there, nil when nothing is).
    private var peers: [TailnetPeer]?
    private var probes: [String: Duration?] = [:]
    private var scan: Task<Void, Never>?

    enum Item {
        case command(Command)
        case session(HostSession, SessionID)
        case worktree(String)
        /// A machine to connect to: what to call it and the name to dial.
        case host(name: String, dial: String)
        /// A Mac with nothing answering: set Axolotty up there over ssh.
        case setUp(name: String, dial: String)
        /// Says something; does nothing.
        case note
    }

    struct Entry {
        var item: Item
        var title: String
        var detail: String
        var symbol: String
        var chord: String
        var activity: Activity = .idle
        var need: StatusRecord.Need?
        var progress: Double?
        /// Sessions: the program icon (who); the state circle trails the title.
        var identity: ProgramIdentity?
        /// Also matched when `title` is not (the full session title when the
        /// shown one drops what the icon says), without highlighting.
        var alias: String?
        /// Made from the query itself (a new branch): always listed, nothing highlighted.
        var literal = false
        var positions: [Int] = []
        var score = 0
    }

    enum Row {
        case header(String)
        case entry(Entry)
    }

    init(model: AppModel, owner: MainWindowController) {
        self.model = model
        self.owner = owner
        super.init()
        field.delegate = self
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onMouseMoved = { [weak self] row in self?.hover(row) }
    }

    /// The worktree picker for a project: type a new branch, or pick a
    /// branch or an existing worktree; ↩ starts the shown agent there.
    func showWorktree(_ host: HostSession, _ wid: WorkspaceID, from dir: String? = nil) {
        let root = dir ?? host.state?.workspace(wid)?.root ?? ""
        var agents: [AgentKind?] = [nil]
        agents += AgentPresets.available(local: host.isLocal).map { Optional($0) }
        let target = WorktreeTarget(host: host, workspace: wid, dir: root.isEmpty ? nil : root, source: nil, agents: agents,
                                    agent: agents.count > 1 ? 1 : 0)
        guard host.isLocal, !root.isEmpty else {
            worktree = target
            mode = .worktree
            show()
            return
        }
        Task { [weak self] in
            let source = await WorktreeSource.read(root)
            guard let self else { return }
            guard source != nil else {
                self.model.notices.emit(("Not a git repository", "Worktrees need one; \(BandView.abbreviate(root)) is not in a repository."))
                return
            }
            var t = target
            t.source = source
            self.worktree = t
            self.mode = .worktree
            self.show()
        }
    }

    func toggle(_ m: Mode) {
        if isVisible, mode == m {
            dismiss()
            return
        }
        mode = m
        show()
    }

    // MARK: Show / hide

    private func show() {
        guard let owner, let window = owner.window else { return }
        let host = owner.shell.overlay
        if !isVisible { previousResponder = window.firstResponder }
        Tooltip.shared.dismiss()
        field.stringValue = ""
        let prompt = switch mode {
        case .commands: "Type a command…"
        case .agents: "Go to session…"
        case .worktree: "Branch for a new worktree…"
        case .hosts: "Connect to a Mac on your tailnet…"
        }
        let lead: ProgramIdentity? = switch mode {
        case .worktree: worktree.map { $0.chosen.map(ProgramIdentity.of) ?? .shell }
        default: nil
        }
        surface.lead(lead)
        if mode == .hosts { startScan() } else { scan?.cancel() }
        field.placeholderAttributedString = NSAttributedString(
            string: prompt,
            attributes: [.font: Axo.Font.field, .foregroundColor: Axo.Color.textTertiary])
        mouseActive = false
        let wasVisible = isVisible
        lockedList = nil  // re-measured from the unfiltered list below
        isVisible = true
        if surface.superview !== host { host.addSubview(surface) }
        host.capturesOutsideClicks = true
        host.onOutsideClick = { [weak self] in self?.dismiss() }
        refilter()
        place()
        window.makeFirstResponder(field)
        if !wasVisible { surface.animateIn() }
    }

    /// Centred on the content column, a sixth of the way down (clamped).
    /// The list height measured when the palette opened: typing never
    /// changes the palette's size (a shrinking box makes the field jump).
    private var lockedList: CGFloat?

    private func place() {
        guard let owner else { return }
        let host = owner.shell.overlay
        let column = host.convert(owner.shell.content.bounds, from: owner.shell.content)
        let top = owner.shell.titlebarHeight
        let width = min(max(column.width - 64, Axo.Metric.paletteMinWidth), Axo.Metric.paletteWidth)
        let entries = rows.reduce(0) { n, r in if case .entry = r { n + 1 } else { n } }
        let headers = rows.count - entries
        let listH = CGFloat(min(entries, Axo.Metric.paletteMaxRows)) * Axo.Metric.paletteRow
            + CGFloat(min(headers, 3)) * Axo.Metric.paletteSectionHeight
        if lockedList == nil { lockedList = max(listH, Axo.Metric.paletteEmptyHeight) }
        let height = surface.height(forList: lockedList ?? listH)
        // A fixed 80 below the band (Zed, Warp), closer in short windows.
        let gap = min(Axo.Metric.paletteTop, max(16, (column.height - top - height) / 3))
        let y = min(top + gap, max(top + 8, column.maxY - height - 16))
        surface.frame = NSRect(x: (column.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height)
    }

    func dismiss(restoreFocus: Bool = true) {
        guard isVisible, let owner else { return }
        isVisible = false
        scan?.cancel()
        let host = owner.shell.overlay
        host.capturesOutsideClicks = false
        host.onOutsideClick = nil
        surface.animateOut()
        if restoreFocus, let window = owner.window {
            let r = previousResponder
            if let r, r !== field, r !== field.currentEditor() { window.makeFirstResponder(r) } else {
                owner.content.current?.restoreFocus()
            }
        }
    }

    // MARK: Filtering

    private func candidates() -> [(String, [Entry])] {
        let commands = Command.all.filter(\.inPalette).map {
            Entry(item: .command($0), title: $0.title.replacingOccurrences(of: "…", with: ""),
                  detail: "", symbol: symbol(for: $0), chord: $0.chord)
        }
        switch mode {
        case .commands: return [("Commands", commands)]
        case .agents: return agentSections()
        case .worktree: return worktreeSections()
        case .hosts: return hostSections()
        }
    }

    // MARK: Connect to Host

    private func startScan() {
        scan?.cancel()
        peers = nil
        probes = [:]
        scan = Task { [weak self] in
            let found = await TailnetDirectory.scan()
            guard let self, !Task.isCancelled else { return }
            peers = found
            relist()
            // Every online Mac is asked at once; each row settles as it answers.
            await withTaskGroup(of: (String, Duration?).self) { group in
                for p in found where p.online { group.addTask { (p.dialName, await TailnetDirectory.probe(p.dialName)) } }
                for await (dial, took) in group {
                    guard !Task.isCancelled else { return }
                    probes[dial] = .some(took)
                    relist()
                }
            }
        }
    }

    /// The list changed under the person: refilter, keeping the selection's place.
    private func relist() {
        guard isVisible, mode == .hosts else { return }
        let keep = table.selectedRow
        lockedList = nil
        refilter()
        if keep > 0, keep < rows.count, case .entry = rows[keep] { table.selectRowIndexes([keep], byExtendingSelection: false) }
    }

    /// Macs that answered first (they connect now), then those still asked
    /// or with nothing listening, then the ones away. What is typed is also
    /// offered as an address. Detail says how the link would go: direct or
    /// through which relay, and its round trip.
    private func hostSections() -> [(String, [Entry])] {
        var out: [(String, [Entry])] = []
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        func here(_ dial: String) -> HostSession? { model.host(at: .tcp(host: dial, port: TailnetDirectory.port)) }
        func symbol(_ name: String) -> String {
            let n = name.lowercased()
            return n.contains("mini") ? "macmini" : n.contains("studio") ? "macstudio" : n.contains("imac") ? "desktopcomputer" : "laptopcomputer"
        }
        guard let peers else {
            out.append(("Your tailnet", [Entry(item: .note, title: "Looking for your Macs…", detail: "", symbol: "antenna.radiowaves.left.and.right",
                                               chord: "", literal: true)]))
            return out
        }
        var ready: [Entry] = [], other: [Entry] = [], away: [Entry] = []
        for p in peers {
            let path = p.relay.map { "via \($0)" } ?? "direct"
            var e = Entry(item: .host(name: p.name, dial: p.dialName), title: p.name, detail: "", symbol: symbol(p.name), chord: "",
                          alias: p.dialName)
            if !p.online {
                e.detail = "Offline · connects when it’s back"
                away.append(e)
            } else if let h = here(p.dialName) {
                // Already in the sidebar: what it says there, and its remedy.
                if h.phase == .connected {
                    e.detail = "Connected"
                    ready.append(e)
                } else if let r = h.linkRemedy, r.setUp != nil {
                    e.item = .setUp(name: p.name, dial: p.dialName)
                    e.detail = h.isBehind ? "Needs update · ↩ updates it over SSH" : "Not running · ↩ sets it up over SSH"
                    other.append(e)
                } else {
                    e.detail = SidebarViewController.hostStatus(h).meta
                    other.append(e)
                }
            } else if let probe = probes[p.dialName] {
                if let took = probe {
                    e.detail = "\(path) · \(Self.ms(took))"
                    ready.append(e)
                } else {
                    e.item = .setUp(name: p.name, dial: p.dialName)
                    e.detail = "Not set up · ↩ sets it up over SSH"
                    other.append(e)
                }
            } else {
                e.detail = "\(path) · asking…"
                other.append(e)
            }
        }
        if !ready.isEmpty { out.append(("Ready", ready)) }
        if !other.isEmpty { out.append(("On your tailnet", other)) }
        if !away.isEmpty { out.append(("Away", away)) }
        if !typed.isEmpty, !peers.contains(where: { $0.name.lowercased() == typed.lowercased() || $0.dialName == typed }) {
            out.append(("Address", [Entry(item: .host(name: typed, dial: typed), title: typed, detail: "tailnet name or address",
                                          symbol: "network", chord: "", literal: true)]))
        }
        if peers.isEmpty, typed.isEmpty {
            let why = TailscaleCLI.path == nil ? "Tailscale isn’t installed on this Mac" : "No other Macs of yours are on the tailnet"
            out.append(("Your tailnet", [Entry(item: .note, title: why, detail: "type a name or address", symbol: "info.circle",
                                               chord: "", literal: true)]))
        }
        return out
    }

    static func ms(_ d: Duration) -> String {
        let v = Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
        return v < 1 ? "<1 ms" : "\(Int(v.rounded())) ms"
    }

    /// A new branch named by what is typed (from the base), then existing
    /// worktrees to reopen, then local branches not checked out anywhere.
    /// Every row starts the agent the field's mark shows.
    private func worktreeSections() -> [(String, [Entry])] {
        guard let t = worktree else { return [] }
        let id = t.chosen.map(ProgramIdentity.of) ?? .shell
        let typed = WorktreeSource.branchName(field.stringValue)
        let src = t.source
        var out: [(String, [Entry])] = []
        if !typed.isEmpty, src?.branches.contains(typed) != true {
            out.append(("New branch", [Entry(item: .worktree(typed), title: typed,
                                             detail: src?.base.map { "from \($0)" } ?? "from HEAD",
                                             symbol: "plus", chord: "", identity: id, literal: true)]))
        }
        guard let src else { return out }
        let open = src.branches.filter { src.worktrees[$0] != nil }.map {
            Entry(item: .worktree($0), title: $0, detail: "", symbol: "arrow.triangle.branch", chord: "", identity: id)
        }
        if !open.isEmpty { out.append(("Worktrees", open)) }
        let free = src.branches.filter { !src.checkedOut.contains($0) }.map {
            Entry(item: .worktree($0), title: $0, detail: "", symbol: "arrow.triangle.branch", chord: "", identity: id)
        }
        if !free.isEmpty { out.append(("Branches", free)) }
        return out
    }

    private func cycleAgent(_ d: Int) {
        guard var t = worktree, t.agents.count > 1 else { return }
        t.agent = (t.agent + d + t.agents.count) % t.agents.count
        worktree = t
        surface.lead(t.chosen.map(ProgramIdentity.of) ?? .shell)
        let keep = table.selectedRow
        refilter()
        if keep >= 0, keep < rows.count, case .entry = rows[keep] { table.selectRowIndexes([keep], byExtendingSelection: false) }
    }

    /// A session row: the icon, and the title as the sidebar shows it (the
    /// vendor name dropped beside the vendor's mark), still found by its full title.
    private func sessionEntry(_ h: HostSession, _ st: HostState, _ sid: SessionID, detail: String, chord: String) -> Entry {
        let identity = st.identity(of: sid)
        let full = st.sessionTitle(sid)
        let shown = identity.rowTitle(full)
        return Entry(item: .session(h, sid), title: shown, detail: detail, symbol: "terminal", chord: chord,
                     activity: st.activity(of: sid), need: st.need(of: sid), progress: st.progress(of: sid), identity: identity, alias: shown == full ? nil : full)
    }

    /// Go to Session: every session, grouped by what it needs from you,
    /// newest change first (idle ones in sidebar order). The
    /// one question with many agents running is "who needs me", and sidebar
    /// order (by project) does not answer it. Detail is the project and how
    /// long the session has been in its state; nothing else.
    ///
    /// A leading `!`, `.` or `~` narrows to needs-you, finished or working.
    private func agentSections() -> [(String, [Entry])] {
        struct Hit { var entry: Entry; var since: Double }
        var groups: [Activity: [Hit]] = [:]
        let now = Date().timeIntervalSince1970
        for h in model.hosts {
            guard let st = h.state else { continue }
            for w in st.workspaces {
                for sid in w.sessions where st.sessions[sid] != nil {
                    let panes = st.panes(of: sid)
                    let a = st.activity(of: sid)
                    let since = panes.filter { $0.activity == a }.map(\.activitySince).max() ?? 0
                    var detail = w.name
                    if since > 0, a != .idle { detail += " · " + SidebarViewController.elapsed(now - since) }
                    let number = owner?.sidebar.sessionNumber(host: h.id, sid).map { "⌘\($0)" } ?? ""
                    let e = sessionEntry(h, st, sid, detail: detail, chord: number)
                    // Failed sits with waiting: both need you.
                    groups[a == .error ? .blocked : a, default: []].append(Hit(entry: e, since: since))
                }
            }
        }
        let order: [(Activity, String, Character)] = [
            (.blocked, "Needs you", "!"), (.done, "Finished", "."), (.working, "Working", "~"), (.idle, "Idle", " "),
        ]
        let narrow = field.stringValue.first.flatMap { c in order.first { $0.2 == c && c != " " }?.0 }
        return order.compactMap { a, title, _ in
            guard narrow == nil || narrow == a, let hits = groups[a] else { return nil }
            // Idle sessions keep sidebar order (their ⌘n); the rest, newest change first.
            return (title, (a == .idle ? hits : hits.sorted { $0.since > $1.since }).map(\.entry))
        }
    }

    /// One glyph per command (SF Symbols, one drawing language).
    private func symbol(for c: Command) -> String {
        let map: [String: String] = [
            "palette": "command", "new-session": "plus.rectangle",
            "new-worktree": "arrow.triangle.branch", "open-editor": "chevron.left.forwardslash.chevron.right",
            "prev-prompt": "chevron.up.2", "next-prompt": "chevron.down.2",
            "new-window": "macwindow.badge.plus", "connect-host": "laptopcomputer.and.arrow.down", "open-folder": "folder",
            "reopen": "arrow.uturn.backward", "close-pane": "xmark.rectangle", "close-session": "xmark.square",
            "close-window": "xmark", "clear": "eraser", "find": "magnifyingglass", "find-next": "chevron.down", "find-previous": "chevron.up", "toggle-sidebar": "sidebar.left",
            "font-bigger": "textformat.size.larger",
            "font-smaller": "textformat.size.smaller", "font-reset": "textformat.size", "top": "arrow.up.to.line",
            "bottom": "arrow.down.to.line", "fullscreen": "arrow.up.left.and.arrow.down.right",
            "prev-session": "chevron.up", "next-session": "chevron.down", "next-attention": "bell.badge",
            "rename-session": "pencil", "split-right": "rectangle.split.2x1",
            "split-down": "rectangle.split.1x2", "prev-pane": "arrow.left.square", "next-pane": "arrow.right.square",
            "focus-left": "arrow.left", "focus-right": "arrow.right", "focus-up": "arrow.up", "focus-down": "arrow.down",
            "resize-left": "arrow.left.and.line.vertical.and.arrow.right", "resize-right": "arrow.left.and.line.vertical.and.arrow.right",
            "resize-up": "arrow.up.and.line.horizontal.and.arrow.down", "resize-down": "arrow.up.and.line.horizontal.and.arrow.down",
            "zoom": "arrow.up.left.and.arrow.down.right.square", "equalize": "square.split.2x2",
        ]
        return map[c.id] ?? "command"
    }

    private func refilter() {
        var q = field.stringValue
        // Jump to Agent's scope prefix is not part of the query.
        if mode == .agents, let c = q.first, "!.~".contains(c) { q = String(q.dropFirst()).trimmingCharacters(in: .whitespaces) }
        rows = []
        for (title, entries) in candidates() {
            var matched: [Entry] = []
            for var e in entries {
                if e.literal {
                    e.score = .max
                } else if let m = Fuzzy.match(q, in: e.title) {
                    e.positions = m.positions
                    e.score = m.score
                } else if let alias = e.alias, let m = Fuzzy.match(q, in: alias) {
                    e.positions = []
                    e.score = m.score
                } else {
                    continue
                }
                matched.append(e)
            }
            if !q.isEmpty { matched.sort { $0.score > $1.score } }
            guard !matched.isEmpty else { continue }
            rows.append(.header(title))
            rows += matched.prefix(q.isEmpty && title == "Commands" ? 40 : 60).map { .entry($0) }
        }
        table.reloadData()
        selectFirst()
        surface.showNoMatches(rows.isEmpty ? q : nil)
        if isVisible { place() }
    }

    private func selectFirst() {
        if let i = rows.firstIndex(where: { if case .entry = $0 { true } else { false } }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
            table.scrollRowToVisible(0)  // keep the first section header in view
        }
    }

    private func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        mouseActive = false
        var i = table.selectedRow
        for _ in 0 ..< rows.count {
            i = (i + d + rows.count) % rows.count
            if case .entry = rows[i] { break }
        }
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    private func hover(_ row: Int) {
        mouseActive = true
        guard row >= 0, row < rows.count, case .entry = rows[row], row != table.selectedRow else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    // MARK: Field delegate

    func controlTextDidChange(_ obj: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): activate(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        case #selector(NSResponder.insertTab(_:)) where mode == .worktree: cycleAgent(1)
        case #selector(NSResponder.insertBacktab(_:)) where mode == .worktree: cycleAgent(-1)
        default:
            // ⌃P / ⌃N as in Emacs and every picker.
            if sel == #selector(NSResponder.moveBackward(_:)) || sel == Selector(("previousLine:")) {
                move(-1)
            } else if sel == #selector(NSResponder.moveForward(_:)) || sel == Selector(("nextLine:")) {
                move(1)
            } else {
                return false
            }
        }
        return true
    }

    @objc private func clicked() { activate(table.clickedRow) }

    private func activate(_ row: Int) {
        guard row >= 0, row < rows.count, case let .entry(e) = rows[row], let owner else { return }
        if case .note = e.item { return }
        dismiss()
        switch e.item {
        case let .command(c):
            // Focus is back on the pane, so the action travels the normal responder chain.
            NSApp.sendAction(c.action, to: nil, from: self)
        case let .session(h, sid):
            owner.show(h, sid)
        case let .host(name, dial):
            owner.arrive(at: model.connect(to: AppModel.SavedHost(name: name, host: dial)))
        case let .setUp(name, dial):
            let s = AppModel.SavedHost(name: name, host: dial)
            model.setUp(s)
            if let h = model.host(at: s.endpoint) { owner.arrive(at: h) }
        case .note:
            break
        case let .worktree(branch):
            guard let t = worktree else { return }
            Task { await owner.createSession(t.host, in: t.workspace, cwd: t.dir, name: branch, launch: owner.launchLine(t.chosen, t.host),
                                             worktree: branch) }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return Axo.Metric.paletteSectionHeight }
        return Axo.Metric.paletteRow
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(title):
            let v = PaletteHeader()
            v.label.stringValue = title
            return v
        case let .entry(e):
            let cell = (tableView.makeView(withIdentifier: .init("entry"), owner: nil) as? PaletteCell) ?? PaletteCell()
            cell.identifier = .init("entry")
            cell.configure(e)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        for i in 0 ..< table.numberOfRows {
            (table.view(atColumn: 0, row: i, makeIfNecessary: false) as? PaletteCell)?.selected = i == table.selectedRow
        }
    }
}

/// The palette body: field row, one hairline, the list. No hint footer:
/// arrows, return and escape are what every list on the platform answers to.
final class PaletteSurface: Surface {
    let field = SearchField(placeholder: "")
    let table = PaletteTableView()
    private let scroll = NSScrollView()
    private let lens = Symbol("magnifyingglass", size: 16, weight: .regular, color: Axo.Color.textTertiary)
    /// In place of the lens when the palette starts something: what it starts.
    private let mark = ProgramIcon(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    private let rule = Rule(Axo.Color.borderSubtle)
    private let noMatches = Label("", font: Axo.Font.body, color: Axo.Color.textSecondary)

    init() {
        super.init(elevation: .float, radius: Axo.Metric.paletteRadius)
        let column = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowSizeStyle = .custom
        table.selectionHighlightStyle = .regular  // PaletteRowView draws the plate
        table.refusesFirstResponder = true
        table.style = .plain
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: Axo.Metric.palettePadding, left: 0, bottom: Axo.Metric.palettePadding, right: 0)
        noMatches.alignment = .center
        noMatches.isHidden = true
        mark.glyphSize = 16
        mark.isHidden = true
        for v in [lens, mark, field, rule, scroll, noMatches] as [NSView] { content.addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// `query` non-nil: nothing matched it; say so in the list's place.
    func showNoMatches(_ query: String?) {
        noMatches.isHidden = query == nil
        if let query { noMatches.stringValue = "No matches for “\(query)”" }
        needsLayout = true
    }

    /// The field's leading mark: the lens, or the program a pick will start.
    func lead(_ identity: ProgramIdentity?) {
        lens.isHidden = identity != nil
        mark.isHidden = identity == nil
        if let identity { mark.identity = identity }
    }

    func height(forList list: CGFloat) -> CGFloat {
        Axo.Metric.paletteFieldHeight + list + Axo.Metric.palettePadding * 2
    }

    override func layout() {
        super.layout()
        let b = bounds
        let fh = Axo.Metric.paletteFieldHeight
        let p = Axo.Metric.palettePadding
        let x0 = Axo.Space.xl
        lens.frame = NSRect(x: x0 - 1, y: (fh - 20) / 2, width: 20, height: 20)
        mark.frame = lens.frame
        let fs = field.intrinsicContentSize
        field.frame = NSRect(x: lens.frame.maxX + Axo.Space.md, y: ((fh - fs.height) / 2).rounded(),
                             width: b.width - lens.frame.maxX - Axo.Space.md - x0, height: fs.height)
        rule.frame = NSRect(x: 0, y: fh, width: b.width, height: rule.thickness)
        scroll.frame = NSRect(x: p, y: fh + rule.thickness, width: b.width - p * 2, height: b.height - fh - rule.thickness)
        table.tableColumns.first?.width = scroll.contentSize.width
        let ns = noMatches.intrinsicContentSize
        noMatches.frame = NSRect(x: x0, y: (scroll.frame.minY + min(scroll.frame.height, Axo.Metric.paletteEmptyHeight) / 2
                                     - ns.height / 2).rounded(), width: b.width - x0 * 2, height: ns.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    /// Opens in 160 ms: from 98 % scale and 4 pt higher, fading in (ease-out).
    func animateIn() {
        layoutSubtreeIfNeeded()
        Axo.Motion.rise(self, anchorX: layer?.bounds.midX ?? 0)
    }

    func animateOut() {
        Axo.Motion.run(Axo.Motion.tickOut, { animator().alphaValue = 0 }) { [weak self] in
            guard let self, self.alphaValue == 0 else { return }
            self.removeFromSuperview()
            self.alphaValue = 1
        }
    }
}

final class PaletteTableView: NSTableView {
    var onMouseMoved: ((Int) -> Void)?
    private var lastPoint: NSPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        // Only real pointer movement takes over from the keyboard (Otty `mouseActive`).
        let p = convert(event.locationInWindow, from: nil)
        defer { lastPoint = p }
        guard let last = lastPoint, hypot(p.x - last.x, p.y - last.y) > 1 else { return }
        onMouseMoved?(row(at: p))
    }
}

/// Draws the neutral selection plate (concentric: palette radius − padding).
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        Axo.Color.selected.setFill()
        let path = ContinuousRect.path(bounds, radius: Axo.Metric.paletteRowRadius)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.addPath(path)
        ctx.fillPath()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// A section label: sentence case, tertiary, sits on the baseline of its rows.
final class PaletteHeader: NSView {
    let label = Label("", font: Axo.Font.section, color: Axo.Color.textTertiary)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: Axo.Space.lg - 2, y: bounds.height - s.height - Axo.Space.xs, width: bounds.width - Axo.Space.lg,
                             height: s.height)
    }
}

final class PaletteCell: NSTableCellView {
    private let icon = NSImageView()
    private let program = ProgramIcon(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let state = StatusGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let title = Label("", font: Axo.Font.body, color: Axo.Color.text)
    private let detail = Label("", font: Axo.Font.small, color: Axo.Color.textTertiary)
    /// Menu-style shortcut text (`⌘1`), no key plates: a column of plates on
    /// every row is the loudest thing in a list that is about its titles.
    private let shortcut = Label("", font: Axo.Font.shortcut, color: Axo.Color.textTertiary)
    private var entry: PaletteController.Entry?
    private static let chordColumn = ceil(("⌘8" as NSString).size(withAttributes: [.font: Axo.Font.shortcut]).width)
    var selected = false {
        didSet {
            guard selected != oldValue else { return }
            icon.contentTintColor = selected ? Axo.Color.text : Axo.Color.textSecondary
            if let entry { configure(entry) }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = Axo.Color.textSecondary
        icon.imageScaling = .scaleNone
        detail.lineBreakMode = .byTruncatingMiddle
        for v in [icon, program, title, detail, state, shortcut] as [NSView] { addSubview(v) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let h = bounds.height
        let lead = Axo.Space.lg - 2
        icon.frame = NSRect(x: lead, y: (h - 20) / 2, width: 20, height: 20)
        program.frame = NSRect(x: lead + 2, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
        var right = bounds.width - Axo.Space.md
        if !shortcut.isHidden {
            let k = shortcut.intrinsicContentSize
            shortcut.frame = NSRect(x: right - k.width, y: ((h - k.height) / 2).rounded(), width: k.width, height: k.height)
            right = shortcut.frame.minX - Axo.Space.lg
        }
        if !state.isHidden {
            // One column for every session's circle, as if each had a ⌘n.
            if shortcut.isHidden { right -= Self.chordColumn + Axo.Space.lg }
            state.frame = NSRect(x: right + 1.5 - 16, y: ((h - 16) / 2).rounded(), width: 16, height: 16)
            right = state.frame.minX - Axo.Space.md
        }
        let tx = icon.frame.maxX + Axo.Space.md
        let ts = title.intrinsicContentSize
        let ds = detail.intrinsicContentSize
        // A long title gives way to its detail (up to 40% of the row): the
        // detail is what tells two similar titles apart.
        let keep = detail.stringValue.isEmpty ? 0 : min(ceil(ds.width), (right - tx) * 0.4) + Axo.Space.md
        let tw = min(ceil(ts.width), right - tx - keep)
        title.frame = NSRect(x: tx, y: ((h - ts.height) / 2).rounded(), width: max(0, tw), height: ts.height)
        let dx = title.frame.maxX + Axo.Space.md
        detail.frame = NSRect(x: dx, y: ((h - ds.height) / 2).rounded() + 0.5, width: max(0, right - dx), height: ds.height)
        detail.isHidden = detail.frame.width < 40
    }

    func configure(_ e: PaletteController.Entry) {
        entry = e
        // Sessions show what they run, with their state circle trailing;
        // commands and places carry their one SF Symbol.
        program.isHidden = e.identity == nil
        icon.isHidden = e.identity != nil
        state.activity = e.identity == nil ? .idle : e.activity
        state.need = e.need
        state.progress = e.progress
        state.isHidden = state.activity == .idle
        if let id = e.identity {
            program.identity = id
            program.lit = selected
            program.glyphSize = 13
        }
        icon.image = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)
        // Matched characters: full ink + medium weight; the rest one tier down
        // while a query is active, so the match reads at a glance.
        let base: NSColor = e.positions.isEmpty || selected ? Axo.Color.text : Axo.Color.textSecondary
        let s = NSMutableAttributedString(string: e.title, attributes: [
            .font: Axo.Font.body, .foregroundColor: base,
        ])
        let chars = Array(e.title)
        var utf16 = 0
        var offsets: [Int] = []
        for c in chars {
            offsets.append(utf16)
            utf16 += String(c).utf16.count
        }
        for i in e.positions where i < chars.count {
            let r = NSRange(location: offsets[i], length: String(chars[i]).utf16.count)
            s.addAttributes([.font: Axo.Font.title, .foregroundColor: Axo.Color.text], range: r)
        }
        title.attributedStringValue = s
        detail.stringValue = e.detail
        shortcut.stringValue = e.chord
        shortcut.textColor = selected ? Axo.Color.textSecondary : Axo.Color.textTertiary
        shortcut.isHidden = e.chord.isEmpty
        setAccessibilityLabel(e.title + (e.detail.isEmpty ? "" : ", " + e.detail))
        needsLayout = true
    }
}
