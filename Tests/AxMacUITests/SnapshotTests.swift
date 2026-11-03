import AppKit
@testable import AxMacUI
import AxModel
import AxProtocol
import Testing

/// The components as they are drawn, against references (`Snapshots/`), at 1× (where craft
/// is judged) and 2×. Drawn offscreen in a window never shown, so a run takes no focus.
/// References are of macOS 27's system font: `AXSNAPSHOT_RECORD=1` redraws them after an
/// intended change or an OS update, and each new picture is looked at before it is committed.
@Suite("Snapshots", .serialized)
struct SnapshotTests {
    static func check(_ sheet: Sheet, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for scale: CGFloat in [1, 2] {
            try Snapshot.expect(Snapshot.render(sheet, size: sheet.size, scale: scale), named: "\(name)@\(Int(scale))x",
                                sourceLocation: sourceLocation)
        }
    }

    @Test func theSameViewDrawsTheSamePixelsAndOneWordMoreIsSeen() {
        // The canary: drawing is deterministic, and the comparison sees a small change.
        let a = Snapshot.render(Button("Restart"), size: NSSize(width: 90, height: 28))
        let b = Snapshot.render(Button("Restart"), size: NSSize(width: 90, height: 28))
        #expect(Snapshot.difference(a, b).pixels == 0)
        let c = Snapshot.render(Button("Restarts"), size: NSSize(width: 90, height: 28))
        #expect(Snapshot.difference(a, c).pixels > 0)
        let d = Snapshot.render(Button("Restart", variant: .primary), size: NSSize(width: 90, height: 28))
        #expect(Snapshot.difference(a, d).pixels > 100, "a variant's plate")
    }

    @Test func buttons() throws {
        var rows: [(NSView, NSSize?)] = []
        for v in [Button.Variant.primary, .secondary, .ghost, .danger] {
            for s in [Button.Size.small, .regular, .large] { rows.append((Button("Connect", variant: v, size: s), nil)) }
        }
        rows.append((Button("New Session", symbol: "plus", variant: .secondary), nil))
        rows.append((IconButton(symbol: "sidebar.left", label: "Sidebar"), nil))
        try Self.check(Sheet(rows), "buttons")
    }

    @Test func chipsAndKeys() throws {
        var rows: [(NSView, NSSize?)] = []
        // As the band shows them: an agent's question, or a failure.
        for (a, text) in [(Activity.blocked, "Allow Bash: swift test --filter Quic?"), (.blocked, "Needs input"),
                          (.error, "Failed")]
        {
            let c = Chip()
            c.update(a, text: text)
            rows.append((c, nil))
        }
        let diff = DiffChip()
        diff.set(GitChanges(root: "/r", files: [.init(path: "a.swift", added: 412, removed: 96, kind: .modified)]))
        rows.append((diff, nil))
        rows.append((Keycaps("⌘K"), nil))
        rows.append((Keycaps("⇧⌘P"), nil))
        try Self.check(Sheet(rows), "chips")
    }

    @Test func toasts() throws {
        let error = ToastView(.init(title: "Mac Studio", body: "Lost the link: the host stopped answering",
                                    activity: .error, host: nil, pane: nil))
        let long = ToastView(.init(title: "MacBook Pro", body: "The server on this Mac answered with an older protocol, so its panes are read-only until it is updated. "
                                       + "Update it from the sidebar, or run axolotty setup on that Mac.",
                                   activity: .error, host: nil, pane: nil))
        let w: CGFloat = 340
        try Self.check(Sheet([(error, NSSize(width: w, height: error.height(for: w))),
                              (long, NSSize(width: w, height: long.height(for: w)))]), "toasts")
    }

