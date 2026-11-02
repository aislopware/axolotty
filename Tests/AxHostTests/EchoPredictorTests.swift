import AxClient
import AxTestSupport
import Foundation
import Testing

/// Local echo for a far host (`EchoPredictor`), in virtual time: first its
/// rules one by one, then against a simulated shell across a delayed link.
/// A failure prints its seed; `AXSEED=<n>` replays one.
@Suite("Echo prediction")
struct EchoPredictorTests {
    /// A shell's screen: a prompt, then what was typed. `cell` answers like the mirror.
    struct Grid {
        var cells: [[Character]]
        var x = 2, y = 0
        var atPrompt = true
        var primary = true
        var secret = false
        var cursorVisible = true

        init(cols: Int = 40, rows: Int = 8) {
            cells = Array(repeating: Array(repeating: " ", count: cols), count: rows)
            cells[0][0] = "$"
        }

        var cols: Int { cells[0].count }

        func screen() -> EchoPredictor.Screen {
            let c = cells
            return EchoPredictor.Screen(cursorX: x, cursorY: y, cols: cols, cursorVisible: cursorVisible, primary: primary,
                                        atPrompt: atPrompt, mouseTracking: false, secret: secret) { x, y in
                y >= 0 && y < c.count && x >= 0 && x < c[y].count ? c[y][x] : nil
            }
        }

        mutating func put(_ ch: Character) {
            cells[y][x] = ch
            x = min(x + 1, cols - 1)
        }
    }

    static func ms(_ n: Int) -> Duration { .milliseconds(n) }

    // MARK: The rules

    @Test func aTypedKeyShowsAtOnceAndItsEchoConfirmsIt() {
        var p = EchoPredictor(rtt: Self.ms(40))
        var g = Grid()
        let r1 = p.typed("ls", on: g.screen(), at: .zero)
        #expect(r1)
        #expect(p.overlay(at: .zero).cells.map(\.character) == ["l", "s"])
        #expect(p.overlay(at: .zero).cursor?.x == 4)
        #expect(p.overlay(at: .zero).marked == false, "40 ms is near enough to draw guesses plainly")
        g.put("l")
        p.observed(g.screen(), at: Self.ms(40))
        #expect(p.guesses.map(\.character) == ["s"], "the echo of l landed; s is still on its way")
        g.put("s")
        p.observed(g.screen(), at: Self.ms(41))
        #expect(p.guesses.isEmpty)
        #expect(p.misses == 0)
    }

    @Test func aNearLinkOrALocalOneNeverGuesses() {
        var near = EchoPredictor(rtt: Self.ms(4))
        let r2 = near.typed("a", on: Grid().screen(), at: .zero)
        #expect(!r2)
        var local = EchoPredictor()
        let r3 = local.typed("a", on: Grid().screen(), at: .zero)
        #expect(!r3)
    }

    @Test func onlyAShellsInputLineIsGuessedAt() {
        var g = Grid()
        for change in [{ (g: inout Grid) in g.atPrompt = false }, { $0.primary = false }, { $0.secret = true },
                       { $0.cursorVisible = false }] {
            var p = EchoPredictor(rtt: Self.ms(50))
            g = Grid()
            change(&g)
            let r4 = p.typed("a", on: g.screen(), at: .zero)
            #expect(!r4)
        }
        // Over other text (the middle of a line, a suggestion that went another way) it would collide.
        g = Grid()
        g.cells[0][2] = "x"
        var p = EchoPredictor(rtt: Self.ms(50))
        let r5 = p.typed("a", on: g.screen(), at: .zero)
        #expect(!r5)
    }

