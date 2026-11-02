import AxClient
import AxHost
import AxModel
import AxProtocol
import Foundation
import Synchronization
import Testing

/// The tailnet listener: who Tailscale says is calling decides who is served.
@Suite("Tailnet", .timeLimit(.minutes(1)))
struct TailnetTests {
    /// Connect to Host lists the person's own Macs, online first: not this
    /// Mac, not someone else's server, not a phone; direct or by which relay.
    @Test func theDirectoryListsThePersonsOwnMacs() {
        let status = Data("""
        {"BackendState":"Running","Self":{"ID":"s","HostName":"Studio","OS":"macOS","UserID":2},
         "Peer":{
          "k1":{"ID":"n1","HostName":"MacBook Pro","DNSName":"mbp.ts.example.","OS":"macOS","Online":false,"UserID":2,
                "Relay":"fra","CurAddr":"","TailscaleIPs":["100.64.0.2"]},
          "k2":{"ID":"n2","HostName":"Mini","DNSName":"mini.ts.example.","OS":"macOS","Online":true,"UserID":2,
                "Relay":"fra","CurAddr":"192.168.1.9:41641","TailscaleIPs":["100.64.0.9"]},
          "k3":{"ID":"n3","HostName":"Air","DNSName":"air.ts.example.","OS":"macOS","Online":true,"UserID":2,
                "Relay":"sin","CurAddr":"","TailscaleIPs":["100.64.0.10"]},
          "k4":{"ID":"n4","HostName":"build","DNSName":"build.ts.example.","OS":"linux","Online":true,"UserID":2},
          "k5":{"ID":"n5","HostName":"theirs","DNSName":"theirs.ts.example.","OS":"macOS","Online":true,"UserID":9},
          "k6":{"ID":"n6","HostName":"localhost","DNSName":"phone.ts.example.","OS":"iOS","Online":true,"UserID":2}}}
        """.utf8)
        let peers = TailnetDirectory.parse(status)
        #expect(peers.map(\.name) == ["Air", "Mini", "MacBook Pro"])
        #expect(peers.map(\.dialName) == ["air.ts.example", "mini.ts.example", "mbp.ts.example"])
        #expect(peers.map(\.relay) == ["sin", nil, "fra"])
        #expect(peers.map(\.online) == [true, true, false])
        #expect(TailnetDirectory.parse(Data(#"{"BackendState":"Stopped"}"#.utf8)) == [])

        // A host is found again however it was dialled, to say how its path goes.
        for dialled in ["air.ts.example", "AIR.ts.example.", "air", "100.64.0.10"] {
            #expect(TailnetDirectory.peer(dialledAs: dialled, in: peers)?.name == "Air", "\(dialled)")
        }
        #expect(TailnetDirectory.peer(dialledAs: "ai", in: peers) == nil)
        #expect(TailnetDirectory.relayPlace("sin") == "Singapore")
        #expect(TailnetDirectory.relayPlace("dc-old") == "dc-old", "a region of its own")
    }

    @Test func tellsTailnetAddressesApart() {
        #expect(Tailnet.isTailnet("100.64.0.3"))
        #expect(Tailnet.isTailnet("100.127.255.1"))
        #expect(!Tailnet.isTailnet("100.128.0.1"))
        #expect(!Tailnet.isTailnet("192.168.1.4"))
        #expect(Tailnet.isTailnet("fd7a:115c:a1e0::3"))
        #expect(!Tailnet.isTailnet("fe80::1"))
        #expect(Tailnet.host(of: "100.64.0.2:51234") == "100.64.0.2")
        #expect(Tailnet.host(of: "[fd7a:115c:a1e0::2]:51234") == "fd7a:115c:a1e0::2")
    }

    @Test func readsWhatTailscaleSays() {
        let whois = #"{"Node":{"ID":5},"UserProfile":{"ID":2,"LoginName":"cong@example.com","DisplayName":"Cong"},"CapMap":null}"#
        #expect(Tailnet.parseWhois(Data(whois.utf8)) == Tailnet.User(id: 2, login: "cong@example.com"))
        let status = #"{"BackendState":"Running","Self":{"UserID":2},"User":{"2":{"LoginName":"cong@example.com"}}}"#
        #expect(Tailnet.parseStatusSelf(Data(status.utf8)) == Tailnet.User(id: 2, login: "cong@example.com"))
        let stopped = #"{"BackendState":"Stopped","Self":{"UserID":2}}"#
        #expect(Tailnet.parseStatusSelf(Data(stopped.utf8)) == nil)
    }

    @Test func admitsOnlyTheSamePerson() {
        let me = Tailnet.User(id: 2, login: "me")
        let asked = Mutex(0)
        let gate = TailnetGate(whois: { peer in
            asked.withLock { $0 += 1 }
            return peer.hasPrefix("100.64.0.2") ? me : Tailnet.User(id: 9, login: "someone")
        }, me: { me })
        #expect(gate.admits("100.64.0.2:4000"))
        #expect(gate.admits("100.64.0.2:4001"))  // cached by address
        #expect(asked.withLock { $0 } == 1)
        #expect(!gate.admits("100.64.0.9:4000"))
        #expect(!gate.admits("192.168.1.2:4000"))  // never off the tailnet
        let closed = TailnetGate(whois: { _ in me }, me: { nil })
        #expect(!closed.admits("100.64.0.2:4000"))  // no Tailscale to ask: closed
    }

    /// Over this Mac's real tailnet address, when it has one: the same person
    /// is served, anyone else is told "denied" and not retried.
    @Test(.enabled(if: !Tailnet.localAddresses().isEmpty))
    func servesTheSamePersonOverTheTailnet() async throws {
        let address = try #require(Tailnet.localAddresses().first { !$0.contains(":") })
        let port = UInt16.random(in: 20000 ... 40000)
        let fx = try await HostFixture { c in
            c.tailnetPort = port
            c.tailnetGate = TailnetGate(whois: { _ in Tailnet.User(id: 1, login: "me") }, me: { Tailnet.User(id: 1, login: "me") })
        }
        let c = HostConnection(endpoint: .tcp(host: address, port: port), hello: ClientHello(client: ClientID(), name: "laptop"))
        // The listener comes up on the server's first pass over the interfaces.
        var connected = false
        for _ in 0 ..< 20 where !connected {
            connected = (try? await c.connect(reconnect: false)) != nil
            if !connected { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(connected)
        let (_, _, p) = try await makeSession(c)
        let m = c.attach(p)
        c.send(.text(p, "echo over-the-tailnet\n"))
        #expect(await waitScreen(m, contains: "over-the-tailnet"))
        c.disconnect()
        await fx.tearDown()

        let other = try await HostFixture { c in
            c.tailnetPort = port &+ 1
            c.tailnetGate = TailnetGate(whois: { _ in Tailnet.User(id: 9, login: "someone") }, me: { Tailnet.User(id: 1, login: "me") })
        }
        try await Task.sleep(for: .milliseconds(200))
        let d = HostConnection(endpoint: .tcp(host: address, port: port &+ 1), hello: ClientHello(client: ClientID(), name: "stranger"))
        await #expect(throws: ConnectionError.failed(.denied)) { try await d.connect(reconnect: true) }
        await other.tearDown()
    }
}
