public import Foundation

/// Links to a far Mac's own loopback: the dev server a pane there started
/// (`http://localhost:5173`), the callback a sign-in there waits on
/// (`redirect_uri=http://127.0.0.1:8085/`). Opened here as they are, they
/// would reach this Mac's loopback, where nothing of the kind listens; their
/// ports are forwarded first (`HostConnection.forward`), so they open here
/// exactly as they would there.
public enum Loopback {
    /// The port a web link to a loopback address goes to (its scheme's own
    /// when it names none); nil for any other link.
    public static func port(of url: URL) -> UInt16? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = c.scheme?.lowercased(), let host = c.host, isLoopback(host)
        else { return nil }
        if let p = c.port { return UInt16(exactly: p).flatMap { $0 > 0 ? $0 : nil } }
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// The loopback ports a link needs: its own, then those of loopback
    /// links in its query (a sign-in page's `redirect_uri`), each once.
    public static func ports(in url: URL) -> [UInt16] {
        var out: [UInt16] = []
        if let p = port(of: url) { out.append(p) }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.compactMap(\.value) ?? []
        for v in values {
            if let inner = URL(string: v), let p = port(of: inner), !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// `url` at `port` here instead; an "any address" host (`0.0.0.0`, what
    /// a server listening everywhere prints) becomes `localhost`.
    public static func moved(_ url: URL, to port: UInt16) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if let h = c.host, anyAddress.contains(h) { c.host = "localhost" }
        c.port = Int(port)
        return c.url ?? url
    }

    private static let anyAddress: Set<String> = ["0.0.0.0", "::", "[::]"]

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        if ["localhost", "::1", "[::1]"].contains(h) || anyAddress.contains(h) || h.hasSuffix(".localhost") { return true }
        // 127.0.0.0/8, written out.
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}
