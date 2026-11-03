import AxClient
import AxModel
import AxProtocol
import AxTestSupport
import Foundation
import Synchronization
import Testing

/// A far pane's dev server answering on this Mac's loopback (feature
/// "tunnel"). The host here is this Mac, so the dev server already holds its
/// port on this loopback and every forward lands on a port of its own: the
/// path a busy port takes in real use.
@Suite(.serialized) struct TunnelTests {
    @Test func aDevServerOnTheHostAnswersHereWholeOnEveryConnection() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let body = pattern(3 << 20)  // past the window: acks must keep it going
        let dev = try DevServer { fd in
            _ = readRequest(fd)
            writeAll(fd, Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
        }
        defer { dev.stop() }
        let here = try c.forward(port: dev.port)
        #expect(here != dev.port, "this loopback already has the dev server's port")
        #expect(try c.forward(port: dev.port) == here, "one forward per host port")
        #expect(c.forwarded == [dev.port: here])

        // A browser opens several at once.
        let replies = await withTaskGroup(of: Data?.self) { g in
            for _ in 0 ..< 6 {
                g.addTask { await blocking { fetch(here, Data("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)) } }
            }
            return await g.reduce(into: [Data?]()) { $0.append($1) }
        }
        for r in replies {
            let r = try #require(r)
            #expect(r.count > body.count && r.suffix(body.count) == body)
        }
        // Every stream let go of its sockets at both ends; the listener stays.
        #expect(await until { tunnelSockets(here: here, there: dev.port) == 1 },
                "\(tunnelSockets(here: here, there: dev.port) - 1) left open")
        await fx.tearDown()
    }

    @Test func overASlowLinkAPageArrivesWhole() async throws {
        let fx = try await HostFixture()
        let relay = try LinkRelay(to: fx.paths.hostSocket.path(percentEncoded: false))
        relay.delay = .milliseconds(10)
        let c = HostConnection(endpoint: .tcp(host: "127.0.0.1", port: relay.port),
                               hello: ClientHello(client: ClientID(), name: "slow"))
        try await c.connect(reconnect: true)
        let body = pattern(1 << 20)
        let dev = try DevServer { fd in
            _ = readRequest(fd)
            writeAll(fd, body)
        }
        defer { dev.stop() }
        let here = try c.forward(port: dev.port)
        let got = await blocking { fetch(here, Data("GET /app.js HTTP/1.1\r\n\r\n".utf8)) }
        #expect(got == body)
        c.disconnect()
        relay.close()
        await fx.tearDown()
    }

    @Test func aRequestEndedByItsSenderIsAnsweredAfterIt() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        // Reads to EOF, then answers with what it read, reversed: only works
        // if the client's half-close reaches the dev server as one.
        let dev = try DevServer { fd in
            let got = readAll(fd)
            writeAll(fd, Data(got.reversed()))
        }
        defer { dev.stop() }
        let here = try c.forward(port: dev.port)
        let sent = pattern(200 << 10)
        let back = await blocking { fetch(here, sent, halfClose: true) }
        #expect(back == Data(sent.reversed()))
        await fx.tearDown()
    }

    @Test func aReaderThatFallsBehindGetsEveryByteInOrder() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let body = pattern(4 << 20)
        let dev = try DevServer { fd in writeAll(fd, body) }
        defer { dev.stop() }
        let here = try c.forward(port: dev.port)
        let got = await blocking { () -> Data? in
            guard let fd = try? TCPSocket.connect(host: "127.0.0.1", port: here) else { return nil }
            defer { close(fd) }
            limitWaits(fd)
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 16 << 10)
            while true {
                let n = read(fd, &buf, buf.count)
                guard n > 0 else { break }
                out.append(contentsOf: buf[0 ..< n])
                usleep(300)  // slower than loopback: the window fills and waits
            }
            return out
        }
        #expect(got == body)
        await fx.tearDown()
    }

