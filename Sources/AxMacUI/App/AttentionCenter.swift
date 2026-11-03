import AppKit
import AxModel
import AxProtocol
import UserNotifications

/// Routes host events to the person (spec §1.4): a toast when the app is active
/// but the pane is not on screen, a system notification when the app is in the
/// background, and the Dock badge for waiting or failed panes at all times.
/// A notice from a far Mac names it.
/// A notice is withdrawn (banner and toast) once its pane no longer wants
/// the person: they looked, or it moved on. One banner per pane: a newer
/// state replaces the older. Waiting is Time Sensitive (breaks through a
/// Focus) and sounds; failed sounds; done is quiet. A state change waits a
/// second before it speaks: a permission a rule grants at once, or a finish
/// the person is already watching, never reaches them.

final class AttentionCenter: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var tokens: [SignalToken] = []
    private var authorized: Bool?
    var keyWindow: () -> MainWindowController?

    /// UNUserNotificationCenter needs a bundle (absent under `swift run`).
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    init(model: AppModel, keyWindow: @escaping () -> MainWindowController?) {
        self.model = model
        self.keyWindow = keyWindow
        super.init()
        tokens.append(model.anyChange.observe { [weak self] host, change in
            switch change {
            case let .event(e): self?.handle(host, e)
            case .deltas, .connected, .disconnected:
                self?.updateBadge()
                self?.withdrawSettled()
            case .latency, .setup: break
            }
        })
        tokens.append(model.notices.observe { [weak self] title, body in
            self?.keyWindow()?.toasts?.show(.init(title: title, body: body, activity: .idle))
        })
        tokens.append(model.errors.observe { [weak self] message in
            self?.keyWindow()?.toasts?.show(.init(title: "Something went wrong", body: message, activity: .error))
        })
        if canNotify { UNUserNotificationCenter.current().delegate = self }
    }

    /// A state change held for its grace second, per pane (a newer one replaces it).
    private var pending: [PaneID: Task<Void, Never>] = [:]
    static let grace: Duration = .seconds(1)

    /// Panes with a banner or toast out, and the host each belongs to.
    private var outstanding: [PaneID: UUID] = [:]

    private func withdrawSettled() {
        guard !outstanding.isEmpty else { return }
        var gone: [PaneID] = []
        for (pane, hostID) in outstanding {
            let a = model.host(hostID)?.pane(pane)?.activity
            if a == nil || a == .idle || a == .working { gone.append(pane) }
        }
        guard !gone.isEmpty else { return }
        for p in gone {
            outstanding[p] = nil
            for w in NSApp.windows.compactMap({ $0.windowController as? MainWindowController }) { w.toasts?.dismiss(pane: p) }
        }
        if canNotify { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.map(Self.requestID)) }
    }

    private static func requestID(_ pane: PaneID) -> String { "pane-" + pane.raw.uuidString }

    private func updateBadge() {
        let n = model.waitingCount
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func handle(_ host: HostSession, _ e: HostEvent) {
        switch e {
        case let .attention(pane, activity, message):
            let info = host.pane(pane)
            let session = info.flatMap { host.state?.sessionTitle($0.session) } ?? "Session"
            let title = switch activity {
            case .blocked: "\(session) needs input"
            case .done: "\(session) finished"
            case .error: "\(session) failed"
            default: session
            }
            pending[pane]?.cancel()
            pending[pane] = Task { [weak self, weak host] in
                try? await Task.sleep(for: Self.grace)
                guard !Task.isCancelled, let self, let host else { return }
                self.pending[pane] = nil
                // Still in that state, and not seen meanwhile (seen turns done/error idle).
                guard host.pane(pane)?.activity == activity else { return }
                self.deliver(host, pane, title: title, body: message, activity: activity)
            }
        case let .notification(pane, title, body):
            // OSC 9 says only the words: the session is what they're about.
            let session = host.pane(pane).flatMap { host.state?.sessionTitle($0.session) } ?? "Axolotty"
            deliver(host, pane, title: title.isEmpty ? session : title, body: body, activity: .done)
        case let .bell(pane):
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            _ = pane
        case let .clipboard(_, text):
            // OSC 52 or pbcopy, here or on a far Mac (whose copies are the
            // person's too: as over ssh, a copy there lands where they sit).
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case let .openURL(text):
            // A far program's link (a sign-in, a preview) opens here, where
            // the person is; only the web: nothing on this Mac is run.
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            LinkOpener.openWeb(url, from: host.far)
        case .claudeConversation:
            break  // AppModel keeps it with the closed session
        }
    }

    /// A far Mac's notice names it: "zsh needs input" alone can't say which
    /// machine waits. This Mac's go unnamed, as everything here does.
    private static func toastBody(_ host: HostSession, _ body: String) -> String {
        host.isLocal ? body : [host.name, body].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func deliver(_ host: HostSession, _ pane: PaneID, title: String, body: String, activity: Activity) {
        if NSApp.isActive, let w = keyWindow() {
            // Nothing to say when the person is looking at that pane.
            if w.selection?.host === host, let sid = host.pane(pane)?.session, w.selection?.session == sid,
               w.window?.isKeyWindow == true
            {
                return
            }
            w.toasts?.show(.init(title: title, body: Self.toastBody(host, body), activity: activity, host: host, pane: pane))
            outstanding[pane] = host.id
            return
        }
        if activity == .blocked || activity == .error { NSApp.requestUserAttention(.informationalRequest) }
        guard canNotify else {
            keyWindow()?.toasts?.show(.init(title: title, body: Self.toastBody(host, body), activity: activity, host: host, pane: pane))
            return
        }
        outstanding[pane] = host.id
        post(host, pane, title: title, body: body, activity: activity)
    }

    private func post(_ host: HostSession, _ pane: PaneID, title: String, body: String, activity: Activity) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let c = UNMutableNotificationContent()
            c.title = title
            if !host.isLocal { c.subtitle = host.name }  // the banner's own line for where
            c.body = body
            c.sound = activity == .blocked || activity == .error ? .default : nil
            c.interruptionLevel = activity == .blocked ? .timeSensitive : activity == .done ? .passive : .active
            c.threadIdentifier = pane.raw.uuidString
            c.userInfo = ["host": host.id.uuidString, "pane": pane.raw.uuidString]
            // One per pane: the newest state replaces what was there.
            center.add(UNNotificationRequest(identifier: Self.requestID(pane), content: c, trigger: nil))
        }
        if authorized == true { send() }
        guard authorized == nil else { return }
        Task {
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorized = ok
            if ok { send() }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let h = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
              let p = (info["pane"] as? String).flatMap(PaneID.init)
        else { return }
        await MainActor.run {
            guard let host = model.host(h) else { return }
            keyWindow()?.reveal(host, p)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions
    {
        [.banner, .sound]
    }
}
