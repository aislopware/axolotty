@testable import AxClient
import Foundation
import Testing

/// Setting a far Mac up over ssh (`HostSetup`): its rules, then the whole
/// install run against this Mac, with "ssh" a shell in a scratch home and
/// launchctl a stand-in that writes down what it was asked.
@Suite("Host setup", .timeLimit(.minutes(1)))
struct HostSetupTests {
    @Test func theHostSaysWhatItIs() throws {
        let f = try HostSetup.facts("Darwin\narm64\n26.1\n/Users/ada\n")
        #expect(f.system == "Darwin" && f.arch == "arm64" && f.home == "/Users/ada")
        #expect((f.version.majorVersion, f.version.minorVersion) == (26, 1))
        #expect(throws: HostSetup.Failure.self) { try HostSetup.facts("Darwin\n") }
    }

    @Test func onlyAMacThisBuildRunsOnIsSetUp() throws {
        func facts(_ s: String, _ arch: String, _ v: Int) -> HostSetup.Facts {
            .init(system: s, arch: arch, version: .init(majorVersion: v, minorVersion: 0, patchVersion: 0), home: "/h")
        }
        try HostSetup.supports(facts("Darwin", "arm64", 27), archs: ["arm64"])
        try HostSetup.supports(facts("Darwin", "x86_64", 28), archs: ["arm64", "x86_64"])
        try HostSetup.supports(facts("Darwin", "arm64", 27), archs: [])  // unreadable: let the host try
        for (f, why) in [(facts("Linux", "x86_64", 6), "Macs"), (facts("Darwin", "arm64", 26), "macOS 27"),
                         (facts("Darwin", "x86_64", 27), "Intel")] {
            #expect {
                try HostSetup.supports(f, archs: ["arm64"])
            } throws: { e in
                guard case let .unsupported(text) = e as? HostSetup.Failure else { return false }
                return text.contains(why)
            }
        }
    }

    @Test func aTailnetPeersFirstKeyIsTakenAndAChangedOneIsNot() {
        let ssh = HostSetup(ssh: "mini", from: URL(filePath: "/")).remote
        #expect(ssh.contains("BatchMode=yes"), "never waits on a prompt nobody sees")
        #expect(ssh.contains("StrictHostKeyChecking=accept-new"))
        #expect(HostSetup.failure(status: 255, stderr: "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @")
            == .signIn("@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @"))
    }

    @Test func sshsWordsSayWhetherToSignIn() {
        #expect(HostSetup.failure(status: 255, stderr: "ada@mini: Permission denied (publickey,password).") == .signIn("ada@mini: Permission denied (publickey,password)."))
        #expect(HostSetup.failure(status: 255, stderr: "Host key verification failed.\n") == .signIn("Host key verification failed."))
        #expect(HostSetup.failure(status: 255, stderr: "ssh: connect to host mini port 22: Operation timed out")
            == .failed("It didn’t answer ssh. Is it awake and on the tailnet?"))
        #expect(HostSetup.failure(status: 255, stderr: "ssh: connect to host mini port 22: Connection refused")
            == .failed("Remote Login is off there. Turn it on in System Settings › General › Sharing, or use Tailscale SSH."))
        #expect(HostSetup.failure(status: 255, stderr: "ssh: Could not resolve hostname mini: nodename nor servname provided")
            == .failed("ssh: Could not resolve hostname mini: nodename nor servname provided"))
        #expect(HostSetup.failure(status: 1, stderr: "") == .failed("The install stopped (exit 1)."))
    }

    @Test func theScriptsSurviveAnyLoginShell() {
        for s in [HostSetup.checkScript, HostSetup.installScript] {
            #expect(!s.contains("'") && !s.contains("\\"), "inside '…' fish reads \\ and ' as escapes")
        }
    }

    @Test func machOHeadersNameTheirArchitectures() {
        let me = HostSetup.archs(of: URL(filePath: CommandLine.arguments[0]))
        #if arch(arm64)
        #expect(me.contains("arm64"))
        #endif
        #expect(HostSetup.archs(of: URL(filePath: "/bin/ls")).isSuperset(of: ["arm64", "x86_64"]), "universal")
        #expect(HostSetup.archs(of: URL(filePath: "/etc/hosts")).isEmpty)
    }

    // MARK: The whole install, here

    struct Scratch {
        let root: URL
        var home: URL { root.appending(path: "home dir") }  // a space, as in "Application Support"
        var from: URL { root.appending(path: "from") }
        var fakes: URL { root.appending(path: "fakes") }
        var server: URL { home.appending(path: "Library/Application Support/Axolotty/server") }
        var plist: URL { home.appending(path: "Library/LaunchAgents/\(HostSetup.label).plist") }
        var calls: URL { home.appending(path: "launchctl.log") }

        /// `bootstrap`: how many times it refuses before it works (-1: always).
        init(refusals: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "axsetup-\(UUID().uuidString.prefix(8))")
            let fm = FileManager.default
            for d in [home, from, fakes] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
            try write(fakes.appending(path: "launchctl"), """
            #!/bin/sh
            echo "$*" >> "$HOME/launchctl.log"
            case "$1" in
              print) exit 1 ;;
              bootstrap)
                n=$(cat "$HOME/refused" 2>/dev/null || echo 0)
                if [ \(refusals) -lt 0 ] || [ "$n" -lt \(refusals) ]; then echo $((n + 1)) > "$HOME/refused"; exit 5; fi ;;
            esac
            exit 0
            """)
        }

        func binaries(_ version: String) throws {
            for b in HostSetup.binaries { try write(from.appending(path: b), "#!/bin/sh\necho \(b) \(version)\n") }
        }

        func write(_ url: URL, _ text: String) throws {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }

        /// "ssh": the line goes to a shell in the scratch home, as ssh hands it to the login shell.
        var setup: HostSetup {
            HostSetup(remote: ["/usr/bin/env", "HOME=\(home.path(percentEncoded: false))",
                               "PATH=\(fakes.path(percentEncoded: false)):/usr/bin:/bin:/usr/sbin:/sbin", "/bin/sh", "-c"],
                      from: from, timeout: 30)
        }

        func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    }

    @Test func aFarMacIsSetUpAndUpdatedInPlace() async throws {
        let s = try Scratch()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.binaries("1")
        let steps = Steps()
        try await s.setup.install { steps.add($0) }
        #expect(steps.all == [.checking, .copying, .starting])
        for b in HostSetup.binaries {
            let path = s.server.appending(path: b).path(percentEncoded: false)
            #expect(FileManager.default.isExecutableFile(atPath: path), "\(b) is in place")
            #expect(s.text(s.server.appending(path: b)).contains("\(b) 1"))
        }
        let plist = s.text(s.plist)
        #expect(plist.contains("<string>\(s.server.path(percentEncoded: false))/axolottyd</string>"), "the server, by its full path")
        let lint = Process()
        lint.executableURL = URL(filePath: "/usr/bin/plutil")
        lint.arguments = ["-lint", "-s", s.plist.path(percentEncoded: false)]
        try lint.run()
        lint.waitUntilExit()
        #expect(lint.terminationStatus == 0, "a valid property list")
        let uid = getuid()
        // No login session (print gui/ fails): the user's background domain.
        #expect(s.text(s.calls).split(separator: "\n") == ["print gui/\(uid)", "bootout user/\(uid)/\(HostSetup.label)",
                                                         "bootstrap user/\(uid) \(s.plist.path(percentEncoded: false))"])

        // Again, with new binaries: replaced, nothing left over.
        try s.binaries("2")
        try await s.setup.install()
        #expect(s.text(s.server.appending(path: "axolottyd")).contains("axolottyd 2"))
        let left = try FileManager.default.contentsOfDirectory(atPath: s.server.path(percentEncoded: false)).sorted()
        #expect(left == HostSetup.binaries.sorted())
    }

    @Test func launchdTakingAMomentIsWaitedFor() async throws {
        let s = try Scratch(refusals: 2)
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.binaries("1")
        try await s.setup.install()
        #expect(s.text(s.calls).components(separatedBy: "bootstrap").count - 1 == 3, "two refusals, then started")
    }

    @Test func launchdRefusingIsSaid() async throws {
        let s = try Scratch(refusals: -1)
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.binaries("1")
        await #expect {
            try await s.setup.install()
        } throws: { e in
            guard case let .failed(text) = e as? HostSetup.Failure else { return false }
            return text.contains("launchd would not start the server")
        }
    }

    @Test func aHostThatWantsASignInSaysSo() async throws {
        let setup = HostSetup(remote: ["/bin/sh", "-c", "echo 'ada@mini: Permission denied (publickey).' >&2; exit 255", "--"],
                              from: URL(filePath: "/nonexistent"), timeout: 10)
        await #expect(throws: HostSetup.Failure.signIn("ada@mini: Permission denied (publickey).")) {
            try await setup.install()
        }
    }

    final class Steps: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [HostSetup.Step] = []
        func add(_ s: HostSetup.Step) { lock.withLock { steps.append(s) } }
        var all: [HostSetup.Step] { lock.withLock { steps } }
    }
}
