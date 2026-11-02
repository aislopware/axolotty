#if os(macOS)
public import AxModel
public import AxProtocol
import CryptoKit
public import Foundation

/// Finds, installs and launches `axolotty-ptyd`.
///
/// The holder must outlive the server and the app, including app updates, so:
/// - it runs from a content-addressed copy under `bin/` (an update that replaces
///   the bundle never touches the running image or its path);
/// - it is spawned in its own session (`POSIX_SPAWN_SETSID`), so neither the
///   server's process group nor launchd's job teardown signals it;
/// - its lock file makes a second launch exit at once, so racing servers are safe.
public enum Holder {
    /// Copies `bundled` into `paths.bin` as `axolotty-ptyd-<sha256 prefix>` (once) and returns the copy.
    public static func install(_ bundled: URL, paths: RuntimePaths) throws -> URL {
        let data = try Data(contentsOf: bundled)
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let target = paths.bin.appending(path: "axolotty-ptyd-\(digest)")
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: target.path(percentEncoded: false)) {
            let tmp = paths.bin.appending(path: ".ptyd-\(UUID().uuidString)")
            try data.write(to: tmp)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path(percentEncoded: false))
            if rename(tmp.path(percentEncoded: false), target.path(percentEncoded: false)) != 0 {
                try? fm.removeItem(at: tmp)
                throw CustodyError.holderUnavailable("install: \(String(cString: strerror(errno)))")
            }
        }
        return target
    }

    /// Spawns the holder detached. Returns its pid. A holder that finds the lock taken exits 0.
    @discardableResult
    public static func launch(_ executable: URL, paths: RuntimePaths, ringBytes: Int = 8 << 20,
                              watchPID: pid_t? = nil) throws -> pid_t {
        try paths.prepare()
        let args = [
            executable.path(percentEncoded: false),
            "--socket", paths.holderSocket.path(percentEncoded: false),
            "--lock", paths.holderLock.path(percentEncoded: false),
            "--ring-dir", paths.run.path(percentEncoded: false),
            "--ring-bytes", String(ringBytes),
        ] + (watchPID.map { ["--watch-pid", String($0)] } ?? [])
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
                                              | POSIX_SPAWN_SETSIGMASK))
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)

        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0 ... 2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        posix_spawn_file_actions_addchdir(&actions, "/")

        var pid: pid_t = 0
        let cargs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }
        let env = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), strdup("LANG=en_US.UTF-8"), nil]
        defer { env.forEach { free($0) } }
        let rc = posix_spawn(&pid, args[0], &actions, &attr, cargs, env)
        guard rc == 0 else { throw CustodyError.holderUnavailable("spawn: \(String(cString: strerror(rc)))") }
        // Reap it if it exits while we live (lock lost, shutdown); otherwise launchd adopts it.
        let child = pid
        Thread.detachNewThread {
            var st: Int32 = 0
            while waitpid(child, &st, 0) < 0, errno == EINTR {}
        }
        return pid
    }

    /// Connects to the running holder, launching `executable` first if there is none.
    public static func connect(
        paths: RuntimePaths, executable: URL?, timeout: Duration = .seconds(3), watchPID: pid_t? = nil,
        onExit: @escaping @Sendable (PaneID, ChildStatus) -> Void = { _, _ in },
        onDisconnect: @escaping @Sendable () -> Void = {}
    ) async throws -> CustodyClient {
        let socket = paths.holderSocket.path(percentEncoded: false)
        if let c = try? CustodyClient(socketPath: socket, onExit: onExit, onDisconnect: onDisconnect) { return c }
        guard let executable else { throw CustodyError.holderUnavailable("no holder running") }
        try launch(executable, paths: paths, watchPID: watchPID)
        let deadline = ContinuousClock.now + timeout
        var delay = Duration.milliseconds(2)
        while true {
            do {
                return try CustodyClient(socketPath: socket, onExit: onExit, onDisconnect: onDisconnect)
            } catch {
                if ContinuousClock.now > deadline { throw CustodyError.holderUnavailable("\(error)") }
                try await Task.sleep(for: delay)
                delay = min(delay * 2, .milliseconds(50))
            }
        }
    }
}
#endif
