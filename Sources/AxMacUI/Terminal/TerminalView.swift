import AppKit
import AxClient
import AxModel
import AxProtocol
import AxRender
import AxVT
import QuartzCore
import Synchronization

/// Colours a terminal view needs from the theme, packed RGBA (R in the low byte).
struct TerminalColors: Equatable {
    var ground: UInt32
    var selection: UInt32
    var accent: UInt32
    var cursorText: UInt32
    /// Find: every match, and the current one. The theme's own yellow mixed
    /// into its ground, so they belong to any palette and keep text legible.
    var findMatch: UInt32
    var findCurrent: UInt32
    /// The text colour: what a hovered link is underlined in (no new hue on the grid).
    var foreground: NSColor

    init(theme: TerminalTheme) {
        ground = theme.background.packed
        selection = theme.selectionBackground.packed
        accent = theme.cursor.packed
        cursorText = theme.cursorText.packed
        let f = theme.foreground
        foreground = NSColor(srgbRed: CGFloat(f.r) / 255, green: CGFloat(f.g) / 255, blue: CGFloat(f.b) / 255, alpha: 1)
        let yellow = theme.ansi.count > 11 ? theme.ansi[theme.isDark ? 3 : 11] : RGB(229, 192, 123)
        findMatch = Self.mix(theme.background, yellow, theme.isDark ? 0.30 : 0.38).packed
        findCurrent = Self.mix(theme.background, yellow, theme.isDark ? 0.62 : 0.80).packed
    }

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        func m(_ x: UInt8, _ y: UInt8) -> UInt8 { UInt8((Double(x) + (Double(y) - Double(x)) * t).rounded()) }
        return RGB(m(a.r, b.r), m(a.g, b.g), m(a.b, b.b))
    }
}

@MainActor
protocol TerminalViewDelegate: AnyObject {
    /// The view became first responder (the person is typing here).
    func terminalDidBecomeFocused(_ view: TerminalView)
    /// A click landed on a pane that is not the focused one; it only focuses.
    func terminalIsFocusedPane(_ view: TerminalView) -> Bool
}

/// One pane's terminal: a Metal layer fed by a mirror, plus keyboard, IME, mouse,
/// selection, scrolling and cursor motion. Input goes to the host as events; the
/// host encodes them for its program.
final class TerminalView: NSView, NSTextInputClient, NSMenuItemValidation {
    let pane: PaneID
    let connection: HostConnection
    let mirror: MirrorTerminal
    let prefs: Preferences
    weak var delegate: (any TerminalViewDelegate)?

    private let frameState: TerminalFrame?
    private var renderer: TerminalRenderer?
    private var link: CADisplayLink?
    private var lastGeneration: UInt64 = .max
    /// Local echo for a far host: guesses drawn until the host's own echo lands.
    private var predictor = EchoPredictor()
    private var predictionTimer: DispatchWorkItem?
    private var needsRender = true
    private var idleFrames = 0
    private let wake = WakeFlag()
    private var cursor = CursorAnimator()
    private let selection = VTSelectionGesture()

    var colors: TerminalColors {
        didSet {
            guard colors != oldValue else { return }
            frameState?.invalidate()
            dimLayer.backgroundColor = Self.cg(colors.ground)
            setNeedsRender()
        }
    }

    // Grid geometry (pixels) for the current bounds.
    private(set) var grid = (cols: 0, rows: 0)
    private var origin = (x: Float(0), y: Float(0))
    private var cellSize = (w: 1, h: 1)
    private var lastViewport: (cols: Int, rows: Int, cw: Int, ch: Int)?
    private var viewportTimer: Timer?
    private var lastViewportSend = 0.0

    /// While frozen (animated relayout), the grid keeps its size and the drawing is
    /// clipped top-left; the final size is committed once at the end (one SIGWINCH).
    var gridFrozen = false {
        didSet { if !gridFrozen, oldValue { updateGrid() } }
    }

    // Overlays inside the layer tree (all non-interactive).
    private let dimLayer = CALayer()
    private let focusRingLayer = CALayer()
    /// Light mode only: a one-pixel contact edge, since a near-white sheet on
    /// a pale frame has no figure without it. Dark sheets sit darker than the
    /// frame and need none.
    private let edgeLayer = CALayer()
    /// The pane's identity strip (shown in splits; laid out over the top of the sheet).
    let strip = PaneStripView()
    var showsStrip = false {
        didSet {
            guard showsStrip != oldValue else { return }
            strip.isHidden = !showsStrip
            layoutOverlays()
            updateGrid()
            setNeedsRender()
        }
    }
    private let preeditLayer = CATextLayer()

    // Input state.
    private var marked = NSMutableAttributedString()
    private var markedSelection = NSRange(location: 0, length: 0)
    private var accumulator: [String]?
    private var mouseMode: MouseMode = .none
    private var scrollRemainder = 0.0
    private var pressedButtons = Set<UInt8>()

    private enum MouseMode { case none, selecting, reporting }

