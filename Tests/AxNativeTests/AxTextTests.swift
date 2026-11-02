import AxText
import Testing

@Suite struct StripANSI {
    func strip(_ chunks: [String]) -> String {
        var state = ax_strip_state()
        var out = [UInt8]()
        for chunk in chunks {
            let bytes = Array(chunk.utf8)
            var buf = [UInt8](repeating: 0, count: bytes.count)
            let n = ax_strip_ansi(&state, bytes, bytes.count, &buf, buf.count)
            out += buf[0 ..< n]
        }
        return String(decoding: out, as: UTF8.self)
    }

    @Test("keeps visible text and newlines, drops CSI/OSC/controls", arguments: [
        ("plain\n", "plain\n"),
        ("\u{1b}[1;32mgreen\u{1b}[0m", "green"),
        ("a\u{1b}]0;title\u{07}b", "ab"),
        ("a\u{1b}]8;;https://x\u{1b}\\link\u{1b}]8;;\u{1b}\\b", "alinkb"),
        ("\u{1b}(Bx\u{1b}=y", "xy"),
        ("tab\there\r\n", "tab\there\n"),
        ("é ✻ 漢字", "é ✻ 漢字"),
        ("\u{1b}P1$r0m\u{1b}\\z", "z"),
    ])
    func strips(input: String, expected: String) {
        #expect(strip([input]) == expected)
    }

    @Test("an escape split across chunks gives the same text as one chunk")
    func splitInvariant() {
        let s = "x\u{1b}[38;2;1;2;3my\u{1b}]133;A\u{07}z\u{1b}[?2004hw"
        let whole = strip([s])
        let bytes = Array(s.utf8)
        for cut in 1 ..< bytes.count {
            let a = String(decoding: bytes[..<cut], as: UTF8.self)
            let b = String(decoding: bytes[cut...], as: UTF8.self)
            // Splitting inside a UTF-8 scalar would make lossy Strings; this input is ASCII.
            #expect(strip([a, b]) == whole, "cut at \(cut)")
        }
    }

    @Test func findsNeedles() {
        let hay = Array("esc to interrupt".utf8)
        #expect(ax_find(hay, hay.count, Array("to".utf8), 2) == 4)
        #expect(ax_find(hay, hay.count, Array("nope".utf8), 4) == -1)
        #expect(ax_find(hay, hay.count, nil, 0) == 0)
    }
}
