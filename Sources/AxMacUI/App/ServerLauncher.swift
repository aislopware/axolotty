import AppKit
import AxProtocol
import Foundation
import ServiceManagement
import os

/// Starts the local server when nothing answers on its socket.
///
/// Shipping app: `axolottyd` runs as a LaunchAgent registered through
/// SMAppService (launchd keeps it alive and starts it at login). Dev builds
/// (`swift run AxolottyDev`) have no bundle, so the sibling binary is spawned in its
/// own session instead; either way the server outlives the app.
enum ServerLauncher {
    static let agentPlist = "dev.axolotty.server.plist"
    private static let log = Logger(subsystem: "dev.axolotty", category: "launcher")

    static func isRunning(_ paths: RuntimePaths) -> Bool {
        guard let fd = try? UnixSocket.connect(path: paths.hostSocket.path(percentEncoded: false)) else { return false }
        close(fd)
        return true
    }

    /// Returns nil on success, else a reason to show.
    static func ensureRunning(_ paths: RuntimePaths) async -> String? {
        if isRunning(paths) { return nil }
        do { try paths.prepare() } catch { return "Can’t create \(paths.root.path(percentEncoded: false)): \(error)" }
        let bundled = Bundle.main.bundleURL.pathExtension == "app"
            && FileManager.default.fileExists(
                atPath: Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(agentPlist)")
                    .path(percentEncoded: false))
        if bundled {
            let service = SMAppService.agent(plistName: agentPlist)
            do {
                if service.status != .enabled { try service.register() }
            } catch {
                log.error("LaunchAgent registration failed: \(error, privacy: .public); spawning directly")
                if let e = spawnSibling(paths) { return e }
            }
        } else if let e = spawnSibling(paths) {
            return e
        }
        for _ in 0 ..< 100 {
            if isRunning(paths) { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return "The Axolotty server did not start."
    }

    private static func spawnSibling(_ paths: RuntimePaths) -> String? {
        guard let dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() else {
            return "Can’t locate the app’s executables."
        }
        let exe = dir.appending(path: "axolottyd").path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: exe) else { return "axolottyd is missing next to the app." }
        var attr = posix_spawnattr_t(nil as OpaquePointer?)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0 ... 2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
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
        let rc = posix_spawn(&pid, exe, &actions, &attr, argv, envp)
        guard rc == 0 else { return "Couldn’t start axolottyd: \(String(cString: strerror(rc)))" }
        // The server outlives us; reap it only if it exits while we run.
        let child = pid
        Thread.detachNewThread {
            var st: Int32 = 0
            while waitpid(child, &st, 0) < 0, errno == EINTR {}
        }
        return nil
    }
}