    init(pane: PaneID, connection: HostConnection, prefs: Preferences, colors: TerminalColors) {
        self.pane = pane
        self.connection = connection
        self.prefs = prefs
        self.colors = colors
        mirror = connection.attach(pane)
        frameState = try? TerminalFrame()
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        registerForDraggedTypes([.fileURL, .string])

        for l in [dimLayer, focusRingLayer, edgeLayer, preeditLayer] {
            l.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
            l.isHidden = false
            layer?.addSublayer(l)
        }
        // Every pane is a sheet set in the frame (design-system §1.1).
        for l in [dimLayer, focusRingLayer, edgeLayer] {
            l.cornerRadius = Axo.Metric.sheetRadius
            l.cornerCurve = .continuous
        }
        dimLayer.backgroundColor = Self.cg(colors.ground)
        dimLayer.opacity = 0
        focusRingLayer.borderWidth = 1
        focusRingLayer.opacity = 0
        preeditLayer.isHidden = true
        preeditLayer.contentsScale = 2
        strip.isHidden = true
        addSubview(strip)

        let flag = wake
        mirror.onChange { [weak self] in
            guard flag.pending.exchange(true, ordering: .acquiringAndReleasing) == false else { return }
            Task { @MainActor in
                flag.pending.store(false, ordering: .releasing)
                self?.setNeedsRender()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        mirror.onChange(nil)
        link?.invalidate()
        viewportTimer?.invalidate()
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layoutOverlays()
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.contentsGravity = .topLeft
        l.needsDisplayOnBoundsChange = false
        return l
    }

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    private static func cg(_ packed: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(packed & 0xFF) / 255, green: CGFloat(packed >> 8 & 0xFF) / 255,
                blue: CGFloat(packed >> 16 & 0xFF) / 255, alpha: alpha)
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard let window else { return SecureInput.set(self, false) }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        updateRenderer()
        NotificationCenter.default.removeObserver(self)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name,
                                                   object: window)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRenderer()
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer?.presentsWithTransaction = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer?.presentsWithTransaction = false
        flushViewport()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutOverlays()
        updateGrid()
        if inLiveResize { render(CACurrentMediaTime()) } else { setNeedsRender() }
    }

