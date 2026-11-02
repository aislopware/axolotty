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
    private let progressLine = ProgressLine()
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
        progressLine.layer.zPosition = 10  // over the strip: the two read as one header
        layer?.addSublayer(progressLine.layer)

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
        layoutPill()
        layoutSizeBadge()
        layoutEndedBar()
        progressLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: ProgressLine.height)
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
        if before != grid, copy != nil { endCopyMode(keepSelection: false) }  // its rows moved
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
            updateFrame(frameState)
            renderer.prepare(frameState, selectionBackground: colors.selection)
            cursorInfo = frameState.cursor
            if generation != lastGeneration { cursor.noteActivity(now) }
            lastGeneration = generation
            needsRender = false
        }
        cursor.preferred = switch prefs.cursorShape {
        case .bar: .bar
        case .block: .block
        case .underline: .underline
        }
        cursor.blinkEnabled = prefs.cursorBlink
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

    /// OSC 9;4 as the program reported it (see `ProgressLine`).
    func setProgress(_ value: Int?, tone: ProgressTone?) {
        progressLine.set(value, tone: tone, appearance: effectiveAppearance)
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
        if hints != nil, !event.modifierFlags.contains(.command) {
            quickSelectKey(event)
            return
        }
        if copy != nil, !event.modifierFlags.contains(.command) {
            copyModeKey(event)
            return
        }
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
        }
        connection.send(.key(pane, input))
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
        if hints != nil { endQuickSelect() }
        if copy != nil { endCopyMode(keepSelection: false) }
        if event.modifierFlags.contains(.command), let link = link(at: event) {
            LinkOpener.open(link.target, cwd: linkContext.cwd, local: linkContext.local)
            setHoveredLink(nil)
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
            if prefs.copyOnSelect, let text = mirror.withTerminal({ $0.selectionText(.plain) }) ?? nil, !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
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

    // MARK: New output below

    private var pill: NewOutputPill?
    /// Scrollback length when the person scrolled away from the bottom.
    private var readingFrom: Int?

    /// While scrolled back, counts the lines that arrived below (rows pushed
    /// into scrollback since) and shows the pill; at the bottom, hides it.
    private func updateNewOutput() {
        guard let (back, rows) = mirror.withTerminal({ ($0.isScrolledBack, $0.scrollbackRows) }) else { return }
        guard back else {
            readingFrom = nil
            if let pill { hidePill(pill) }
            return
        }
        let base = readingFrom ?? rows
        readingFrom = base
        let fresh = rows - base
        guard fresh > 0 else {
            if fresh < 0 { readingFrom = rows }  // scrollback was pruned or cleared
            return
        }
        let p = pill ?? makePill()
        p.set(lines: fresh)
        layoutPill()
        if p.isHidden || p.alphaValue < 1 {
            p.isHidden = false
            Axo.Motion.run(Axo.Motion.Beat(duration: 0.16, curve: Axo.Motion.easeOut)) { p.animator().alphaValue = 1 }
        }
    }

    private func makePill() -> NewOutputPill {
        let p = NewOutputPill()
        p.alphaValue = 0
        p.onClick = { [weak self] in
            self?.scrollToBottomOfBuffer(nil)
            self?.window?.makeFirstResponder(self)
        }
        addSubview(p)
        pill = p
        return p
    }

    private func hidePill(_ p: NewOutputPill) {
        guard !p.isHidden else { return }
        Axo.Motion.run(Axo.Motion.tickOut, { p.animator().alphaValue = 0 }) { [weak p] in
            if p?.alphaValue == 0 { p?.isHidden = true }
        }
    }

    private func layoutPill() {
        guard let p = pill else { return }
        let w = p.preferredWidth, h = NewOutputPill.height
        p.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: bounds.height - 10 - h, width: w, height: h)
    }

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

    /// The latest command's output to the pasteboard; a badge says how much.
    @objc func copyLastOutput(_ sender: Any?) {
        guard let text = mirror.withTerminal({ $0.lastCommandOutput() }) ?? nil else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
        badge.show(n == 1 ? "Copied 1 line" : "Copied \(n) lines", for: 1.1)
        layoutSizeBadge()
    }

    // MARK: Quick select

    /// One labelled thing on screen.
    private struct Hint {
        var label: String
        var runs: [VTSearch.Run]
        var hit: TerminalHints.Hit
    }

    private var hints: [Hint]?
    private var hintTyped = ""
    private let hintLayer = CALayer()

    /// ⇧⌘Space: every URL, path, hash and address on screen gets a label;
    /// typing it copies the text, typing it in capitals opens it. The
    /// nearest (lowest) thing gets the shortest, home-row label. Esc leaves.
    @objc func quickSelect(_ sender: Any?) {
        if hints != nil { return endQuickSelect() }
        var found: [(TerminalHints.Hit, [VTSearch.Run])] = []
        var row = 0
        while row < grid.rows {
            guard let line = mirror.withTerminal({ $0.line(atViewportRow: row) }) ?? nil, !line.cells.isEmpty else {
                row += 1
                continue
            }
            for h in TerminalHints.find(in: line.text) {
                let runs = Self.runs(line, h.range).filter { $0.row >= 0 && $0.row < grid.rows }
                if !runs.isEmpty { found.append((h, runs)) }
            }
            row = max(row + 1, (line.cells.last?.row ?? row) + 1)
        }
        guard !found.isEmpty else {
            badge.show("Nothing to select", for: 0.9)
            layoutSizeBadge()
            return
        }
        let labels = TerminalHints.labels(found.count)
        hints = found.reversed().enumerated().map { i, f in Hint(label: labels[i], runs: f.1, hit: f.0) }
        hintTyped = ""
        drawHints()
    }

    private func endQuickSelect() {
        hints = nil
        hintTyped = ""
        hintLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        hintLayer.removeFromSuperlayer()
    }

    private func quickSelectKey(_ event: NSEvent) {
        guard let all = hints else { return }
        if event.keyCode == 53 { return endQuickSelect() }  // esc
        if event.keyCode == 51 {  // delete
            if hintTyped.isEmpty { return endQuickSelect() }
            hintTyped.removeLast()
            return drawHints()
        }
        guard let ch = event.charactersIgnoringModifiers, ch.count == 1, ch.first?.isLetter == true else {
            NSSound.beep()
            return
        }
        let open = event.modifierFlags.contains(.shift)
        hintTyped += ch.lowercased()
        let left = all.filter { $0.label.hasPrefix(hintTyped) }
        guard !left.isEmpty else {
            hintTyped.removeLast()
            NSSound.beep()
            return
        }
        guard left.count == 1, let hint = left.first, hint.label == hintTyped else { return drawHints() }
        endQuickSelect()
        let ctx = linkContext
        if open, let target = hint.hit.target, LinkOpener.open(target, cwd: ctx.cwd, local: ctx.local) { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint.hit.text, forType: .string)
        badge.show("Copied", for: 0.8)
        layoutSizeBadge()
    }

    /// Each hit underlined in the accent, its label on a plate of the
    /// accent over its first cells (the text under it stays readable to its
    /// right). Labels that no longer match what was typed go away.
    private func drawHints() {
        guard let hints, let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hintLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        if hintLayer.superlayer == nil {
            hintLayer.zPosition = 6
            layer.addSublayer(hintLayer)
        }
        hintLayer.frame = bounds
        let scale = metalLayer?.contentsScale ?? 2
        let cw = CGFloat(cellSize.w) / scale, ch = CGFloat(cellSize.h) / scale
        let ox = CGFloat(origin.x) / scale, oy = CGFloat(origin.y) / scale
        let accent = Self.cg(colors.accent)
        let ink = Self.cg(colors.cursorText)
        let font = NSFont.monospacedSystemFont(ofSize: max(9, ch * 0.62), weight: .bold)
        for h in hints where h.label.hasPrefix(hintTyped) {
            for r in h.runs {
                let u = CALayer()
                u.backgroundColor = accent
                u.frame = CGRect(x: ox + CGFloat(r.from) * cw, y: oy + CGFloat(r.row + 1) * ch - 2,
                                 width: CGFloat(r.to - r.from + 1) * cw, height: 1)
                hintLayer.addSublayer(u)
            }
            guard let first = h.runs.first else { continue }
            let rest = String(h.label.dropFirst(hintTyped.count))
            let w = max(cw * CGFloat(rest.count), cw) + 4
            let plate = CALayer()
            plate.backgroundColor = accent
            plate.cornerRadius = 3
            plate.cornerCurve = .continuous
            plate.frame = CGRect(x: ox + CGFloat(first.from) * cw - 1, y: oy + CGFloat(first.row) * ch + 1, width: w, height: ch - 2)
            // CATextLayer draws from its top: centre the line in the plate.
            let textH = ceil(font.ascender - font.descender)
            let text = CATextLayer()
            text.string = NSAttributedString(string: rest.uppercased(), attributes: [
                .font: font, .foregroundColor: NSColor(cgColor: ink) ?? .black,
            ])
            text.alignmentMode = .center
            text.contentsScale = scale
            text.frame = CGRect(x: 0, y: max(0, (ch - 2 - textH) / 2).rounded(), width: w, height: textH)
            plate.addSublayer(text)
            hintLayer.addSublayer(plate)
        }
        CATransaction.commit()
    }

    // MARK: Copy mode

    /// Keyboard selection (⇧⌘X): a cursor in screen coordinates (row 0 is
    /// the oldest scrollback row), and where a selection started.
    private struct CopyState {
        var col: Int
        var row: Int
        var anchor: (col: Int, row: Int)?
        enum Kind { case chars, lines, block }
        var kind = Kind.chars
    }

    private var copy: CopyState?
    private let copyCursor = CALayer()
    /// Says the pane is in copy mode for as long as it is (keys don't reach
    /// the program), what a selection would take, and where in the history
    /// the cursor is.
    private let copyTag = CALayer()
    private let copyTagText = CATextLayer()

    /// Enters at the terminal's cursor. Keys are vi's: h j k l (and arrows),
    /// w b e, 0 ^ $, g G, H M L, ⌃u ⌃d, v V ⌃v to select, y or ↩ to copy,
    /// Esc or q to leave. Nothing reaches the program meanwhile.
    @objc func copyMode(_ sender: Any?) {
        if copy != nil { return endCopyMode(keepSelection: false) }
        endQuickSelect()
        guard let start = mirror.withTerminal({ t -> CopyState in
            let pos = t.scrollPosition
            let c = t.cursor
            return CopyState(col: Int(c.x), row: pos.total - Int(t.rows) + Int(c.y))
        }) else { return }
        copy = start
        badge.show("v to select · y to copy · esc to leave", for: 1.6)
        layoutSizeBadge()
        updateCopyMode()
        // Entered from the menu, the run loop may not turn until the next
        // event; show the cursor now.
        CATransaction.flush()
    }

    private func endCopyMode(keepSelection: Bool) {
        copy = nil
        copyCursor.removeFromSuperlayer()
        copyTag.removeFromSuperlayer()
        if !keepSelection { mirror.withTerminal { $0.clearSelection() } }
        mirror.withTerminal { $0.scrollViewport(.bottom) }
        mirror.touch()
        setNeedsRender()
    }

    private func copyModeKey(_ event: NSEvent) {
        guard var c = copy else { return }
        let ctrl = event.modifierFlags.contains(.control)
        let key = event.charactersIgnoringModifiers ?? ""
        let rows = max(1, grid.rows), cols = max(1, grid.cols)
        let (total, top) = mirror.withTerminal { t in (t.scrollPosition.total, t.scrollPosition.offset) } ?? (rows, 0)
        func rowText(_ screenRow: Int) -> [Character] {
            let vr = screenRow - top
            guard vr >= 0, vr < rows, let line = mirror.withTerminal({ $0.line(atViewportRow: vr) }) ?? nil else { return [] }
            var chars = [Character](repeating: " ", count: cols)
            for (i, cell) in line.cells.enumerated() where cell.row == vr && cell.col < cols {
                chars[cell.col] = Array(line.text)[i]
            }
            return chars
        }
        func isWord(_ ch: Character) -> Bool { ch.isLetter || ch.isNumber || ch == "_" }
        switch event.keyCode {
        case 53: return endCopyMode(keepSelection: false)  // esc
        case 36, 76: return finishCopy(c)  // return
        case 123: c.col -= 1
        case 124: c.col += 1
        case 126: c.row -= 1
        case 125: c.row += 1
        default:
            switch (ctrl, key) {
            case (true, "u"): c.row -= rows / 2
            case (true, "d"): c.row += rows / 2
            case (true, "v"): toggle(&c, .block)
            case (false, "h"): c.col -= 1
            case (false, "l"): c.col += 1
            case (false, "k"): c.row -= 1
            case (false, "j"): c.row += 1
            case (false, "0"): c.col = 0
            case (false, "^"): c.col = rowText(c.row).firstIndex { $0 != " " } ?? 0
            case (false, "$"): c.col = (rowText(c.row).lastIndex { $0 != " " } ?? 0)
            case (false, "g"): c.row = 0
            case (false, "G"): c.row = total - 1
            case (false, "H"): c.row = top
            case (false, "M"): c.row = top + rows / 2
            case (false, "L"): c.row = top + rows - 1
            case (false, "w"), (false, "e"), (false, "b"):
                // Words run across line ends, as in vi: the motion walks
                // (row, col) pairs over the screen, rows read on demand.
                var row = c.row, col = c.col, t = rowText(row)
                func at(_ r: Int, _ i: Int) -> Bool { i >= 0 && i < t.count && isWord(t[i]) }
                func step(_ d: Int) -> Bool {
                    col += d
                    if col >= cols {
                        guard row + 1 < total, row + 1 < top + rows else { col = cols - 1; return false }
                        row += 1; col = 0; t = rowText(row)
                    } else if col < 0 {
                        guard row > 0, row - 1 >= top else { col = 0; return false }
                        row -= 1; col = cols - 1; t = rowText(row)
                    }
                    return true
                }
                switch key {
                case "w":
                    while at(row, col), step(1) {}
                    while !at(row, col), step(1) {}
                case "e":
                    _ = step(1)
                    while !at(row, col), step(1) {}
                    while col + 1 < t.count, isWord(t[col + 1]) { col += 1 }
                default:
                    _ = step(-1)
                    while !at(row, col), step(-1) {}
                    while col > 0, at(row, col - 1) { col -= 1 }
                }
                c.row = row
                c.col = col
            case (false, "v"): toggle(&c, .chars)
            case (false, "V"): toggle(&c, .lines)
            case (false, "y"): return finishCopy(c)
            case (false, "q"): return endCopyMode(keepSelection: false)
            default: return NSSound.beep()
            }
        }
        c.col = max(0, min(c.col, cols - 1))
        c.row = max(0, min(c.row, total - 1))
        copy = c
        updateCopyMode()
    }

    /// v / V / ⌃v start a selection of that kind; the same key again drops it.
    private func toggle(_ c: inout CopyState, _ kind: CopyState.Kind) {
        if c.anchor != nil, c.kind == kind {
            c.anchor = nil
        } else {
            if c.anchor == nil { c.anchor = (c.col, c.row) }
            c.kind = kind
        }
    }

    private func finishCopy(_ c: CopyState) {
        var state = c
        if state.anchor == nil {  // nothing selected: copy the cursor's line
            state.anchor = (0, c.row)
            state.kind = .lines
            copy = state
            updateCopyMode()
        }
        let text = mirror.withTerminal { $0.selectionText(.plain) } ?? nil
        endCopyMode(keepSelection: false)
        guard let text, !text.isEmpty else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let n = text.split(separator: "\n", omittingEmptySubsequences: false).count
        badge.show(n == 1 ? "Copied" : "Copied \(n) lines", for: 0.9)
        layoutSizeBadge()
    }

    /// Scrolls the cursor into view, installs the selection, and draws the
    /// cursor as an accent outline over its cell.
    private func updateCopyMode() {
        guard let c = copy, let layer else { return }
        let rows = max(1, grid.rows), cols = max(1, grid.cols)
        mirror.withTerminal { t in
            let top = t.scrollPosition.offset
            if c.row < top { t.scrollViewport(.delta(c.row - top)) }
            if c.row >= top + rows { t.scrollViewport(.delta(c.row - (top + rows - 1))) }
            if let a = c.anchor {
                switch c.kind {
                case .chars: t.select(screen: a, (c.col, c.row))
                case .lines:
                    let (r0, r1) = a.row <= c.row ? (a.row, c.row) : (c.row, a.row)
                    t.select(screen: (0, r0), (cols - 1, r1))
                case .block: t.select(screen: a, (c.col, c.row), rectangle: true)
                }
            } else {
                t.clearSelection()
            }
        }
        let top = mirror.withTerminal { $0.scrollPosition.offset } ?? 0
        mirror.touch()
        setNeedsRender()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if copyCursor.superlayer == nil {
            copyCursor.zPosition = 6
            copyCursor.borderWidth = 1.5
            copyCursor.cornerRadius = 1.5
            layer.addSublayer(copyCursor)
        }
        let scale = metalLayer?.contentsScale ?? 2
        let cw = CGFloat(cellSize.w) / scale, ch = CGFloat(cellSize.h) / scale
        let ox = CGFloat(origin.x) / scale, oy = CGFloat(origin.y) / scale
        copyCursor.borderColor = Self.cg(colors.accent)
        copyCursor.backgroundColor = Self.cg(colors.accent, alpha: 0.25)
        copyCursor.frame = CGRect(x: ox + CGFloat(c.col) * cw, y: oy + CGFloat(c.row - top) * ch, width: cw, height: ch)

        let total = mirror.withTerminal { $0.scrollPosition.total } ?? rows
        let mode = switch (c.anchor != nil, c.kind) {
        case (false, _): "COPY"
        case (true, .chars): "SELECT"
        case (true, .lines): "SELECT LINES"
        case (true, .block): "SELECT BLOCK"
        }
        let font = NSFont.monospacedSystemFont(ofSize: max(9, ch * 0.6), weight: .bold)
        let text = NSAttributedString(string: "\(mode)  \(c.row + 1)/\(total)", attributes: [
            .font: font, .foregroundColor: NSColor(cgColor: Self.cg(colors.cursorText)) ?? .black,
        ])
        if copyTag.superlayer == nil {
            copyTag.zPosition = 7
            copyTag.cornerRadius = 4
            copyTag.cornerCurve = .continuous
            copyTag.addSublayer(copyTagText)
            layer.addSublayer(copyTag)
        }
        let textW = ceil(text.size().width), textH = ceil(font.ascender - font.descender)
        let tagW = textW + 12, tagH = textH + 6
        copyTag.backgroundColor = Self.cg(colors.accent)
        copyTag.frame = CGRect(x: bounds.width - tagW - ox, y: oy, width: tagW, height: tagH)
        copyTagText.string = text
        copyTagText.contentsScale = scale
        copyTagText.frame = CGRect(x: 6, y: 3, width: textW, height: textH)
        CATransaction.commit()
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

    /// Where relative paths resolve, and whether they are on this Mac.
    var linkContext: (cwd: String, local: Bool) = ("", true)

    private struct HoveredLink: Equatable {
        var runs: [VTSearch.Run]
        var target: TerminalLinks.Target
    }

    private var hoveredLink: HoveredLink?
    private let linkLayer = CALayer()

    /// The link under the pointer: an OSC 8 hyperlink, else a URL or an
    /// existing path in the text (its logical line, across soft wraps).
    private func link(at event: NSEvent) -> HoveredLink? { link(atWindowPoint: event.locationInWindow) }

    private func link(atWindowPoint wp: NSPoint) -> HoveredLink? {
        let p = convert(wp, from: nil)
        guard bounds.contains(p), cellSize.w > 0 else { return nil }
        let scale = Double(metalLayer?.contentsScale ?? 2)
        let px = Double(p.x) * scale - Double(origin.x), py = Double(p.y) * scale - Double(origin.y)
        guard px >= 0, py >= 0 else { return nil }
        let col = Int(px / Double(cellSize.w)), row = Int(py / Double(cellSize.h))
        guard let line = mirror.withTerminal({ $0.line(atViewportRow: row) }) ?? nil,
              let at = line.cells.firstIndex(where: { $0.row == row && $0.col == col })
        else { return nil }
        let ctx = linkContext
        // OSC 8 first: the program said exactly what this text points to.
        if let uri = line.uris[at], let url = URL(string: uri) {
            var lo = at, hi = at
            while lo > 0, line.uris[lo - 1] == uri { lo -= 1 }
            while hi + 1 < line.uris.count, line.uris[hi + 1] == uri { hi += 1 }
            return HoveredLink(runs: Self.runs(line, lo ..< hi + 1), target: .url(url))
        }
        guard let found = TerminalLinks.link(in: line.text, at: at),
              LinkOpener.canOpen(found.target, cwd: ctx.cwd, local: ctx.local)
        else { return nil }
        return HoveredLink(runs: Self.runs(line, found.range), target: found.target)
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
        if prefs.confirmUnsafePaste, !bracketed, VTInputEncoder.pasteIsUnsafe(text) {
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
        updateNewOutput()
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

    @objc func interruptProgram(_ sender: Any?) {
        connection.send(.signal(pane, SIGINT))
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
