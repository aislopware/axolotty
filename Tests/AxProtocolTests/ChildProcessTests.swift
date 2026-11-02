import AxProtocol
import Foundation
import Testing

@Suite("Child process", .timeLimit(.minutes(1)))
struct ChildProcessTests {
    /// Commands that end at once, many at a time: every one is reaped. The
    /// race `Process` loses (its exit source registered after the exit) left
    /// HostSetupTests waiting for ever in waitUntilExit, about once in 150.
    @Test func commandsThatEndAtOnceAreAllSeenToEnd() async throws {
        let statuses = await withTaskGroup(of: Int32.self) { g in
            for i in 0 ..< 400 {
                g.addTask { (try? ChildProcess.run("/bin/sh", ["-c", "exit \(i % 7)"]))?.status ?? -1 }
            }
            return await g.reduce(into: [Int32]()) { $0.append($1) }
        }
        #expect(statuses.count == 400)
        #expect(statuses.sorted() == (0 ..< 400).map { Int32($0 % 7) }.sorted())
    }

    @Test func bothStreamsAndTheInputFlowAtOnce() throws {
        // A megabyte on each stream: read in turn, either would stall the other.
        let r = try ChildProcess.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero; head -c 1000000 /dev/zero >&2; echo done >&2"])
        #expect(r.status == 0 && r.stdout.count == 1_000_000 && r.stderr.count == 1_000_005)
        // Two megabytes through cat, which writes back while it is still being fed.
        var input = Data(count: 2 << 20)
        for i in input.indices { input[i] = UInt8(truncatingIfNeeded: i &* 7) }
        let c = try ChildProcess.run("/bin/cat", [], input: input)
        #expect(c.stdout == input && c.status == 0)
        // A reader that leaves early is an error for the command, not a signal here.
        let early = try ChildProcess.run("/usr/bin/head", ["-c", "10"], input: input)
        #expect(early.stdout.count == 10 && early.status == 0)
    }

    @Test func aDeadlineStopsItAndSaysSo() throws {
        let start = ContinuousClock.now
        let r = try ChildProcess.run("/bin/sh", ["-c", "echo started; exec sleep 30"], timeout: 0.3)
        #expect(r.timedOut && r.status == 128 + SIGTERM)
        #expect(String(decoding: r.stdout, as: UTF8.self) == "started\n")
        #expect(ContinuousClock.now - start < .seconds(3))
        // One that ignores TERM gets KILL a second later.
        let stubborn = try ChildProcess.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.05; done"], timeout: 0.2)
        #expect(stubborn.timedOut && stubborn.status == 128 + SIGKILL)
        // In time: no signal, its own code.
        let quick = try ChildProcess.run("/bin/sh", ["-c", "exit 4"], timeout: 5)
        #expect(!quick.timedOut && quick.status == 4)
    }

    @Test func itsEndIsReadAsTheShellWould() throws {
        #expect(try ChildProcess.run("/bin/sh", ["-c", "kill -9 $$"]).status == 128 + 9)
        #expect(try ChildProcess.run("/usr/bin/env", [], environment: ["AXCP": "x"]).stdout == Data("AXCP=x\n".utf8))
        #expect(throws: POSIXError.self) { try ChildProcess.run("/nonexistent", []) }
    }
}
