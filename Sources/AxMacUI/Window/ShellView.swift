import AppKit
import QuartzCore

/// The window's root: our own sidebar column (opaque, resizable, springs open
/// and closed), the content column, and the overlay layer for palette, toasts
/// and popovers. No system sidebar, no toolbar items, no child windows: every
/// pixel is drawn by the design system, so corners, borders and shadows match.
final class ShellView: NSView {
    let sidebar: NSView
    let content: NSView
    let overlay = OverlayHostView()
    let sidebarColumn = SidebarColumn()
    private let handle = SidebarResizeHandle()
    let sidebarToggle = IconButton(symbol: "sidebar.left", label: "Toggle Sidebar")
    /// The only other control in the titlebar strip (the sidebar has no footer).
    let newSessionButton = IconButton(symbol: "plus", label: "New Session")

    /// Sidebar width when open (persisted).
    private(set) var sidebarWidth: CGFloat
    private(set) var collapsed: Bool
    /// 1 = fully open, 0 = closed; animated by a spring on the display link.
    private(set) var reveal: CGFloat
    private var link: CADisplayLink?
    private var motion: (from: CGFloat, to: CGFloat, start: CFTimeInterval)?
    /// Called while the content column moves (grids freeze) and when it settles.
    var onContentMotion: ((Bool) -> Void)?
    var onLayout: (() -> Void)?

    init(sidebar: NSView, content: NSView) {
        self.sidebar = sidebar
        self.content = content
        let d = UserDefaults.standard
        let w = d.double(forKey: "sidebarWidth")
        sidebarWidth = w > 0 ? min(max(CGFloat(w), Axo.Metric.sidebarMin), Axo.Metric.sidebarMax) : Axo.Metric.sidebarWidth
        collapsed = d.bool(forKey: "sidebarCollapsed")
        reveal = collapsed ? 0 : 1
        super.init(frame: NSRect(origin: .zero, size: Axo.Metric.windowDefault))
        wantsLayer = true
        sidebarColumn.addSubview(sidebar)
        addSubview(content)
        addSubview(sidebarColumn)
        addSubview(handle)
        addSubview(sidebarToggle)
        addSubview(newSessionButton)
        addSubview(overlay)
        handle.onDrag = { [weak self] phase, dx in self?.resizeSidebar(phase, dx) }
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleClicked(_:))
        sidebarToggle.tooltip = "Toggle Sidebar  ⌃⌘S"
        newSessionButton.target = nil
        newSessionButton.action = #selector(MainWindowController.newSession(_:))
        newSessionButton.tooltip = "New Session  ⌘T"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Height of the titlebar strip (traffic lights' lane), from the window.
    var titlebarHeight: CGFloat {
        guard let w = window else { return Axo.Metric.bandHeight }
        return max(28, w.frame.height - w.contentLayoutRect.height)
    }

    /// Where content chrome may start so it clears the traffic lights and toggle.
    /// 20 pt, not the 8 between the buttons: at 8 the session's icon and title
    /// read as a third button in the same group.
    var collapsedLeading: CGFloat {
        newSessionButton.frame.maxX + Prim.Space.s8
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.isPaused = true
        l.add(to: .main, forMode: .common)
        link = l
    }

    /// Keeps every self-made layer in the window at the screen's scale.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let scale = window?.backingScaleFactor else { return }
        LayerScale.current = scale
        layer?.syncContentsScale(scale)
    }

