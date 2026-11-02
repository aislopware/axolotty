#if os(macOS)
public import Foundation

/// Runs a short-lived command and collects what it said, on the calling
/// thread (call it off the main thread).
///
/// Not `Process`: its exit is noticed by a dispatch process source, which
/// misses an exit that comes before it is registered (a command that fails
/// at once), and `waitUntilExit` then waits for ever (seen: HostSetupTests
/// stuck in -[NSConcreteTask waitUntilExit] with the child long gone; the
/// same reason `CommandChild` reaps with `waitpid`). Here one thread does
/// everything: posix_spawn, one `poll` loop over the child's standard input,
/// output and error (so a full pipe never stalls the other), and `waitpid`
/// on that pid, which cannot miss it.
public enum ChildProcess {
    public struct Output: Sendable, Equatable {
        /// The exit code, or 128 + the signal that ended it.
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        /// The deadline passed and it was stopped.
        public var timedOut: Bool
    }

    /// Runs `path` with `arguments`. `input` is written to its standard input
    /// (nil: /dev/null). Past `timeout` seconds it gets SIGTERM, a second
    /// later SIGKILL, and whatever it said by then is returned; a grandchild
    /// still holding its output open is not waited for past that either.
    public static func run(_ path: String, _ arguments: [String], environment: [String: String]? = nil,
                           input: Data? = nil, timeout: Double? = nil) throws -> Output {
        var inPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&errPipe) == 0 else {
            outPipe.forEach { _ = close($0) }
            throw POSIXError(.EMFILE)
        }
        if input != nil, pipe(&inPipe) != 0 {
            (outPipe + errPipe).forEach { _ = close($0) }
            throw POSIXError(.EMFILE)
        }
        // Our ends never reach any child (this one or another thread's).
        for fd in [outPipe[0], errPipe[0], inPipe[1]] where fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        // A child that stops reading is an EPIPE here, not a signal.
        if inPipe[1] >= 0 { _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1) }

        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Only the three descriptors below; no controlling terminal to stop on.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        let env = environment ?? ProcessInfo.processInfo.environment
        let cargv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, cargv, cenv)
        // The child's ends are the child's now.
        for fd in [outPipe[1], errPipe[1], inPipe[0]] where fd >= 0 { _ = close(fd) }
        guard rc == 0 else {
            for fd in [outPipe[0], errPipe[0], inPipe[1]] where fd >= 0 { _ = close(fd) }
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
        }

        let start = ContinuousClock.now
        let deadline = timeout.map { start + .milliseconds(Int($0 * 1000)) }
        var out = Data(), err = Data()
        var fds = (stdin: inPipe[1], stdout: outPipe[0], stderr: errPipe[0])
        var written = 0
        let pending = input ?? Data()
        if fds.stdin >= 0, pending.isEmpty {
            _ = close(fds.stdin)
            fds.stdin = -1
        }
        var signalled: Int32 = 0
        var status: Int32?
        var buf = [UInt8](repeating: 0, count: 64 << 10)

        /// Signals the child once the deadline passes (TERM, then KILL a second later).
        func enforce(_ now: ContinuousClock.Instant) {
            guard let deadline, now >= deadline, status == nil else { return }
            if signalled == 0 {
                kill(pid, SIGTERM)
                signalled = SIGTERM
            } else if signalled == SIGTERM, now >= deadline + .seconds(1) {
                kill(pid, SIGKILL)
                signalled = SIGKILL
            }
        }

        while fds.stdout >= 0 || fds.stderr >= 0 || fds.stdin >= 0 {
            let now = ContinuousClock.now
            enforce(now)
            // Past the deadline and its grace, stop listening: a grandchild may hold the pipes.
            if let deadline, now >= deadline + .seconds(2) { break }
            if status == nil {
                var st: Int32 = 0
                if waitpid(pid, &st, WNOHANG) == pid { status = st }
            }
            var polled: [pollfd] = []
            if fds.stdin >= 0 { polled.append(pollfd(fd: fds.stdin, events: Int16(POLLOUT), revents: 0)) }
            if fds.stdout >= 0 { polled.append(pollfd(fd: fds.stdout, events: Int16(POLLIN), revents: 0)) }
            if fds.stderr >= 0 { polled.append(pollfd(fd: fds.stderr, events: Int16(POLLIN), revents: 0)) }
            // Wake at least every 50 ms to reap and to watch the deadline.
            let n = poll(&polled, nfds_t(polled.count), 50)
            if n < 0, errno != EINTR { break }
            for p in polled where p.revents != 0 {
                if p.fd == fds.stdin {
                    let w = pending.withUnsafeBytes { raw in
                        Darwin.write(p.fd, raw.baseAddress! + written, min(raw.count - written, 64 << 10))
                    }
                    if w > 0 { written += w }
                    if w < 0, errno != EAGAIN, errno != EINTR { written = pending.count }  // its reader went
                    if written >= pending.count {
                        _ = close(fds.stdin)
                        fds.stdin = -1
                    }
                    continue
                }
                let r = buf.withUnsafeMutableBytes { Darwin.read(p.fd, $0.baseAddress, $0.count) }
                if r > 0 {
                    if p.fd == fds.stdout { out.append(contentsOf: buf[0 ..< r]) } else { err.append(contentsOf: buf[0 ..< r]) }
                } else if r == 0 || (errno != EAGAIN && errno != EINTR) {
                    _ = close(p.fd)
                    if p.fd == fds.stdout { fds.stdout = -1 } else { fds.stderr = -1 }
                }
            }
        }
        for fd in [fds.stdin, fds.stdout, fds.stderr] where fd >= 0 { _ = close(fd) }

        // Reap it: it has closed its output (and is ending), or it is being stopped.
        while status == nil {
            var st: Int32 = 0
            if deadline == nil || signalled == SIGKILL {
                // Nothing left to enforce: block, as `Process` would, but on this pid.
                while waitpid(pid, &st, 0) < 0, errno == EINTR {}
                status = st
                break
            }
            let r = waitpid(pid, &st, WNOHANG)
            if r == pid {
                status = st
            } else if r < 0, errno != EINTR {
                status = 0  // not ours to reap any more
            } else {
                enforce(ContinuousClock.now)
                usleep(2_000)
            }
        }
        let st = status ?? 0
        let code: Int32 = (st & 0x7f) == 0 ? (st >> 8) & 0xff : 128 + (st & 0x7f)
        return Output(status: code, stdout: out, stderr: err, timedOut: signalled != 0)
    }
}
#endif
