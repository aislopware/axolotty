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
        /// Cells drawn as a suggestion (faint, grey).
        var faint: Set<Int> = []

        init(cols: Int = 40, rows: Int = 8) {
            cells = Array(repeating: Array(repeating: " ", count: cols), count: rows)
            cells[0][0] = "$"
        }

        var cols: Int { cells[0].count }

        func screen() -> EchoPredictor.Screen {
            let c = cells, f = faint, row = y
            return EchoPredictor.Screen(cursorX: x, cursorY: y, cols: cols, cursorVisible: cursorVisible, primary: primary,
                                        atPrompt: atPrompt, mouseTracking: false, secret: secret,
                                        suggested: { x, y in y == row && f.contains(x) }) { x, y in
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
        for (i, ch) in "cho hi".enumerated() {  // the suggestion, drawn faintly
            g.cells[0][3 + i] = ch
            g.faint.insert(3 + i)
        }
        p.observed(g.screen(), at: Self.ms(50))
        #expect(p.guesses.isEmpty, "e echoed and the cursor moved on")
        let along = p.typed("ch", on: g.screen(), at: Self.ms(60))
        #expect(along, "c and h sit where the suggestion already shows them")
        p.observed(g.screen(), at: Self.ms(70))  // the suggestion again, no echo yet
        #expect(p.guesses.map(\.character) == ["c", "h"], "the suggestion's c is not c's echo")
        g.x = 5
        g.faint.subtract([3, 4])
        p.observed(g.screen(), at: Self.ms(110))
        #expect(p.guesses.isEmpty && p.misses == 0)

        // The same text, not a suggestion: a key typed before it pushes it right.
        var q = EchoPredictor(rtt: Self.ms(50))
        var h = Grid()
        Self.line(&h, "m f", col: 1)
        let before = q.typed("w", on: h.screen(), at: .zero)
        #expect(!before, "f would move: the host draws that")
        var r = EchoPredictor(rtt: Self.ms(50))
        Self.line(&h, "echo", col: 1)
        let inText = r.typed("c", on: h.screen(), at: .zero)
        #expect(!inText, "c is there, but it is text, not a suggestion: typing c inserts another")
    }

    /// A suggestion that went another way is typed over, not stopped at:
    /// the key takes its cell and the rest of it is veiled, since the shell
    /// will clear or replace it. Text that isn't a suggestion still stops it.
    @Test func typingAgainstASuggestionVeilsIt() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        for (i, ch) in "clear".enumerated() {
            g.cells[0][2 + i] = ch
            g.faint.insert(2 + i)
        }
        let over = p.typed("qz", on: g.screen(), at: .zero)
        #expect(over)
        let o = p.overlay(at: .zero)
        #expect(o.cells.map(\.character) == ["q", "z", " ", " ", " "], "q and z in place of c and l; ear veiled")
        #expect(o.cursor?.x == 4)
        // The shell's answer: q, z, and no suggestion any more.
        g.cells[0] = Array("$ qz" + String(repeating: " ", count: 36))
        g.faint = []
        g.x = 4
        p.observed(g.screen(), at: Self.ms(50))
        #expect(p.guesses.isEmpty && p.misses == 0, "confirmed; the veil goes with the guesses")

        var q = EchoPredictor(rtt: Self.ms(50))
        var h = Grid()
        h.cells[0][2] = "x"  // real text, not a suggestion
        let stopped = q.typed("a", on: h.screen(), at: .zero)
        #expect(!stopped)
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

    /// ⌫ takes back the last character typed, guessed or already echoed:
    /// the cell goes blank and the cursor steps back at once, and the host's
    /// own erase confirms it, however its frames fall.
    @Test func aBackspaceTakesBackWhatWasTyped() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        p.typed("ab", on: g.screen(), at: .zero)
        let back = p.erased(on: g.screen(), at: Self.ms(5))
        #expect(back)
        #expect(p.overlay(at: Self.ms(5)).cells.map(\.character) == ["a", " "], "b is taken back before its echo")
        #expect(p.overlay(at: Self.ms(5)).cursor?.x == 3)
        let again = p.typed("c", on: g.screen(), at: Self.ms(6))
        #expect(again, "typed where b was")
        #expect(p.overlay(at: Self.ms(6)).cells.map(\.character) == ["a", "c"])

        // The host's frames, one per key: each confirms its step in turn.
        for (i, step) in [{ (g: inout Grid) in g.put("a") }, { $0.put("b") },
                          { $0.x -= 1; $0.cells[0][$0.x] = " " }, { $0.put("c") }].enumerated() {
            step(&g)
            p.observed(g.screen(), at: Self.ms(50 + i))
        }
        #expect(p.guesses.isEmpty && p.misses == 0)

        // An echoed character goes the same way; all the host's answer in one frame.
        let erased = p.erased(on: g.screen(), at: Self.ms(100))
        #expect(erased)
        #expect(p.overlay(at: Self.ms(100)).cells.map { [$0.x] } == [[3]] && p.overlay(at: Self.ms(100)).cursor?.x == 3)
        g.x -= 1
        g.cells[0][g.x] = " "
        p.observed(g.screen(), at: Self.ms(150))
        #expect(p.guesses.isEmpty && p.misses == 0)
    }

    /// Only what this run typed is taken back: ⌫ at the start of the line is
    /// the host's (the prompt stays), and so is ⌫ after Return or an arrow.
    @Test func aBackspaceNeverTakesBackThePrompt() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        let atPrompt = p.erased(on: g.screen(), at: .zero)
        #expect(!atPrompt)
        let held = p.typed("x", on: g.screen(), at: Self.ms(1))
        #expect(!held, "held: the host says what that ⌫ did")
        p.observed(g.screen(), at: Self.ms(60))
        p.typed("a", on: g.screen(), at: Self.ms(61))
        g.put("a")
        p.observed(g.screen(), at: Self.ms(110))
        let one = p.erased(on: g.screen(), at: Self.ms(120))
        #expect(one, "a was typed in this run")
        p.erased(on: g.screen(), at: Self.ms(121))  // the next would reach the prompt
        #expect(p.guesses.isEmpty, "the host answers that ⌫ before anything more is guessed")
        let after = p.typed("b", on: g.screen(), at: Self.ms(122))
        #expect(!after)
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

    /// The host's line as a line editor keeps it: `text` after the prompt,
    /// the cursor `col` into it.
    static func line(_ g: inout Grid, _ text: String, col: Int? = nil) {
        g.cells[g.y] = Array(("$ " + text).padding(toLength: g.cols, withPad: " ", startingAt: 0))
        g.x = 2 + (col ?? text.count)
    }

    /// ← and → move the cursor within what was typed, and a key typed there
    /// goes in, the rest of the line moving right, as the shell will draw it.
    @Test func arrowsMoveWithinWhatWasTypedAndKeysGoInThere() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        p.typed("ac", on: g.screen(), at: .zero)
        let left = p.moved(by: -1, on: g.screen(), at: Self.ms(1))
        #expect(left)
        #expect(p.overlay(at: Self.ms(1)).cursor?.x == 3, "between a and c")
        p.typed("b", on: g.screen(), at: Self.ms(2))
        #expect(p.overlay(at: Self.ms(2)).cells.map(\.character) == ["a", "b", "c"])
        #expect(p.overlay(at: Self.ms(2)).cursor?.x == 4)
        let right = p.moved(by: 1, on: g.screen(), at: Self.ms(3))
        #expect(right)
        #expect(p.overlay(at: Self.ms(3)).cursor?.x == 5)

        // The shell's frames, one per key.
        for (i, (text, col)) in [("a", 1), ("ac", 2), ("ac", 1), ("abc", 2), ("abc", 3)].enumerated() {
            Self.line(&g, text, col: col)
            p.observed(g.screen(), at: Self.ms(50 + i))
        }
        #expect(p.guesses.isEmpty && p.misses == 0)

        // ⌫ inside the line: the rest moves left, its old last cell goes blank.
        p.moved(by: -1, on: g.screen(), at: Self.ms(100))
        p.moved(by: -1, on: g.screen(), at: Self.ms(101))
        let erased = p.erased(on: g.screen(), at: Self.ms(102))
        #expect(erased)
        let o = p.overlay(at: Self.ms(102))
        #expect(o.cells.map { "\($0.x)\($0.character)" } == ["2b", "3c", "4 "])
        #expect(o.cursor?.x == 2)
        Self.line(&g, "bc", col: 0)
        p.observed(g.screen(), at: Self.ms(150))
        #expect(p.guesses.isEmpty && p.misses == 0, "all three keys answered in one frame")
    }

    /// Past what this run typed an arrow is the host's: ← into the prompt or
    /// older text, → at the end (it takes a shell's suggestion). And an edit
    /// inside the line waits when text the run doesn't own follows it.
    @Test func anArrowPastTheRunIsTheHosts() {
        var p = EchoPredictor(rtt: Self.ms(50))
        var g = Grid()
        let first = p.moved(by: -1, on: g.screen(), at: .zero)
        #expect(!first, "no run yet: the prompt is before the cursor")

        var q = EchoPredictor(rtt: Self.ms(50))
        g = Grid()
        q.typed("ab", on: g.screen(), at: .zero)
        q.moved(by: 1, on: g.screen(), at: Self.ms(1))
        #expect(q.guesses.isEmpty, "→ at the end: every guess goes until the host answers")
        let held = q.typed("c", on: g.screen(), at: Self.ms(2))
        #expect(!held)

        var r = EchoPredictor(rtt: Self.ms(50))
        g = Grid()
        r.typed("e", on: g.screen(), at: .zero)
        Self.line(&g, "echo hi", col: 1)  // e, and the rest suggested
        g.faint = Set(3 ..< 9)
        r.observed(g.screen(), at: Self.ms(50))
        let beside = r.moved(by: -1, on: g.screen(), at: Self.ms(60))
        #expect(!beside, "a suggestion follows: where it goes is the shell's")
        let after = r.typed("x", on: g.screen(), at: Self.ms(61))
        #expect(!after, "held until the host has answered the ←")
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
        /// ⌫ presses, and those drawn before the host took the character back.
        var erases = 0, erasedEarly = 0
        /// ← → presses, and those drawn before the host moved the cursor.
        var moves = 0, movedEarly = 0
        var broken: String?
    }

    /// A shell's line editor: what was typed after the prompt, and the
    /// cursor in it. Keys insert; ⌫ takes the one before the cursor; ← → move.
    struct Editor {
        var text: [Character] = []
        var col = 0

        mutating func apply(_ key: Character, cols: Int) {
            switch key {
            case "\u{7f}": if col > 0 { text.remove(at: col - 1); col -= 1 }
            case "←": if col > 0 { col -= 1 }
            case "→": if col < text.count { col += 1 }
            default: if 2 + text.count < cols - 1 { text.insert(key, at: col); col += 1 }
            }
        }

        func draw(_ g: inout Grid) {
            for x in 2 ..< g.cols { g.cells[g.y][x] = x - 2 < text.count ? text[x - 2] : " " }
            g.x = 2 + col
        }
    }

    /// Two seconds of typing into a shell `oneWay` ms away. `faithful`: the
    /// shell echoes every key as typed; otherwise it sometimes echoes another
    /// character, swallows one, or draws its next prompt late.
    static func simulate(seed: UInt64, oneWay: Int, faithful: Bool) -> Run {
        var rng = SimRNG(seed: seed)
        var host = Grid()
        var editor = Editor()
        var mirror = host
        var p = EchoPredictor(rtt: ms(oneWay * 2))
        var toHost: [(at: Int, key: Character)] = []
        var toClient: [(at: Int, grid: Grid)] = []
        var pendingPrompt: Int?
        /// Keys whose answer hasn't reached the mirror: when sent, and whether guessed.
        var unanswered: [(at: Int, guessed: Bool)] = []
        let trace = ProcessInfo.processInfo.environment["AXECHO_TRACE"] != nil
        var run = Run()
        let letters = Array("abcdefghijklmnopqrstuvwxyz -./")

        for now in 0 ..< 2000 {
            let t = ms(now)
            var eventful = false  // a key, a frame or a tick: what is drawn may have changed
            // The person types about every 60 ms; Return, ⌫ and arrows now and then.
            if rng.unit() < 1.0 / 60 {
                eventful = true
                let r = rng.unit()
                let key: Character = r < 0.08 ? "\r" : r < 0.14 ? "\u{7f}" : r < 0.20 ? "←" : r < 0.23 ? "→"
                    : letters[Int(rng.next() % UInt64(letters.count))]
                if trace { print("key \(key.debugDescription) at \(now)") }
                var guessed = false
                if key == "\r" {
                    p.interrupted(at: t)
                } else if key == "\u{7f}" {
                    run.erases += 1
                    // A ⌫ or an arrow not guessed drops every guess: nothing is drawn.
                    p.erased(on: mirror.screen(), at: t)
                    guessed = p.overlay(at: t) != .none
                    if guessed { run.erasedEarly += 1 }
                } else if key == "←" || key == "→" {
                    run.moves += 1
                    p.moved(by: key == "←" ? -1 : 1, on: mirror.screen(), at: t)
                    guessed = p.overlay(at: t) != .none
                    if guessed { run.movedEarly += 1 }
                } else {
                    run.typed += 1
                    guessed = p.typed(String(key), on: mirror.screen(), at: t)
                    if guessed { run.predicted += 1 }
                    if p.overlay(at: t).cells.contains(where: { $0.character == key }) { run.early += 1 }
                }
                unanswered.append((now, guessed))
                toHost.append((now + oneWay, key))
                if trace {
                    let o = p.overlay(at: t)
                    print("  mirror \(String(mirror.cells[mirror.y]).debugDescription) x \(mirror.x); drawn \(o.cells.map { "\($0.x)\($0.character)" }) cursor \(o.cursor.map { "\($0.x)" } ?? "-")")
                }
            }
            // The shell.
            while let k = toHost.first, k.at <= now {
                toHost.removeFirst()
                switch k.key {
                case "\r":
                    host.atPrompt = false
                    host.y = min(host.y + 1, host.cells.count - 1)
                    host.x = 0
                    editor = Editor()
                    pendingPrompt = now + (faithful ? 3 : 3 + Int(rng.next() % 40))
                case "\u{7f}", "←", "→":
                    guard host.atPrompt else { break }
                    editor.apply(k.key, cols: host.cols)
                    editor.draw(&host)
                default:
                    guard host.atPrompt else { break }
                    if faithful || rng.unit() < 0.8 {
                        editor.apply(k.key, cols: host.cols)
                    } else if rng.unit() < 0.5 {
                        editor.apply(Character(k.key.uppercased()), cols: host.cols)
                    }  // else: swallowed
                    editor.draw(&host)
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
                if p.misses > missesBefore, trace {
                    print("MISS at \(now): guesses \(had.map { "\($0.character)@\($0.x),\($0.y) t\($0.at)" }) cursor \(mirror.x),\(mirror.y) prompt \(mirror.atPrompt) row: \(String(mirror.cells[mirror.y]))")
                }
                if p.misses == missesBefore { run.confirmed += before - p.guesses.count }
            }
            if p.tick(at: t) || changed { eventful = true }
            // What is drawn: no guess outlives the predictor's patience; and
            // with a faithful shell, every guessed cell and the cursor show what
            // the host will once it has the keys in flight, and nothing is left
            // guessed once it has answered them all.
            if let first = p.oldestGuess, t - first > p.patience {
                run.broken = "at \(now) ms a guess outlived its patience"
            }
            // A key's answer is in the mirror a round trip after it was sent.
            unanswered.removeAll { now >= $0.at + 2 * oneWay }
            // Between a key, a frame and a tick nothing drawn or due changes.
            if eventful, faithful, !toHost.contains(where: { $0.key == "\r" }), pendingPrompt == nil, host.atPrompt {
                let o = p.overlay(at: t)
                var future = host
                if !toHost.isEmpty {
                    var ahead = editor
                    for k in toHost.map(\.key) { ahead.apply(k, cols: host.cols) }
                    ahead.draw(&future)
                }
                for g in o.cells where future.cells[g.y][g.x] != g.character {
                    run.broken = "at \(now) ms (\(g.x), \(g.y)) is drawn \(g.character.debugDescription), the host will show \(future.cells[g.y][g.x].debugDescription)"
                }
                // While every key on its way was guessed, the line as drawn is
                // the line the host will show: every cell, and the cursor.
                if !unanswered.isEmpty, unanswered.allSatisfy(\.guessed), mirror.y == future.y {
                    var drawn = mirror.cells[mirror.y]
                    for g in o.cells where g.y == mirror.y { drawn[g.x] = g.character }
                    if drawn != future.cells[future.y] {
                        run.broken = "at \(now) ms the line is drawn \(String(drawn).debugDescription), the host's will be \(String(future.cells[future.y]).debugDescription)"
                    }
                    let c = o.cursor ?? (mirror.x, mirror.y)
                    if c.x != future.x || c.y != future.y {
                        run.broken = "at \(now) ms the cursor is drawn at \(c.x), the host's will be at \(future.x)"
                    }
                }
                if toHost.isEmpty, toClient.isEmpty, !p.guesses.isEmpty {
                    run.broken = "at \(now) ms the host has answered every key, yet \(p.guesses.count) guesses remain"
                }
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
        var early = 0, typed = 0, erases = 0, erasedEarly = 0, moves = 0, movedEarly = 0
        for seed in Self.seeds.prefix(50) {
            let r = Self.simulate(seed: seed, oneWay: 40, faithful: true)
            early += r.early
            typed += r.typed
            erases += r.erases
            erasedEarly += r.erasedEarly
            moves += r.moves
            movedEarly += r.movedEarly
        }
        // Only the keys just after a Return (or a ⌫ into the prompt) wait for the host.
        #expect(typed > 0 && Double(early) / Double(typed) > 0.6, "\(early) of \(typed) keys were drawn before their echo")
        #expect(erases > 0 && Double(erasedEarly) / Double(erases) > 0.5, "\(erasedEarly) of \(erases) ⌫ were drawn before the host's")
        #expect(moves > 0 && Double(movedEarly) / Double(moves) > 0.4, "\(movedEarly) of \(moves) arrows were drawn before the host's")
    }

    @Test func aShellThatSurprisesNeverLeavesAWrongGuessShowing() {
        for seed in Self.seeds {
            let r = Self.simulate(seed: seed, oneWay: 40, faithful: false)
            #expect(r.broken == nil, "seed \(seed): \(r.broken ?? "")")
            if r.broken != nil { return }
        }
    }
}
