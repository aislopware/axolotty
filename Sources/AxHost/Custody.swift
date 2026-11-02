#if os(macOS)
public import AxModel
internal import AxSys
import Foundation
import Synchronization

/// Errors from the PTY holder (POSIX errno values) or from its connection.
public enum CustodyError: Error, Equatable, Sendable {
    case errno(Int32)
    case disconnected
    case protocolViolation
    case holderUnavailable(String)
}

/// A child's wait status as the holder reports it.
public enum ChildStatus: Equatable, Sendable {
    case running
    case exited(Int32)  // raw wait(2) status
    case unknown

    init(raw: Int32) {
        self = raw == Int32.min /* AXC_ALIVE */ ? .running : raw == -1 ? .unknown : .exited(raw)
    }

    /// The exit code, or 128 + signal, like a shell reports it.
    public var exitCode: Int32? {
        guard case .exited(let st) = self else { return nil }
        let sig = st & 0x7F
        return sig == 0 ? (st >> 8) & 0xFF : 128 + sig
    }
}

/// Descriptors handed over by the holder. The receiver owns them.
public struct CustodyHandle: Sendable {
    public let pid: Int32
    public let master: Int32
    public let ring: Int32
    public let status: ChildStatus
}

public struct CustodyListing: Equatable, Sendable {
    public let id: PaneID
    public let pid: Int32
    public let status: ChildStatus
    public let attached: Bool
}

public struct SpawnSpec: Sendable {
    public var path: String
    public var argv: [String]
    public var env: [String]
    public var cwd: String?
    public var cols: UInt16, rows: UInt16, widthPx: UInt16, heightPx: UInt16

    public init(path: String, argv: [String], env: [String], cwd: String?,
                cols: UInt16, rows: UInt16, widthPx: UInt16 = 0, heightPx: UInt16 = 0) {
        self.path = path
        self.argv = argv
        self.env = env
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.widthPx = widthPx
        self.heightPx = heightPx
    }
}

/// The server's connection to `axolotty-ptyd` (see AxCustody.h).
///
/// The holder answers requests strictly in order, one reply per request that
/// has one, so pending replies are a FIFO. A dedicated thread reads replies and
/// `EXITED` events; requests are written under the same lock that enqueues
/// their waiter so order on the wire matches order in the queue.
public final class CustodyClient: Sendable {
    private struct Reply {
        var op: UInt8
        var payload: [UInt8]
        var fds: [Int32]
    }

    private typealias Waiter = CheckedContinuation<Reply, any Error>

    private struct State {
        var waiters: [Waiter] = []
        var closed = false
    }

    private let fd: Int32
    private let state = Mutex(State())
    private let events: @Sendable (PaneID, ChildStatus) -> Void
    private let disconnected: @Sendable () -> Void
    public let holderPid: Int32
    public let version: UInt32

