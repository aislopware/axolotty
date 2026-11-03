import AxClient
import Foundation
import Testing

@Suite struct LoopbackTests {
    @Test func aLinkToTheFarMacsOwnLoopbackNamesItsPort() throws {
        let cases: [(String, UInt16?)] = [
            ("http://localhost:5173/", 5173),
            ("http://127.0.0.1:8000/docs", 8000),
            ("http://127.1.2.3:9", 9),
            ("http://0.0.0.0:3000", 3000),
            ("http://[::1]:4000/", 4000),
            ("http://app.localhost:5173", 5173),
            ("ws://localhost:24678", 24678),
            ("http://localhost/", 80),
            ("https://LOCALHOST", 443),
            ("https://example.com:5173", nil),
            ("http://128.0.0.1:80", nil),
            ("http://127.0.0.1.example.com", nil),
            ("file:///tmp/a", nil),
        ]
        for (text, want) in cases {
            #expect(Loopback.port(of: try #require(URL(string: text))) == want, "\(text)")
        }
    }

    @Test func aSignInsCallbackIsForwardedWithThePage() throws {
        let url = try #require(URL(string:
            "https://github.com/login/oauth/authorize?client_id=x&redirect_uri=http%3A%2F%2F127.0.0.1%3A8085%2Fcb&state=y"))
        #expect(Loopback.ports(in: url) == [8085])
        let page = try #require(URL(string: "http://localhost:3000/login?next=http://localhost:3000/&cb=http://localhost:9000"))
        #expect(Loopback.ports(in: page) == [3000, 9000], "each once, the page's own first")
    }

    @Test func aMovedLinkKeepsEverythingButItsPort() throws {
        let url = try #require(URL(string: "http://localhost:5173/src/App.tsx?t=1#top"))
        #expect(Loopback.moved(url, to: 61234).absoluteString == "http://localhost:61234/src/App.tsx?t=1#top")
        let any = try #require(URL(string: "http://0.0.0.0:8000/"))
        #expect(Loopback.moved(any, to: 8000).absoluteString == "http://localhost:8000/", "any-address means here")
    }
}
