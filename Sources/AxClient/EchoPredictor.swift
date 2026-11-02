/// Local echo for a far host, after Slopty's rules and mosh's idea: a key
/// typed into a shell's input line is drawn at once, where its echo will
/// land, and the host's own output confirms it or takes it back.
///
/// Prediction only runs when guessing can't hurt:
/// - the round trip is over half a display refresh (`minimumRTT`); on a
///   link faster than that the real echo is already in the next frame;
/// - the cursor is visible, in a shell's input line (OSC 133), on the
///   primary screen; no mouse tracking, no hidden prompt;
/// - each typed character lands on a blank cell, one already showing that
///   very character, or one of a shell's suggestion for the rest of the line
///   (zsh-autosuggestions, fish); never the last column, where the line
///   would wrap. A suggestion typed against is veiled: it no longer fits,
///   and the shell will clear or replace it;
/// - ⌫ only takes back what was typed in this run on this line, never the
///   prompt or text the host put there.
///
/// Guesses are steps in the order typed (put a character, take one back),
/// as the host will apply them. A frame from the host shows a run of them
/// done when the cursor is where they leave it and every character they put
/// is there. Screens repeat (after "a" is the same as after "a", "b", ⌫), so
/// a frame confirms the shortest run it fits, and later frames the rest; one
/// that fits none contradicts the guesses. Guesses still waiting when their
/// time is up, on a screen that already fits all of them, are confirmed.
///
/// After a key that isn't predicted (Return, arrows, ⌃ chords), nothing is
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

    /// One key the host hasn't answered yet: a character put at (x, y), or
    /// the one at (x, y) taken back (`character` nil).
    private struct Step: Equatable {
        var x: Int
        var y: Int
        var character: Character?
        var at: Duration
        /// Where the cursor is once the host has applied it.
        var after: (x: Int, y: Int) { character == nil ? (x, y) : (x + 1, y) }
        static func == (a: Step, b: Step) -> Bool { a.x == b.x && a.y == b.y && a.character == b.character && a.at == b.at }
    }

    private var steps: [Step] = [] {
        didSet { if steps.isEmpty { veiled = [] } }  // answered: the host's own redraw shows
    }
    /// The cursor before the first unanswered step.
    private var origin: (x: Int, y: Int) = (0, 0)
    /// Where this run of typing began on its line: ⌫ goes no further left.
    private var runStart: (x: Int, y: Int)?
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

    /// The cells the guesses will leave, left to right.
    public var guesses: [Guess] {
        var cells: [Guess] = []
        if let at = steps.last?.at {
            for v in veiled { cells.append(Guess(x: v.x, y: v.y, character: " ", at: at)) }
        }
        for s in steps {
            let g = Guess(x: s.x, y: s.y, character: s.character ?? " ", at: s.at)
            if let i = cells.firstIndex(where: { $0.x == s.x && $0.y == s.y }) { cells[i] = g } else { cells.append(g) }
        }
        return cells.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    private var cursor: (x: Int, y: Int) { steps.last?.after ?? origin }

    /// What a cell will show once the guesses land, nil if no guess touches it.
    private func predicted(_ x: Int, _ y: Int) -> Character?? {
        if let s = steps.last(where: { $0.x == x && $0.y == y }) { return s.character ?? " " }
        return veiled.contains { $0.x == x && $0.y == y } ? " " : nil
    }

    private func mayGuess(on screen: Screen, at now: Duration) -> Bool {
        guessing && heldSince == nil && screen.allowsGuessing && (mutedUntil.map { now >= $0 } ?? true)
    }

    /// Holds guessing until the host has answered a key sent now.
    private mutating func hold(at now: Duration) {
        heldSince = now
        runStart = nil
    }

    // MARK: Input

    /// Plain text typed at `now`. Returns whether the overlay changed.
    @discardableResult
    public mutating func typed(_ text: String, on screen: Screen, at now: Duration) -> Bool {
        let before = steps.count
        var guessed = 0
        if mayGuess(on: screen, at: now) {
            mutedUntil = nil
            if steps.isEmpty { origin = (screen.cursorX, screen.cursorY) }
            fitsAll = false
            for ch in text {
                let (x, y) = cursor
                // Its width is the host's to say, or its cell isn't free to guess in:
                // a blank cell, or one already showing this very character (a
                // shell's suggestion of the rest of the line, drawn faintly).
                let ahead = predicted(x, y)
                let under = ahead ?? screen.cell(x, y)
                let suggestion = ahead == nil && screen.suggested(x, y)
                guard Self.predictable(ch), y == screen.cursorY, x < screen.cols - 1,
                      under == " " || under == ch || suggestion else { break }
                if suggestion, under != ch {
                    // Typed against the suggestion: the rest of it goes too.
                    var i = x + 1
                    while i < screen.cols, screen.suggested(i, y), screen.cell(i, y) != " " {
                        veiled.append((i, y))
                        i += 1
                    }
                }
                if runStart == nil { runStart = (x, y) }
                steps.append(Step(x: x, y: y, character: ch, at: now))
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

    /// ⌫ typed at `now`: the last character of this run is taken back, when
    /// there is one; otherwise it is the host's to say. Returns whether the
    /// overlay changed.
    @discardableResult
    public mutating func erased(on screen: Screen, at now: Duration) -> Bool {
        if mayGuess(on: screen, at: now), let run = runStart {
            if steps.isEmpty { origin = (screen.cursorX, screen.cursorY) }
            let (x, y) = cursor
            if y == run.y, x - 1 >= run.x {
                steps.append(Step(x: x - 1, y: y, character: nil, at: now))
                fitsAll = false
                return true
            }
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
            runStart = nil
            guard !steps.isEmpty else { return false }
            steps.removeAll()  // a program took over the screen: no guess means anything now
            return true
        }
        guard !steps.isEmpty else {
            if let run = runStart, screen.cursorY != run.y { runStart = nil }
            return false
        }
        // The runs of steps the screen shows done. The cell alone can't say:
        // a space looks the same before its echo, and a suggestion shows the
        // rest of the line before it is typed; so the cursor must be where
        // they leave it, too.
        let at = (screen.cursorX, screen.cursorY)
        var fits: [Int] = at == origin ? [0] : []
        var shown: [Int: Character] = [:]  // x → what steps 0..<k put on the row
        for (k, s) in steps.enumerated() {
            shown[s.x] = s.character  // taken back: whatever is there now
            guard s.after == at, s.y == screen.cursorY else { continue }
            if shown.allSatisfy({ screen.cell($0.key, s.y) == $0.value }) { fits.append(k + 1) }
        }
        guard let k = fits.first(where: { $0 > 0 }) ?? fits.first else { return miss(at: now) }
        fitsAll = fits.last == steps.count
        if k > 0 {
            origin = steps[k - 1].after
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
        origin = cursor
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

    private mutating func miss(at now: Duration) -> Bool {
        steps.removeAll()
        runStart = nil
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