    /// Re-reads font size and backing scale.
    func updateRenderer() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        renderer = RenderPool.shared.renderer(scale: scale, size: prefs.fontSize, family: prefs.fontFamily)
        if let r = renderer, let m = metalLayer {
            r.configure(m)
            m.isOpaque = false  // rounded sheet: the corners outside the mask must composite
            m.contentsScale = scale
            preeditLayer.contentsScale = scale
        }
        frameState?.invalidate()
        updateGrid()
        setNeedsRender()
    }

    private func layoutOverlays() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        focusRingLayer.frame = bounds
        edgeLayer.frame = bounds
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: PaneStripView.height)
        layoutFindCard()
        if readsSecret { layoutLock() }
        layoutSizeBadge()
        layoutEndedBar()
        // AppKit resets the backing layer's geometry when it attaches it, so
        // the sheet clip is (re)applied here rather than in makeBackingLayer.
        layer?.cornerRadius = Axo.Metric.sheetRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let dark = effectiveAppearance.isDark
        edgeLayer.borderWidth = dark ? 0 : hairline
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edgeLayer.borderColor = Axo.Color.border.cgColor
        }
        CATransaction.commit()
    }

    // MARK: Grid and viewport

    private func updateGrid() {
        guard let renderer, let m = metalLayer else { return }
        let scale = m.contentsScale
        let w = bounds.width * scale, h = bounds.height * scale
        m.drawableSize = CGSize(width: max(1, w.rounded()), height: max(1, h.rounded()))
        let f = renderer.font
        cellSize = (f.cellWidth, f.cellHeight)
        guard !gridFrozen else { return }
        let padX = Axo.Metric.panePaddingX * scale
        // Under a strip the rows start 6 pt below it instead of 10 below the edge.
        let top = showsStrip ? PaneStripView.height + 6 : Axo.Metric.panePaddingTop
        let padT = top * scale, padB = Axo.Metric.panePaddingBottom * scale
        let cols = max(2, Int((w - 2 * padX) / CGFloat(f.cellWidth)))
        let rows = max(1, Int((h - padT - padB) / CGFloat(f.cellHeight)))
        let leftX = max(0, w - 2 * padX - CGFloat(cols * f.cellWidth))
        origin = (Float((padX + (leftX / 2)).rounded(.down)), Float(padT.rounded(.down)))
        let before = grid
        grid = (cols, rows)
        if before.cols > 0, before != grid, window != nil { showSize() }
        scheduleViewport()
    }

    /// Tells the host our grid (applied if we drive this pane's size). Throttled
    /// to one message per 50 ms with a trailing send, so drags and live resizes
    /// cost a handful of SIGWINCHes rather than one per frame.
    private func scheduleViewport() {
        guard grid.cols > 0, !gridFrozen else { return }
        let v = (cols: grid.cols, rows: grid.rows, cw: cellSize.w, ch: cellSize.h)
        if let l = lastViewport, l == v { return }
        let now = CACurrentMediaTime()
        if now - lastViewportSend >= 0.05 {
            flushViewport()
        } else if viewportTimer == nil {
            viewportTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushViewport() }
            }
        }
    }

    func flushViewport() {
        viewportTimer?.invalidate()
        viewportTimer = nil
        guard grid.cols > 0, !gridFrozen else { return }
        lastViewport = (grid.cols, grid.rows, cellSize.w, cellSize.h)
        lastViewportSend = CACurrentMediaTime()
        connection.send(.viewport(pane, cols: UInt16(clamping: grid.cols), rows: UInt16(clamping: grid.rows),
                                  cellWidth: UInt16(clamping: cellSize.w), cellHeight: UInt16(clamping: cellSize.h)))
    }

    /// Makes this client the pane's size driver and re-sends the grid.
    func takeSize() {
        connection.send(.takeSize(pane))
        lastViewport = nil
        flushViewport()
    }

    // MARK: Rendering

    func setNeedsRender() {
        needsRender = true
        idleFrames = 0
        link?.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        render(link.targetTimestamp)
    }

    private var isCursorFocused: Bool {
        guard let window, window.isKeyWindow else { return false }
        return window.firstResponder === self
    }

    private func render(_ now: Double) {
        guard let renderer, let frameState, let m = metalLayer, bounds.width > 0, bounds.height > 0 else { return }
        let generation = mirror.generation
        let changed = generation != lastGeneration || needsRender
        var cursorInfo = frameState.cursor
        if changed {
            if generation != lastGeneration { checkPrediction() }
            updateFrame(frameState)
            renderer.prepare(frameState, selectionBackground: colors.selection)
            cursorInfo = frameState.cursor
            if generation != lastGeneration { cursor.noteActivity(now) }
            lastGeneration = generation
            needsRender = false
        }
        cursor.reduceMotion = Axo.Motion.reduced
        let out = cursor.frame(now, cursor: cursorInfo, focused: isCursorFocused)
        let cursorChanged = out.style != lastCursor
        guard changed || cursorChanged else {
            idleFrames += 1
            if idleFrames > 2, !out.animating { link?.isPaused = true }
            return
        }
        lastCursor = out.style
        idleFrames = 0
        link?.preferredFrameRateRange = out.blinkOnly
            ? CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30) : .default
        guard let drawable = m.nextDrawable() else {
            needsRender = true
            return
        }
        var p = DrawParams()
        p.origin = origin
        p.cursor = out.style
        p.cursorTextColor = colors.cursorText
        p.accent = colors.accent
        p.selectionBackground = colors.selection
        p.clearColor = colors.ground
        if !mirror.isReady || endedCode != nil { p.cursor.shape = nil }  // nothing to type to
        renderer.draw(frameState, to: drawable.texture, params: p, present: drawable)
        updatePreeditFrame()
    }

    private var lastCursor = CursorStyle()

    // MARK: Pane chrome (driven by the container)

    func setDimmed(_ dimmed: Bool, alpha: CGFloat, animated: Bool) {
        let target = Float(dimmed ? alpha : 0)
        guard dimLayer.opacity != target else { return }
        if animated, !Axo.Motion.reduced {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
            a.toValue = target
            a.duration = Axo.Motion.fadeIn.duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            dimLayer.add(a, forKey: "opacity")
        }
        dimLayer.opacity = target
    }

    /// Increase Contrast: the focused pane gets a 1 pt accent ring.
    func setFocusRing(_ on: Bool) {
        focusRingLayer.borderColor = Self.cg(colors.accent, alpha: 0.6)
        focusRingLayer.opacity = on ? 1 : 0
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            cursor.focusGained(CACurrentMediaTime())
            delegate?.terminalDidBecomeFocused(self)
            applySecureInput()
            if window?.isKeyWindow == true { reportFocus(true) }
            setNeedsRender()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            SecureInput.set(self, false)
            reportFocus(false)
            setNeedsRender()
        }
        return ok
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        applySecureInput()
        guard window?.firstResponder === self else { return }
        let key = note.name == NSWindow.didBecomeKeyNotification
        if key {
            cursor.focusGained(CACurrentMediaTime())
            takeSize()
        }
        reportFocus(key)
        setNeedsRender()
    }

    private var reportedFocus: Bool?

    private func reportFocus(_ on: Bool) {
        guard reportedFocus != on else { return }
        reportedFocus = on
        connection.send(.focus(pane, on))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // An ended pane has no program to type to: Return restarts it.
        if endedCode != nil, !event.modifierFlags.contains(.command) {
            if event.keyCode == 36 || event.keyCode == 76 { onRestart?() } else { NSSound.beep() }
            return
        }
        // A ⌘ chord no menu claimed is not terminal input (Terminal.app and
        // iTerm agree): the encoder has no legacy form for Super and would send
        // CSI-u that the shell prints as text ("15;5u"). Let it beep.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        let optionAlt = KeyTranslation.optionIsAlt(event, prefs.optionAsAlt)
        cursor.noteActivity(CACurrentMediaTime())
        // Control chords and Option-as-Alt bypass the input method: they are terminal
        // keys, not text, and AppKit would turn ⌃A into moveToBeginningOfParagraph:.
        if !hasMarkedText(), event.modifierFlags.contains(.control) || optionAlt {
            sendKey(event, action: event.isARepeat ? .repeat : .press,
                    text: KeyTranslation.text(event, optionAsAlt: optionAlt), optionAlt: optionAlt)
            return
        }
        let hadMarked = hasMarkedText()
        accumulator = []
        interpretKeyEvents([event])
        let committed = accumulator ?? []
        accumulator = nil
        if !committed.isEmpty {
            for text in committed {
                sendKey(event, action: event.isARepeat ? .repeat : .press, text: text, optionAlt: false)
            }
        } else if !hadMarked, !hasMarkedText() {
            sendKey(event, action: event.isARepeat ? .repeat : .press,
                    text: KeyTranslation.text(event, optionAsAlt: false), optionAlt: false)
        }
        updatePreedit()
    }

    override func keyUp(with event: NSEvent) {
        guard !hasMarkedText(), !event.modifierFlags.contains(.command) else { return }
        sendKey(event, action: .release, text: "", optionAlt: KeyTranslation.optionIsAlt(event, prefs.optionAsAlt))
    }

    override func flagsChanged(with event: NSEvent) {
        updateLinkHoverForModifiers(event.modifierFlags)
        guard !hasMarkedText(), let action = KeyTranslation.modifierAction(event) else { return }
        connection.send(.key(pane, KeyTranslation.input(event, action: action, text: "", optionAsAlt: false)))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        // ⌃⇥ / ⌃⇧⇥ switch sessions (menus cannot bind Tab chords reliably).
        if event.keyCode == 48, event.modifierFlags.contains(.control) {
            let sel = event.modifierFlags.contains(.shift)
                ? #selector((any AxActions).selectPreviousSession(_:)) : #selector((any AxActions).selectNextSession(_:))
            return NSApp.sendAction(sel, to: nil, from: self)
        }
        return super.performKeyEquivalent(with: event)
    }

    private func sendKey(_ event: NSEvent, action: KeyInput.Action, text: String, optionAlt: Bool) {
        let input = KeyTranslation.input(event, action: action, text: text, optionAsAlt: optionAlt)
        if action != .release {
            snapToBottom()
            NSCursor.setHiddenUntilMouseMoves(true)
            // Plain text, a bare ⌫, ← and → are guessed at; anything else
            // (Return, ↑ ↓, ⌃ and ⌥ chords) is the host's to answer before the next guess.
            let chord = optionAlt || !event.modifierFlags.intersection([.control, .command, .option, .shift]).isEmpty
            let plain = !optionAlt && event.modifierFlags.intersection([.control, .command]).isEmpty
                && !text.isEmpty && !text.unicodeScalars.contains { $0.properties.generalCategory == .control }
            if plain {
                predict(text)
            } else if !chord, event.keyCode == 51 {  // ⌫ (kVK_Delete): its text is the encoder's, not ours
                predictEdit { p, s, t in p.erased(on: s, at: t) }
            } else if !chord, event.keyCode == 123 || event.keyCode == 124 {  // ← →
                let dx = event.keyCode == 123 ? -1 : 1
                predictEdit { p, s, t in p.moved(by: dx, on: s, at: t) }
            } else {
                holdPrediction()
            }
        }
        connection.send(.key(pane, input))
    }

    // MARK: Local echo

    private static func clock() -> Duration { .seconds(CACurrentMediaTime()) }

    /// What the predictor reads off the mirror. Call inside `withTerminal`.
    private func echoScreen(_ t: VTTerminal) -> EchoPredictor.Screen {
        let c = t.cursor
        return EchoPredictor.Screen(cursorX: Int(c.x), cursorY: Int(c.y), cols: Int(t.cols), cursorVisible: c.visible,
                                    primary: t.activeScreen == .primary, atPrompt: t.cursorAtPrompt,
                                    // A scrolled-back view has no cursor line to draw guesses on.
                                    mouseTracking: t.mouseTracking, secret: readsSecret || t.isScrolledBack,
                                    suggested: { x, y in t.looksSuggested(atActiveX: x, y: y) }) { x, y in
            t.character(atActiveX: x, y: y)
        }
    }

    private func predict(_ text: String) {
        predictor.rtt = connection.rtt
        // This Mac, or a near one: the echo beats any guess; touch nothing.
        guard (predictor.rtt ?? .zero) >= EchoPredictor.minimumRTT || !predictor.guesses.isEmpty else { return }
        let now = Self.clock()
        let changed = mirror.withTerminal { t in predictor.typed(text, on: echoScreen(t), at: now) } ?? false
        if changed { showPrediction(now) }
    }

    /// ⌫ or an arrow: an edit of what this run typed, or the host's to answer.
    private func predictEdit(_ edit: (inout EchoPredictor, EchoPredictor.Screen, Duration) -> Bool) {
        predictor.rtt = connection.rtt
        let now = Self.clock()
        let changed = mirror.withTerminal { t in edit(&predictor, echoScreen(t), now) } ?? false
        if changed { showPrediction(now) }
    }

    /// Text that isn't a plain key (a paste, dictation, Return) went out.
    private func holdPrediction() {
        if predictor.interrupted(at: Self.clock()) { showPrediction(Self.clock()) }
    }

    /// The mirror changed: confirm or take back the guesses. Before a frame is built.
    private func checkPrediction() {
        let now = Self.clock()
        let changed = mirror.withTerminal { t in predictor.observed(echoScreen(t), at: now) } ?? false
        if changed { showPrediction(now, render: false) }
    }

    private func showPrediction(_ now: Duration, render: Bool = true) {
        guard let frameState else { return }
        let o = predictor.overlay(at: now)
        frameState.setOverlay(o.cells.map { (row: $0.y, col: $0.x, character: $0.character) }, marked: o.marked,
                              cursor: o.cursor)
        if render { setNeedsRender() }
        // An echo that never comes is a miss; a guess that waits past 250 ms
        // turns marked. Look again then, output or not.
        predictionTimer?.cancel()
        // (An arrow's guess may change no cell, only where the cursor is.)
        guard let deadline = predictor.nextDeadline, let first = predictor.oldestGuess else { return }
        let wake = min(deadline, o.marked ? deadline : first + EchoPredictor.markedAge)
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let t = Self.clock()
            predictor.tick(at: t)
            showPrediction(t)
        }
        predictionTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, (wake - now) / .seconds(1)) + 0.001, execute: w)
    }

    /// Typing returns a scrolled-back view to the live screen.
    private func snapToBottom() {
        let moved = mirror.withTerminal { t -> Bool in
            guard t.isScrolledBack else { return false }
            t.scrollViewport(.bottom)
            return true
        } ?? false
        if moved { mirror.touch() }
    }

    override func doCommand(by selector: Selector) {
        // Keys reach the terminal from keyDown; editing commands mean nothing here.
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        unmarkText()
        if accumulator != nil {
            accumulator?.append(text)
        } else if !text.isEmpty {
            // Outside keyDown (e.g. the emoji picker or dictation): send as typed text.
            holdPrediction()
            connection.send(.text(pane, text))
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            marked = NSMutableAttributedString(attributedString: s)
        } else {
            marked = NSMutableAttributedString(string: string as? String ?? "")
        }
        markedSelection = selectedRange
        updatePreedit()
    }

    func unmarkText() {
        marked = NSMutableAttributedString()
        updatePreedit()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.length > 0 ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        let r = convert(cursorRect(), to: nil)
        return window.convertToScreen(r)
    }

    /// The cursor cell in view points.
    private func cursorRect() -> NSRect {
        let scale = metalLayer?.contentsScale ?? 2
        let c = frameState?.cursor
        let x = (CGFloat(origin.x) + CGFloat((c?.x ?? 0) * cellSize.w)) / scale
        let y = (CGFloat(origin.y) + CGFloat((c?.y ?? 0) * cellSize.h)) / scale
        return NSRect(x: x, y: y, width: CGFloat(cellSize.w) / scale, height: CGFloat(cellSize.h) / scale)
    }

    private func updatePreedit() {
        preeditLayer.isHidden = marked.length == 0
        guard marked.length > 0 else { return }
        let font = Axo.Font.terminal(size: prefs.fontSize)
        let s = NSMutableAttributedString(string: marked.string, attributes: [
            .font: font, .foregroundColor: Axo.Color.text,
            .underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: NSColor(cgColor: Self.cg(colors.accent)) ?? .controlAccentColor,
        ])
        preeditLayer.string = s
        preeditLayer.backgroundColor = Self.cg(colors.ground)
        updatePreeditFrame()
    }

    private func updatePreeditFrame() {
        guard !preeditLayer.isHidden, let s = preeditLayer.string as? NSAttributedString else { return }
        let r = cursorRect()
        let size = s.size()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preeditLayer.frame = NSRect(x: r.minX, y: r.minY, width: ceil(size.width) + 2, height: max(r.height, ceil(size.height)))
        CATransaction.commit()
    }

    // MARK: Mouse

    private struct CellPoint {
        var col: Int
        var row: Int
        /// Pixels relative to the grid origin.
        var px: Double
        var py: Double
        /// Fractional cells (what the host wants for mouse reports).
        var fx: Double
        var fy: Double
    }

    private func cellPoint(_ event: NSEvent) -> CellPoint {
        let p = convert(event.locationInWindow, from: nil)
        let scale = Double(metalLayer?.contentsScale ?? 2)
        let px = Double(p.x) * scale - Double(origin.x), py = Double(p.y) * scale - Double(origin.y)
        let fx = px / Double(cellSize.w), fy = py / Double(cellSize.h)
        let cols = max(1, frameState?.cols ?? grid.cols), rows = max(1, frameState?.rows ?? grid.rows)
        return CellPoint(col: min(max(Int(fx.rounded(.down)), 0), cols - 1),
                         row: min(max(Int(fy.rounded(.down)), 0), rows - 1), px: px, py: py, fx: fx, fy: fy)
    }

    /// Mouse goes to the program when it tracks the mouse and Shift is not held.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.shift) else { return false }
        return mirror.withTerminal { $0.mouseTracking } ?? false
    }

    private func sendMouse(_ action: MouseInput.Action, button: UInt8, _ event: NSEvent) {
        let c = cellPoint(event)
        connection.send(.mouse(pane, MouseInput(action: action, button: button, mods: KeyTranslation.mods(event.modifierFlags),
                                                x: max(0, c.fx), y: max(0, c.fy))))
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let link = link(at: event) {
            if let far = linkContext.far, let found = link.found, case let .path(_, line, column) = link.target {
                LinkOpener.openFar(found, line: line, column: column, on: far)
            } else {
                LinkOpener.open(link.target, cwd: linkContext.cwd, local: linkContext.far == nil)
            }
            setHoveredLink(nil)
            return
        }
        // ⌘-clicked a far path before its host answered: open it when it does.
        if event.modifierFlags.contains(.command), let far = linkContext.far, LinkOpener.opensFar(far),
           case let .path(p, line, column)? = linkCandidate(atWindowPoint: event.locationInWindow),
           FarPaths.lookup(p, cwd: linkContext.cwd, on: far) == nil {
            let cwd = linkContext.cwd
            FarPaths.ask([p], cwd: cwd, on: far) {
                if case let .some(.some(there)) = FarPaths.lookup(p, cwd: cwd, on: far) {
                    LinkOpener.openFar(there, line: line, column: column, on: far)
                }
            }
            return
        }
        let wasFocused = delegate?.terminalIsFocusedPane(self) ?? true
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if wasFocused, reportsMouse(event) {
            mouseMode = .reporting
            pressedButtons.insert(1)
            sendMouse(.press, button: 1, event)
            return
        }
        mouseMode = .selecting
        let c = cellPoint(event)
        let time = UInt64(event.timestamp * 1e9)
        let interval = NSEvent.doubleClickInterval
        mirror.withTerminal { t in
            selection.repeatInterval = UInt64(interval * 1e9)
            selection.press(t, col: c.col, row: c.row, x: c.px, y: c.py, timeNanos: time)
        }
        mirror.touch()
    }

    override func mouseDragged(with event: NSEvent) {
        switch mouseMode {
        case .reporting:
            sendMouse(.motion, button: 1, event)
        case .selecting:
            let c = cellPoint(event)
            let h = UInt32(bounds.height * (metalLayer?.contentsScale ?? 2))
            let geo = VTSelectionGesture.Geometry(cellWidth: UInt32(cellSize.w), paddingLeft: UInt32(origin.x), screenHeight: h)
            let rect = event.modifierFlags.contains(.option)
            mirror.withTerminal { t in
                // Autoscroll while dragging past the top or bottom edge.
                if c.py < 0 { t.scrollViewport(.delta(-1)) }
                if c.py > Double(h) - Double(origin.y) { t.scrollViewport(.delta(1)) }
                selection.drag(t, col: c.col, row: c.row, x: c.px, y: c.py, geometry: geo, rectangle: rect)
            }
            mirror.touch()
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch mouseMode {
        case .reporting:
            pressedButtons.remove(1)
            sendMouse(.release, button: 1, event)
        case .selecting:
            let c = cellPoint(event)
            mirror.withTerminal { selection.release($0, col: c.col, row: c.row) }
            mirror.touch()
        case .none:
            break
        }
        mouseMode = .none
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event), delegate?.terminalIsFocusedPane(self) ?? true {
            pressedButtons.insert(2)
            sendMouse(.press, button: 2, event)
            return
        }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if pressedButtons.remove(2) != nil { sendMouse(.release, button: 2, event) } else { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, reportsMouse(event) else { return }
        pressedButtons.insert(3)
        sendMouse(.press, button: 3, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        if pressedButtons.remove(3) != nil { sendMouse(.release, button: 3, event) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        if pressedButtons.contains(2) { sendMouse(.motion, button: 2, event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if pressedButtons.contains(3) { sendMouse(.motion, button: 3, event) }
    }

    override func mouseMoved(with event: NSEvent) {
        updateLinkHover(event)
        if reportsMouse(event), delegate?.terminalIsFocusedPane(self) ?? false { sendMouse(.motion, button: 0, event) }
    }

    override func mouseExited(with event: NSEvent) { setHoveredLink(nil) }

    // MARK: Size while resizing

    private var sizeBadge: SizeBadge?

    private func showSize() { badge.show(cols: grid.cols, rows: grid.rows); layoutSizeBadge() }

    private var badge: SizeBadge {
        if let b = sizeBadge { return b }
        let b = SizeBadge()
        addSubview(b)
        sizeBadge = b
        return b
    }

    // MARK: Ended

    /// The program's exit code once it has ended (nil while it runs).
    var endedCode: Int32? {
        didSet {
            guard endedCode != oldValue else { return }
            if let code = endedCode {
                let bar = endedBar ?? {
                    let b = EndedBar()
                    b.onRestart = { [weak self] in self?.onRestart?() }
                    addSubview(b)
                    endedBar = b
                    return b
                }()
                bar.set(code: code)
                layoutEndedBar()
                setNeedsRender()
                bar.alphaValue = 0
                Axo.Motion.run(Axo.Motion.tick) { bar.animator().alphaValue = 1 }
            } else {
                endedBar?.removeFromSuperview()
                endedBar = nil
            }
        }
    }

    var onRestart: (() -> Void)?
    private var endedBar: EndedBar?

    private func layoutEndedBar() {
        guard let b = endedBar else { return }
        let w = min(b.preferredWidth, bounds.width - 24), h = EndedBar.height
        b.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: bounds.height - 12 - h, width: w, height: h)
    }

    // MARK: Command blocks (OSC 133)

    @objc func previousPrompt(_ sender: Any?) {
        mirror.withTerminal { $0.scrollViewport(.prompts(-1)) }
        mirror.touch()
    }

    @objc func nextPrompt(_ sender: Any?) {
        mirror.withTerminal { $0.scrollViewport(.prompts(1)) }
        mirror.touch()
    }

    private func layoutSizeBadge() {
        guard let b = sizeBadge else { return }
        let w = b.preferredWidth, h = SizeBadge.height
        b.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }

    // MARK: Secure input

    /// The program is reading a password: keys are kept from other apps
    /// (Secure Keyboard Entry) while this pane has focus, and a lock says so.
    var readsSecret = false {
        didSet { if readsSecret != oldValue { applySecureInput() } }
    }

    private lazy var lock: Symbol = {
        let s = Symbol("lock.fill", size: 11, weight: .semibold, color: Axo.Color.textTertiary)
        s.toolTip = "Secure Keyboard Entry: other apps can’t read what you type here"
        s.setAccessibilityLabel("Secure Keyboard Entry on")
        addSubview(s)
        return s
    }()

    func applySecureInput() {
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        SecureInput.set(self, readsSecret && focused)
        if readsSecret || lock.superview != nil {
            lock.isHidden = !readsSecret
            layoutLock()
        }
    }

    private func layoutLock() {
        let top = (showsStrip ? PaneStripView.height : 0) + 8
        lock.frame = NSRect(x: bounds.width - Axo.Metric.panePaddingX - 12, y: top, width: 12, height: 14)
    }

    // MARK: Links

    /// Where relative paths resolve, and on which Mac.
    var linkContext = LinkContext()

    private struct HoveredLink: Equatable {
        var runs: [VTSearch.Run]
        var target: TerminalLinks.Target
        /// A far pane's path, as its host found it.
        var found: HostPath?
    }

    private var hoveredLink: HoveredLink?
    private let linkLayer = CALayer()

    /// The link under the pointer: an OSC 8 hyperlink, else a URL or an
    /// existing path in the text (its logical line, across soft wraps).
    private func link(at event: NSEvent) -> HoveredLink? { link(atWindowPoint: event.locationInWindow) }

    /// The link text under a point, before checking it opens.
    private func linkCandidate(atWindowPoint wp: NSPoint) -> TerminalLinks.Target? {
        guard let (line, at) = lineAndCell(atWindowPoint: wp) else { return nil }
        return TerminalLinks.link(in: line.text, at: at)?.target
    }

    private func lineAndCell(atWindowPoint wp: NSPoint) -> (VTLine, Int)? {
        let p = convert(wp, from: nil)
        guard bounds.contains(p), cellSize.w > 0 else { return nil }
        let scale = Double(metalLayer?.contentsScale ?? 2)
        let px = Double(p.x) * scale - Double(origin.x), py = Double(p.y) * scale - Double(origin.y)
        guard px >= 0, py >= 0 else { return nil }
        let col = Int(px / Double(cellSize.w)), row = Int(py / Double(cellSize.h))
        guard let line = mirror.withTerminal({ $0.line(atViewportRow: row) }) ?? nil,
              let at = line.cells.firstIndex(where: { $0.row == row && $0.col == col })
        else { return nil }
        return (line, at)
    }

    private func link(atWindowPoint wp: NSPoint) -> HoveredLink? {
        guard let (line, at) = lineAndCell(atWindowPoint: wp) else { return nil }
        let ctx = linkContext
        // OSC 8 first: the program said exactly what this text points to.
        if let uri = line.uris[at], let url = URL(string: uri) {
            var lo = at, hi = at
            while lo > 0, line.uris[lo - 1] == uri { lo -= 1 }
            while hi + 1 < line.uris.count, line.uris[hi + 1] == uri { hi += 1 }
            return HoveredLink(runs: Self.runs(line, lo ..< hi + 1), target: .url(url))
        }
        guard let found = TerminalLinks.link(in: line.text, at: at) else { return nil }
        // A far pane's path underlines once its host says it is there.
        if let far = ctx.far, case let .path(p, _, _) = found.target {
            guard LinkOpener.opensFar(far) else { return nil }
            switch FarPaths.lookup(p, cwd: ctx.cwd, on: far) {
            case let .some(.some(there)):
                return HoveredLink(runs: Self.runs(line, found.range), target: found.target, found: there)
            case .some(.none):
                return nil
            case .none:
                askFarPaths(also: p)
                return nil
            }
        }
        guard LinkOpener.canOpen(found.target, cwd: ctx.cwd, local: ctx.far == nil) else { return nil }
        return HoveredLink(runs: Self.runs(line, found.range), target: found.target)
    }

    /// Asks a far pane's host, in one go, about every path on the screen, and
    /// shows the link under the pointer when the answer comes.
    private func askFarPaths(also extra: String? = nil) {
        let ctx = linkContext
        guard let far = ctx.far, LinkOpener.opensFar(far) else { return }
        var candidates = mirror.withTerminal { t -> [String] in
            var texts = Set<String>(), out: [String] = []
            for row in 0 ..< Int(t.rows) {
                guard let line = t.line(atViewportRow: row), texts.insert(line.text).inserted else { continue }
                for l in TerminalLinks.find(in: line.text) { if case let .path(p, _, _) = l.target { out.append(p) } }
            }
            return out
        } ?? []
        if let extra { candidates.insert(extra, at: 0) }
        FarPaths.ask(candidates, cwd: ctx.cwd, on: far) { [weak self] in
            guard let self, NSEvent.modifierFlags.contains(.command) else { return }
            updateLinkHoverForModifiers(NSEvent.modifierFlags)
        }
    }

    private static func runs(_ line: VTLine, _ range: Range<Int>) -> [VTSearch.Run] {
        var out: [VTSearch.Run] = []
        for i in range {
            let c = line.cells[i]
            if let last = out.last, last.row == c.row, last.to + 1 == c.col {
                out[out.count - 1].to = c.col
            } else {
                out.append(VTSearch.Run(row: c.row, from: c.col, to: c.col, selected: false))
            }
        }
        return out
    }

    private func updateLinkHover(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command), mouseMode == .none else { return setHoveredLink(nil) }
        setHoveredLink(link(at: event))
    }

    /// ⌘ pressed or released over the view: show or drop the link under the pointer.
    private func updateLinkHoverForModifiers(_ flags: NSEvent.ModifierFlags) {
        guard flags.contains(.command), mouseMode == .none, let window else { return setHoveredLink(nil) }
        if hoveredLink == nil, linkContext.far != nil { askFarPaths() }
        setHoveredLink(link(atWindowPoint: window.mouseLocationOutsideOfEventStream))
    }

    /// Underlines the link in the accent and turns the pointer into a hand.
    private func setHoveredLink(_ link: HoveredLink?) {
        guard link != hoveredLink else { return }
        hoveredLink = link
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        linkLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if linkLayer.superlayer == nil, let layer {
            linkLayer.zPosition = 5
            layer.addSublayer(linkLayer)
        }
        linkLayer.frame = bounds
        if let link {
            let scale = metalLayer?.contentsScale ?? 2
            let cw = CGFloat(cellSize.w) / scale, ch = CGFloat(cellSize.h) / scale
            let ox = CGFloat(origin.x) / scale, oy = CGFloat(origin.y) / scale
            let color = colors.foreground.cgColor
            for r in link.runs {
                let line = CALayer()
                line.backgroundColor = color
                // Rows grow downward (flipped); the underline sits at the cell's foot.
                let y = oy + CGFloat(r.row + 1) * ch - 2
                line.frame = CGRect(x: ox + CGFloat(r.from) * cw, y: y, width: CGFloat(r.to - r.from + 1) * cw, height: 1)
                linkLayer.addSublayer(line)
            }
            NSCursor.pointingHand.set()
        } else {
            NSCursor.iBeam.set()
        }
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func scrollWheel(with event: NSEvent) {
        var dy = Double(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            dy /= Double(cellSize.h) / Double(metalLayer?.contentsScale ?? 2)
        } else {
            dy *= 3
        }
        if event.phase == .began || event.phase == .mayBegin { scrollRemainder = 0 }
        scrollRemainder += dy
        let rows = Int(scrollRemainder.rounded(.towardZero))
        guard rows != 0 else { return }
        scrollRemainder -= Double(rows)

        if reportsMouse(event) {
            let button: UInt8 = rows > 0 ? 4 : 5
            for _ in 0 ..< min(abs(rows), 10) { sendMouse(.press, button: button, event) }
            return
        }
        let alternate = mirror.withTerminal { $0.activeScreen == .alternate } ?? false
        if alternate {
            // Alternate-scroll (mode 1007): wheel becomes arrow keys for pagers and editors.
            let code: UInt16 = rows > 0 ? 126 : 125
            for _ in 0 ..< min(abs(rows), 10) {
                connection.send(.key(pane, KeyInput(action: .press, key: VTKeys.mac(code))))
            }
            return
        }
        mirror.withTerminal { $0.scrollViewport(.delta(-rows)) }
        mirror.touch()
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if reportsMouse(event) { return nil }
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        item("Copy", #selector(copy(_:)))
        item("Paste", #selector(paste(_:)))
        menu.addItem(.separator())
        item("Split Right", #selector((any AxActions).splitRight(_:)))
        item("Split Down", #selector((any AxActions).splitDown(_:)))
        menu.addItem(.separator())
        item("Clear Buffer", #selector((any AxActions).clearBuffer(_:)))
        item("Close Pane", #selector((any AxActions).closePane(_:)))
        return menu
    }

    // MARK: Edit actions

    @objc func copy(_ sender: Any?) {
        guard let text = mirror.withTerminal({ $0.selectionText(.plain) }) ?? nil, !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        if let html = mirror.withTerminal({ $0.selectionText(.html) }) ?? nil { pb.setString(html, forType: .html) }
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        pasteText(text)
    }

    private func pasteText(_ text: String) {
        let bracketed = mirror.withTerminal { $0.mode(2004) } ?? false
        if !bracketed, VTInputEncoder.pasteIsUnsafe(text) {
            let alert = NSAlert()
            alert.messageText = "Paste text that may run commands?"
            alert.informativeText = "The text contains line breaks or control characters, and the program is not in bracketed-paste mode, so it may run as soon as it is pasted."
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn, let self else { return }
                self.snapToBottom()
                self.connection.send(.paste(self.pane, text))
            }
            return
        }
        snapToBottom()
        holdPrediction()
        connection.send(.paste(pane, text))
    }

    @objc override func selectAll(_ sender: Any?) {
        mirror.withTerminal { $0.selectAll() }
        mirror.touch()
    }

    @objc func scrollToTopOfBuffer(_ sender: Any?) {
        mirror.withTerminal { $0.scrollViewport(.top) }
        mirror.touch()
    }

    @objc func scrollToBottomOfBuffer(_ sender: Any?) {
        mirror.withTerminal { $0.scrollViewport(.bottom) }
        mirror.touch()
    }

    @objc func clearBuffer(_ sender: Any?) {
        connection.send(.clear(pane))
    }

    // MARK: Find

    private(set) var findCard: FindCard?
    /// The last needle, kept after closing so ⌘G resumes it.
    private var findNeedle = ""

    /// Copies the terminal into the frame and, while finding, paints the
    /// visible matches under the text and updates the card's count.
    private func updateFrame(_ frameState: TerminalFrame) {
        guard let card = findCard, !findNeedle.isEmpty else {
            mirror.withTerminal { frameState.update(from: $0) }
            frameState.setHighlights([])
            findCard?.show(total: 0, index: nil)
            return
        }
        let found = mirror.withSearch(findNeedle) { t, search in
            frameState.update(from: t)
            return (search.visibleRuns(rows: Int(t.rows), cols: Int(t.cols)), search.total, search.selectedIndex)
        }
        guard let (runs, total, index) = found else { return }
        frameState.setHighlights(runs.map {
            TerminalFrame.Highlight(row: $0.row, from: $0.from, to: $0.to,
                                    color: $0.selected ? colors.findCurrent : colors.findMatch)
        })
        card.show(total: total, index: index)
    }

    /// ⌘F: opens the card (or focuses it), seeded with a one-line selection.
    @objc func showFind(_ sender: Any?) {
        if let sel = mirror.withTerminal({ $0.selectionText(.plain) }) ?? nil,
           !sel.isEmpty, !sel.contains("\n"), sel.count <= 200
        {
            findNeedle = sel
        }
        let card = findCard ?? makeFindCard()
        card.needle = findNeedle
        layoutFindCard()
        card.focus()
        if !findNeedle.isEmpty { step(older: true, fromStart: true) }
        setNeedsRender()
    }

    @objc func findNext(_ sender: Any?) { findStep(older: true) }
    @objc func findPrevious(_ sender: Any?) { findStep(older: false) }

    private func findStep(older: Bool) {
        guard !findNeedle.isEmpty else { return showFind(nil) }
        if findCard == nil {
            makeFindCard().needle = findNeedle
            layoutFindCard()
        }
        step(older: older, fromStart: false)
    }

    private func step(older: Bool, fromStart: Bool) {
        let covered = rowsUnderFindCard
        _ = mirror.withSearch(findNeedle) { t, search in
            // A fresh needle starts at the newest match (nearest the prompt).
            if fromStart, search.selectedIndex != nil { return }
            search.select(older: older)
            // The search scrolls a match just into view, which can be the top
            // row, under the card: bring it a third of the way down instead.
            let rows = Int(t.rows)
            if let row = search.visibleRuns(rows: rows, cols: Int(t.cols)).first(where: \.selected)?.row, row < covered {
                t.scrollViewport(.delta(row - max(covered, rows / 3)))
            }
        }
        mirror.touch()
        setNeedsRender()
    }

    /// Terminal rows the find card hides (0 when closed).
    private var rowsUnderFindCard: Int {
        guard let card = findCard, cellSize.h > 0 else { return 0 }
        let scale = metalLayer?.contentsScale ?? 2
        let bottom = (card.frame.maxY + 4) * scale - CGFloat(origin.y)
        return max(0, Int(ceil(bottom / CGFloat(cellSize.h))))
    }

    @objc func closeFind(_ sender: Any?) {
        guard let card = findCard else { return }
        let hadFocus = window?.firstResponder === card.field.currentEditor() || window?.firstResponder === card.field
        card.removeFromSuperview()
        findCard = nil
        mirror.endSearch()
        frameState?.setHighlights([])
        setNeedsRender()
        if hadFocus { window?.makeFirstResponder(self) }
    }

    private func makeFindCard() -> FindCard {
        let card = FindCard()
        card.onChange = { [weak self] text in
            guard let self else { return }
            findNeedle = text
            if !text.isEmpty { step(older: true, fromStart: true) }
            setNeedsRender()
        }
        card.onStep = { [weak self] older in self?.findStep(older: older) }
        card.onClose = { [weak self] in self?.closeFind(nil) }
        addSubview(card)
        findCard = card
        return card
    }

    /// Top-right, inset like a sheet, below the pane strip when one shows.
    private func layoutFindCard() {
        guard let card = findCard else { return }
        let size = FindCard.size
        let top = (showsStrip ? PaneStripView.height : 0) + 8
        let width = min(size.width, bounds.width - 16)
        card.frame = NSRect(x: (bounds.width - 8 - width).rounded(), y: top, width: width, height: size.height)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return mirror.withTerminal { $0.hasSelection } ?? false
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return !findNeedle.isEmpty
        case #selector(closeFind(_:)):
            return findCard != nil
        default:
            return true
        }
    }

    // MARK: Drag and drop (files paste as shell-quoted paths)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty
        {
            let quoted = urls.map { Self.shellQuote($0.path(percentEncoded: false)) }.joined(separator: " ")
            connection.send(.paste(pane, quoted + " "))
            return true
        }
        if let s = pb.string(forType: .string) {
            pasteText(s)
            return true
        }
        return false
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,~".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Accessibility

    override func accessibilityValue() -> Any? {
        mirror.withTerminal { $0.text(.plain) }
    }
}

/// Coalesces mirror change notifications into one main-actor hop.
private final class WakeFlag: Sendable {
    let pending = Atomic<Bool>(false)
}