    @Test func anEchoThatDiffersTakesEveryGuessBackAndMutes() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        p.typed("ab", on: g.screen(), at: .zero)
        g.put("A")  // the host had other ideas (a vi mode, a key binding)
        let missed = p.observed(g.screen(), at: Self.ms(50))
        #expect(missed)
        #expect(p.guesses.isEmpty)
        #expect(p.misses == 1)
        let muted = p.typed("c", on: g.screen(), at: Self.ms(60))
        #expect(!muted, "muted after a miss")
        g.put("b")
        g.put("c")
        p.observed(g.screen(), at: Self.ms(110))  // a round trip after the unguessed c: the host has answered it
        let back = p.typed("d", on: g.screen(), at: .seconds(2))
        #expect(back)
        #expect(p.overlay(at: .seconds(2)).marked, "guesses right after a miss are marked as guesses")
    }

    @Test func anEchoThatNeverComesIsAMiss() {
        var p = EchoPredictor(rtt: Self.ms(50))
        p.typed("a", on: Grid().screen(), at: .zero)
        #expect(p.nextDeadline == p.patience)
        let r10 = p.tick(at: p.patience - Self.ms(1))
        #expect(!r10)
        #expect(p.overlay(at: Self.ms(300)).marked, "a guess waiting past 250 ms is marked")
        let r11 = p.tick(at: p.patience)
        #expect(r11)
        #expect(p.guesses.isEmpty && p.misses == 1)
    }

    @Test func afterReturnNothingIsGuessedUntilTheHostAnswers() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        p.typed("a", on: g.screen(), at: .zero)
        let dropped = p.interrupted(at: Self.ms(5))
        #expect(dropped, "Return drops the guesses")
        let early = p.typed("b", on: g.screen(), at: Self.ms(10))
        #expect(!early, "typed ahead of the next prompt: the host says where it goes")
        g.put("a")
        p.observed(g.screen(), at: Self.ms(50))  // the echo of a, sent before Return was seen
        let stillHeld = p.typed("", on: g.screen(), at: Self.ms(51))
        #expect(!stillHeld && p.guesses.isEmpty)
        g.y = 1
        g.x = 2
        g.put("b")
        p.observed(g.screen(), at: Self.ms(61))  // the new prompt, with b on it
        let next = p.typed("c", on: g.screen(), at: Self.ms(62))
        #expect(next)
        #expect(p.guesses.first.map { [$0.x, $0.y] } == [3, 1])
    }

    /// zsh-autosuggestions draws the rest of a remembered command faintly
    /// after the cursor. Typing along it is guessed over it, and the faint
    /// text never counts as an echo: only the host's cursor moving on does.
    @Test func aSuggestionIsTypedAlongButNeverTakenForTheEcho() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        let first = p.typed("e", on: g.screen(), at: .zero)
        #expect(first)
        g.put("e")
        for (i, ch) in "cho hi".enumerated() { g.cells[0][3 + i] = ch }  // the suggestion
        p.observed(g.screen(), at: Self.ms(50))
        #expect(p.guesses.isEmpty, "e echoed and the cursor moved on")
        let along = p.typed("ch", on: g.screen(), at: Self.ms(60))
        #expect(along, "c and h sit where the suggestion already shows them")
        p.observed(g.screen(), at: Self.ms(70))  // the suggestion again, no echo yet
        #expect(p.guesses.map(\.character) == ["c", "h"], "the suggestion's c is not c's echo")
        g.x = 5
        p.observed(g.screen(), at: Self.ms(110))
        #expect(p.guesses.isEmpty && p.misses == 0)
        let off = p.typed("x", on: g.screen(), at: Self.ms(120))
        #expect(!off, "the suggestion says o here: x would collide with it")
    }

    @Test func aKeyLeftUnguessedHoldsLaterGuessesNotEarlierOnes() {
        var g = Grid(cols: 6)
        g.x = 4
        var p = EchoPredictor(rtt: Self.ms(50))
        let some = p.typed("abc", on: g.screen(), at: .zero)
        #expect(some)
        #expect(p.guesses.map(\.character) == ["a"], "b would land in the last column: the host draws that wrap")
        g.x = 2
        let held = p.typed("d", on: Grid().screen(), at: Self.ms(1))
        #expect(!held, "b and c went out unguessed")
    }

    @Test func farLinksMarkTheirGuesses() {
        var p = EchoPredictor(rtt: Self.ms(120))
        p.typed("a", on: Grid().screen(), at: .zero)
        #expect(p.overlay(at: .zero).marked)
    }

    @Test func wideOrCombiningCharactersAreLeftToTheHost() {
        var p = EchoPredictor(rtt: Self.ms(50))
        let r16 = p.typed("é", on: Grid().screen(), at: .zero)
        #expect(r16)
        var q = EchoPredictor(rtt: Self.ms(50))
        let r17 = q.typed("漢", on: Grid().screen(), at: .zero)
        #expect(!r17)
        let r18 = q.typed("x", on: Grid().screen(), at: Self.ms(1))
        #expect(!r18, "held until the host has drawn it")
    }

    // MARK: Against a simulated shell

    static var seeds: [UInt64] {
        if let s = ProcessInfo.processInfo.environment["AXSEED"].flatMap(UInt64.init) { return [s] }
        return Array(1 ... UInt64(ProcessInfo.processInfo.environment["AXMODEL_RUNS"].flatMap(Int.init) ?? 300))
    }

    struct Run {
        var predicted = 0, confirmed = 0, misses = 0
        /// Keys whose character was on screen before its echo came back.
        var early = 0, typed = 0
        var broken: String?
    }

    /// Two seconds of typing into a shell `oneWay` ms away. `faithful`: the
    /// shell echoes every key as typed; otherwise it sometimes echoes another
    /// character, swallows one, or draws its next prompt late.
    static func simulate(seed: UInt64, oneWay: Int, faithful: Bool) -> Run {
        var rng = SimRNG(seed: seed)
        var host = Grid()
        var mirror = host
        var p = EchoPredictor(rtt: ms(oneWay * 2))
        var toHost: [(at: Int, key: Character)] = []
        var toClient: [(at: Int, grid: Grid)] = []
        var pendingPrompt: Int?
        var run = Run()
        let letters = Array("abcdefghijklmnopqrstuvwxyz -./")

        for now in 0 ..< 2000 {
            let t = ms(now)
            // The person types about every 60 ms; Return and ⌫ now and then.
            if rng.unit() < 1.0 / 60 {
                let r = rng.unit()
                let key: Character = r < 0.08 ? "\r" : r < 0.14 ? "\u{7f}" : letters[Int(rng.next() % UInt64(letters.count))]
                if ProcessInfo.processInfo.environment["AXECHO_TRACE"] != nil { print("key \(key.debugDescription) at \(now)") }
                if key == "\r" || key == "\u{7f}" {
                    p.interrupted(at: t)
                } else {
                    run.typed += 1
                    if p.typed(String(key), on: mirror.screen(), at: t) { run.predicted += 1 }
                    if p.overlay(at: t).cells.contains(where: { $0.character == key }) { run.early += 1 }
                }
                toHost.append((now + oneWay, key))
            }
            // The shell.
            while let k = toHost.first, k.at <= now {
                toHost.removeFirst()
                switch k.key {
                case "\r":
                    host.atPrompt = false
                    host.y = min(host.y + 1, host.cells.count - 1)
                    host.x = 0
                    pendingPrompt = now + (faithful ? 3 : 3 + Int(rng.next() % 40))
                case "\u{7f}":
                    if host.x > 2, host.atPrompt { host.x -= 1; host.cells[host.y][host.x] = " " }
                default:
                    guard host.atPrompt, host.x < host.cols - 1 else { break }
                    if faithful || rng.unit() < 0.8 {
                        host.put(k.key)
                    } else if rng.unit() < 0.5 {
                        host.put(Character(k.key.uppercased()))
                    }  // else: swallowed
                }
                toClient.append((now + oneWay, host))
            }
            if let at = pendingPrompt, at <= now {
                pendingPrompt = nil
                if host.y == host.cells.count - 1 {
                    host.cells.removeFirst()
                    host.cells.append(Array(repeating: " ", count: host.cols))
                    host.y -= 1
                }
                host.y += 1
                host.y = min(host.y, host.cells.count - 1)
                host.cells[host.y] = Array(repeating: " ", count: host.cols)
                host.cells[host.y][0] = "$"
                host.x = 2
                host.atPrompt = true
                toClient.append((now + oneWay, host))
            }
            // The mirror, and the predictor's look at it.
            var changed = false
            while let o = toClient.first, o.at <= now {
                toClient.removeFirst()
                mirror = o.grid
                changed = true
            }
            if changed {
                let before = p.guesses.count, missesBefore = p.misses
                let had = p.guesses
                p.observed(mirror.screen(), at: t)
                if p.misses > missesBefore, ProcessInfo.processInfo.environment["AXECHO_TRACE"] != nil {
                    print("MISS at \(now): guesses \(had.map { "\($0.character)@\($0.x),\($0.y) t\($0.at)" }) cursor \(mirror.x),\(mirror.y) prompt \(mirror.atPrompt) row: \(String(mirror.cells[mirror.y]))")
                }
                if p.misses == missesBefore { run.confirmed += before - p.guesses.count }
            }
            p.tick(at: t)
            // What is drawn: every guess sits on a cell the mirror still has blank,
            // and none outlives the predictor's patience.
            for g in p.guesses {
                if mirror.cells[g.y][g.x] != " " {
                    run.broken = "at \(now) ms a guess of \(g.character) covers \(mirror.cells[g.y][g.x]) at (\(g.x), \(g.y))"
                }
                if t - g.at > p.patience { run.broken = "at \(now) ms a guess outlived its patience" }
            }
            if run.broken != nil { break }
        }
        run.misses = p.misses
        return run
    }

    @Test func aFaithfulShellIsNeverMispredicted() {
        for seed in Self.seeds {
            for oneWay in [10, 40, 120] {
                let r = Self.simulate(seed: seed, oneWay: oneWay, faithful: true)
                #expect(r.broken == nil, "seed \(seed), \(oneWay) ms each way: \(r.broken ?? "")")
                #expect(r.misses == 0, "seed \(seed), \(oneWay) ms each way: \(r.misses) misses")
                if r.misses > 0 || r.broken != nil { return }
            }
        }
    }

    @Test func mostKeysShowBeforeTheirEcho() {
        var early = 0, typed = 0
        for seed in Self.seeds.prefix(50) {
            let r = Self.simulate(seed: seed, oneWay: 40, faithful: true)
            early += r.early
            typed += r.typed
        }
        // Only the keys just after a Return or ⌫ wait for the host.
        #expect(typed > 0 && Double(early) / Double(typed) > 0.6, "\(early) of \(typed) keys were drawn before their echo")
    }

    @Test func aShellThatSurprisesNeverLeavesAWrongGuessShowing() {
        for seed in Self.seeds {
            let r = Self.simulate(seed: seed, oneWay: 40, faithful: false)
            #expect(r.broken == nil, "seed \(seed): \(r.broken ?? "")")
            if r.broken != nil { return }
        }
    }
}
