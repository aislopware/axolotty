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

/// SIGPIPE in the test process, said instead of dying of it. XNU raises a
/// write's EPIPE as a signal to the whole process, not the writing thread,
/// when the descriptor is not a socket. So it comes from a pipe or FIFO
/// whose reader is gone (sockets here set SO_NOSIGPIPE). Production
/// processes ignore it, so the test process does too, but says so on
/// standard error, with every write end whose reader is gone right then, to
/// name the writer. `scripts/deep.sh` fails a step whose log has the line.
public let sigpipeTrap: Void = {
    signal(SIGPIPE) { _ in
        // The handler runs on any thread, beside the writer, which may close
        // its descriptor at once: the list is a best effort.
        say("AXTEST SIGPIPE: a write into a pipe whose reader is gone; pipe write ends (* = reader gone):")
        // Async-signal-safe only: fstat, fcntl, poll, write; no allocation.
        for fd: Int32 in 0 ..< 4096 {
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFIFO,
                  fcntl(fd, F_GETFL) & O_ACCMODE == O_WRONLY else { continue }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let gone = poll(&p, 1, 0) > 0 && p.revents & Int16(POLLHUP | POLLERR) != 0
            say(" ")
            sayNumber(Int(fd))
            if gone { say("*") }
        }
        say("\n")
    }
}()

private func say(_ s: StaticString) {
    _ = write(2, s.utf8Start, s.utf8CodeUnitCount)
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