    @Test func cards() throws {
        var card = HoverCard(title: "axolotty")
        card.facts = [HoverCard.Fact(.state(.working, nil), "Claude is editing Frame.swift"),
                      HoverCard.Fact(.symbol("folder"), "~/Workspace/oss/aislopware/axolotty", truncation: .byTruncatingMiddle)]
        let ended = EndedBar()
        ended.set(code: 130)
        let crashed = EndedBar()
        crashed.set(code: 139)
        let find = FindCard()
        find.field.stringValue = "QuicLink"
        find.show(total: 12, index: 2)
        let badge = PaneBadge()
        badge.show(cols: 120, rows: 40)
        try Self.check(Sheet([(TooltipView("Split Right  ⌘D"), nil), (HoverCardView(card), nil),
                              (ended, NSSize(width: ended.preferredWidth, height: EndedBar.height)),
                              (crashed, NSSize(width: crashed.preferredWidth, height: EndedBar.height)),
                              (find, FindCard.size), (badge, NSSize(width: badge.preferredWidth, height: PaneBadge.height))]),
                       "cards")
    }

    /// The band over a pane: a local Claude at work with its branch and subagents, a far
    /// Mac's shell, and the same far band when the window is not key.
    @Test func bands() throws {
        let now = Date().timeIntervalSince1970
        let size = NSSize(width: 720, height: Axo.Metric.bandHeight)
        let local = BandView()
        local.update(.init(project: "axolotty", session: "Claude", identity: .of(.claude), activity: .working,
                           since: now - 252.5, branch: "main", subagents: 2, host: nil), key: true)
        local.diff.set(GitChanges(root: "/r", files: [.init(path: "Frame.swift", added: 412, removed: 96, kind: .modified)]))
        let far = BandView()
        far.update(.init(project: "slopty", session: "zsh", identity: .shell, activity: .idle, since: 0,
                         branch: "quic-pacer", host: ("MacBook Pro", "laptopcomputer")), key: true)
        let away = BandView()
        away.update(.init(project: "slopty", session: "zsh", identity: .shell, activity: .idle, since: 0,
                          branch: "quic-pacer", host: ("MacBook Pro", "laptopcomputer")), key: false)
        try Self.check(Sheet([(local, size), (far, size), (away, size)]), "bands")
    }

    /// The bar over a session whose host is out of reach, in its three kinds: coming back
    /// by itself, waited for, and waiting on the person. Its real copy.
    @Test func veils() throws {
        let size = NSSize(width: 640, height: LinkVeil.barHeight)
        let back = LinkVeil(frame: NSRect(origin: .zero, size: size))
        back.set("Reconnecting to MacBook Pro", retrying: true, action: "Reconnect Now") {}
        let offline = LinkVeil(frame: NSRect(origin: .zero, size: size))
        offline.set("MacBook Pro is offline", retrying: true, idle: true, action: nil, nil)
        let behind = LinkVeil(frame: NSRect(origin: .zero, size: size))
        behind.set("MacBook Pro runs another Axolotty version", retrying: false, action: "Update There") {}
        for v in [back, offline, behind] { v.show(animated: false) }
        try Self.check(Sheet([(back, size), (offline, size), (behind, size)]), "veils")
    }

    /// The window's empty sheet, at the window's least size: the launcher, and a far Mac
    /// out of reach in its two kinds, waited for and waiting on the person. Its real copy.
    @Test func emptyWindow() throws {
        let size = Axo.Metric.windowMin
        let launcher = EmptyStateView()
        launcher.configure(agents: [.claude, .codex, .gemini], projects: [.init(id: WorkspaceID(), name: "axolotty", key: "axolotty")],
                           selected: nil)
        let offline = EmptyStateView()
        offline.set(.away(title: "MacBook Pro is offline",
                          detail: "Tailscale last saw it 50 minutes ago. Your sessions keep running there; "
                              + "this window reattaches the moment it’s back.",
                          retrying: true, action: nil, machine: "laptopcomputer"))
        let setUp = EmptyStateView()
        setUp.set(.away(title: "Axolotty isn’t running on MacBook Pro",
                        detail: "MacBook Pro is reachable. Set Axolotty up there over SSH and this Mac connects by itself.",
                        retrying: false, action: "Set Up over SSH", machine: "laptopcomputer"))
        for (view, name) in [(launcher, "empty-launcher"), (offline, "empty-offline"), (setUp, "empty-setup")] {
            try Snapshot.expect(Snapshot.render(view, size: size, scale: 1, margin: 0, on: Axo.Color.frame), named: "\(name)@1x")
        }
    }
}
