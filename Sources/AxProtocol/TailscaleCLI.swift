#if os(macOS)
public import Foundation

/// The Tailscale CLI, which both ends ask: the host who is calling (`whois`),
/// the app which machines it could reach (`status`). Axolotty does no
/// transport work of its own; Tailscale carries, encrypts and authenticates.
public enum TailscaleCLI {
    /// On PATH for the standalone and Homebrew installs, inside the app
    /// bundle for the App Store one.
    public static let path: String? = {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Runs the CLI and returns its output, or nil when it fails or takes
    /// longer than `timeout` seconds. Blocks: call it off the main thread.
    public static func run(_ arguments: [String], timeout: Double = 3) -> Data? {
        guard let path, let r = try? ChildProcess.run(path, arguments, timeout: timeout), r.status == 0, !r.timedOut else { return nil }
        return r.stdout
    }
}
#endif
