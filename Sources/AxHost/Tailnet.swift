#if os(macOS)
import AxProtocol
import Darwin
public import Foundation
import Synchronization

/// The tailnet this Mac is on. Axolotty does no transport work of its own:
/// Tailscale (or a headscale/slopscale control plane) brings NAT traversal,
/// the direct path and WireGuard, so the link to a remote host is a plain
/// TCP stream between two tailnet addresses, admitted by who is calling.
public enum Tailnet {
    /// Where a host listens on its tailnet addresses.
    public static let port: UInt16 = 7518

    /// This Mac's tailnet addresses (CGNAT 100.64.0.0/10 and Tailscale's
    /// ULA fd7a:115c:a1e0::/48), read from the interfaces.
    public static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var p = head
        while let ifa = p {
            p = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr, (ifa.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if isTailnet(text), !out.contains(text) { out.append(text) }
        }
        return out.sorted()
    }

    /// Whether a numeric address is a tailnet one.
    public static func isTailnet(_ address: String) -> Bool {
        if address.lowercased().hasPrefix("fd7a:115c:a1e0:") { return true }
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (octets[1] & 0xC0) == 64
    }

    /// The address part of "ip:port" or "[ip6]:port".
    public static func host(of peer: String) -> String {
        if peer.hasPrefix("["), let end = peer.firstIndex(of: "]") {
            return String(peer[peer.index(after: peer.startIndex) ..< end])
        }
        guard let colon = peer.lastIndex(of: ":") else { return peer }
        return String(peer[..<colon])
    }

    // MARK: The Tailscale CLI

    static func run(_ arguments: [String], timeout: Double = 3) -> Data? { TailscaleCLI.run(arguments, timeout: timeout) }

    /// A tailnet user: the control plane's numeric id and login.
    public struct User: Equatable, Sendable {
        public var id: Int64
        public var login: String
        public init(id: Int64, login: String) {
            self.id = id
            self.login = login
        }
    }

    /// Who is calling from `peer` ("ip:port" or a bare address).
    public static func whois(_ peer: String) -> User? {
        guard let data = run(["whois", "--json", peer]) else { return nil }
        return parseWhois(data)
    }

    /// The user this Mac is signed in as, when Tailscale is running.
    public static func signedInUser() -> User? {
        guard let data = run(["status", "--json", "--peers=false"]) else { return nil }
        return parseStatusSelf(data)
    }

    public static func parseWhois(_ data: Data) -> User? {
        struct W: Decodable {
            struct P: Decodable {
                var ID: Int64
                var LoginName: String
            }

            var UserProfile: P
        }
        guard let w = try? JSONDecoder().decode(W.self, from: data) else { return nil }
        return User(id: w.UserProfile.ID, login: w.UserProfile.LoginName)
    }

    public static func parseStatusSelf(_ data: Data) -> User? {
        struct S: Decodable {
            struct N: Decodable { var UserID: Int64 }
            struct P: Decodable { var LoginName: String }
            var BackendState: String?
            var `Self`: N?
            var User: [String: P]?
        }
        guard let s = try? JSONDecoder().decode(S.self, from: data), s.BackendState == "Running",
              let me = s.Self else { return nil }
        return User(id: me.UserID, login: s.User?[String(me.UserID)]?.LoginName ?? "")
    }
}

/// Admits a tailnet caller when it is signed in as the same person as this
/// Mac (every one of their devices, nobody else's, no tagged nodes). With no
/// Tailscale to ask, it fails closed. Answers are cached per address, since
/// a node keeps its tailnet address and a relink should not wait on the CLI.
public final class TailnetGate: Sendable {
    private struct Cache {
        var me: (user: Tailnet.User, at: ContinuousClock.Instant)?
        var peers: [String: (allowed: Bool, at: ContinuousClock.Instant)] = [:]
    }

    private let cache = Mutex(Cache())
    private let whois: @Sendable (String) -> Tailnet.User?
    private let me: @Sendable () -> Tailnet.User?

    public init(whois: @escaping @Sendable (String) -> Tailnet.User? = Tailnet.whois,
                me: @escaping @Sendable () -> Tailnet.User? = Tailnet.signedInUser) {
        self.whois = whois
        self.me = me
    }

    /// Blocks while it asks Tailscale (tens of milliseconds); call it off
    /// any latency-sensitive queue.
    public func admits(_ peer: String) -> Bool {
        let address = Tailnet.host(of: peer)
        guard Tailnet.isTailnet(address) else { return false }
        let now = ContinuousClock.now
        let cached = cache.withLock { c -> Bool? in
            guard let hit = c.peers[address] else { return nil }
            // Yes for five minutes, no for ten seconds (a fresh sign-in shouldn't wait long).
            let ttl: Duration = hit.allowed ? .seconds(300) : .seconds(10)
            return now - hit.at < ttl ? hit.allowed : nil
        }
        if let cached { return cached }
        let mine = cache.withLock { c -> Tailnet.User? in
            guard let m = c.me, now - m.at < .seconds(60) else { return nil }
            return m.user
        } ?? me()
        guard let mine else { return false }
        let caller = whois(peer)
        let allowed = caller?.id == mine.id
        cache.withLock { c in
            c.me = (mine, now)
            c.peers[address] = (allowed, now)
        }
        return allowed
    }
}
#endif
