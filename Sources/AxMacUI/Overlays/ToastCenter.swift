import AppKit
import AxModel
import QuartzCore

/// In-window toasts: float surfaces stacked at the top-right of the content
/// column, under the band, at most three. Not bottom-centre (Zed's place):
/// in a terminal the bottom row is the live prompt, and a card there covers
/// what you are typing. Hover pauses the timer; a click jumps to the pane.
final class ToastCenter {
    private let model: AppModel
    private let overlay: ToastOverlay
    private var toasts: [ToastView] = []
    var onActivate: ((HostSession, PaneID) -> Void)?
    /// The rect (in the host's coordinates) toasts stack inside.
    var region: (() -> NSRect)?

    init(host: NSView, model: AppModel) {
        self.model = model
        overlay = ToastOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay, positioned: .below, relativeTo: nil)
        overlay.onLayout = { [weak self] in self?.restack(animated: false) }
    }

    /// Re-stacks after the region moved (sidebar toggled, window resized).
    func relayout() { restack(animated: false) }

    struct Content {
        var title: String
        var body: String
        var activity: Activity
        var host: HostSession?
        var pane: PaneID?
    }

    func show(_ c: Content) {
        // One toast per pane: a newer state replaces the older card.
        if let pane = c.pane, let old = toasts.first(where: { $0.info.pane == pane }) { remove(old, animated: false) }
        let t = ToastView(c)
        t.onClick = { [weak self, weak t] in
            guard let self, let t else { return }
            if let h = c.host, let p = c.pane { onActivate?(h, p) }
            remove(t, animated: true)
        }
        t.onExpire = { [weak self, weak t] in
            guard let t else { return }
            self?.remove(t, animated: true)
        }
        toasts.insert(t, at: 0)
        overlay.addSubview(t)
        while toasts.count > Axo.Metric.toastMax, let last = toasts.last { remove(last, animated: true) }
        restack(animated: true, entering: t)
        t.startTimer()
        NSAccessibility.post(element: t, notification: .announcementRequested,
                             userInfo: [.announcement: "\(c.title). \(c.body)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The person reached the pane another way: its card has nothing left to say.
    func dismiss(pane: PaneID) {
        for t in toasts where t.info.pane == pane { remove(t, animated: true) }
    }

    private func remove(_ t: ToastView, animated: Bool) {
        guard let i = toasts.firstIndex(where: { $0 === t }) else { return }
        toasts.remove(at: i)
        t.stopTimer()
        if animated, !Axo.Motion.reduced {
            Axo.Motion.fade(in: false, {
                t.animator().alphaValue = 0
                t.animator().setFrameOrigin(NSPoint(x: t.frame.minX + 16, y: t.frame.minY))
            }) { t.removeFromSuperview() }
        } else {
            t.removeFromSuperview()
        }
        restack(animated: animated)
    }

    private func restack(animated: Bool, entering: ToastView? = nil) {
        let b = overlay.bounds
        let safe = region?() ?? b
        var y = safe.minY + Axo.Space.md
        let x = safe.maxX - Axo.Space.lg - Axo.Metric.toastWidth
        var frames: [(ToastView, NSRect)] = []
        for t in toasts {
            let h = t.height(for: Axo.Metric.toastWidth)
            frames.append((t, NSRect(x: x, y: y, width: Axo.Metric.toastWidth, height: h)))
            y += h + Axo.Metric.toastGap
        }
        for (t, f) in frames where t === entering {
            t.frame = f.offsetBy(dx: 0, dy: -8)
            t.alphaValue = 0
        }
        let apply = {
            for (t, f) in frames {
                if animated { t.animator().frame = f } else { t.frame = f }
                if t === entering { t.animator().alphaValue = 1 }
            }
        }
        if animated {
            Axo.Motion.animate(entering == nil ? Axo.Motion.standard : Axo.Motion.pop, apply)
        } else {
            apply()
            entering?.alphaValue = 1
        }
    }
}

/// Passes clicks through except on toasts.
final class ToastOverlay: NSView {
    var onLayout: (() -> Void)?
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

final class ToastView: Surface {
    let info: ToastCenter.Content
    var onClick: (() -> Void)?
    var onExpire: (() -> Void)?
    /// Who is speaking: the session's program icon with its state badge.
    private let glyph = ProgramIcon(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let title = Label("", font: Axo.Font.bodyStrong, color: Axo.Color.text)
    private let body = NSTextField(wrappingLabelWithString: "")
    /// Only on a card that asks for you (waiting or failed): the whole card is
    /// a button, but nothing about a card says so, so the ask gets a visible verb.
    private let show = Button("Show", variant: .secondary, size: .small)
    private var asks: Bool { (info.activity == .blocked || info.activity == .error) && info.pane != nil }
    private var timer: Timer?
    private var remaining: TimeInterval
    private var started = Date()
    private static let pad = Axo.Space.lg

    init(_ c: ToastCenter.Content) {
        info = c
        // 6 s when it asks something of you (it is also a button), 4 s otherwise.
        remaining = c.activity == .error || c.activity == .blocked ? 6 : 4
        super.init(elevation: .float, radius: Axo.Metric.toastRadius)
        title.stringValue = c.title
        body.font = Axo.Font.small
        body.textColor = Axo.Color.textSecondary
        body.stringValue = c.body
        body.maximumNumberOfLines = 3
        if let h = c.host, let pane = c.pane, let st = h.state, let sid = st.panes[pane]?.session {
            let identity = st.identity(of: sid)
            glyph.identity = identity
            // Same rule as the row: the mark beside the title already names the agent.
            title.stringValue = identity.rowTitle(c.title)
            glyph.activity = c.activity == .idle ? .done : c.activity
        } else {
            // App-level messages (a host error): a plain warning glyph.
            glyph.identity = ProgramIdentity(symbol: "exclamationmark.triangle")
        }
        glyph.lit = true
        show.target = self
        show.action = #selector(showPressed(_:))
        show.isHidden = !asks
        for v in [glyph, title, body, show] as [NSView] { content.addSubview(v) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(c.title). \(c.body)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var textX: CGFloat { Self.pad + 16 + Axo.Space.md }
    /// Room the trailing button takes from the text column.
    private var trailing: CGFloat { asks ? ceil(show.intrinsicContentSize.width) + Axo.Space.md : 0 }

    @objc private func showPressed(_ sender: Any?) { onClick?() }

    func height(for width: CGFloat) -> CGFloat {
        let textW = width - textX - Self.pad - trailing
        body.preferredMaxLayoutWidth = textW
        let bodyH = info.body.isEmpty ? 0 : ceil(body.fittingSize.height) + 2
        return max(44, Self.pad + ceil(title.intrinsicContentSize.height) + bodyH + Self.pad - 1)
    }

    override func layout() {
        super.layout()
        let textW = bounds.width - textX - Self.pad - trailing
        let th = ceil(title.intrinsicContentSize.height)
        title.frame = NSRect(x: textX, y: Self.pad - 1, width: textW, height: th)
        glyph.frame = NSRect(x: Self.pad, y: title.frame.minY + (th - 16) / 2, width: 16, height: 16)
        if asks {
            // Trailing, centred on the title line (as Mail's and Xcode's banners).
            let b = show.intrinsicContentSize
            let w = ceil(b.width)
            show.frame = NSRect(x: bounds.width - Self.pad - w, y: (title.frame.midY - b.height / 2).rounded(),
                                width: w, height: b.height)
        }
        body.preferredMaxLayoutWidth = textW
        body.frame = NSRect(x: textX, y: title.frame.maxY + 2, width: textW, height: ceil(body.fittingSize.height))
        body.isHidden = info.body.isEmpty
    }

    // Hover pauses the countdown.
    func startTimer() {
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.onExpire?() }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard timer != nil else { return }
        remaining = max(1.5, remaining - Date().timeIntervalSince(started))
        stopTimer()
    }

    override func mouseExited(with event: NSEvent) {
        if timer == nil { startTimer() }
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        if asks, let hit = super.hitTest(point), hit === show || hit.isDescendant(of: show) { return hit }
        return self
    }
}
