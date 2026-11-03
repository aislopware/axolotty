import AppKit
import Network

/// The moments a remote link most likely died without saying so: the Mac
/// woke, or the network under it changed (Wi-Fi to Ethernet, a new
/// network, a VPN, Tailscale coming up). Each one asks every link at once
/// (`HostConnection.kick`). A live link answers within one beat and stays;
/// a dead one is redialled now instead of after its liveness gives up, so
/// opening the lid finds the remote sessions already back.
final class LinkNudge {
    private let monitor = NWPathMonitor()
    private var lastPath: String?
    private var wake: NotificationCenter.ObservationToken?
    private let nudge: () -> Void

    init(_ nudge: @escaping () -> Void) {
        self.nudge = nudge
        wake = NSWorkspace.shared.notificationCenter.addObserver(of: NSWorkspace.shared, for: .didWake) { [weak self] _ in
            self?.nudge()
        }
        monitor.pathUpdateHandler = { [weak self] path in
            // Which interfaces carry traffic, and whether any does: a change
            // there moves every TCP path; an update that says the same is noise.
            let key = "\(path.status == .satisfied) " + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.pathChanged(key) } }
        }
        monitor.start(queue: DispatchQueue(label: "axolotty.network"))
    }

    isolated deinit {
        monitor.cancel()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    }

    private func pathChanged(_ key: String) {
        defer { lastPath = key }
        guard let last = lastPath, last != key else { return }  // the first report is how things are, not a change
        nudge()
    }
}
