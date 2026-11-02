/// Local echo for a far host, after Slopty's rules and mosh's idea: a key
/// typed into a shell's input line is drawn at once, where its echo will
/// land, and the host's own output confirms it or takes it back.
///
/// Prediction only runs when guessing can't hurt:
/// - the round trip is over half a display refresh (`minimumRTT`); on a
///   link faster than that the real echo is already in the next frame;
/// - the cursor is visible, in a shell's input line (OSC 133), on the
///   primary screen; no mouse tracking, no hidden prompt;
/// - a run of typing owns the text it typed, from where it began. At its
///   end a character lands where only blanks or a shell's suggestion of the
///   rest of the line (zsh-autosuggestions, fish) follow, since it would
///   push any other text right; never the last column, where the line
///   would wrap. A suggestion typed against is veiled: it no longer fits,
///   and the shell will clear or replace it;
/// - inside that text, ← and → move the cursor, a character is inserted
///   and ⌫ takes the one before the cursor back, the rest moving as a line
///   editor moves it; only while nothing but blanks follows it;
/// - ⌫ and ← stop where the run began: the prompt and text the host put
///   there are the host's, and so is → at the end (it takes a suggestion).
///
/// Guesses are steps in the order typed, each the run's line as the host
/// will have it after that key. A frame from the host shows a run of them
/// done when the cursor is where they leave it and the line's text is
/// there. Screens repeat (after "a" is the same as after "a", "b", ⌫), so
/// a frame confirms the shortest run it fits, and later frames the rest; one
/// that fits none contradicts the guesses. Guesses still waiting when their
/// time is up, on a screen that already fits all of them, are confirmed.
///
/// After a key that isn't predicted (Return, ↑, ⌃ and ⌥ chords), nothing is
/// guessed until the host has answered it: until then, where the next
/// character lands is the host's to say. A guess the host contradicts, or
/// leaves unconfirmed too long, clears every guess and mutes prediction for a
/// while; the real screen was right all along, so nothing needs undoing.
///
/// A pure door: time comes in as a value since any epoch, and the screen as
/// the questions it answers. No clock, no I/O (`DoorTests`).
public struct EchoPredictor {
    /// What the mirror shows right now, read under its lock.
    public struct Screen {
        public var cursorX: Int
        public var cursorY: Int
        public var cols: Int
        public var cursorVisible: Bool
        /// Not the alternate screen (full-screen programs draw their own).
        public var primary: Bool
        /// In a shell's prompt or input line, by its OSC 133 marks.
        public var atPrompt: Bool
        public var mouseTracking: Bool
        /// The program reads a hidden line (a password).
        public var secret: Bool
        /// The character in a cell of the active screen, " " for a blank one.
        public var cell: (_ x: Int, _ y: Int) -> Character?
        /// The cell is drawn as a shell's suggestion of the rest of the line
        /// (faint, or grey): the line editor's to redraw, not text in the way.
        public var suggested: (_ x: Int, _ y: Int) -> Bool

        public init(cursorX: Int, cursorY: Int, cols: Int, cursorVisible: Bool, primary: Bool, atPrompt: Bool,
                    mouseTracking: Bool, secret: Bool, suggested: @escaping (_ x: Int, _ y: Int) -> Bool = { _, _ in false },
                    cell: @escaping (_ x: Int, _ y: Int) -> Character?) {
            self.cursorX = cursorX
            self.cursorY = cursorY
            self.cols = cols
            self.cursorVisible = cursorVisible
            self.primary = primary
            self.atPrompt = atPrompt
            self.mouseTracking = mouseTracking
            self.secret = secret
            self.suggested = suggested
            self.cell = cell
        }

        var allowsGuessing: Bool { cursorVisible && primary && atPrompt && !mouseTracking && !secret }
    }

