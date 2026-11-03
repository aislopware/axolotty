import AppKit
import AxModel
import QuartzCore

/// Over a session whose host is out of reach: the last frame stays where it
/// was, dimmed, and a bar docked along the session's top edge says what is
/// happening and offers the one thing to do. Never a blank sheet: on a remote
/// link a drop is routine, and the work should still be there to read while
/// it comes back. Docked, not floating: it belongs to the session, as a
/// window's info bar does, and spans every pane instead of sitting on one
/// pane's text or across the seam between two.
///
///     ╭──────────────────────────────────────────────────────────╮
///     │ ◌  Reconnecting to MacBook Pro               [Reconnect] │
///     ├──────────────────────────────────────────────────────────┤
///     │  (the panes, dimmed)                                     │
///
/// The one thing to do follows what is wrong: reconnect a dropped link, set
/// Axolotty up on a Mac that lacks it, update one that runs an older one;
/// nothing while that setup runs (the capsule says so).
///
/// Typing is not queued (a `y⏎` held through the gap could answer another
/// prompt); the capsule says so by being there, and clicks reach only it.
final class LinkVeil: NSView, DesignRefreshable {
    private let scrim = CALayer()
    private let bar = Bar()
    private let rule = CALayer()
    private let stateMark = StatusGlyphView(frame: .zero)
    private let label = Label("", font: Axo.Font.smallStrong, color: Axo.Color.text)
    private let action = Button("Reconnect Now", variant: .secondary, size: .small)
    static let barHeight: CGFloat = 36
    private var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(scrim)
        addSubview(bar)
        bar.wantsLayer = true
        label.lineBreakMode = .byTruncatingTail
        // The panes' own top corners, so the bar reads as their header.
        bar.layer?.cornerRadius = Axo.Metric.sheetRadius
        bar.layer?.cornerCurve = .continuous
        bar.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        bar.layer?.addSublayer(rule)
        bar.addSubview(stateMark)
        bar.addSubview(label)
        bar.addSubview(action)
        stateMark.activity = .working
        action.target = self
        action.action = #selector(act)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        designDidChange()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// What the capsule says ("Reconnecting to MacBook Pro", or why it
    /// waits) and the one thing it offers (nil: nothing to do but wait).
    /// `idle`: nothing is under way, the Mac is only waited for (offline),
    /// so no glyph at all.
    func set(_ text: String, retrying: Bool, idle: Bool = false, action title: String?, _ handler: (() -> Void)?) {
        label.stringValue = text
        // Amber, as in the sidebar: it waits on the person, nothing failed.
        stateMark.activity = idle ? .idle : retrying ? .working : .blocked
        stateMark.isHidden = idle
        setAccessibilityLabel(text)
        action.isHidden = title == nil
        if let title, action.title != title { action.title = title }
        onAction = handler
        needsLayout = true
    }

    func designDidChange() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The ground's own colour over the panes: they recede, they don't go grey.
            Axo.Motion.still {
                scrim.backgroundColor = Axo.Color.ground.withAlphaComponent(0.5).cgColor
                bar.layer?.backgroundColor = Axo.Color.elevated.cgColor
                rule.backgroundColor = Axo.Color.borderSubtle.cgColor
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        designDidChange()
    }

    override func layout() {
        super.layout()
        let h = Self.barHeight
        let pad = Axo.Space.md
        Axo.Motion.still {
            scrim.frame = bounds
            rule.frame = NSRect(x: 0, y: h - hairline, width: bounds.width, height: hairline)
        }
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        let glyph = stateMark.isHidden ? 0 : Axo.Metric.statusSlot
        stateMark.frame = NSRect(x: pad, y: ((h - glyph) / 2).rounded(), width: glyph, height: glyph)
        let lead = stateMark.isHidden ? pad : pad + glyph + Axo.Space.sm
        let bw = action.isHidden ? 0 : ceil(action.intrinsicContentSize.width)
        let bh = Axo.Metric.controlSmall
        action.frame = NSRect(x: bounds.width - pad - bw, y: ((h - bh) / 2).rounded(), width: bw, height: bh)
        let room = (action.isHidden ? bounds.width - pad : action.frame.minX - Axo.Space.md) - lead
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: lead, y: ((h - lh) / 2).rounded(), width: max(0, min(room, ceil(label.intrinsicContentSize.width))),
                             height: lh)
    }

    /// Everything under the veil is out of reach until the link is back.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    @objc private func act() { onAction?() }

    // MARK: Motion

    /// Fades in after a beat: a blink of a drop that heals at once shows
    /// nothing. Shown at once when the session opens on a host already down.
    func show(animated: Bool) {
        guard animated else {
            pending?.cancel()
            pending = nil
            isHidden = false
            alphaValue = 1
            return
        }
        if !isHidden {
            reveal()  // up already, or fading out: back to full
            return
        }
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            pending = nil
            reveal()
        }
    }

    private var pending: Task<Void, Never>?

    private func reveal() { Axo.Motion.reveal(self, on: Axo.Motion.glide) }

    func hide(animated: Bool) {
        pending?.cancel()
        pending = nil
        guard !isHidden else { return }
        guard animated, !Axo.Motion.reduced else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Axo.Motion.swift.duration
            ctx.timingFunction = Axo.Motion.easeIn
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        })
    }

    /// Flipped, so its layer's min-Y corners are the top ones.
    private final class Bar: NSView {
        override var isFlipped: Bool { true }
    }
}
