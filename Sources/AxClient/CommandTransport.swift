#if os(macOS)
import Darwin
public import Foundation
import Synchronization

/// A host reached through a command's standard input and output: `ssh host
/// axolotty bridge`, `docker exec -i c axolotty bridge`. The command gets one
/// end of a socket pair as fd 0 and 1, so the link is a socket on our side
/// (no SIGPIPE, the same framing code as the local Unix socket), and its
/// standard error is kept for saying why it failed.
public final class CommandChild: @unchecked Sendable {
    public let pid: pid_t
    /// Our end of the socket pair; owned by the connection once handed over.
    public let fd: Int32
    private let errFD: Int32
    private let errSource: any DispatchSourceRead
    private let exitSource: any DispatchSourceProcess
    private let queue = DispatchQueue(label: "axolotty.command")

    private struct State {
        var stderr = Data()
        /// The pipe reached its end. Its number is closed and may be any
        /// other file's now, so it is never read again.
        var stderrEnded = false
        var status: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    private let state = Mutex(State())

    /// Spawns `argv` (looked up on PATH) in a session of its own.
    public static func spawn(_ argv: [String], environment: [String: String]? = nil) throws -> CommandChild {
        guard let exe = argv.first, !exe.isEmpty else { throw POSIXError(.EINVAL) }
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EMFILE) }
        var err: [Int32] = [-1, -1]
        guard pipe(&err) == 0 else {
            Darwin.close(pair[0])
            Darwin.close(pair[1])
            throw POSIXError(.EMFILE)
        }
        defer {
            Darwin.close(pair[1])
            Darwin.close(err[1])
        }
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // No controlling terminal: ssh can never stop to ask on one.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, pair[1], 0)
        posix_spawn_file_actions_adddup2(&actions, pair[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        let env = environment ?? ProcessInfo.processInfo.environment
        let cargv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        let cenv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cargv.forEach { free($0) }
            cenv.forEach { free($0) }
        }
        var pid: pid_t = 0
        let rc = posix_spawnp(&pid, exe, &actions, &attr, cargv, cenv)
        guard rc == 0 else {
            Darwin.close(pair[0])
            Darwin.close(err[0])
            throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .ENOENT)
        }
        return CommandChild(pid: pid, fd: pair[0], errFD: err[0])
    }

    private init(pid: pid_t, fd: Int32, errFD: Int32) {
        self.pid = pid
        self.fd = fd
        self.errFD = errFD
        _ = fcntl(errFD, F_SETFL, fcntl(errFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errFD, F_SETFD, FD_CLOEXEC)
        errSource = DispatchSource.makeReadSource(fileDescriptor: errFD, queue: queue)
        exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        errSource.setEventHandler { [weak self] in self?.drainStderr() }
        errSource.setCancelHandler { [errFD] in _ = Darwin.close(errFD) }
        exitSource.setEventHandler { [weak self] in self?.reap() }
        errSource.resume()
        exitSource.resume()
    }

    deinit {
        exitSource.cancel()
        errSource.cancel()
        if state.withLock({ $0.status == nil }) {
            kill(pid, SIGKILL)
            let pid = pid
            DispatchQueue.global().async {
                var st: Int32 = 0
                while waitpid(pid, &st, 0) < 0, errno == EINTR {}
            }
        }
    }

    /// Runs on `queue` only, from the pipe's source and from `reap`.
    private func drainStderr() {
        guard !state.withLock({ $0.stderrEnded }) else { return }
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(errFD, $0.baseAddress, $0.count) }
            guard n > 0 else {
                if n == 0 {
                    state.withLock { $0.stderrEnded = true }
                    errSource.cancel()
                }
                return
            }
            state.withLock { s in
                s.stderr.append(contentsOf: buf[0 ..< n])
                if s.stderr.count > 16 << 10 { s.stderr = s.stderr.suffix(8 << 10) }
            }
        }
    }

    private func reap() {
        var st: Int32 = 0
        var r: pid_t
        repeat { r = waitpid(pid, &st, WNOHANG) } while r < 0 && errno == EINTR
        guard r == pid else { return }
        drainStderr()
        // WIFEXITED / WEXITSTATUS, spelled out (the macros don't import).
        let code: Int32 = (st & 0x7F) == 0 ? (st >> 8) & 0xFF : 128 + (st & 0x7F)
        let waiters = state.withLock { s -> [CheckedContinuation<Int32, Never>] in
            s.status = code
            defer { s.waiters = [] }
            return s.waiters
        }
        exitSource.cancel()
        waiters.forEach { $0.resume(returning: code) }
    }

    /// The last lines the command wrote to standard error, trimmed.
    public var stderrTail: String {
        let text = state.withLock { String(decoding: $0.stderr, as: UTF8.self) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: "\n")
    }

    public var exitStatus: Int32? { state.withLock { $0.status } }

    /// Waits for the command to end, asking it to after `grace` seconds
    /// (SIGTERM, then SIGKILL one second later). Returns its exit status
    /// (128 + signal when killed).
    public func finish(grace: Double = 0) async -> Int32 {
        if let s = exitStatus { return s }
        let pid = pid
        queue.asyncAfter(deadline: .now() + grace) { [weak self] in
            guard self?.exitStatus == nil else { return }
            kill(pid, SIGTERM)
            self?.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                if self?.exitStatus == nil { kill(pid, SIGKILL) }
            }
        }
        return await withCheckedContinuation { c in
            let done = state.withLock { s -> Int32? in
                if let st = s.status { return st }
                s.waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}
#endif