    /// One guessed cell, in active-screen cells: the character it will show,
    /// " " for one ⌫ takes back.
    public struct Guess: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var character: Character
        /// When its latest key was typed.
        public var at: Duration
    }

    /// What to draw over the mirror's own frame.
    public struct Overlay: Equatable, Sendable {
        public var cells: [Guess]
        /// Where the cursor would be after the guesses; nil without any.
        public var cursor: (x: Int, y: Int)?
        /// Faint and underlined: a far link, a slow echo, or a recent miss.
        public var marked: Bool

        public static let none = Overlay(cells: [], cursor: nil, marked: false)

        public static func == (a: Overlay, b: Overlay) -> Bool {
            a.cells == b.cells && a.cursor?.x == b.cursor?.x && a.cursor?.y == b.cursor?.y && a.marked == b.marked
        }
    }

    /// Below this the host's echo beats a guess to the screen anyway.
    public static let minimumRTT: Duration = .milliseconds(8)
    /// From here on a guess is marked as one (Slopty's rule).
    public static let markedRTT: Duration = .milliseconds(80)
    /// A guess this old is marked too.
    public static let markedAge: Duration = .milliseconds(250)
    /// How long a miss keeps guesses marked once prediction comes back.
    public static let markedAfterMiss: Duration = .seconds(10)

    /// The run's text as the host will have it, from where the run began,
    /// and the cursor in it.
    private struct Line: Equatable {
        var text: [Character] = []
        var col = 0
        /// What the line shows `i` cells in: nil past its end (blank, or
        /// whatever the host draws there).
        func at(_ i: Int) -> Character? { i < text.count ? text[i] : nil }
    }

    /// One key the host hasn't answered yet: the line once it has.
    private struct Step: Equatable {
        var line: Line
        var at: Duration
    }

    private var steps: [Step] = [] {
        didSet { if steps.isEmpty { veiled = [] } }  // answered: the host's own redraw shows
    }
    /// Where this run of typing began; its line is laid out from here.
    private var anchor: (x: Int, y: Int) = (0, 0)
    /// The line as the host has it, every step before the first unanswered one done.
    private var base = Line()
    /// The run goes on: ⌫ and arrows move within what it typed. Off after a
    /// key the host answers on its own, or a screen that no longer shows it.
    private var open = false
    /// The latest screen already fits every step (its frames were ambiguous).
    private var fitsAll = false
    /// Cells of a suggestion typing went against, drawn blank until the
    /// host has answered.
    private var veiled: [(x: Int, y: Int)] = []
    /// The latest round trip; nil (a local link) never guesses.
    public var rtt: Duration?
    /// A key not predicted went out at this time and the host hasn't answered.
    private var heldSince: Duration?
    private var mutedUntil: Duration?
    private var missedAt: Duration?
    /// Misses so far (for the view's tests and a debug readout).
    public private(set) var misses = 0

    public init(rtt: Duration? = nil) { self.rtt = rtt }

    private var guessing: Bool { (rtt ?? .zero) >= Self.minimumRTT }

    /// How long a guess may wait for its echo before it counts as a miss.
    public var patience: Duration {
        let r = rtt ?? .zero
        return max(.seconds(1), r * 3 + .milliseconds(250))
    }

    private var latest: Line { steps.last?.line ?? base }

    /// The cells the guesses will leave, left to right: every cell a step
    /// changed, as the last one leaves it, and the veiled suggestion.
    public var guesses: [Guess] {
        guard let last = steps.last else { return [] }
        var when: [Int: Duration] = [:]  // cell → the latest step that changed it
        var before = base
        for s in steps {
            for i in 0 ..< max(before.text.count, s.line.text.count) where before.at(i) != s.line.at(i) { when[i] = s.at }
            before = s.line
        }
        var cells = veiled.filter { v in !when.keys.contains { anchor.x + $0 == v.x } }
            .map { Guess(x: $0.x, y: $0.y, character: " ", at: last.at) }
        for (i, at) in when { cells.append(Guess(x: anchor.x + i, y: anchor.y, character: last.line.at(i) ?? " ", at: at)) }
        return cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    private var cursor: (x: Int, y: Int) { (anchor.x + latest.col, anchor.y) }

    /// Whether the cell `i` in from the anchor will be blank: cleared by a
    /// step, veiled, or blank on the screen and untouched.
    private func blank(_ i: Int, on screen: Screen) -> Bool {
        let x = anchor.x + i
        if let ch = latest.at(i) { return ch == " " }
        if steps.contains(where: { $0.line.text.count > i }) || base.text.count > i { return true }
        if veiled.contains(where: { $0.x == x && $0.y == anchor.y }) { return true }
        return screen.cell(x, anchor.y) == " "
    }

    /// Everything after the line's text is blank: an edit inside it moves
    /// that text and nothing the host drew beside it.
    private func tailIsBlank(on screen: Screen) -> Bool {
        (latest.text.count ..< max(latest.text.count, screen.cols - anchor.x)).allSatisfy { blank($0, on: screen) }
    }

    /// The screen shows `line` done: the cursor where it leaves it, and
    /// every character of it in place.
    private func shows(_ line: Line, on screen: Screen) -> Bool {
        screen.cursorX == anchor.x + line.col && screen.cursorY == anchor.y
            && line.text.indices.allSatisfy { screen.cell(anchor.x + $0, anchor.y) == line.text[$0] }
    }

    private func mayGuess(on screen: Screen, at now: Duration) -> Bool {
        guessing && heldSince == nil && screen.allowsGuessing && (mutedUntil.map { now >= $0 } ?? true)
    }

    /// Holds guessing until the host has answered a key sent now.
    private mutating func hold(at now: Duration) {
        heldSince = now
        open = false
    }

    /// Starts a run at the cursor, unless one is going (or its guesses still are).
    private mutating func begin(on screen: Screen) -> Bool {
        if open { return true }
        guard steps.isEmpty else { return false }
        anchor = (screen.cursorX, screen.cursorY)
        base = Line()
        open = true
        return true
    }

    private mutating func step(_ line: Line, at now: Duration) {
        steps.append(Step(line: line, at: now))
        fitsAll = false
        mutedUntil = nil
    }

    // MARK: Input

    /// Plain text typed at `now`. Returns whether the overlay changed.
    @discardableResult
    public mutating func typed(_ text: String, on screen: Screen, at now: Duration) -> Bool {
        let before = steps.count
        var guessed = 0
        if mayGuess(on: screen, at: now), begin(on: screen) {
            for ch in text {
                var line = latest
                let i = line.col, x = anchor.x + i
                guard Self.predictable(ch), anchor.y == screen.cursorY else { break }
                if i < line.text.count {
                    // Inside the line: the rest of it moves right, as a line
                    // editor inserts; nothing else may stand in its way.
                    guard anchor.x + line.text.count < screen.cols - 1, tailIsBlank(on: screen) else { break }
                } else {
                    // At its end, the cell and everything after it must be free:
                    // blank, or a shell's suggestion of the rest of the line. Text
                    // there would be pushed right (the key goes in before it), and
                    // never the last column, where the line would wrap.
                    let free = blank(i, on: screen)
                    let suggestion = !free && screen.suggested(x, anchor.y)
                    guard x < screen.cols - 1, free || suggestion,
                          (i + 1 ..< max(i + 1, screen.cols - anchor.x)).allSatisfy({
                              blank($0, on: screen) || screen.suggested(anchor.x + $0, anchor.y)
                          })
                    else { break }
                    if suggestion, screen.cell(x, anchor.y) != ch {
                        // Typed against the suggestion: the rest of it goes too.
                        var j = x + 1
                        while j < screen.cols, screen.suggested(j, anchor.y), screen.cell(j, anchor.y) != " " {
                            veiled.append((j, anchor.y))
                            j += 1
                        }
                    }
                }
                line.text.insert(ch, at: i)
                line.col += 1
                step(line, at: now)
                guessed += 1
            }
        }
        // A key that went out unguessed moves the cursor by however much
        // the host decides, so a guess after it would sit in the wrong
        // place: hold until the host has answered it. The guesses before it
        // stand; their echoes come first.
        if guessed < text.count { hold(at: now) }
        return steps.count != before
    }

    /// ⌫ typed at `now`: the character before the cursor is taken back when
    /// this run typed it; otherwise it is the host's to say. Returns whether
    /// the overlay changed.
    @discardableResult
    public mutating func erased(on screen: Screen, at now: Duration) -> Bool {
        var line = latest
        if mayGuess(on: screen, at: now), open, line.col > 0,
           line.col == line.text.count || tailIsBlank(on: screen) {
            line.text.remove(at: line.col - 1)
            line.col -= 1
            step(line, at: now)
            return true
        }
        return interrupted(at: now)
    }

    /// ← (`by` -1) or → (+1) typed at `now`: the cursor moves within what
    /// this run typed. Past either end it is the host's to say (→ at the end
    /// takes a shell's suggestion). Returns whether the overlay changed.
    @discardableResult
    public mutating func moved(by dx: Int, on screen: Screen, at now: Duration) -> Bool {
        var line = latest
        if mayGuess(on: screen, at: now), open, line.text.indices.contains(line.col + min(dx, 0)),
           abs(dx) == 1, tailIsBlank(on: screen) {
            line.col += dx
            step(line, at: now)
            return true
        }
        return interrupted(at: now)
    }

    /// A key that isn't predicted went out (Return, an arrow, a ⌃ chord, a
    /// paste): every guess is dropped until the host has answered.
    @discardableResult
    public mutating func interrupted(at now: Duration) -> Bool {
        let had = !steps.isEmpty
        steps.removeAll()
        hold(at: now)
        return had
    }

    // MARK: The host's answer

    /// The mirror applied output from the host. Confirms the guesses its
    /// echo shows done and takes back the ones it contradicts.
    @discardableResult
    public mutating func observed(_ screen: Screen, at now: Duration) -> Bool {
        // Output from a full round trip after the held key is the host's
        // answer to it; anything sooner was already on its way before it.
        if let h = heldSince, now - h >= (rtt ?? .zero) { heldSince = nil }
        guard screen.allowsGuessing else {
            open = false
            guard !steps.isEmpty else { return false }
            steps.removeAll()  // a program took over the screen: no guess means anything now
            return true
        }
        guard !steps.isEmpty else {
            // The host changed the line on its own (a completion, a redraw):
            // what this run typed is no longer known.
            if open, !shows(base, on: screen) { open = false }
            return false
        }
        // The runs of steps the screen shows done. The cell alone can't say:
        // a space looks the same before its echo, and a suggestion shows the
        // rest of the line before it is typed; so the cursor must be where
        // they leave it, too. Screens repeat (after "a" is the same as after
        // "a", "b", ⌫), so the shortest run that fits is taken, and later
        // frames confirm the rest.
        var fits: [Int] = shows(base, on: screen) ? [0] : []
        for (k, s) in steps.enumerated() where shows(s.line, on: screen) { fits.append(k + 1) }
        guard let k = fits.first(where: { $0 > 0 }) ?? fits.first else { return miss(at: now) }
        fitsAll = fits.last == steps.count
        if k > 0 {
            base = steps[k - 1].line
            steps.removeFirst(k)
            return true
        }
        if let first = steps.first, now - first.at >= patience { return settle(at: now) }
        return false
    }

    /// Time is up for the oldest guess: confirmed if the screen already
    /// shows them all, a miss otherwise.
    private mutating func settle(at now: Duration) -> Bool {
        guard fitsAll else { return miss(at: now) }
        base = latest
        steps.removeAll()
        return true
    }

    /// No output came; a guess left waiting too long is a miss.
    @discardableResult
    public mutating func tick(at now: Duration) -> Bool {
        guard let first = steps.first, now - first.at >= patience else { return false }
        return settle(at: now)
    }

    /// When `tick` next has something to decide, nil when nothing is waiting.
    public var nextDeadline: Duration? { steps.first.map { $0.at + patience } }

    /// When the oldest unanswered key went out.
    public var oldestGuess: Duration? { steps.first?.at }

    private mutating func miss(at now: Duration) -> Bool {
        steps.removeAll()
        open = false
        misses += 1
        missedAt = now
        mutedUntil = now + max(.seconds(1), (rtt ?? .zero) * 4)
        return true
    }

    // MARK: Drawing

    public func overlay(at now: Duration) -> Overlay {
        guard !steps.isEmpty else { return .none }
        let r = rtt ?? .zero
        let marked = r >= Self.markedRTT
            || steps.contains { now - $0.at >= Self.markedAge }
            || missedAt.map { now - $0 < Self.markedAfterMiss } ?? false
        return Overlay(cells: guesses, cursor: cursor, marked: marked)
    }

    /// One narrow cell for sure: printable ASCII and Latin letters. Anything
    /// wider, combining or unusual is left to the host.
    static func predictable(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x20 ... 0x7E).contains(v) || (0xA0 ... 0x24F).contains(v)
    }
}
