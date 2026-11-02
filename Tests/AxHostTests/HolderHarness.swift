import AxHost
import AxModel
import AxProtocol
import AxTestSupport
import CryptoKit
import Foundation
import Synchronization
import Testing

/// Builds `axolotty-ptyd` straight from its C sources (cached by content hash),
/// so holder tests never run a stale binary and never need a separate build step.
enum PtydBinary {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static let url: URL = {
        if let o = ProcessInfo.processInfo.environment["AXOLOTTY_PTYD"] { return URL(filePath: o) }
        let fm = FileManager.default
        let sys = repo.appending(path: "Sources/AxSys")
        let sources = [repo.appending(path: "Sources/axolotty-ptyd/main.c")]
            + ((try? fm.contentsOfDirectory(at: sys, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "c" }.sorted { $0.path < $1.path }
        let headers = ((try? fm.contentsOfDirectory(at: sys.appending(path: "include"), includingPropertiesForKeys: nil))
            ?? []).sorted { $0.path < $1.path }
        var h = SHA256()
        for f in sources + headers { h.update(data: (try? Data(contentsOf: f)) ?? Data()) }
        let digest = h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let dir = repo.appending(path: ".build/axtest")
        let out = dir.appending(path: "axolotty-ptyd-\(digest)")
        if fm.isExecutableFile(atPath: out.path) { return out }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appending(path: ".ptyd-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/xcrun")
        p.arguments = ["clang", "-std=c23", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
                       "-I", sys.appending(path: "include").path, "-o", tmp.path] + sources.map(\.path)
        try? p.run()
        p.waitUntilExit()
        precondition(p.terminationStatus == 0, "compiling axolotty-ptyd failed")
        _ = rename(tmp.path, out.path)
        return out
    }()
}

/// One isolated holder per test: its own short runtime root under /tmp
/// (sun_path is 104 bytes), torn down with SHUTDOWN.
final class HolderFixture: Sendable {
    let paths: RuntimePaths
    let exits: AsyncStream<(PaneID, ChildStatus)>
    private let exitSink: AsyncStream<(PaneID, ChildStatus)>.Continuation

    init() throws {
        _ = sigpipeTrap
        let root = URL(filePath: "/tmp/axt-\(UUID().uuidString.prefix(8).lowercased())", directoryHint: .isDirectory)
        paths = RuntimePaths(root: root)
        try paths.prepare()
        (exits, exitSink) = AsyncStream.makeStream()
    }

    func connect() async throws -> CustodyClient {
        let sink = exitSink
        return try await Holder.connect(paths: paths, executable: PtydBinary.url, watchPID: getpid(), onExit: { sink.yield(($0, $1)) })
    }

    /// Connects to a holder already launched, never starting one of its own.
    func attach(timeout: Duration = .seconds(3)) async throws -> CustodyClient {
        let sink = exitSink
        let deadline = ContinuousClock.now + timeout
        while true {
            do {
                return try await Holder.connect(paths: paths, executable: nil, onExit: { sink.yield(($0, $1)) })
            } catch {
                if ContinuousClock.now > deadline { throw error }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func nextExit(_ id: PaneID) async -> ChildStatus? {
        for await (pid, st) in exits where pid == id { return st }
        return nil
    }

    func tearDown(_ client: CustodyClient?) {
        try? client?.shutdownHolder()
        try? FileManager.default.removeItem(at: paths.root)
    }
}

/// Reads from a non-blocking master until `needle` appears or the deadline passes.
func readUntil(_ fd: Int32, contains needle: String, timeout: Duration = .seconds(3)) -> String {
    var got = Data()
    let deadline = ContinuousClock.now + timeout
    var buf = [UInt8](repeating: 0, count: 4096)
    while ContinuousClock.now < deadline {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&p, 1, 20)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 { got.append(contentsOf: buf[0 ..< n]) }
        if String(decoding: got, as: UTF8.self).contains(needle) { break }
        if n == 0 { break }
    }
    return String(decoding: got, as: UTF8.self)
}

func writeAll(_ fd: Int32, _ s: String) {
    var bytes = Array(s.utf8)[...]
    while !bytes.isEmpty {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n > 0 { bytes = bytes.dropFirst(n) } else if errno != EAGAIN && errno != EINTR { return }
    }
}

func shell(_ script: String) -> SpawnSpec {
    SpawnSpec(path: "/bin/sh", argv: ["sh", "-c", script], env: ["PATH=/usr/bin:/bin", "TERM=dumb"], cwd: "/tmp",
              cols: 80, rows: 24)
}

/// Polls `body` until it returns non-nil.
func eventually<T>(timeout: Duration = .seconds(3), _ body: () throws -> T?) rethrows -> T? {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let v = try body() { return v }
        usleep(5000)
    }
    return try body()
}
