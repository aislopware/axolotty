public import Dispatch
public import Foundation
import Synchronization

/// A framed, non-blocking stream socket driven by GCD sources.
///
/// - Reads run on `queue`; every decoded frame is delivered there, in order.
/// - `send` is thread-safe and never blocks: bytes queue in memory and a write
///   source drains them. `pendingBytes` tells producers how far behind the peer
///   is (the host uses it to decide when to resync a slow client instead of
///   buffering without bound).
public final class FramedConnection: @unchecked Sendable {
    public let fd: Int32
    public let queue: DispatchQueue
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite

    private struct Out {
        var chunks: [Data] = []
        var head = 0  // bytes of chunks[0] already written
        var pending = 0
        var writing = false
        var closed = false
    }

    private let out = Mutex(Out())
    private var decoder = FrameDecoder()
    private var onFrame: ((Frame) -> Void)?
    private var onClose: (((any Error)?) -> Void)?
    private let closedFlag = Atomic<Bool>(false)
    private var started = false

    public var pendingBytes: Int { out.withLock { $0.pending } }
    public var isClosed: Bool { closedFlag.load(ordering: .acquiring) }

    /// Bytes to skip up to and including `preamble` before any frame (a
    /// remote command's banner); nil once seen or when there is none.
    private var preamble: Data?
    private var banner = Data()
    /// What came before the preamble (an ssh banner or an rc file's echo),
    /// for diagnostics; at most 4 KiB.
    public private(set) var bannerText = ""

    /// Takes ownership of `fd` (made non-blocking, close-on-exec, no SIGPIPE).
    /// With `preamble`, everything the peer sends before it is skipped.
    public init(fd: Int32, label: String, preamble: Data? = nil) {
        self.preamble = preamble
        self.fd = fd
        queue = DispatchQueue(label: "axolotty.conn.\(label)", qos: .userInteractive)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        writeSource = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        readSource.setCancelHandler { [fd] in _ = Darwin.close(fd) }
    }

    /// Starts reading. Callbacks run on `queue`.
    public func start(onFrame: @escaping (Frame) -> Void, onClose: @escaping ((any Error)?) -> Void) {
        self.onFrame = onFrame
        self.onClose = onClose
        started = true
        readSource.setEventHandler { [weak self] in self?.readAvailable() }
        writeSource.setEventHandler { [weak self] in self?.flush() }
        readSource.resume()
    }

    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        let kick = out.withLock { o -> Bool in
            guard !o.closed else { return false }
            o.chunks.append(data)
            o.pending += data.count
            if o.writing { return false }
            o.writing = true
            return true
        }
        if kick { queue.async { [weak self] in self?.flush() } }
    }

    public func send(_ frame: Frame) { send(Wire.encode(frame)) }

    public func send(_ message: HostMessage) {
        if let d = try? MessageCodec.frame(message) { send(d) }
    }

    public func send(_ message: ClientMessage) {
        if let d = try? MessageCodec.frame(message) { send(d) }
    }

    public func close(_ error: (any Error)? = nil) {
        guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        out.withLock { o in
            o.closed = true
            o.chunks.removeAll()
            o.head = 0
            o.pending = 0
            o.writing = false
        }
        queue.async { [self] in
            writeSource.setEventHandler {}
            // Suspended or never-activated sources must be resumed before cancel.
            if !writeSourceActive { writeSource.resume() }
            writeSourceActive = true
            writeSource.cancel()
            if !started { readSource.resume() }
            readSource.cancel()
            onClose?(error)
            onFrame = nil
            onClose = nil
        }
    }

    // MARK: Reading

    private func readAvailable() {
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if preamble != nil {
                    guard let rest = skipBanner(buf[0 ..< n]) else {
                        if n < buf.count { return }
                        continue
                    }
                    decoder.feed(rest)
                } else {
                    decoder.feed(buf[0 ..< n])
                }
                do {
                    while let frame = try decoder.next() { onFrame?(frame) }
                } catch {
                    close(error)
                    return
                }
                if n < buf.count { return }
            } else if n == 0 {
                close(nil)
                return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                close(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
        }
    }

    /// Feeds banner bytes; returns what follows the preamble once it is seen.
    private func skipBanner(_ chunk: ArraySlice<UInt8>) -> Data? {
        guard let magic = preamble else { return Data(chunk) }
        banner.append(contentsOf: chunk)
        guard let r = banner.range(of: magic) else {
            // Keep a tail long enough to complete a split preamble; give up
            // on a peer that talks a megabyte without ever saying it.
            if banner.count > 1 << 20 { close(WireError.malformed("no bridge preamble")) }
            return nil
        }
        bannerText = String(decoding: banner[banner.startIndex ..< r.lowerBound].suffix(4096), as: UTF8.self)
        let rest = Data(banner[r.upperBound...])
        preamble = nil
        banner = Data()
        return rest
    }

    // MARK: Writing (on queue)

    private var writeSourceActive = false

    private func flush() {
        while true {
            let next = out.withLock { o -> (Data, Int)? in
                guard !o.closed, let first = o.chunks.first else {
                    o.writing = false
                    return nil
                }
                return (first, o.head)
            }
            guard let (chunk, head) = next else {
                if writeSourceActive {
                    writeSource.suspend()
                    writeSourceActive = false
                }
                return
            }
            let n = chunk.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress! + head, raw.count - head)
            }
            if n > 0 {
                out.withLock { o in
                    o.pending -= n
                    if head + n == chunk.count {
                        o.chunks.removeFirst()
                        o.head = 0
                    } else {
                        o.head = head + n
                    }
                }
            } else if n < 0, errno == EAGAIN {
                if !writeSourceActive {
                    writeSource.resume()
                    writeSourceActive = true
                }
                return
            } else if n < 0, errno == EINTR {
                continue
            } else {
                close(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPIPE))
                return
            }
        }
    }
}