    @Test func aPortNobodyListensOnThereIsRefusedHereAtOnce() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let dev = try DevServer { _ in }
        let here = try c.forward(port: dev.port)
        dev.stop()
        let started = ContinuousClock.now
        let reply = await blocking { fetch(here, Data("GET / HTTP/1.1\r\n\r\n".utf8)) }
        #expect(reply?.isEmpty ?? true, "nothing comes back")
        #expect(ContinuousClock.now - started < .seconds(2), "and it says so at once")
        await fx.tearDown()
    }

    @Test func aForwardOutlivesALinkThatDrops() async throws {
        let fx = try await HostFixture()
        let c = try await fx.client()
        let dev = try DevServer { fd in
            _ = readRequest(fd)
            writeAll(fd, Data("HTTP/1.1 204 No Content\r\n\r\n".utf8))
        }
        defer { dev.stop() }
        let here = try c.forward(port: dev.port)
        let request = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        #expect(await blocking { fetch(here, request) }?.starts(with: Data("HTTP/1.1 204".utf8)) == true)

        try await fx.restart()
        let healed = await until(.seconds(10)) {
            await blocking { fetch(here, request) }?.starts(with: Data("HTTP/1.1 204".utf8)) == true
        }
        #expect(healed, "the same port here answers again once the link is back")
        #expect(c.forwarded == [dev.port: here])

        c.disconnect()
        #expect(c.forwarded.isEmpty, "a host let go of takes its forwards with it")
        #expect(await until { await blocking { fetch(here, request) } == nil }, "and the port here is free")
        await fx.tearDown()
    }
}

// MARK: Helpers

/// The sockets one forward holds in this process (both ends of its tunnels
/// live here): its listener and the connections it accepted, at `here`, and
/// the host's dials to the dev server at `there`.
private func tunnelSockets(here: UInt16, there: UInt16) -> Int {
    (0 ..< Int32(getdtablesize())).reduce(0) { n, fd in
        guard fcntl(fd, F_GETFD) >= 0 else { return n }
        let peer = TCPSocket.peerAddress(fd)?.split(separator: ":").last.flatMap { UInt16($0) }
        return n + (TCPSocket.localPort(fd) == here || peer == there ? 1 : 0)
    }
}

private func pattern(_ n: Int) -> Data {
    var d = Data(count: n)
    for i in d.indices { d[i] = UInt8(truncatingIfNeeded: i &* 131 &+ (i >> 9)) }
    return d
}

private func blocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in Thread.detachNewThread { c.resume(returning: work()) } }
}

private func limitWaits(_ fd: Int32, seconds: Int = 10) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

private func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { p in
        var off = 0
        while off < p.count {
            let n = write(fd, p.baseAddress!.advanced(by: off), p.count - off)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            off += n
        }
    }
}

private func readAll(_ fd: Int32) -> Data {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 64 << 10)
    while true {
        let n = read(fd, &buf, buf.count)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { return out }
        out.append(contentsOf: buf[0 ..< n])
    }
}

/// Reads up to the blank line that ends a request's head.
private func readRequest(_ fd: Int32) -> Data {
    var out = Data()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 {
        out.append(byte)
        if out.suffix(4) == Data("\r\n\r\n".utf8) { break }
    }
    return out
}

/// Connects to the forward here, sends `request` (then ends its side, with
/// `halfClose`) and reads the reply to EOF; nil if nothing answers.
private func fetch(_ port: UInt16, _ request: Data, halfClose: Bool = false) -> Data? {
    guard let fd = try? TCPSocket.connect(host: "127.0.0.1", port: port, timeout: 2) else { return nil }
    defer { close(fd) }
    limitWaits(fd)
    writeAll(fd, request)
    if halfClose { shutdown(fd, SHUT_WR) }
    return readAll(fd)
}

/// A dev server on this loopback: each connection is served on a thread of
/// its own, then closed.
private final class DevServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private final class Flag: Sendable { let raised = Atomic<Bool>(false) }
    private let stopped = Flag()
    private let gone = DispatchSemaphore(value: 0)

    init(_ serve: @escaping @Sendable (Int32) -> Void) throws {
        fd = try TCPSocket.listen(address: "127.0.0.1", port: 0, backlog: 64)
        port = try #require(TCPSocket.localPort(fd))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        Thread.detachNewThread { [fd, stopped, gone] in
            while !stopped.raised.load(ordering: .acquiring) {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 50) == 1 else { continue }
                let c = accept(fd, nil, nil)
                guard c >= 0 else { continue }
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
                limitWaits(c)
                Thread.detachNewThread {
                    serve(c)
                    close(c)
                }
            }
            close(fd)
            gone.signal()
        }
    }

    /// Returns once the port is closed.
    func stop() {
        guard !stopped.raised.exchange(true, ordering: .acquiringAndReleasing) else { return }
        gone.wait()
    }
}
