import AxModel
import Testing

@Suite("Quick Select hints")
struct TerminalHintsTests {
    @Test func everythingCopyableIsFound() {
        let line = "commit 3f9a2c1d pushed to https://github.com/a/b from 10.0.0.12:8080 see Sources/App/main.swift:42"
        let hits = TerminalHints.find(in: line)
        #expect(hits.map(\.kind) == [.hash, .url, .address, .path])
        #expect(hits.map(\.text) == ["3f9a2c1d", "https://github.com/a/b", "10.0.0.12:8080", "Sources/App/main.swift:42"])
    }

    @Test func wordsAndNumbersAreNotHashes() {
        #expect(TerminalHints.find(in: "deadbeefcafe 1234567 999.1.1.1").isEmpty)
    }

    @Test func labelsAreUniqueAndPrefixFree() {
        for n in [1, 26, 27, 80, 300] {
            let l = TerminalHints.labels(n)
            #expect(l.count == n)
            #expect(Set(l).count == n)
            for a in l { for b in l where a != b { #expect(!b.hasPrefix(a)) } }
        }
    }
}
