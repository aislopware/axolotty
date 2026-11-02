/// Local echo for a far host, after Slopty's rules and mosh's idea: a key
/// typed into a shell's input line is drawn at once, where its echo will
/// land, and the host's own output confirms it or takes it back.
///
/// Prediction only runs when guessing can't hurt:
/// - the round trip is over half a display refresh (`minimumRTT`); on a
///   link faster than that the real echo is already in the next frame;
/// - the cursor is visible, in a shell's input line (OSC 133), on the
///   primary screen; no mouse tracking, no hidden prompt;
/// - each guessed cell is blank, or already shows that very character (a
///   shell's suggestion for the rest of the line); never the last column,
///   where the line would wrap. An echo counts once the host's cursor has
///   moved past its cell with the character in it.
///
/// After a key that isn't plain text (Return, arrows, ⌃ chords), nothing is
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

        public init(cursorX: Int, cursorY: Int, cols: Int, cursorVisible: Bool, primary: Bool, atPrompt: Bool,
                    mouseTracking: Bool, secret: Bool, cell: @escaping (_ x: Int, _ y: Int) -> Character?) {
            self.cursorX = cursorX
            self.cursorY = cursorY
            self.cols = cols
            self.cursorVisible = cursorVisible
            self.primary = primary
            self.atPrompt = atPrompt
            self.mouseTracking = mouseTracking
            self.secret = secret
            self.cell = cell
        }

        var allowsGuessing: Bool { cursorVisible && primary && atPrompt && !mouseTracking && !secret }
    }

    /// One guessed character, in active-screen cells.
    public struct Guess: Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var character: Character
        /// When it was typed.
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

    public private(set) var guesses: [Guess] = []
    /// The latest round trip; nil (a local link) never guesses.
    public var rtt: Duration?
    /// A non-text key went out at this time and the host hasn't answered.
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

    // MARK: Input

    /// Plain text typed at `now`. Returns whether the overlay changed.
    @discardableResult
    public mutating func typed(_ text: String, on screen: Screen, at now: Duration) -> Bool {
        let before = guesses.count
        var guessed = 0
        if guessing, heldSince == nil, screen.allowsGuessing, mutedUntil.map({ now >= $0 }) ?? true {
            mutedUntil = nil
            for ch in text {
                let y = guesses.last?.y ?? screen.cursorY
                let x = guesses.last.map { $0.x + 1 } ?? screen.cursorX
                // Its width is the host's to say, or its cell isn't free to guess in.
                // A blank cell, or one already showing this very character (a
                // shell's suggestion of the rest of the line, drawn faintly).
                let under = screen.cell(x, y)
                guard Self.predictable(ch), y == screen.cursorY, x >= screen.cursorX, x < screen.cols - 1,
                      under == " " || under == ch else { break }
                guesses.append(Guess(x: x, y: y, character: ch, at: now))
                guessed += 1
            }
        }
        // A key that went out unguessed moves the cursor by however much
        // the host decides, so a guess after it would sit in the wrong
        // place: hold until the host has answered it. The guesses before it
        // stand; their echoes come first.
        if guessed < text.count { heldSince = now }
        return guesses.count != before
    }

    /// A key that isn't plain text went out (Return, an arrow, a ⌃ chord,
    /// a paste): every guess is dropped until the host has answered.
    @discardableResult
    public mutating func interrupted(at now: Duration) -> Bool {
        let had = !guesses.isEmpty
        guesses.removeAll()
        heldSince = now
        return had
    }

    // MARK: The host's answer

    /// The mirror applied output from the host. Confirms the guesses its
    /// echo matches and takes back the ones it contradicts.
    @discardableResult
    public mutating func observed(_ screen: Screen, at now: Duration) -> Bool {
        // Output from a full round trip after the held key is the host's
        // answer to it; anything sooner was already on its way before it.
        if let h = heldSince, now - h >= (rtt ?? .zero) { heldSince = nil }
        guard !guesses.isEmpty else { return false }
        guard screen.allowsGuessing else {
            guesses.removeAll()  // a program took over the screen: no guess means anything now
            return true
        }
        var kept: [Guess] = []
        for g in guesses {
            // Its echo landed once the host's cursor has moved past it with
            // the character in place. The cell alone can't say: a space looks
            // the same before its echo, and a suggestion shows the rest of the
            // line before it is typed.
            let passed = screen.cursorY != g.y || screen.cursorX > g.x
            if passed, screen.cell(g.x, g.y) == g.character { continue }
            if passed || now - g.at >= patience { return miss(at: now) }
            kept.append(g)
        }
        let changed = kept != guesses
        guesses = kept
        return changed
    }

    /// No output came; a guess left waiting too long is a miss.
    @discardableResult
    public mutating func tick(at now: Duration) -> Bool {
        guard let first = guesses.first, now - first.at >= patience else { return false }
        return miss(at: now)
    }

    /// When `tick` next has something to decide, nil when nothing is waiting.
    public var nextDeadline: Duration? { guesses.first.map { $0.at + patience } }

    private mutating func miss(at now: Duration) -> Bool {
        guesses.removeAll()
        misses += 1
        missedAt = now
        mutedUntil = now + max(.seconds(1), (rtt ?? .zero) * 4)
        return true
    }

    // MARK: Drawing

    public func overlay(at now: Duration) -> Overlay {
        guard let last = guesses.last else { return .none }
        let r = rtt ?? .zero
        let marked = r >= Self.markedRTT
            || guesses.contains { now - $0.at >= Self.markedAge }
            || missedAt.map { now - $0 < Self.markedAfterMiss } ?? false
        return Overlay(cells: guesses, cursor: (last.x + 1, last.y), marked: marked)
    }

    /// One narrow cell for sure: printable ASCII and Latin letters. Anything
    /// wider, combining or unusual is left to the host.
    static func predictable(_ ch: Character) -> Bool {
        guard ch.unicodeScalars.count == 1, let v = ch.unicodeScalars.first?.value else { return false }
        return (0x20 ... 0x7E).contains(v) || (0xA0 ... 0x24F).contains(v)
    }
}
