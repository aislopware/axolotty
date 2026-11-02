// `axolotty bridge`: this host's server on standard input and output, for a
// client that reaches the host through a command (`ssh host axolotty
// bridge`, `docker exec -i c axolotty bridge`). It starts the server when
// nothing answers, prints the bridge preamble (so the client can skip an ssh
// banner or an rc file's echo), then copies bytes both ways until either
// side ends. Frames pass through untouched; the server sees a local client.
import AxProtocol
import Darwin
import Foundation

enum Bridge {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let paths = RuntimePaths.standard()
        let socket = paths.hostSocket.path(percentEncoded: false)
        guard let fd = connectOrStart(socket: socket, paths: paths) else {
            fail("the Axolotty server didn't start on this host", .unreachable)
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = Wire.bridgePreamble.withUnsafeBytes { writeAll(1, $0) }

        // Two pumps; the first to end ends the bridge (the peer closed, or
        // the server went away).
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            pump(from: 0, to: fd)
            shutdown(fd, SHUT_WR)
            done.signal()
        }
        Thread.detachNewThread {
            pump(from: fd, to: 1)
            done.signal()
        }
        done.wait()
        exit(Exit.ok.rawValue)
    }

    /// The server's socket, starting `axolottyd` (the sibling of this
    /// executable) in a session of its own when nothing answers.
    static func connectOrStart(socket: String, paths: RuntimePaths) -> Int32? {
        if let fd = try? UnixSocket.connect(path: socket) { return fd }
        try? paths.prepare()
        // One starter at a time: two bridges opened at once must not race two servers.
        let lockPath = paths.run.appending(path: "bridge.lock").path(percentEncoded: false)
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer {
            if lock >= 0 {
                flock(lock, LOCK_UN)
                close(lock)
            }
        }
        if let fd = try? UnixSocket.connect(path: socket) { return fd }
        let exe = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
            .appending(path: "axolottyd").path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: exe) else { return nil }
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for f: Int32 in 0 ... 2 {
            posix_spawn_file_actions_addopen(&actions, f, "/dev/null", f == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir(&actions, "/")
        var env = ProcessInfo.processInfo.environment
        env["AXOLOTTY_HOME"] = paths.root.path(percentEncoded: false)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(exe), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        guard posix_spawn(&pid, exe, &actions, &attr, argv, envp) == 0 else { return nil }
        for _ in 0 ..< 200 {
            if let fd = try? UnixSocket.connect(path: socket) { return fd }
            usleep(25_000)
        }
        return nil
    }

    private static func pump(from src: Int32, to dst: Int32) {
        var buf = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let n = buf.withUnsafeMutableBytes { read(src, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            let ok = buf.withUnsafeBytes { writeAll(dst, UnsafeRawBufferPointer(rebasing: $0[0 ..< n])) }
            guard ok else { return }
        }
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = write(fd, bytes.baseAddress! + off, bytes.count - off)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            off += n
        }
        return true
    }
}
