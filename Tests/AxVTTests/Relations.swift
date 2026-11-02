import AxTestSupport
import AxVT
import Foundation
import Testing

let corpus = Fixture.all(in: .module, dir: "Fixtures/corpus", ext: "bin").map {
    Fixture(name: $0.name, bytes: Array($0.bytes.dropFirst()))  // byte 0 is the fuzzer's mode switch
}

func term(_ cols: UInt16 = 80, _ rows: UInt16 = 24, continuation: Int = 0) throws -> VTTerminal {
    try VTTerminal(cols: cols, rows: rows, scrollbackBytes: 1 << 20, replies: false, continuationBytes: continuation)
}

/// Everything a viewer could see: styled screen + scrollback, cursor, title, active screen.
struct Observed: Equatable {
    var screen: String
    var cursor: VTCursor
    var title: String
    var alternate: Bool

    init(_ t: VTTerminal) {
        screen = t.text(.vt, trim: false)
        cursor = t.cursor
        title = t.title
        alternate = t.activeScreen == .alternate
    }
}

@Suite("Terminal relations over Ghostty's fuzz corpus")
struct CorpusRelations {
    @Test("corpus is present") func corpusLoaded() { #expect(corpus.count >= 100) }

    @Test("feeding in small chunks equals one feed", arguments: corpus)
    func chunking(fx: Fixture) throws {
        let whole = try term()
        whole.write(fx.bytes)
        for size in [1, 3, 7] {
            let split = try term()
            var i = 0
            while i < fx.bytes.count {
                split.write(fx.bytes[i ..< min(i + size, fx.bytes.count)])
                i += size
            }
            #expect(Observed(split) == Observed(whole), "chunk size \(size)")
        }
    }

    @Test("a snapshot restores to the same terminal", arguments: corpus)
    func snapshotRoundTrip(fx: Fixture) throws {
        let t = try term(continuation: 4096)
        t.write(fx.bytes)
        let restored = try VTTerminal.restore(try t.snapshot())
        #expect(Observed(restored) == Observed(t))
    }

    /// The property late-joining clients rely on: snapshot at ANY byte offset (even
    /// inside an escape sequence or UTF-8 scalar), restore, keep streaming → identical.
    @Test("snapshot mid-stream then continue equals uninterrupted", arguments: corpus.prefix(40))
    func snapshotThenContinue(fx: Fixture) throws {
        guard fx.bytes.count > 2 else { return }
        let reference = try term(continuation: 4096)
        reference.write(fx.bytes)
        var rng = SeededRNG(seed: UInt64(fx.bytes.count))
        for _ in 0 ..< 4 {
            let cut = Int.random(in: 1 ..< fx.bytes.count, using: &rng)
            let host = try term(continuation: 4096)
            host.write(fx.bytes[..<cut])
            let mirror = try VTTerminal.restore(try host.snapshot())
            mirror.write(fx.bytes[cut...])
            #expect(Observed(mirror) == Observed(reference), "cut at \(cut)")
        }
    }
}

@Suite struct Events {
    @Test func programStatusOSC7501() throws {
        let t = try term()
        let msg = Data("Running tests".utf8).base64EncodedString()
        let ev = t.write("\u{1b}]7501;state=working:app=claude:msg=\(msg)\u{1b}\\")
        guard case let .programStatus(s)? = ev.first else {
            Issue.record("no program status in \(ev)")
            return
        }
        #expect(s.state == .working)
        #expect(s.app == "claude")
        #expect(s.message == "Running tests")
    }

    @Test func progressComesThroughOnlyWhileWorkingOrBlocked() throws {
        let t = try term()
        func status(_ seq: String) -> VTProgramStatus? {
            t.write(seq).lazy.compactMap { if case let .programStatus(s) = $0 { s } else { nil } }.first
        }
        #expect(status("\u{1b}]7501;state=working:progress=40\u{07}")?.progress == 40)
        #expect(status("\u{1b}]7501;state=working\u{07}")?.progress == nil)  // indeterminate
        #expect(status("\u{1b}]7501;state=done:progress=100\u{07}")?.progress == nil)
    }

