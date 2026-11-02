import AxHost
import AxModel
import Foundation
import Testing

/// End-to-end tests against a real `axolotty-ptyd` process: these are the
/// guarantees that make "update the app without losing running programs" true.
@Suite("PTY holder", .timeLimit(.minutes(1)))
struct HolderTests {
    @Test func spawnHandsOverAWorkingMasterAndRing() async throws {
        let fx = try HolderFixture()
        let client = try await fx.connect()
        defer { fx.tearDown(client) }
        #expect(client.version == 1)

        let id = PaneID()
        let h = try await client.spawn(id: id, shell("printf 'ready\\n'; read x; printf 'echo:%s\\n' \"$x\"; sleep 30"))
        defer { close(h.master) }
        #expect(h.pid > 0)
        #expect(readUntil(h.master, contains: "ready").contains("ready"))
        writeAll(h.master, "ping\n")
        #expect(readUntil(h.master, contains: "echo:ping").contains("echo:ping"))
        let ring = try JournalRing(fd: h.ring)
        #expect(ring.head == 0, "the holder never writes while the server holds the reader role")
    }

    @Test func reportsExitStatusesAndSignals() async throws {
        let fx = try HolderFixture()
        let client = try await fx.connect()
        defer { fx.tearDown(client) }

        let a = PaneID()
        let ha = try await client.spawn(id: a, shell("exit 3"))
        close(ha.master)
        close(ha.ring)
        #expect(await fx.nextExit(a)?.exitCode == 3)

        let b = PaneID()
        let hb = try await client.spawn(id: b, shell("sleep 30"))
        defer { close(hb.master); close(hb.ring) }
        try await client.signal(id: b, SIGTERM)
        #expect(await fx.nextExit(b)?.exitCode == 128 + SIGTERM)

        let listed = try await client.list()
        #expect(Set(listed.map(\.id)) == [a, b])
        #expect(listed.allSatisfy { $0.status != .running })
        await #expect(throws: CustodyError.errno(ESRCH)) { try await client.signal(id: b, SIGTERM) }
    }

    @Test func rejectsDuplicateIdsAndBadExecutables() async throws {
        let fx = try HolderFixture()
        let client = try await fx.connect()
        defer { fx.tearDown(client) }
        let id = PaneID()
        let h = try await client.spawn(id: id, shell("sleep 30"))
        defer { close(h.master); close(h.ring) }
        await #expect(throws: CustodyError.errno(EEXIST)) { _ = try await client.spawn(id: id, shell("true")) }
        var bad = shell("")
        bad.path = "/nonexistent/axolotty"
        await #expect(throws: CustodyError.errno(ENOENT)) { _ = try await client.spawn(id: PaneID(), bad) }
        await #expect(throws: CustodyError.errno(ENOENT)) { _ = try await client.attach(id: PaneID()) }
    }

    /// The core survival property: the server goes away, the program keeps
    /// running and its output is journaled; a new server attaches and finds it.
    @Test func outputSurvivesServerDisconnectAndReattach() async throws {
        let fx = try HolderFixture()
        let first = try await fx.connect()
        let id = PaneID()
        let h = try await first.spawn(id: id, shell("read x; printf 'got:%s\\n' \"$x\"; sleep 30"))
        let journal = try JournalRing(fd: h.ring)

        first.disconnect()  // the "server crashed"
        writeAll(h.master, "abc\n")
        close(h.master)  // the dead server's descriptor is gone too

        let drained = eventually { () -> String? in
            let s = String(decoding: journal.read(from: journal.tail) ?? Data(), as: UTF8.self)
            return s.contains("got:abc") ? s : nil
        }
        #expect(drained?.contains("got:abc") == true, "the holder drains into the ring while detached")

        let second = try await fx.connect()
        defer { fx.tearDown(second) }
        let listed = try await second.list()
        #expect(listed.map(\.id) == [id])
        #expect(listed.first?.attached == false)
        #expect(listed.first?.status == .running)

        let h2 = try await second.attach(id: id)
        defer { close(h2.master) }
        #expect(h2.pid == h.pid)
        let ring2 = try JournalRing(fd: h2.ring)
        #expect(ring2.head == journal.head, "same shared journal")
        #expect(try await second.list().first?.attached == true)

        try await second.close(id: id)  // hang-up; the session is forgotten (no EXITED)
        #expect(eventually { kill(h.pid, 0) != 0 ? true : nil } == true, "SIGHUP ended the program")
        #expect(try await second.list().isEmpty)
    }

    @Test func releaseResumesDraining() async throws {
        let fx = try HolderFixture()
        let client = try await fx.connect()
        defer { fx.tearDown(client) }
        let id = PaneID()
        let h = try await client.spawn(id: id, shell("read x; printf 'late:%s\\n' \"$x\"; sleep 30"))
        defer { close(h.master) }
        let ring = try JournalRing(fd: h.ring)
        try client.release(id: id)
        writeAll(h.master, "zz\n")
        let s = eventually { () -> String? in
            let s = String(decoding: ring.read(from: 0) ?? Data(), as: UTF8.self)
            return s.contains("late:zz") ? s : nil
        }
        #expect(s != nil)
    }

    /// A holder that crashed hands nothing back; the server still has the
    /// descriptors and gives a fresh holder custody of the live program.
    @Test func freshHolderAdoptsLiveSessions() async throws {
        let fx = try HolderFixture()
        let first = try await fx.connect()
        let id = PaneID()
        let h = try await first.spawn(id: id, shell("read x; printf 'still:%s\\n' \"$x\"; sleep 30"))
        defer { close(h.master); close(h.ring) }
        kill(first.holderPid, SIGKILL)
        _ = eventually { kill(first.holderPid, 0) != 0 ? true : nil }

        let second = try await fx.connect()
        defer { fx.tearDown(second) }
        #expect(second.holderPid != first.holderPid)
        try await second.adopt(id: id, pid: h.pid, master: h.master, ring: h.ring)
        #expect(try await second.list().map(\.id) == [id])
        writeAll(h.master, "alive\n")
        #expect(readUntil(h.master, contains: "still:alive").contains("still:alive"))
        await #expect(throws: CustodyError.errno(EEXIST)) {
            try await second.adopt(id: id, pid: h.pid, master: h.master, ring: h.ring)
        }
    }

    @Test func concurrentLaunchesLeaveOneHolder() async throws {
        let fx = try HolderFixture()
        let pids = try (0 ..< 4).map { _ in try Holder.launch(PtydBinary.url, paths: fx.paths, watchPID: getpid()) }
        // Attach, not connect: connect would launch a fifth when none has bound yet.
        let client = try await fx.attach()
        defer { fx.tearDown(client) }
        #expect(pids.contains(client.holderPid))
        let survivors = eventually { () -> [pid_t]? in
            let alive = pids.filter { kill($0, 0) == 0 && $0 != client.holderPid }
            return alive.isEmpty ? alive : nil
        }
        #expect(survivors == [], "losers exit when the lock is taken")
    }

    @Test func installIsContentAddressedAndIdempotent() throws {
        let fx = try HolderFixture()
        defer { fx.tearDown(nil) }
        let a = try Holder.install(PtydBinary.url, paths: fx.paths)
        let b = try Holder.install(PtydBinary.url, paths: fx.paths)
        #expect(a == b)
        #expect(FileManager.default.isExecutableFile(atPath: a.path))
        #expect(a.lastPathComponent.hasPrefix("axolotty-ptyd-"))
    }
}
