import AppKit
import AxClient
import AxModel
import AxProtocol

/// One window: our own sidebar column, the band, a session's panes and the
/// status bar, plus the in-window overlay layer (palette, toasts, tooltips).
/// No system sidebar, toolbar items or child windows: an empty compact
/// toolbar only sets the titlebar height so the traffic lights sit centred
/// in the band. Handles every window-level action in the responder chain.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let model: AppModel
    let sidebar: SidebarViewController
    let content: SessionViewController
    let shell: ShellView
    private var tokens: [SignalToken] = []
    private(set) var selection: (host: HostSession, session: SessionID)?
    private(set) lazy var palette = PaletteController(model: model, owner: self)
    private(set) var toasts: ToastCenter?
    private var branch: String?
    private var branchFor: String?

    init(model: AppModel, autosave: Bool) {
        self.model = model
        sidebar = SidebarViewController(model: model)
        content = SessionViewController(model: model)
        shell = ShellView(sidebar: sidebar.view, content: content.view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Axo.Metric.windowDefault),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed
        window.backgroundColor = Axo.Color.ground
        window.minSize = Axo.Metric.windowMin
        window.delegate = self
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        // An empty compact toolbar: titlebar height only (traffic lights centred).
        let toolbar = NSToolbar(identifier: "main")
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.contentView = shell
        window.setContentSize(Axo.Metric.windowDefault)

        if autosave { window.setFrameAutosaveName("AxolottyMain") }
        if !autosave || !window.setFrameUsingName("AxolottyMain") { window.center() }

        toasts = ToastCenter(host: shell.overlay, model: model)
        toasts?.region = { [weak self] in
            guard let self else { return .zero }
            let c = self.shell.content.frame
            let top = self.shell.titlebarHeight
            return NSRect(x: c.minX, y: top, width: c.width, height: c.height - top)
        }
        toasts?.onActivate = { [weak self] host, pane in self?.reveal(host, pane) }
        wire()
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func wire() {
        sidebar.onSelect = { [weak self] host, sid in self?.show(host, sid) }
        sidebar.onNewSession = { [weak self] in self?.newSession(nil) }
        sidebar.onCreate = { [weak self] host, wid, agent in
            guard let self else { return }
            Task { await self.createSession(host, in: wid, cwd: nil, name: nil, launch: self.launchLine(agent, host)) }
        }
        sidebar.onNewWorktree = { [weak self] host, wid in self?.palette.showWorktree(host, wid) }
        sidebar.onRemoveWorktree = { [weak self] host, sid in self?.removeWorktree(host, sid) }
        sidebar.onCloseSession = { [weak self] host, sid in self?.close(host, sid) }
        content.band.chip.onClick = { [weak self] in self?.content.current?.restoreFocus() }
        content.band.diff.onClick = { [weak self] in self?.openInEditor(nil) }
        content.emptyView.onLaunch = { [weak self] agent, wid in
            guard let self, let host = self.currentHost else { return }
            Task { await self.createSession(host, in: wid, cwd: nil, name: nil, launch: self.launchLine(agent, host)) }
        }
        content.emptyView.onOpenFolder = { [weak self] in self?.openFolder(nil) }
        content.emptyView.onRemedy = { [weak self] in
            guard let self, let host = awayHost, let remedy = host.linkRemedy else { return }
            if let target = remedy.setUp { model.setUp(target) } else { host.retry() }
        }
        sidebar.footer.onJump = { [weak self] activity in self?.jump(to: activity) }
        tokens.append(model.anyChange.observe { [weak self] host, change in self?.hostChanged(host, change) })
        tokens.append(model.hostsChanged.observe { [weak self] in self?.hostsChanged() })
        tokens.append(model.themeChanged.observe { [weak self] in self?.applyTheme() })
        tokens.append(model.fontChanged.observe { [weak self] in self?.content.refreshAppearance() })
        shell.onLayout = { [weak self] in
            guard let self else { return }
            // The band clears the traffic lights and the toggle wherever the
            // content column currently starts (it moves while the sidebar springs).
            let clear = self.shell.collapsedLeading - self.shell.content.frame.minX
            self.content.bandHeight = self.shell.titlebarHeight
            self.content.leadingClearance = max(Axo.Space.xl, clear)
            self.content.stageLeading = Axo.Metric.sheetInset * (1 - self.shell.reveal)
            self.toasts?.relayout()
        }
        shell.onContentMotion = { [weak self] moving in
            self?.content.setGridsFrozen(moving)
        }
    }

    private func applyTheme() {
        let t = model.theme
        DesignTokens.install(t)
        window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = Axo.Color.rgb(t.background)
        shell.refreshDesign()
        content.refreshAppearance()
        sidebar.refreshVisibleRows()
    }

    // MARK: Selection

    /// Shows a session in this window and returns focus to its terminal.
    func show(_ host: HostSession, _ sid: SessionID, focus pane: PaneID? = nil) {
        guard let info = host.session(sid) else { return }
        // Going somewhere else meanwhile means the person moved on.
        if arriving !== host { arriving = nil }
        selection = (host, sid)
        sidebar.select(host: host.id, session: sid)
        content.show(host, info, animated: true)
        if let pane { content.current?.focus(pane) }
        content.current?.onFocusChange = { [weak self] _ in self?.refreshChrome() }
        if host.isLocal {
            UserDefaults.standard.set(sid.raw.uuidString, forKey: "lastSession")
            UserDefaults.standard.set(info.workspace.raw.uuidString, forKey: "lastWorkspace")
        }
        refreshChrome()
    }

    /// Shows the pane's session and focuses the pane.
    func reveal(_ host: HostSession, _ pane: PaneID) {
        guard let sid = host.pane(pane)?.session else { return }
        show(host, sid, focus: pane)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func hostChanged(_ host: HostSession, _ change: HostChange) {
        switch change {
        case .connected:
            content.sync(host)
            content.linkChanged(host)
            if arriving === host {
                arrive(at: host)
            } else if selection == nil || selection?.host === host {
                selectInitial(host)
            }
        case .deltas:
            content.sync(host)
            if let s = selection, s.host === host, host.session(s.session) == nil { selectNeighbor(host) }
            if selection == nil { selectInitial(host) }
        case .disconnected:
            // A session on screen stays there, veiled, while its host comes
            // back: a drop is routine on a remote link, and the work is still
            // worth reading. Only a window with nothing of it shown says so whole.
            content.linkChanged(host)
            let waitingElsewhere = arriving.map { $0 !== host } ?? false
            if (selection == nil && !waitingElsewhere) || (selection?.host === host && content.current?.host !== host) {
                showAway(host)
            }
        case .event:
            break
        case .latency:
            return
        case .setup:
            content.linkChanged(host)
            if awayHost === host, content.current == nil { showAway(host) }
            return
        }
        refreshChrome()
    }

    /// A host was added or forgotten: a window on a forgotten one moves on.
    private func hostsChanged() {
        content.dropHosts(except: Set(model.hosts.map(\.id)))
        if let s = selection, !model.hosts.contains(where: { $0 === s.host }) {
            selection = nil
            if let local = model.local { selectNeighbor(local) } else { showLauncher() }
        }
        refreshChrome()
    }

    /// The host the person asked to go to, until it answers.
    private weak var arriving: HostSession?

    /// The person chose this host (Connect to Host): go there as soon as it
    /// answers, to its first session, or to a fresh shell in its home when
    /// it has none, the way a first launch opens one on this Mac.
    func arrive(at host: HostSession) {
        guard let st = host.state, host.phase == .connected else {
            // The window goes there now and says how the link is doing
            // (connecting, or why it can't, with the one thing to do), not
            // a line in the sidebar under a session the person just left.
            arriving = host
            selection = nil
            sidebar.deselect()
            showAway(host)
            refreshChrome()
            return
        }
        arriving = nil
        if let first = st.orderedSessions.first {
            show(host, first)
        } else {
            Task { await createSession(host, in: st.workspaces.first?.id, cwd: nil, name: nil) }
        }
    }

    private func selectInitial(_ host: HostSession) {
        guard let st = host.state else { return }
        if let s = selection, s.host === host, host.session(s.session) != nil {
            show(host, s.session)
            return
        }
        let last = UserDefaults.standard.string(forKey: "lastSession").flatMap(SessionID.init)
        if let last, st.sessions[last] != nil {
            show(host, last)
        } else if let first = st.orderedSessions.first {
            show(host, first)
        } else if host.isLocal, model.bootstrap(host) {
            // First run against a fresh server: open a Home session right away.
            Task { await createSession(host, in: st.workspaces.first?.id, cwd: nil, name: nil) }
        } else {
            selection = nil
            showLauncher()
        }
    }

    /// The host whose away sheet is up (nil: none is).
    private weak var awayHost: HostSession?

    /// A whole window for a host out of reach: why, and the one thing to do.
    private func showAway(_ host: HostSession) {
        awayHost = host
        let status = host.linkStatus ?? ("Reconnecting to \(host.name)", true)
        content.showEmpty(.away(title: status.text, detail: host.linkDetail, retrying: status.retrying,
                                action: host.linkRemedy?.title,
                                machine: host.waitsForTheMac ? SidebarViewController.hostSymbol(host) : nil))
    }

    /// The empty window: launch tiles for this host's agents, starting in the
    /// last project used (or the first).
    private func showLauncher() {
        let host = currentHost
        let projects = host?.state?.workspaces.map {
            EmptyStateView.Project(id: $0.id, name: $0.name, key: $0.root.isEmpty ? $0.name : $0.root)
        } ?? []
        let last = UserDefaults.standard.string(forKey: "lastWorkspace").flatMap(UUID.init(uuidString:)).map(WorkspaceID.init(raw:))
        content.emptyView.configure(agents: AgentPresets.available(local: host?.isLocal ?? true), projects: projects,
                                    selected: projects.first { $0.id == last })
        awayHost = nil
        content.showEmpty(.noSessions)
    }

    private func selectNeighbor(_ host: HostSession) {
        let order = model.sidebarOrder
        if let next = order.first(where: { $0.0 === host }) {
            show(next.0, next.1)
        } else if let any = order.first {
            show(any.0, any.1)
        } else {
            selection = nil
            showLauncher()
            refreshChrome()
        }
    }

    // MARK: Chrome (band, chip, status bar, title)

    func refreshChrome() {
        let key = window?.isKeyWindow ?? true
        let counts = model.hosts.reduce((blocked: 0, error: 0, working: 0, done: 0)) { acc, h in
            guard let a = h.state?.attention else { return acc }
            return (acc.blocked + a.blocked, acc.error + a.error, acc.working + a.working, acc.done + a.done)
        }
        sidebar.footer.update(counts: counts)
        guard let (host, sid) = selection, let st = host.state, let s = st.sessions[sid] else {
            content.band.update(nil, key: key)
            content.band.isHidden = content.current == nil  // the empty sheet says it
            content.band.chip.isHidden = true
            branchFor = nil
            content.band.diff.set(nil)
            // A window waiting on a far Mac is that Mac's (Mission Control, ⌘`).
            window?.title = content.current == nil ? awayHost?.name ?? "Axolotty" : "Axolotty"
            return
        }
        content.band.isHidden = false
        let focusedPane = content.current?.focused ?? s.focus
        let pane = st.panes[focusedPane]
        let title = st.sessionTitle(sid)
        let cwd = pane?.pwd ?? ""
        let identity = st.identity(of: sid)
        let activity = st.activity(of: sid)
        let since = st.panes(of: sid).filter { $0.activity == activity }.map(\.activitySince).max() ?? 0
        let ws = st.workspace(s.workspace)
        func band() -> BandView.Context {
            BandView.Context(project: ws?.name ?? host.name, projectKey: ws.map { $0.root.isEmpty ? $0.name : $0.root } ?? host.name,
                             session: identity.rowTitle(title), identity: identity, activity: activity, since: since,
                             branch: branch, subagents: st.panes(of: sid).reduce(0) { $0 + $1.status.subagentsWorking },
                             host: host.isLocal ? nil : (host.name, SidebarViewController.hostSymbol(host)))
        }
        // Mission Control and the Window menu say which Mac, as the band does.
        window?.title = host.isLocal ? title : "\(title) — \(host.name)"
        updateChip(st, sid)
        // Branch and diff chip follow the focused pane's tree, wherever it is.
        if cwd.isEmpty {
            branchFor = nil
            branch = nil
            content.band.diff.set(nil)
        } else {
            let place = "\(host.id) \(cwd)"
            if branchFor != place {
                branchFor = place
                let hit = GitFacts.cached(host, cwd)
                branch = hit?.branch
                content.band.diff.set(hit?.changes)
            }
            Task { [weak self] in
                let r = await GitFacts.lookup(host, cwd)
                guard let self, self.branchFor == place else { return }
                self.branch = r.branch
                self.content.band.update(band(), key: key)
                self.content.band.diff.set(r.changes)
                self.content.band.needsLayout = true
            }
        }
        content.band.update(band(), key: key)
        content.band.needsLayout = true
    }

    /// The chip speaks only when the shown session wants the person: an agent
    /// waiting for input (with its own question) or failed. Working and done
    /// are already told by the sidebar mark and the terminal itself. In a
    /// split, the asking pane's strip already floods with the question, so the
    /// chip stays away unless that pane is hidden behind a zoomed one (one
    /// answer per question, design-system §1.3).
    private func updateChip(_ st: HostState, _ sid: SessionID) {
        let chip = content.band.chip
        let panes = st.panes(of: sid)
        guard let p = panes.max(by: { $0.activity < $1.activity }), p.activity == .blocked || p.activity == .error else {
            setChip(hidden: true)
            return
        }
        // Strips show when the split is not zoomed; zoomed onto the asking
        // pane there is no strip either, so the chip speaks.
        if panes.count > 1, st.sessions[sid]?.zoomed == nil {
            setChip(hidden: true)
            return
        }
        if p.activity == .blocked {
            chip.update(.blocked, text: String((p.status.headline?.ask ?? "Needs input").prefix(48)))
        } else {
            chip.update(.error, text: "Failed")
        }
        setChip(hidden: false)
    }

    private func setChip(hidden: Bool) {
        let chip = content.band.chip
        guard chip.isHidden != hidden else {
            content.band.needsLayout = true
            return
        }
        if hidden {
            Axo.Motion.fade(in: false, { chip.animator().alphaValue = 0 }) {
                chip.isHidden = true
                chip.alphaValue = 1
            }
        } else {
            content.band.needsLayout = true
            Axo.Motion.reveal(chip, on: Axo.Motion.swift)
        }
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        refreshChrome()
        content.current?.restoreFocus()
        (NSApp.delegate as? AppDelegate)?.windowBecameKey(self)
    }

    func windowDidResignKey(_ notification: Notification) { refreshChrome() }

    func windowWillClose(_ notification: Notification) {
        palette.dismiss()
        (NSApp.delegate as? AppDelegate)?.windowClosed(self)
    }

    // MARK: Actions: sessions and workspaces

    private var currentHost: HostSession? { selection?.host ?? model.local ?? model.hosts.first }

    @objc func newSession(_ sender: Any?) {
        guard let host = currentHost, let st = host.state else { return }
        let ws = selection.flatMap { st.sessions[$0.session]?.workspace } ?? st.workspaces.first?.id
        Task { await createSession(host, in: ws, cwd: nil, name: nil) }
    }

    /// Creates a session (and a Home workspace if the host has none) and shows it.
    /// `launch`: a command typed into the new shell once it exists (an agent
    /// preset). Typed, not spawned, so the pane keeps the person's shell with
    /// its integration and history, and survives the program exiting.
    /// The line that starts `agent` in a new session on `host` (nil: a shell).
    func launchLine(_ agent: AgentKind?, _ host: HostSession, args: String = "") -> String? {
        agent.map { AgentPresets.launchLine($0, args: args, local: host.isLocal) }
    }

    func createSession(_ host: HostSession, in workspace: WorkspaceID?, cwd: String?, name: String?,
                       launch: String? = nil, worktree: String? = nil) async {
        var wid = workspace
        if wid == nil {
            let w = WorkspaceID()
            guard await host.performAndWait(.createWorkspace(w, name: "Home", root: host.isLocal ? NSHomeDirectory() : ""))
            else { return }
            wid = w
        }
        guard let wid else { return }
        let sid = SessionID()
        let pane = PaneID()
        let ok = await host.performAndWait(.createSession(sid, workspace: wid, pane: pane,
                                                          recipe: SpawnRecipe(cwd: cwd, worktree: worktree), name: name))
        guard ok else { return }
        // The PTY buffers it until the shell reads its first line, as typeahead.
        if let launch { host.connection.send(.text(pane, launch + "\r")) }
        show(host, sid)
    }

    @objc func openFolder(_ sender: Any?) {
        guard let window, let host = currentHost else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a workspace."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            self?.openWorkspace(host, root: url.path(percentEncoded: false))
        }
    }

    private func openWorkspace(_ host: HostSession, root: String) {
        let trimmed = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        if let existing = host.state?.workspaces.first(where: { $0.root == trimmed }) {
            if let sid = existing.sessions.first { show(host, sid) } else {
                Task { await createSession(host, in: existing.id, cwd: nil, name: nil) }
            }
            return
        }
        let name = URL(filePath: trimmed).lastPathComponent
        let wid = WorkspaceID()
        Task {
            guard await host.performAndWait(.createWorkspace(wid, name: name, root: trimmed)) else { return }
            await createSession(host, in: wid, cwd: nil, name: nil)
        }
    }

    @objc func closeSession(_ sender: Any?) {
        guard let (host, sid) = selection else { return }
        close(host, sid)
    }

    /// Every way of closing a session comes here, so ⇧⌘T can bring it back.
    func close(_ host: HostSession, _ sid: SessionID) {
        guard let s = host.session(sid) else { return }
        let claude = host.state?.claudePane(of: sid)
        model.closed.append(AppModel.ClosedSession(host: host.id, session: sid, workspace: s.workspace,
                                                   cwd: host.pane(claude ?? s.focus)?.pwd ?? "", name: s.name,
                                                   claude: claude != nil))
        host.perform(.closeSession(sid, reopenable: true))
    }

    @objc func reopenClosedSession(_ sender: Any?) {
        guard let c = model.closed.popLast(), let host = model.host(c.host) else { return }
        let ws = host.state?.workspace(c.workspace)?.id ?? host.state?.workspaces.first?.id
        // Claude Code resumes the conversation it had (`--resume <uuid>`, the
        // id the host read as the session closed). Without one it opens
        // Claude's own picker (`--resume`), not `--continue`: the latest
        // conversation in the folder may be another session's. A conversation
        // never written to can't be resumed (exit 1, where quitting Claude
        // exits 0), so a fresh Claude follows `||`. Anything else comes back
        // as a shell there.
        var launch: String?
        if c.claude, let fresh = launchLine(.claude, host),
           let back = launchLine(.claude, host, args: "--resume" + (c.conversation.map { " " + $0 } ?? "")) {
            launch = back + " || " + fresh
        }
        Task { await createSession(host, in: ws, cwd: c.cwd.isEmpty ? nil : c.cwd, name: c.name, launch: launch) }
    }

    @objc func renameSession(_ sender: Any?) {
        guard let (host, sid) = selection else { return }
        sidebar.rename(host, sid)
    }

    @objc func selectSessionByNumber(_ sender: Any?) {
        guard let n = (sender as? NSMenuItem)?.tag else { return }
        let order = model.sidebarOrder
        guard !order.isEmpty else { return }
        let pick = n == 9 ? order[order.count - 1] : (n - 1 < order.count ? order[n - 1] : nil)
        if let (h, s) = pick { show(h, s) }
    }

    @objc func selectNextSession(_ sender: Any?) { step(1) }
    @objc func selectPreviousSession(_ sender: Any?) { step(-1) }

    private func step(_ d: Int) {
        let order = model.sidebarOrder
        guard !order.isEmpty else { return }
        let i = order.firstIndex { $0.0 === selection?.host && $0.1 == selection?.session } ?? 0
        let (h, s) = order[(i + d + order.count) % order.count]
        show(h, s)
    }

    @objc func selectNextAttention(_ sender: Any?) { jump(to: nil) }

    /// Cycles through panes that need the person (waiting first), or through
    /// panes of one activity when the sidebar's census asks.
    private func jump(to activity: Activity?) {
        var list = model.attentionPanes()
        if let activity {
            list = model.hosts.flatMap { h in
                (h.state?.orderedSessions ?? []).flatMap { sid in
                    (h.state?.panes(of: sid) ?? []).filter { $0.activity == activity }.map { (h, $0) }
                }
            }
        }
        guard !list.isEmpty else { return }
        let current = content.current?.focused
        let i = list.firstIndex { $0.1.id == current }
        let next = i.map { ($0 + 1) % list.count } ?? 0
        let (h, p) = list[next]
        reveal(h, p.id)
    }

    // MARK: Actions: view

    @objc func increaseFontSize(_ sender: Any?) { model.setFontSize(model.prefs.fontSize + 1) }
    @objc func decreaseFontSize(_ sender: Any?) { model.setFontSize(model.prefs.fontSize - 1) }
    @objc func resetFontSize(_ sender: Any?) { model.setFontSize(Axo.Font.terminalSize) }

    @objc func toggleSessionSidebar(_ sender: Any?) { shell.toggleSidebar() }

    @objc func showCommandPalette(_ sender: Any?) { palette.toggle(.commands) }
    @objc func showJumpToAgent(_ sender: Any?) { palette.toggle(.agents) }
    @objc func showConnectToHost(_ sender: Any?) { palette.toggle(.hosts) }

    /// ⌥⌘T: a session on its own branch, in a worktree of the current project.
    @objc func newWorktreeSession(_ sender: Any?) {
        guard let host = currentHost,
              let wid = selection.flatMap({ host.session($0.session)?.workspace }) ?? host.state?.workspaces.first?.id
        else { NSSound.beep(); return }
        // The focused pane's repository when it is in one (a project's
        // root need not be), else the project's root.
        let cwd = currentCwd.flatMap { SidebarViewController.inRepository($0) ? LinkOpener.projectRoot($0) : nil }
        palette.showWorktree(host, wid, from: cwd)
    }

    @objc func removeWorktreeSession(_ sender: Any?) {
        guard let (host, sid) = selection else { return }
        removeWorktree(host, sid)
    }

    /// Closes a worktree session and removes its folder; asks first, and
    /// again in stronger words when the tree has changes. The branch stays.
    func removeWorktree(_ host: HostSession, _ sid: SessionID) {
        guard let window, let path = host.session(sid)?.worktree else { return }
        let branch = host.session(sid)?.name ?? URL(filePath: path).lastPathComponent
        let ask = NSAlert()
        ask.messageText = "Remove the worktree for “\(branch)”?"
        ask.informativeText = "The session closes and its folder, .worktrees/\(URL(filePath: path).lastPathComponent), is deleted. The branch and its commits stay."
        ask.addButton(withTitle: "Remove")
        ask.addButton(withTitle: "Cancel")
        ask.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                do {
                    try await host.connection.perform(.removeWorktree(sid, force: false))
                } catch ConnectionError.intent(.dirty) {
                    self?.confirmDirtyRemoval(host, sid, branch: branch)
                } catch let e as ConnectionError {
                    self?.model.errors.emit(HostSession.describe(e))
                } catch {}
            }
        }
    }

    private func confirmDirtyRemoval(_ host: HostSession, _ sid: SessionID, branch: String) {
        guard let window else { return }
        let ask = NSAlert()
        ask.alertStyle = .critical
        ask.messageText = "“\(branch)” has uncommitted changes"
        ask.informativeText = "Removing the worktree deletes them. Commit or stash them first to keep them."
        let remove = ask.addButton(withTitle: "Delete Changes and Remove")
        remove.hasDestructiveAction = true
        ask.addButton(withTitle: "Cancel")
        ask.beginSheetModal(for: window) { r in
            guard r == .alertFirstButtonReturn else { return }
            host.perform(.removeWorktree(sid, force: true))
        }
    }

    // MARK: Changes

    /// The focused pane's host and directory.
    private var focusedDir: (host: HostSession, dir: String)? {
        guard let (host, sid) = selection, let st = host.state, let s = st.sessions[sid],
              let dir = st.panes[content.current?.focused ?? s.focus]?.pwd, !dir.isEmpty
        else { return nil }
        return (host, dir)
    }

    /// The focused pane's directory when it is on this Mac.
    private var currentCwd: String? { focusedDir.flatMap { $0.host.isLocal ? $0.dir : nil } }

    /// ⌥⌘O: the focused pane's project (its repository, else its folder) in
    /// the editor; a far pane's opens on its host, over SSH.
    @objc func openInEditor(_ sender: Any?) {
        guard let (host, dir) = focusedDir else { NSSound.beep(); return }
        guard let far = host.far else { return LinkOpener.openFolder(LinkOpener.projectRoot(dir)) }
        Task { @MainActor in
            let root = await GitFacts.lookup(host, dir).changes?.root ?? dir
            if !LinkOpener.openFar(HostPath(path: root, isFolder: true), on: far) { NSSound.beep() }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeSession(_:)), #selector(renameSession(_:)):
            return selection != nil
        case #selector(reopenClosedSession(_:)):
            return !model.closed.isEmpty
        case #selector(removeWorktreeSession(_:)):
            return selection.flatMap { $0.host.session($0.session)?.worktree } != nil
        case #selector(openInEditor(_:)):
            guard let (host, _) = focusedDir else { return false }
            return host.far.map(LinkOpener.opensFar) ?? true
        case #selector(toggleSessionSidebar(_:)):
            item.title = shell.collapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(selectNextAttention(_:)):
            return !model.attentionPanes().isEmpty
        case #selector(newSession(_:)), #selector(openFolder(_:)):
            return currentHost?.phase == .connected
        default:
            return true
        }
    }
}
