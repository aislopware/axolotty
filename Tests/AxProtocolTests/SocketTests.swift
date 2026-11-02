import AxProtocol
import Foundation
import Testing

/// Every socket is born without SIGPIPE: set later, the option fails on a
/// link whose peer already left (XNU: EINVAL once shut both ways), and its
/// first write signalled the whole process.
@Suite("Sockets")
struct SocketTests {
    private func guarded(_ fd: Int32) -> Bool {
        var on: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        return getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &len) == 0 && on != 0
    }

    @Test func aLinkWhosePeerLeftAtOnceStillWritesWithoutASignal() throws {
        let path = "/tmp/axsock-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let listener = try UnixSocket.listen(path: path)
        defer { close(listener) }
        let client = try UnixSocket.connect(path: path)
        defer { close(client) }
        let accepted = accept(listener, nil, nil)
        #expect(guarded(accepted), "accepted sockets inherit it")
        close(accepted)  // the peer leaves before the client does anything
        #expect(guarded(client))
        var one: Int32 = 1
        #expect(setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) != 0,
                "too late now: why it is set at birth")
        var b: UInt8 = 0
        #expect(write(client, &b, 1) == -1 && errno == EPIPE)
    }

    @Test func tcpSocketsAreGuardedBothWays() throws {
        let listener = try TCPSocket.listen(address: "127.0.0.1", port: 0)
        defer { close(listener) }
        #expect(guarded(listener))
        var sa = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &sa) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let client = try TCPSocket.connect(host: "127.0.0.1", port: UInt16(bigEndian: sa.sin_port), timeout: 2)
        defer { close(client) }
        #expect(guarded(client))
    }
}