// MARK: - Unix sockets

public enum UnixSocket {
    /// Connects to a Unix stream socket. Returns the fd (blocking).
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = try address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .ECONNREFUSED)
        }
        return fd
    }

    /// Binds and listens (removing a stale socket file first). Returns the fd.
    public static func listen(path: String, backlog: Int32 = 64) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = try address(path)
        unlink(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0, Darwin.listen(fd, backlog) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EADDRINUSE)
        }
        _ = chmod(path, 0o600)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// True when the peer runs as our own user.
    public static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        return addr
    }
}

// MARK: - TCP (the tailnet)

/// TCP for links over a tailnet: Tailscale (WireGuard) already encrypts and
/// authenticates the path, so frames go bare, with Nagle off so a keystroke
/// leaves the moment it is typed.
public enum TCPSocket {
    /// Connects to `host` (a name or address) within `timeout` seconds.
    public static func connect(host: String, port: UInt16, timeout: Double = 5) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { throw POSIXError(.EHOSTUNREACH) }
        defer { freeaddrinfo(res) }
        var lastError = POSIXErrorCode.EHOSTUNREACH
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            ai = a.pointee.ai_next
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var rc = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if rc != 0, errno == EINPROGRESS {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                rc = poll(&p, 1, Int32(timeout * 1000)) == 1 ? 0 : -1
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if rc == 0, getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err != 0 {
                    rc = -1
                    errno = err
                } else if rc != 0 {
                    errno = ETIMEDOUT
                }
            }
            if rc == 0 {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
                tune(fd)
                return fd
            }
            lastError = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
            Darwin.close(fd)
        }
        throw POSIXError(lastError)
    }

    /// Low latency for interactive frames: no Nagle, low-delay DSCP, and
    /// keepalives so a dead path is noticed even when nobody types.
    public static func tune(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
        var idle: Int32 = 10
        _ = setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &idle, socklen_t(MemoryLayout<Int32>.size))
        var tos: Int32 = 0xB8  // DSCP EF: expedited forwarding
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS, &tos, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Listens on one numeric address (a tailnet IP). Returns the fd.
    public static func listen(address: String, port: UInt16, backlog: Int32 = 16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST | AI_PASSIVE
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &res) == 0, let a = res else { throw POSIXError(.EADDRNOTAVAIL) }
        defer { freeaddrinfo(res) }
        let fd = socket(a.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        if a.pointee.ai_family == AF_INET6 {
            _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        }
        guard Darwin.bind(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0, Darwin.listen(fd, backlog) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EADDRINUSE)
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }

    /// The peer's "ip:port" (for `tailscale whois`).
    public static func peerAddress(_ fd: Int32) -> String? {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) == 0 }
        }
        guard ok else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serv = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let rc = withUnsafePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), &serv, socklen_t(serv.count), NI_NUMERICHOST | NI_NUMERICSERV)
            }
        }
        guard rc == 0 else { return nil }
        func str(_ c: [CChar]) -> String { String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        let h = str(host), p = str(serv)
        return h.contains(":") ? "[\(h)]:\(p)" : "\(h):\(p)"
    }
}
