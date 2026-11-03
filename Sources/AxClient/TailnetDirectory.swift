#if os(macOS)
public import Foundation
import AxProtocol

/// One of the person's own machines on the tailnet, as a host to connect to.
public struct TailnetPeer: Equatable, Sendable, Identifiable {
    /// The node's stable id.
    public var id: String
    /// The machine's own name ("MacBook Pro"), as the person sees it.
    public var name: String
    /// MagicDNS name without the trailing dot; what the link dials.
    public var dnsName: String
    /// Its first tailnet address, when MagicDNS is off.
    public var address: String
    public var online: Bool
    /// The DERP region the path goes through, nil when it is direct.
    public var relay: String?
    /// When the tailnet last heard from it (nil: never, or not said).
    public var lastSeen: Date?

    public var dialName: String { dnsName.isEmpty ? address : dnsName }
}

/// Which of the person's machines could be hosts: the peers signed in as the
/// same person (the only callers a host admits), running macOS (the only
/// system a host runs on yet), never this Mac itself.
public enum TailnetDirectory {
    /// Where a host listens on its tailnet addresses (`Tailnet.port` on the host).
    public static let port: UInt16 = 7518

    /// Parses `tailscale status --json`. Online machines first, then by name.
    public static func parse(_ status: Data) -> [TailnetPeer] {
        struct Node: Decodable {
            var ID: String?
            var HostName: String?
            var DNSName: String?
            var OS: String?
            var Online: Bool?
            var UserID: Int64?
            var Relay: String?
            var CurAddr: String?
            var TailscaleIPs: [String]?
            var LastSeen: String?
        }
        struct Status: Decodable {
            var BackendState: String?
            var `Self`: Node?
            var Peer: [String: Node]?
        }
        guard let s = try? JSONDecoder().decode(Status.self, from: status), s.BackendState == "Running",
              let me = s.Self?.UserID else { return [] }
        let peers = (s.Peer ?? [:]).compactMap { key, n -> TailnetPeer? in
            guard n.UserID == me, n.OS == "macOS" else { return nil }
            let dns = (n.DNSName ?? "").hasSuffix(".") ? String((n.DNSName ?? "").dropLast()) : (n.DNSName ?? "")
            let address = n.TailscaleIPs?.first ?? ""
            guard !dns.isEmpty || !address.isEmpty else { return nil }
            // iOS reports "localhost"; a machine's name is better read off its DNS label then.
            let host = n.HostName ?? ""
            let name = host.isEmpty || host == "localhost" ? String(dns.split(separator: ".").first ?? "") : host
            let direct = !(n.CurAddr ?? "").isEmpty
            return TailnetPeer(id: n.ID ?? key, name: name, dnsName: dns, address: address, online: n.Online ?? false,
                               relay: direct ? nil : (n.Relay?.isEmpty == false ? n.Relay : nil),
                               lastSeen: n.LastSeen.flatMap(seen))
        }
        return peers.sorted { a, b in
            a.online != b.online ? a.online : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Tailscale's LastSeen ("2026-11-02T22:40:51.830779125Z"); its zero
    /// time ("0001-01-01T00:00:00Z") is never.
    static func seen(_ s: String) -> Date? {
        // Nanoseconds are more than ISO8601DateFormatter reads: whole seconds do.
        let whole = s.split(separator: ".").first.map { $0.hasSuffix("Z") ? String($0) : $0 + "Z" } ?? s
        guard let d = ISO8601DateFormatter().date(from: whole), d.timeIntervalSince1970 > 0 else { return nil }
        return d
    }

    /// The peer a host was dialled by: its MagicDNS name, short name or address.
    public static func peer(dialledAs host: String, in peers: [TailnetPeer]) -> TailnetPeer? {
        let h = host.lowercased().hasSuffix(".") ? String(host.lowercased().dropLast()) : host.lowercased()
        return peers.first { p in
            let dns = p.dnsName.lowercased()
            return dns == h || p.address == h || (!dns.isEmpty && dns.split(separator: ".").first.map(String.init) == h)
        }
    }

    /// Whether two dial names reach the same Mac without asking Tailscale:
    /// equal (case and a trailing dot aside), or one is the other's short
    /// name (`mbp` and `mbp.ts.example`). An address is only ever itself.
    public static func sameMachine(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().hasSuffix(".") ? String(s.lowercased().dropLast()) : s.lowercased() }
        let x = norm(a), y = norm(b)
        if x == y { return true }
        func isAddress(_ s: String) -> Bool { s.contains(":") || s.split(separator: ".").allSatisfy { UInt8($0) != nil } }
        guard !isAddress(x), !isAddress(y) else { return false }
        func short(_ s: String) -> String { s.split(separator: ".").first.map(String.init) ?? s }
        return (!x.contains(".") && x == short(y)) || (!y.contains(".") && y == short(x))
    }

    /// Where a DERP relay is, from its region code ("sin"); the code as it is
    /// for a region not named here.
    public static func relayPlace(_ code: String) -> String {
        let places = [
            "ams": "Amsterdam", "blr": "Bengaluru", "dbi": "Dubai", "den": "Denver", "dfw": "Dallas",
            "fra": "Frankfurt", "hkg": "Hong Kong", "hnl": "Honolulu", "iad": "Ashburn", "jnb": "Johannesburg",
            "lax": "Los Angeles", "lhr": "London", "mad": "Madrid", "mia": "Miami", "nai": "Nairobi",
            "nue": "Nuremberg", "nyc": "New York", "ord": "Chicago", "par": "Paris", "sao": "São Paulo",
            "sea": "Seattle", "sfo": "San Francisco", "sin": "Singapore", "syd": "Sydney", "tok": "Tokyo",
            "tor": "Toronto", "waw": "Warsaw",
        ]
        return places[code.lowercased()] ?? code
    }

    /// The person's machines, from the running Tailscale; empty without one.
    public static func scan() async -> [TailnetPeer] {
        await Task.detached { TailscaleCLI.run(["status", "--json"]).map(parse) ?? [] }.value
    }

    /// How long a TCP connect to a host's port takes, or nil when nothing
    /// answers there (no Axolotty, or the machine is away).
    public static func probe(_ host: String, port: UInt16 = TailnetDirectory.port, timeout: Double = 1.5) async -> Duration? {
        await Task.detached {
            let start = ContinuousClock.now
            guard let fd = try? TCPSocket.connect(host: host, port: port, timeout: timeout) else { return nil }
            let took = ContinuousClock.now - start
            close(fd)
            return took
        }.value
    }
}
#endif