    override func layout() {
        super.layout()
        let b = bounds
        let w = sidebarWidth
        let x = -(1 - reveal) * w
        sidebarColumn.frame = NSRect(x: x, y: 0, width: w, height: b.height)
        sidebar.frame = sidebarColumn.bounds.insetBy(dx: 0, dy: 0)
        sidebarColumn.isHidden = reveal <= 0.001
        let cx = max(0, x + w)
        content.frame = NSRect(x: cx, y: 0, width: b.width - cx, height: b.height)
        handle.frame = NSRect(x: cx - 3, y: titlebarHeight, width: 6, height: b.height - titlebarHeight)
        handle.isHidden = reveal < 1
        overlay.frame = b
        // The toggle sits right of the traffic lights at a fixed window x.
        let lights = window?.standardWindowButton(.zoomButton)?.frame ?? NSRect(x: 52, y: 6, width: 14, height: 16)
        let s = Axo.Metric.iconButton
        let mid = titlebarHeight / 2
        sidebarToggle.frame = NSRect(x: lights.maxX + 14, y: (mid - s / 2).rounded(), width: s, height: s)
        newSessionButton.frame = sidebarToggle.frame.offsetBy(dx: s + Axo.Space.xs, dy: 0)

        onLayout?()
    }

    // MARK: Collapse

    func toggleSidebar() { setCollapsed(!collapsed, animated: true) }

    @objc private func toggleClicked(_ sender: Any?) { toggleSidebar() }

    func setCollapsed(_ c: Bool, animated: Bool) {
        collapsed = c
        UserDefaults.standard.set(c, forKey: "sidebarCollapsed")
        let target: CGFloat = c ? 0 : 1
        guard animated, !Axo.Motion.reduced, window != nil else {
            reveal = target
            needsLayout = true
            onContentMotion?(false)
            return
        }
        motion = (reveal, target, CACurrentMediaTime())
        onContentMotion?(true)
        link?.isPaused = false
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard let m = motion else {
            l.isPaused = true
            return
        }
        let spring = Axo.Motion.panel
        let t = CACurrentMediaTime() - m.start
        if t >= spring.settleTime {
            reveal = m.to
            motion = nil
            l.isPaused = true
            needsLayout = true
            layoutSubtreeIfNeeded()
            onContentMotion?(false)
            return
        }
        reveal = m.from + (m.to - m.from) * CGFloat(spring.value(at: t))
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    // MARK: Resize

    private var dragStart: CGFloat = 0

    private func resizeSidebar(_ phase: DividerView.DragPhase, _ dx: CGFloat) {
        switch phase {
        case .began:
            dragStart = sidebarWidth
            onContentMotion?(true)
        case .changed:
            sidebarWidth = min(max(dragStart + dx, Axo.Metric.sidebarMin), Axo.Metric.sidebarMax)
            needsLayout = true
        case .ended:
            if dx.isNaN { sidebarWidth = Axo.Metric.sidebarWidth }
            UserDefaults.standard.set(Double(sidebarWidth), forKey: "sidebarWidth")
            needsLayout = true
            onContentMotion?(false)
        }
    }
}

/// The sidebar's opaque column: the frame tone, with no rule. The edge of
/// the terminal sheet beside it is the boundary.
final class SidebarColumn: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Axo.Color.frame.cgColor
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

/// A 6 pt grab strip on the sidebar's edge (double-click resets the width).
final class SidebarResizeHandle: NSView {
    var onDrag: ((DividerView.DragPhase, CGFloat) -> Void)?
    private var start: CGFloat = 0
    private var dragging = false

    override func resetCursorRects() { addCursorRect(bounds, cursor: .columnResize) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDrag?(.began, 0)
            onDrag?(.ended, .nan)
            return
        }
        dragging = true
        start = event.locationInWindow.x
        onDrag?(.began, 0)
    }

    override func mouseDragged(with event: NSEvent) {
        if dragging { onDrag?(.changed, event.locationInWindow.x - start) }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onDrag?(.ended, event.locationInWindow.x - start)
    }
}

/// Hosts in-window overlays (palette, toasts, popovers). Transparent to clicks
/// except on its children; an optional scrim takes clicks to dismiss.
final class OverlayHostView: NSView {
    /// Called on a click that lands on no overlay while `capturesOutsideClicks`.
    var onOutsideClick: (() -> Void)?
    var capturesOutsideClicks = false
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === self { return capturesOutsideClicks ? self : nil }
        return hit
    }

    override func mouseDown(with event: NSEvent) { onOutsideClick?() }
}
