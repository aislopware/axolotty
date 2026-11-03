#if os(macOS)
import AxProtocol
public import Foundation

/// Puts Axolotty's server on a Mac over ssh, so a far Mac needs nothing
/// installed by hand: the server, its PTY holder and the CLI go to
/// `~/Library/Application Support/Axolotty/server`, and a LaunchAgent keeps
/// the server running (at login, and after a crash). Run again, it updates
/// them in place; the shells live on in the holder, which the server copies
/// out to a path of its own.
///
/// Two ssh calls, both with `BatchMode`: nothing ever waits on a prompt the
/// person can't see. One reads what the Mac is; one carries a tar of the
/// binaries on its standard input and runs the install script beside it.
/// The script is plain `/bin/sh` with no single quotes or backslashes, so
/// whatever the login shell (zsh, bash, fish), `'…'` passes it unchanged.
public struct HostSetup: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// ssh wants a password, a key, or a decision about the host key.
        case signIn(String)
        /// Not a Mac, or one this build can't run on.
        case unsupported(String)
        /// Something else went wrong; the remote's own words.
        case failed(String)
    }

    public enum Step: Equatable, Sendable { case checking, copying, starting }

    /// What the host is.
    public struct Facts: Equatable, Sendable {
        public var system: String
        public var arch: String
        public var version: OperatingSystemVersion
        public var home: String

        public static func == (a: Facts, b: Facts) -> Bool {
            a.system == b.system && a.arch == b.arch && a.home == b.home
                && (a.version.majorVersion, a.version.minorVersion, a.version.patchVersion)
                == (b.version.majorVersion, b.version.minorVersion, b.version.patchVersion)
        }
    }

    /// The LaunchAgent's label: the same job the app registers, so a Mac
    /// runs one server however it was installed.
    public static let label = "dev.axolotty.server"
    /// The binaries that go across.
    public static let binaries = ["axolottyd", "axolotty-ptyd", "axolotty"]
    /// Oldest macOS the binaries run on (Package.swift).
    public static let minimumMajor = 27

    /// Runs one command line on the host: `argv + [line]`.
    public var remote: [String]
    /// Where `binaries` are on this Mac.
    public var from: URL
    /// Each ssh call gives up after this long.
    public var timeout: Double

    public init(remote: [String], from: URL, timeout: Double = 120) {
        self.remote = remote
        self.from = from
        self.timeout = timeout
    }

    /// Over ssh to `host` (a tailnet name or address, or a `Host` in ~/.ssh/config).
    ///
    /// A host key ssh has never seen is taken on first use (`accept-new`):
    /// the far Mac is a tailnet peer, already proven by its WireGuard key, so
    /// asking the person to type "yes" in a terminal first proves nothing
    /// more. Known under its address but dialled by its MagicDNS name is the
    /// usual case. A key that *changed* is still refused, and said so.
    public init(ssh host: String, from: URL) {
        self.init(remote: ["/usr/bin/ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
                           "-o", "ConnectTimeout=10",
                           "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "--", host],
                  from: from)
    }

    // MARK: Doing it

    public func check() async throws -> Facts {
        let r = try await run(Self.quoted(Self.checkScript))
        guard r.status == 0 else { throw Self.failure(status: r.status, stderr: r.stderr) }
        let facts = try Self.facts(r.stdout)
        try Self.supports(facts, archs: Self.archs(of: from.appending(path: "axolottyd")))
        return facts
    }

    /// Checks the host, copies the binaries and starts the server there.
    public func install(progress: @Sendable (Step) -> Void = { _ in }) async throws {
        progress(.checking)
        _ = try await check()
        progress(.copying)
        // No resource forks or extended attributes: the far side gets plain files.
        let dir = from.path(percentEncoded: false), limit = timeout
        let tar = try await Task.detached {
            try ChildProcess.run("/usr/bin/tar", ["--no-mac-metadata", "-C", dir, "-cf", "-"] + Self.binaries,
                                 environment: ["COPYFILE_DISABLE": "1"], timeout: limit)
        }.value
        guard tar.status == 0 else {
            throw Failure.failed("Couldn’t pack Axolotty: \(String(decoding: tar.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let r = try await run(Self.quoted(Self.installScript), input: tar.stdout)
        guard r.status == 0, r.stdout.contains("axolotty: started") else {
            throw Self.failure(status: r.status, stderr: r.stderr.isEmpty ? r.stdout : r.stderr)
        }
        progress(.starting)
    }

    // MARK: The scripts (pure)

    /// Prints the system, the machine, the macOS version and the home folder, a line each.
    static let checkScript = """
    uname -s; uname -m; sw_vers -productVersion 2>/dev/null || echo 0; echo "$HOME"
    """

    /// Unpacks the binaries from standard input next to the old ones and
    /// moves each into place (a running server keeps its image), writes the
    /// LaunchAgent and (re)starts it: in the login session when there is
    /// one, else in the user's background domain.
    static let installScript = """
    set -e
    d="$HOME/Library/Application Support/Axolotty/server"
    t="$d/.incoming.$$"
    mkdir -p "$t"
    tar -xf - -C "$t"
    for b in \(binaries.joined(separator: " ")); do chmod 755 "$t/$b"; mv -f "$t/$b" "$d/$b"; done
    rmdir "$t"
    xattr -dr com.apple.quarantine "$d" 2>/dev/null || true
    a="$HOME/Library/LaunchAgents"
    p="$a/\(label).plist"
    mkdir -p "$a"
    cat > "$p" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(label)</string>
      <key>ProgramArguments</key><array><string>$d/axolottyd</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
      <key>ProcessType</key><string>Interactive</string>
    </dict>
    </plist>
    PLIST
    u=$(id -u)
    if launchctl print "gui/$u" >/dev/null 2>&1; then dom="gui/$u"; else dom="user/$u"; fi
    launchctl bootout "$dom/\(label)" >/dev/null 2>&1 || true
    n=0
    until launchctl bootstrap "$dom" "$p" 2>/dev/null; do
      n=$((n + 1)); [ $n -lt 10 ] || { echo "launchd would not start the server in $dom" >&2; exit 1; }
      sleep 0.5
    done
    echo "axolotty: started in $dom"
    """

    /// `line` as one argument to the remote login shell, run by /bin/sh.
    static func quoted(_ script: String) -> String {
        precondition(!script.contains("'") && !script.contains("\\"), "the script must survive any shell's '…'")
        return "/bin/sh -c '\(script)'"
    }

    static func facts(_ out: String) throws -> Facts {
        let lines = out.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 4 else { throw Failure.failed("The host said: \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let v = lines[2].split(separator: ".").map { Int($0) ?? 0 }
        return Facts(system: lines[0], arch: lines[1],
                     version: OperatingSystemVersion(majorVersion: v.first ?? 0, minorVersion: v.count > 1 ? v[1] : 0,
                                                     patchVersion: v.count > 2 ? v[2] : 0),
                     home: lines[3])
    }

    /// Whether these binaries run there.
    static func supports(_ f: Facts, archs: Set<String>) throws {
        guard f.system == "Darwin" else { throw Failure.unsupported("Axolotty hosts are Macs; that one runs \(f.system).") }
        guard f.version.majorVersion >= minimumMajor else {
            throw Failure.unsupported("That Mac runs macOS \(f.version.majorVersion); Axolotty needs macOS \(minimumMajor) or later.")
        }
        guard archs.isEmpty || archs.contains(f.arch) else {
            throw Failure.unsupported("That Mac is \(f.arch == "x86_64" ? "Intel" : f.arch); this Axolotty is built for \(archs.sorted().joined(separator: " and ")).")
        }
    }

    /// What ssh's exit and words mean.
    static func failure(status: Int32, stderr: String) -> Failure {
        let said = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let login = ["Permission denied", "Host key verification failed", "passphrase", "password", "REMOTE HOST IDENTIFICATION HAS CHANGED"]
        if status == 255, login.contains(where: { said.localizedCaseInsensitiveContains($0) }) { return .signIn(said) }
        if status == 255, said.contains("Connection refused") {
            return .failed("Remote Login is off there. Turn it on in System Settings › General › Sharing, or use Tailscale SSH.")
        }
        if status == 255, ["Operation timed out", "No route to host", "Network is unreachable"].contains(where: said.contains) {
            return .failed("It didn’t answer ssh. Is it awake and on the tailnet?")
        }
        if status == 255 { return .failed(said.isEmpty ? "ssh couldn’t reach the host." : said) }
        return .failed(said.isEmpty ? "The install stopped (exit \(status))." : said)
    }

    /// The architectures a Mach-O file holds (thin or universal); empty when unreadable.
    static func archs(of file: URL) -> Set<String> {
        guard let h = try? FileHandle(forReadingFrom: file), let d = try? h.read(upToCount: 4096), d.count >= 8 else { return [] }
        try? h.close()
        func u32(_ at: Int, big: Bool) -> UInt32 {
            guard at + 4 <= d.count else { return 0 }
            let v = d[d.startIndex + at ..< d.startIndex + at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return big ? UInt32(bigEndian: v) : UInt32(littleEndian: v)
        }
        func name(_ cpu: UInt32) -> String? { cpu == 0x0100_000C ? "arm64" : cpu == 0x0100_0007 ? "x86_64" : nil }
        switch u32(0, big: false) {
        case 0xFEED_FACF: return Set([name(u32(4, big: false))].compactMap { $0 })
        case 0xBEBA_FECA:  // FAT_MAGIC, stored big-endian
            let n = Int(u32(4, big: true))
            return Set((0 ..< min(n, 8)).compactMap { name(u32(8 + $0 * 20, big: true)) })
        default: return []
        }
    }

    // MARK: Running

    struct Output { var status: Int32; var stdout: String; var stderr: String }

    /// Runs `remote + [line]`, `input` on its standard input; given up past `timeout`.
    private func run(_ line: String, input: Data? = nil) async throws -> Output {
        let argv = remote + [line], limit = timeout
        let r = try await Task.detached {
            try ChildProcess.run(argv[0], Array(argv.dropFirst()), input: input, timeout: limit)
        }.value
        return Output(status: r.status, stdout: String(decoding: r.stdout, as: UTF8.self),
                      stderr: String(decoding: r.stderr, as: UTF8.self))
    }
}
#endif
