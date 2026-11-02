public import Foundation

/// Loads every file with `ext` under `dir` of a test bundle, sorted by name, so a
/// parameterized test names the file that failed.
public struct Fixture: Sendable, CustomStringConvertible {
    public let name: String
    public let bytes: [UInt8]
    public var description: String { name }

    public init(name: String, bytes: [UInt8]) {
        self.name = name
        self.bytes = bytes
    }

    public static func all(in bundle: Bundle, dir: String, ext: String) -> [Fixture] {
        guard let root = bundle.resourceURL?.appending(path: dir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path())
        else { return [] }
        return names.filter { $0.hasSuffix(".\(ext)") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: root.appending(path: name)) else { return nil }
            return Fixture(name: name, bytes: Array(data))
        }
    }
}

/// Deterministic xorshift generator for seeded tests (no global RNG in tests).
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// A heartbeat line from a long test, on standard error: a watchdog that
/// sees no output for minutes takes the run for stuck (`scripts/watchdog.sh`).
public func progress(_ line: String) {
    let text = "… \(line)\n"
    FileHandle.standardError.write(Data(text.utf8))
    // SwiftPM holds a test process's output until it exits; the watchdog
    // reads its log, so the line goes there too, at once.
    if let log = ProcessInfo.processInfo.environment["AXWATCH_LOG"] {
        let fd = open(log, O_WRONLY | O_APPEND)
        if fd >= 0 {
            _ = text.withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
    }
}

/// SIGPIPE in the test process, said instead of dying of it. It comes from
/// a pipe or FIFO whose reader is gone, or a socket that forgot
/// SO_NOSIGPIPE. Production processes ignore it, so the test process does
/// too, but says so on standard error, with every pipe write end and
/// unguarded socket (its address, and whether its reader is gone right
/// then) to name the writer. XNU signals the whole process for both
/// (`psignal`), so the signal lands on any thread (seen: a socketpair
/// write, caught on the main thread in mach_msg), and the stack printed
/// with it rarely shows the writer. `scripts/deep.sh` fails a step whose log has the line.
public let sigpipeTrap: Void = {
    signal(SIGPIPE) { _ in
        // The writer may have closed its descriptor by now.
        say("AXTEST SIGPIPE: a write into a pipe or socket whose reader is gone; pipe write ends and sockets without SO_NOSIGPIPE (* = reader gone):")
        // Async-signal-safe only: fstat, fcntl, getsockopt, poll, write.
        for fd: Int32 in 0 ..< 4096 {
            var st = stat()
            guard fstat(fd, &st) == 0 else { continue }
            let kind = st.st_mode & S_IFMT
            if kind == S_IFIFO {
                guard fcntl(fd, F_GETFL) & O_ACCMODE == O_WRONLY else { continue }
                say(" pipe:")
            } else if kind == S_IFSOCK {
                var on: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &len) == 0, on == 0 else { continue }
                say(" socket:")
            } else {
                continue
            }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let gone = poll(&p, 1, 0) > 0 && p.revents & Int16(POLLHUP | POLLERR) != 0
            sayNumber(Int(fd))
            if gone { say("*") }
            if kind == S_IFSOCK { sayAddress(fd) }
        }
        say("\nAXTEST SIGPIPE: the thread it came to:\n")
        // Not strictly async-signal-safe, but the thread is in a plain write.
        withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 64) { frames in
            let n = backtrace(frames.baseAddress, 64)
            backtrace_symbols_fd(frames.baseAddress, n, 2)
        }
    }
}()

private func say(_ s: StaticString) {
    _ = write(2, s.utf8Start, s.utf8CodeUnitCount)
}

/// A socket's own address, to name whose it is: `(unix /path)` (no path:
/// a socketpair), `(tcp :port>:port)` local then peer (no peer: a
/// listener). getsockname and getpeername are async-signal-safe.
private func sayAddress(_ fd: Int32) {
    var ss = sockaddr_storage()
    var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let ok = withUnsafeMutablePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    } == 0
    guard ok else { return }
    switch Int32(ss.ss_family) {
    case AF_UNIX:
        say("(unix ")
        var peer = sockaddr_un()
        var pl = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &pl) }
        }
        var local = sockaddr_un()
        _ = withUnsafeMutablePointer(to: &local) { lp in
            withUnsafePointer(to: &ss) { sp in memcpy(lp, sp, MemoryLayout<sockaddr_un>.size) }
        }
        // One end of a connected pair has the path on the other side.
        for var a in [local, peer] {
            withUnsafeBytes(of: &a.sun_path) { b in
                let n = b.firstIndex(of: 0) ?? b.count
                if n > 0 { _ = write(2, b.baseAddress!, n) }
            }
        }
        say(")")
    case AF_INET, AF_INET6:
        say("(tcp :")
        sayNumber(Int(port(of: &ss)))
        var peer = sockaddr_storage()
        var pl = socklen_t(MemoryLayout<sockaddr_storage>.size)
        if withUnsafeMutablePointer(to: &peer, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &pl) }
        }) == 0 {
            say(">:")
            sayNumber(Int(port(of: &peer)))
        }
        say(")")
    default:
        say("(other)")
    }
}

private func port(of ss: inout sockaddr_storage) -> UInt16 {
    withUnsafePointer(to: &ss) {
        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
    }
}

private func sayNumber(_ n: Int) {
    var digits: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutableBytes(of: &digits) { b in
        var i = b.count
        var v = n
        repeat {
            i -= 1
            b[i] = UInt8(48 + v % 10)
            v /= 10
        } while v > 0 && i > 0
        _ = write(2, b.baseAddress! + i, b.count - i)
    }
}
