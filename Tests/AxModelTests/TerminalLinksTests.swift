import AxModel
import Foundation
import Testing

@Suite struct TerminalLinksTests {
    private func targets(_ s: String) -> [TerminalLinks.Target] { TerminalLinks.find(in: s).map(\.target) }

    @Test func urlsLoseProsePunctuation() {
        #expect(targets("see https://example.com/a?b=1.") == [.url(URL(string: "https://example.com/a?b=1")!)])
        #expect(targets("(docs: https://en.wikipedia.org/wiki/Foo_(bar))")
            == [.url(URL(string: "https://en.wikipedia.org/wiki/Foo_(bar)")!)])
        #expect(targets("<https://a.dev>") == [.url(URL(string: "https://a.dev")!)])
    }

    @Test func compilerLocations() {
        #expect(targets("Sources/AxVT/VTLine.swift:42:7: error: boom")
            == [.path("Sources/AxVT/VTLine.swift", line: 42, column: 7)])
        #expect(targets("at main.swift:12") == [.path("main.swift", line: 12, column: nil)])
        #expect(targets("  --> src/lib.rs:3:5") == [.path("src/lib.rs", line: 3, column: 5)])
        #expect(targets("open ~/notes/todo.md now") == [.path("~/notes/todo.md", line: nil, column: nil)])
        #expect(targets("./build.sh") == [.path("./build.sh", line: nil, column: nil)])
        #expect(targets("(/tmp/x.log)") == [.path("/tmp/x.log", line: nil, column: nil)])
    }

    @Test func notLinks() {
        #expect(targets("version 1.2.3 and 4/5 done") == [])
        #expect(targets("main.swift without a line") == [])
        #expect(targets("ratio 16/9") == [])
    }

    @Test func offsetsAreCharacters() {
        let line = "✳ 日本 src/a.swift:1 ok"
        let l = TerminalLinks.link(in: line, at: 6)
        #expect(l?.range == 5 ..< 18)
        #expect(TerminalLinks.link(in: line, at: 2) == nil)
    }

    @Test func aURLIsNotAlsoAPath() {
        #expect(TerminalLinks.find(in: "https://github.com/a/b/blob/main/x.swift").count == 1)
    }
}