    /// Connects and performs HELLO. `onExit` and `onDisconnect` run on the reader thread.
    public init(socketPath: String,
                onExit: @escaping @Sendable (PaneID, ChildStatus) -> Void = { _, _ in },
                onDisconnect: @escaping @Sendable () -> Void = {}) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CustodyError.errno(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw CustodyError.errno(ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw CustodyError.errno(e)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        // HELLO synchronously, before the reader thread exists.
        var hello = Self.message(UInt8(AXC_HELLO), payload: le(AXC_VERSION))
        guard hello.withUnsafeMutableBytes({ ax_send_fds(fd, $0.baseAddress, $0.count, nil, 0) }) == 0,
              let reply = Self.readOneBlocking(fd), reply.op == UInt8(AXC_HELLO), reply.payload.count >= 8
        else {
            Darwin.close(fd)
            throw CustodyError.protocolViolation
        }
        var r = Reader(reply.payload)
        version = r.u32()
        holderPid = r.i32()
        self.fd = fd
        events = onExit
        disconnected = onDisconnect
        let thread = Thread { [self] in readLoop() }
        thread.name = "axolotty.custody"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    deinit { Darwin.close(fd) }

    /// Closes the connection; the holder releases every session it attached.
    public func disconnect() {
        _ = shutdown(fd, SHUT_RDWR)
    }

    // MARK: Verbs

    public func spawn(id: PaneID, _ spec: SpawnSpec) async throws -> CustodyHandle {
        var p = idBytes(id)
        p += le(spec.cols) + le(spec.rows) + le(spec.widthPx) + le(spec.heightPx)
        p += le(UInt32(spec.argv.count)) + le(UInt32(spec.env.count))
        for s in [spec.path, spec.cwd ?? ""] + spec.argv + spec.env { p += Array(s.utf8) + [0] }
        let reply = try await request(UInt8(AXC_SPAWN), p)
        var r = Reader(reply.payload)
        guard reply.op == UInt8(AXC_SPAWN), reply.payload.count >= 24 else {
            reply.fds.forEach { _ = Darwin.close($0) }
            var rr = Reader(reply.payload)
            rr.skip(16)
            throw CustodyError.errno(reply.op == UInt8(AXC_RESULT) && reply.payload.count >= 20 ? rr.i32() : EPROTO)
        }
        r.skip(16)
        let err = r.i32(), pid = r.i32()
        guard err == 0, reply.fds.count == 2 else {
            reply.fds.forEach { _ = Darwin.close($0) }
            throw CustodyError.errno(err == 0 ? EPROTO : err)
        }
        return CustodyHandle(pid: pid, master: reply.fds[0], ring: reply.fds[1], status: .running)
    }

    /// Takes the reader role for a session the holder keeps.
    public func attach(id: PaneID) async throws -> CustodyHandle {
        let reply = try await request(UInt8(AXC_ATTACH), idBytes(id))
        var r = Reader(reply.payload)
        guard reply.op == UInt8(AXC_ATTACH), reply.payload.count >= 28 else {
            reply.fds.forEach { _ = Darwin.close($0) }
            throw CustodyError.protocolViolation
        }
        r.skip(16)
        let err = r.i32(), pid = r.i32(), status = r.i32()
        guard err == 0, reply.fds.count == 2 else {
            reply.fds.forEach { _ = Darwin.close($0) }
            throw CustodyError.errno(err == 0 ? EPROTO : err)
        }
        return CustodyHandle(pid: pid, master: reply.fds[0], ring: reply.fds[1], status: ChildStatus(raw: status))
    }

    /// Hands the reader role back; the holder drains output into the ring.
    public func release(id: PaneID) throws {
        try send(UInt8(AXC_RELEASE), idBytes(id))
    }

    public func signal(id: PaneID, _ signo: Int32, foreground: Bool = false) async throws {
        try await expectResult(UInt8(AXC_SIGNAL), idBytes(id) + le(signo) + [foreground ? 1 : 0])
    }

    /// Hangs up the session's process group and forgets it.
    public func close(id: PaneID) async throws {
        try await expectResult(UInt8(AXC_CLOSE), idBytes(id))
    }

    public func list() async throws -> [CustodyListing] {
        let reply = try await request(UInt8(AXC_LIST), [])
        guard reply.op == UInt8(AXC_LIST), reply.payload.count >= 4 else { throw CustodyError.protocolViolation }
        var r = Reader(reply.payload)
        let n = Int(r.u32())
        guard reply.payload.count >= 4 + n * 25 else { throw CustodyError.protocolViolation }
        return (0 ..< n).map { _ in
            let id = r.id()
            let pid = r.i32(), status = r.i32()
            let attached = r.u8() != 0
            return CustodyListing(id: id, pid: pid, status: ChildStatus(raw: status), attached: attached)
        }
    }

    /// Gives a freshly started holder custody of a session this server kept alive.
    /// The descriptors stay open here too (the holder receives duplicates).
    public func adopt(id: PaneID, pid: Int32, master: Int32, ring: Int32) async throws {
        try await expectResult(UInt8(AXC_ADOPT), idBytes(id) + le(pid), fds: [master, ring])
    }

    /// Hangs up every session and stops the holder (tests, uninstall).
    public func shutdownHolder() throws {
        try send(UInt8(AXC_SHUTDOWN), [])
    }

    // MARK: Plumbing

    private func expectResult(_ op: UInt8, _ payload: [UInt8], fds: [Int32] = []) async throws {
        let reply = try await request(op, payload, fds: fds)
        reply.fds.forEach { _ = Darwin.close($0) }
        guard reply.op == UInt8(AXC_RESULT), reply.payload.count >= 20 else { throw CustodyError.protocolViolation }
        var r = Reader(reply.payload)
        r.skip(16)
        let err = r.i32()
        if err != 0 { throw CustodyError.errno(err) }
    }

    private func request(_ op: UInt8, _ payload: [UInt8], fds: [Int32] = []) async throws -> Reply {
        try await withCheckedThrowingContinuation { (c: Waiter) in
            let failure: (any Error)? = state.withLock { s in
                if s.closed { return CustodyError.disconnected }
                if let e = write(op, payload, fds) { return e }
                s.waiters.append(c)
                return nil
            }
            if let failure { c.resume(throwing: failure) }
        }
    }

    private func send(_ op: UInt8, _ payload: [UInt8]) throws {
        let failure: (any Error)? = state.withLock { s in
            s.closed ? CustodyError.disconnected : write(op, payload, [])
        }
        if let failure { throw failure }
    }

    /// Called with the state lock held.
    private func write(_ op: UInt8, _ payload: [UInt8], _ fds: [Int32]) -> (any Error)? {
        var m = Self.message(op, payload: payload, nfds: UInt8(fds.count))
        let rc = m.withUnsafeMutableBytes { buf in
            fds.withUnsafeBufferPointer { f in
                ax_send_fds(fd, buf.baseAddress, buf.count, f.baseAddress, Int32(f.count))
            }
        }
        return rc == 0 ? nil : CustodyError.errno(rc)
    }

    private static func message(_ op: UInt8, payload: [UInt8], nfds: UInt8 = 0) -> [UInt8] {
        le(UInt32(payload.count + 2)) + [op, nfds] + payload
    }

    private func readLoop() {
        var buffer: [UInt8] = []
        var fdQueue: [Int32] = []
        var chunk = [UInt8](repeating: 0, count: 16 << 10)
        loop: while true {
            var fds = [Int32](repeating: -1, count: 8)
            var nfds: Int32 = 0
            let n = chunk.withUnsafeMutableBytes { c in
                fds.withUnsafeMutableBufferPointer { f in
                    ax_recv_fds(fd, c.baseAddress, c.count, f.baseAddress, Int32(f.count), &nfds)
                }
            }
            fdQueue += fds.prefix(Int(nfds))
            if n == -Int(EINTR) { continue }
            if n <= 0 { break }
            buffer += chunk.prefix(n)
            var off = 0
            while buffer.count - off >= 6 {
                let len = Int(leU32(buffer, off))
                guard len >= 2, len <= 16 << 20 else { break loop }
                guard buffer.count - off >= 4 + len else { break }
                let op = buffer[off + 4], want = Int(buffer[off + 5])
                let take = min(want, fdQueue.count)
                let reply = Reply(op: op, payload: Array(buffer[off + 6 ..< off + 4 + len]),
                                  fds: Array(fdQueue.prefix(take)))
                fdQueue.removeFirst(take)
                off += 4 + len
                deliver(reply)
            }
            buffer.removeFirst(off)
        }
        fdQueue.forEach { _ = Darwin.close($0) }
        let waiters = state.withLock { s in
            s.closed = true
            defer { s.waiters.removeAll() }
            return s.waiters
        }
        waiters.forEach { $0.resume(throwing: CustodyError.disconnected) }
        disconnected()
    }

    private func deliver(_ reply: Reply) {
        if reply.op == UInt8(AXC_EXITED) {
            guard reply.payload.count >= 20 else { return }
            var r = Reader(reply.payload)
            let id = r.id()
            events(id, ChildStatus(raw: r.i32()))
            return
        }
        let waiter = state.withLock { s in s.waiters.isEmpty ? nil : s.waiters.removeFirst() }
        if let waiter { waiter.resume(returning: reply) } else { reply.fds.forEach { _ = Darwin.close($0) } }
    }

    private static func readOneBlocking(_ fd: Int32) -> Reply? {
        var buf: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            if buf.count >= 4 {
                let len = Int(leU32(buf, 0))
                if buf.count >= 4 + len, len >= 2 {
                    return Reply(op: buf[4], payload: Array(buf[6 ..< 4 + len]), fds: [])
                }
            }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            buf += chunk.prefix(n)
        }
    }
}

// MARK: - Little-endian helpers

private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}

