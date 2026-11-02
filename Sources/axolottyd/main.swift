// axolottyd — the Axolotty server: shared document, authoritative terminals,
// agent status, and every client connection. Programs live in axolotty-ptyd,
// so this process can restart (crash, update) without losing them.
//
// It also listens on this Mac's tailnet addresses for the person's other
// devices (Tailscale says who is calling); --no-tailnet turns that off.
//
// Usage: axolottyd [--home DIR] [--ptyd PATH] [--tailnet-port N | --no-tailnet]
import AxHost
import AxProtocol
import Dispatch
import Foundation
import os

let log = Logger(subsystem: "dev.axolotty", category: "daemon")

var args = CommandLine.arguments.dropFirst()
var home: String?
var ptydOverride: String?
var tailnetPort = Tailnet.port
var noTailnet = false
while let a = args.popFirst() {
    switch a {
    case "--home": home = args.popFirst()
    case "--ptyd": ptydOverride = args.popFirst()
    case "--no-tailnet": noTailnet = true
    case "--tailnet-port":
        guard let n = args.popFirst().flatMap(UInt16.init) else { exit(2) }
        tailnetPort = n
    case "--version":
        print("axolottyd 0.1.0")
        exit(0)
    default:
        FileHandle.standardError.write(Data("usage: axolottyd [--home DIR] [--ptyd PATH] [--tailnet-port N | --no-tailnet]\n".utf8))
        exit(2)
    }
}

var env = ProcessInfo.processInfo.environment
if let home { env["AXOLOTTY_HOME"] = home }
let paths = RuntimePaths.standard(environment: env)

/// The holder ships next to this binary (app bundle: Contents/Helpers or MacOS).
@MainActor func bundledHolder() -> URL? {
    if let ptydOverride { return URL(filePath: ptydOverride) }
    let me = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? me
    let candidate = exe.deletingLastPathComponent().appending(path: "axolotty-ptyd")
    return FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
}

/// The CLI ships next to this binary too.
@MainActor func bundledCLI() -> URL? {
    let me = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? me
    let candidate = exe.deletingLastPathComponent().appending(path: "axolotty")
    return FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) ? candidate : nil
}

do {
    try paths.prepare()
    let holder = try bundledHolder().map { try Holder.install($0, paths: paths) }
    var config = ServerConfig(paths: paths, holderExecutable: holder)
    config.cliExecutable = bundledCLI()
    if !noTailnet { config.tailnetPort = tailnetPort }
    let server = Server(config: config)
    try await server.start()
    log.info("axolottyd serving at \(paths.hostSocket.path(percentEncoded: false), privacy: .public)")

    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    let (stops, stop) = AsyncStream<Int32>.makeStream()
    var sources: [any DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { stop.yield(sig) }
        s.resume()
        sources.append(s)
    }
    for await sig in stops {
        log.info("signal \(sig): stopping (programs keep running in the holder)")
        await server.stop()
        break
    }
    _ = sources
    exit(0)
} catch ServerError.alreadyRunning {
    log.info("another axolottyd owns \(paths.root.path(percentEncoded: false), privacy: .public)")
    exit(0)
} catch {
    log.error("axolottyd failed: \(String(describing: error), privacy: .public)")
    FileHandle.standardError.write(Data("axolottyd: \(error)\n".utf8))
    exit(1)
}
