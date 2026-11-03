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
/// - Every send goes into a lane: lane 0 (control) always goes first, then
///   whichever lane has the least queued, a frame at a time. Each pane has
///   its own lane, so a pane pouring out a build log never holds back the
///   echo of a key typed into another (Slopty got the same from a QUIC
///   stream per session). Order holds within a lane, never across lanes.
public final class FramedConnection: FrameLink, @unchecked Sendable {
    public let fd: Int32
    public let queue: DispatchQueue
    private let readSource: any DispatchSourceRead
    private let writeSource: any DispatchSourceWrite

    private struct Out {
        var lanes = SendLanes()
        var writing = false
        var closed = false
    }

    private let out = Mutex(Out())
    private var decoder = FrameDecoder()
    private var onFrame: ((Frame) -> Void)?
    private var onClose: (((any Error)?) -> Void)?
    private let closedFlag = Atomic<Bool>(false)
    private var started = false

    public var pendingBytes: Int { out.withLock { $0.lanes.pending } }

    /// What is queued in one lane (a pane's backlog on this link).
    public func pendingBytes(lane: Int) -> Int { out.withLock { $0.lanes.pending(lane: lane) } }

    /// The lane for a stream of frames that must stay in order (one pane's).
    public static func lane<K: Hashable>(_ key: K) -> Int { SendLanes.lane(key) }
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
        noSIGPIPE(fd)  // again, for a descriptor made elsewhere
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

    public func send(_ data: Data, lane: Int, priority _: Int32) {
        guard !data.isEmpty else { return }
        let kick = out.withLock { o -> Bool in
            guard !o.closed else { return false }
            o.lanes.push(data, lane: lane)
            if o.writing { return false }
            o.writing = true
            return true
        }
        if kick { queue.async { [weak self] in self?.flush() } }
    }

    public func close(_ error: (any Error)?) {
        guard !closedFlag.exchange(true, ordering: .acquiringAndReleasing) else { return }
        out.withLock { o in
            o.closed = true
            o.lanes.removeAll()
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

    // MARK: Pacing (TCP links)

    private var pacer: BulkPacer?
    private let epoch = ContinuousClock.now
    private var retryArmed = false

    /// Paces bulk lanes on this (TCP) socket (`BulkPacer`). Call before `start`.
    public func pace() { pacer = BulkPacer() }

    /// Whether bulk output should wait now (on queue).
    private func bulkMustWait() -> Bool {
        guard pacer != nil else { return false }
        var info = tcp_connection_info()
        var len = socklen_t(MemoryLayout<tcp_connection_info>.size)
        guard getsockopt(fd, IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0 else { return false }
        let rtt: Duration? = info.tcpi_rttcur > 0 ? .milliseconds(Int(info.tcpi_rttcur)) : nil
        return pacer!.holdsBulk(now: ContinuousClock.now - epoch, rtt: rtt, socketBytes: Int(info.tcpi_snd_sbbytes))
    }

    // MARK: Writing (on queue)

    private var writeSourceActive = false

    private func flush() {
        while true {
            let paced = pacer != nil && bulkMustWait()
            let next = out.withLock { o -> (Data, Int)? in
                guard !o.closed, let chunk = o.lanes.next(holdBulk: paced) else {
                    o.writing = false
                    return nil
                }
                return (chunk, o.lanes.head)
            }
            guard let (chunk, head) = next else {
                if paced, !retryArmed, out.withLock({ !$0.closed && $0.lanes.choose() != nil }) {
                    // Bulk waits for the path's queue to drain; look again
                    // shortly. A new send still kicks a flush at once, so an
                    // echo never waits on this.
                    retryArmed = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                        self?.retryArmed = false
                        self?.flush()
                    }
                }
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
                out.withLock { $0.lanes.wrote(n) }
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

/// SO_NOSIGPIPE, set the moment a socket exists. Set later it can fail:
/// XNU refuses any option (EINVAL) on a socket already shut both ways, so
/// a link whose peer left between connect and the option kept SIGPIPE,
/// and its first write signalled the whole process. Sockets a listener
/// accepts inherit it.
public func noSIGPIPE(_ fd: Int32) {
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
}

public enum UnixSocket {
    /// Connects to a Unix stream socket. Returns the fd (blocking).
    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        noSIGPIPE(fd)
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
        noSIGPIPE(fd)
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
            noSIGPIPE(fd)
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
        // Keep little unsent data in the kernel, so the lanes above (not one
        // FIFO socket buffer) decide what goes out next.
        var lowat = Int32(Wire.notSentLowat)
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NOTSENT_LOWAT, &lowat, socklen_t(MemoryLayout<Int32>.size))
        var tos: Int32 = 0xB8  // DSCP EF: expedited forwarding
        _ = setsockopt(fd, IPPROTO_IP, IP_TOS, &tos, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_TCLASS, &tos, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Listens on one numeric address (a tailnet IP). Returns the fd.
    /// `reuse` false: refuses a port anything here already listens on, even
    /// on the wildcard address (SO_REUSEADDR would let this one shadow it).
    public static func listen(address: String, port: UInt16, backlog: Int32 = 16, reuse: Bool = true) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_NUMERICHOST | AI_PASSIVE
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &res) == 0, let a = res else { throw POSIXError(.EADDRNOTAVAIL) }
        defer { freeaddrinfo(res) }
        let fd = socket(a.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        noSIGPIPE(fd)
        var one: Int32 = 1
        if reuse { _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size)) }
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

    /// The port a socket is bound to (a listener asked for port 0).
    public static func localPort(_ fd: Int32) -> UInt16? {
        var ss = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &ss) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { return nil }
        let family = Int32(ss.ss_family)
        return withUnsafePointer(to: &ss) { p -> UInt16? in
            switch family {
            case AF_INET: p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            case AF_INET6: p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
            default: nil
            }
        }
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