private func idBytes(_ id: PaneID) -> [UInt8] {
    withUnsafeBytes(of: id.raw.uuid) { Array($0) }
}

private func leU32(_ b: [UInt8], _ at: Int) -> UInt32 {
    UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
}

private struct Reader {
    let bytes: [UInt8]
    var at = 0

    init(_ b: some Collection<UInt8>) { bytes = Array(b) }

    mutating func skip(_ n: Int) { at += n }

    mutating func u8() -> UInt8 {
        defer { at += 1 }
        return bytes[at]
    }

    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for i in 0 ..< 4 { v |= UInt32(bytes[at + i]) << (8 * i) }
        at += 4
        return v
    }

    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }

    mutating func id() -> PaneID {
        let b = bytes[at ..< at + 16]
        at += 16
        let u = UUID(uuid: (b[b.startIndex], b[b.startIndex + 1], b[b.startIndex + 2], b[b.startIndex + 3],
                            b[b.startIndex + 4], b[b.startIndex + 5], b[b.startIndex + 6], b[b.startIndex + 7],
                            b[b.startIndex + 8], b[b.startIndex + 9], b[b.startIndex + 10], b[b.startIndex + 11],
                            b[b.startIndex + 12], b[b.startIndex + 13], b[b.startIndex + 14], b[b.startIndex + 15]))
        return PaneID(raw: u)
    }
}
#endif
