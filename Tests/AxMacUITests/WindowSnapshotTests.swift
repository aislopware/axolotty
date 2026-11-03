import AppKit
import AxClient
@testable import AxMacUI
import AxModel
import AxProtocol
import Foundation
import Testing

/// The whole window, as a person working on a far Mac sees it: the sidebar, a session
/// split in two with its band and strips, and the palette over it. Built by the real
/// window controller from a host shown without connecting, in a window never ordered in.
/// The terminals are Metal views and come out empty; their text is checked elsewhere.
@Suite("Window snapshots", .serialized)
@MainActor
struct WindowSnapshotTests {
    /// One project on a far Mac with a two-pane session first in the list.
    static func state() -> (HostState, SessionID) {
        var st = SidebarSnapshotTests.state()
        st.name = "MacBook Pro"
        let w = st.workspaces[0]
        let sid = SessionID()
        let left = SidebarSnapshotTests.pane(sid, title: "Window snapshots", program: "claude", agent: .claude, state: .working,
                                             ago: 252.5)
        let right = SidebarSnapshotTests.pane(sid, title: "", program: "zsh", agent: nil, state: nil, ago: 1500)
        st.panes[left.id] = left
        st.panes[right.id] = right
        var info = SessionInfo(id: sid, workspace: w.id, root: left.id)
        info.tree = .split(.horizontal, ratio: 0.5, .leaf(left.id), .leaf(right.id))
        st.sessions[sid] = info
        st.workspaces[0].sessions.insert(sid, at: 0)
        return (st, sid)
    }

    /// A window controller showing the split session, from a host shown without connecting.
    static func window() -> (MainWindowController, HostSession, SessionID, String) {
        let suite = "axolotty.snapshots.\(UUID().uuidString)"
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!)
        let host = HostSession(endpoint: .unix(path: "/nonexistent"), client: ClientID(), clientName: "test", isLocal: false)
        model.add(host, connect: false)
        let (st, sid) = Self.state()
        host.show(st)
        let wc = MainWindowController(model: model, autosave: false)
        wc.window!.setContentSize(Axo.Metric.windowDefault)
        wc.show(host, sid)
        return (wc, host, sid, suite)
    }

    static func badges(_ view: NSView) -> [PaneBadge] {
        view.subviews.flatMap { ($0 as? PaneBadge).map { [$0] } ?? badges($0) }.filter { !$0.isHidden && $0.alphaValue > 0 }
    }

    /// A pane opening is sized several times in one turn; none is a resize, so no size
    /// shows. A resize after shows it. (The first window picture had "54 × 39" on both.)
    @Test func aPaneShowsItsSizeOnAResizeNotOnOpening() async throws {
        let (wc, _, _, suite) = Self.window()
        defer {
            wc.window?.close()
            UserDefaults().removePersistentDomain(forName: suite)
        }
        let content = wc.window!.contentView!
        content.layoutSubtreeIfNeeded()
        #expect(Self.badges(content).isEmpty)
        for _ in 0 ..< 3 { await Task.yield() }
        var size = Axo.Metric.windowDefault
        size.height -= 120
        wc.window!.setContentSize(size)
        content.layoutSubtreeIfNeeded()
        #expect(Self.badges(content).count == 2)
    }

    @Test func aSplitSessionAndThePalette() throws {
        let suite = "axolotty.snapshots.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!)
        let host = HostSession(endpoint: .unix(path: "/nonexistent"), client: ClientID(), clientName: "test", isLocal: false)
        model.add(host, connect: false)
        let (st, sid) = Self.state()
        host.show(st)
        let wc = MainWindowController(model: model, autosave: false)
        defer { wc.window?.close() }
        wc.window!.setContentSize(Axo.Metric.windowDefault)
        wc.show(host, sid)
        try Snapshot.expect(Snapshot.render(window: wc.window!, scale: 1), named: "window@1x")
        wc.palette.toggle(.commands)
        try Snapshot.expect(Snapshot.render(window: wc.window!, scale: 1), named: "window-palette@1x")
    }

    /// Settings is a form centred in its window. Not a picture: its font list, and so its
    /// width, is whatever this Mac has installed.
    @Test func settingsIsACentredForm() throws {
        let suite = "axolotty.snapshots.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let wc = SettingsWindowController(model: AppModel(defaults: UserDefaults(suiteName: suite)!))
        defer { wc.window?.close() }
        let content = wc.window!.contentView!
        content.layoutSubtreeIfNeeded()
        let grid = try #require(content.subviews.first { $0 is NSGridView })
        #expect(abs(grid.frame.midX - content.bounds.midX) <= 0.5)
        #expect(grid.frame.minX >= 24)
    }

    /// The far Mac drops while a split session is open: the panes stay, dimmed, under the
    /// bar that says it is coming back. The moment remote work must not feel remote.
    @Test func aSessionWhoseMacDropped() throws {
        let suite = "axolotty.snapshots.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: UserDefaults(suiteName: suite)!)
        let host = HostSession(endpoint: .unix(path: "/nonexistent"), client: ClientID(), clientName: "test", isLocal: false)
        model.add(host, connect: false)
        let (st, sid) = Self.state()
        host.show(st, phase: .connecting)
        let wc = MainWindowController(model: model, autosave: false)
        defer { wc.window?.close() }
        wc.window!.setContentSize(Axo.Metric.windowDefault)
        wc.show(host, sid)
        try Snapshot.expect(Snapshot.render(window: wc.window!, scale: 1), named: "window-reconnecting@1x")
    }
}
