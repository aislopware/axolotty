import Foundation
import Testing

/// The pure doors stay pure: the logic the simulated link and the virtual-
/// time tests drive reads no clock and does no I/O, so what those tests hold
/// is what runs. Time comes in as a `Duration`; the shells around them
/// (`FramedConnection`, `HostConnection`) read the clock and pass it in.
/// Slopty holds the same with a lint; here a test reads the sources.
@Suite("Pure doors")
struct DoorTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let doors = [
        "Sources/AxProtocol/SendLanes.swift",
        "Sources/AxProtocol/Frame.swift",
        "Sources/AxClient/LinkLiveness.swift",
    ]

    /// What reads the wall clock, sleeps, or touches a descriptor.
    static let forbidden = [
        "ContinuousClock", "SuspendingClock", "Date()", "DispatchTime", ".now()", "asyncAfter",
        "Task.sleep", "Thread.sleep", "usleep(", "mach_absolute_time", "clock_gettime",
        "ProcessInfo", "FileHandle", "Darwin.", "read(", "write(", "send(", "recv(",
    ]

    /// Each forbidden word on a code line (comments are prose and may name them).
    static func reads(_ path: String) throws -> [String] {
        let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
        var found: [String] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            for word in forbidden where code.contains(word) { found.append("\(path):\(n + 1): \(word)") }
        }
        return found
    }

    @Test(arguments: doors)
    func readsNoClockAndDoesNoIO(_ path: String) throws {
        #expect(try Self.reads(path) == [])
    }

    /// The canary: the shell around the doors does read the clock, and the
    /// check must see it there.
    @Test func theCheckSeesAClockWhereOneIsRead() throws {
        #expect(try Self.reads("Sources/AxProtocol/FramedConnection.swift").contains { $0.hasSuffix("ContinuousClock") })
        #expect(try Self.reads("Sources/AxClient/HostConnection.swift").contains { $0.hasSuffix("ContinuousClock") })
    }
}
