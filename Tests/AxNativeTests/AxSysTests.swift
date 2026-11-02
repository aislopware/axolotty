#if os(macOS)
import AxSys
import Darwin
import Testing

/// Real-kernel contract tests for the PTY layer. Each spawns `/bin/sh`, so they are
/// small and few; everything above this layer is tested against a fake PTY.
@Suite struct PTYSpawn {
    func spawn(_ script: String, cols: UInt16 = 80, rows: UInt16 = 24, cwd: String? = nil) throws -> ax_pty_child {
        let args = ["/bin/sh", "-c", script]
        let env = ["PATH=/usr/bin:/bin", "HOME=/tmp", "TERM=xterm-256color", "LC_ALL=C"]
        var child = ax_pty_child()
        let rc = withCStrings(args) { argv in
            withCStrings(env) { envp in
                ax_pty_spawn("/bin/sh", argv, envp, cwd, ax_winsize(cols: cols, rows: rows, width_px: 0, height_px: 0), &child)
            }
        }
        try #require(rc == 0, "spawn failed: \(rc)")
        return child
    }

    /// Reads until EOF/EIO (child closed the slave) and reaps the child.
    func drain(_ child: ax_pty_child) -> (String, Int32) {
        var out = [UInt8]()
        var buf = [UInt8](repeating: 0, count: 4096)
        var pfd = pollfd(fd: child.master_fd, events: Int16(POLLIN), revents: 0)
        while poll(&pfd, 1, 5_000) > 0 {
            let n = read(child.master_fd, &buf, buf.count)
            if n > 0 { out += buf[0 ..< n] } else if n < 0, errno == EAGAIN { continue } else { break }
        }
        close(child.master_fd)
        var status: Int32 = 0
        for _ in 0 ..< 500 where ax_reap(child.pid, &status) == 0 { usleep(2_000) }
        return (String(decoding: out, as: UTF8.self), status)
    }

    @Test func runsAsSessionLeaderWithControllingTTY() throws {
        let child = try spawn("test -t 0 && test -t 1 && ps -o pid=,sess=,tpgid= -p $$ | tr -s ' '; tty")
        let (out, status) = drain(child)
        #expect(status == 0)
        #expect(out.contains("/dev/ttys"))
        // On macOS `ps` prints sess as an address, so check the tpgid: the shell owns the foreground.
        let fields = out.split(whereSeparator: \.isWhitespace)
        #expect(fields.count >= 3 && fields[0] == fields[2], "tpgid should equal the shell's pid: \(out)")
    }

    @Test func appliesWindowSizeAndResize() throws {
        let child = try spawn("sleep 0.2; stty size", cols: 100, rows: 30)
        #expect(ax_pty_resize(child.master_fd, ax_winsize(cols: 132, rows: 43, width_px: 0, height_px: 0)) == 0)
        let (out, _) = drain(child)
        #expect(out.contains("43 132"))
    }

    @Test func honoursCwdAndFallsBackToHome() throws {
        let (a, _) = drain(try spawn("pwd", cwd: "/usr"))
        #expect(a.contains("/usr"))
        let (b, _) = drain(try spawn("pwd", cwd: "/definitely/missing"))
        #expect(b.contains("/tmp") || b.contains("/private/tmp"))
    }

    @Test func doesNotLeakParentDescriptors() throws {
        // A descriptor without FD_CLOEXEC at a number the child would never reuse.
        let planted: Int32 = 211
        #expect(dup2(STDERR_FILENO, planted) == planted)
        defer { close(planted) }
        let (out, _) = drain(try spawn("ls /dev/fd | tr '\\n' ' '"))
        let listed = Set(out.split(separator: " ").compactMap { Int32($0.filter(\.isNumber)) })
        #expect(!listed.contains(planted), "leaked: \(out)")
    }

    @Test func reportsExecFailureAsErrno() {
        var child = ax_pty_child()
        let rc = withCStrings(["/nonexistent/bin"]) { argv in
            withCStrings([]) { envp in
                ax_pty_spawn("/nonexistent/bin", argv, envp, nil, ax_winsize(cols: 80, rows: 24, width_px: 0, height_px: 0), &child)
            }
        }
        #expect(rc == ENOENT)
    }

    @Test func foregroundProcessIsVisibleThroughLibproc() throws {
        let child = try spawn("exec sleep 2")
        defer { kill(child.pid, SIGKILL); _ = drain(child) }
        var name = [CChar](repeating: 0, count: 64)
        var found = ""
        for _ in 0 ..< 200 {
            let pgid = ax_pty_foreground_pgid(child.master_fd)
            if pgid > 0, ax_proc_name(pgid, &name, name.count) > 0 {
                found = String(decoding: name.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
                if found == "sleep" { break }
            }
            usleep(5_000)
        }
        #expect(found == "sleep")
        var cmd = [CChar](repeating: 0, count: 256)
        #expect(ax_proc_cmdline(child.pid, &cmd, cmd.count) > 0)
        let cmdline = String(decoding: cmd.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        #expect(cmdline == "sleep 2")
    }
}

func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { ptrs.forEach { free($0) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}
#endif