    @Test func blockedThenClear() throws {
        let t = try term()
        let a = t.write("\u{1b}]7501;state=blocked:kind=permission\u{07}")
        let b = t.write("\u{1b}]7501;state=clear\u{07}")
        #expect(a.contains { if case let .programStatus(s) = $0 { s.state == .blocked } else { false } })
        #expect(b.contains { if case let .programStatus(s) = $0 { s.state == .clear } else { false } })
    }

    @Test func shellIntegrationMarks() throws {
        let t = try term()
        let cmd = "ls"
        let ev = t.write("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}\(cmd)\r\n\u{1b}]133;C;cmdline=\(cmd)\u{07}out\r\n\u{1b}]133;D;0\u{07}")
        let prompts = ev.compactMap { if case let .prompt(p) = $0 { p } else { nil } }
        #expect(prompts.first == .promptStart)
        #expect(prompts.contains(.inputStart))
        #expect(prompts.contains(.commandEnd(exitCode: 0)))
    }

    @Test func titlePwdBellNotification() throws {
        let t = try term()
        let ev = t.write("\u{1b}]2;hello\u{07}\u{1b}]7;file://host/tmp/x\u{07}\u{07}\u{1b}]777;notify;Build;done\u{07}")
        #expect(ev.contains(.titleChanged("hello")))
        #expect(ev.contains(.bell))
        #expect(ev.contains(.notification(title: "Build", body: "done")))
        #expect(ev.contains { if case let .pwdChanged(p) = $0 { p.hasSuffix("/tmp/x") } else { false } })
    }

    @Test func progressReport() throws {
        let t = try term()
        #expect(t.write("\u{1b}]9;4;1;42\u{07}") == [.progress(.set(42))])
        #expect(t.write("\u{1b}]9;4;0\u{07}") == [.progress(.remove)])
    }
}

@Suite struct Replies {
    final class Box: @unchecked Sendable { var bytes: [UInt8] = [] }

    @Test("the authoritative terminal answers device attributes; a mirror stays silent")
    func onlyAuthorityReplies() throws {
        let box = Box()
        let host = try VTTerminal(cols: 80, rows: 24, replies: true)
        host.onReply = { box.bytes += $0 }
        host.write("\u{1b}[c")
        #expect(String(decoding: box.bytes, as: UTF8.self).hasPrefix("\u{1b}[?"))

        let mirror = try term()
        var heard = false
        mirror.onReply = { _ in heard = true }
        mirror.write("\u{1b}[c\u{1b}[6n")
        #expect(!heard)
    }

    private func answer(_ query: String, setup: (VTTerminal) -> Void = { _ in }) throws -> String {
        let box = Box()
        let t = try VTTerminal(cols: 80, rows: 24, replies: true)
        setup(t)
        t.onReply = { box.bytes += $0 }
        t.write(query)
        return String(decoding: box.bytes, as: UTF8.self)
    }

    @Test("device attributes say VT220-level with colour and clipboard, like Ghostty")
    func deviceAttributes() throws {
        #expect(try answer("\u{1b}[c") == "\u{1b}[?62;22;52c")
        #expect(try answer("\u{1b}[>c") == "\u{1b}[>1;10;0c")
    }

    @Test("XTVERSION names Axolotty and its version")
    func xtversion() throws {
        #expect(try answer("\u{1b}[>q") { $0.setVersion("0.1.0") } == "\u{1b}P>|Axolotty 0.1.0\u{1b}\\")
    }

    @Test("size reports use the size driver's cells")
    func sizeReports() throws {
        #expect(try answer("\u{1b}[18t") == "\u{1b}[8;24;80t")
        #expect(try answer("\u{1b}[16t") { $0.setCellSize(width: 16, height: 34) } == "\u{1b}[6;34;16t")
    }

    @Test("the colour scheme answers, and a program that asked hears it change")
    func colourScheme() throws {
        #expect(try answer("\u{1b}[?996n") == "\u{1b}[?997;1n")
        #expect(try answer("\u{1b}[?996n") { _ = $0.setColorScheme(dark: false) } == "\u{1b}[?997;2n")
        let t = try VTTerminal(cols: 80, rows: 24, replies: true)
        #expect(t.setColorScheme(dark: false) == nil)  // nobody asked
        t.write("\u{1b}[?2031h")
        #expect(t.setColorScheme(dark: true).map { String(decoding: $0, as: UTF8.self) } == "\u{1b}[?997;1n")
        #expect(t.setColorScheme(dark: true) == nil)  // no change, no report
    }
}
