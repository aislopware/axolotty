import AppKit
import AxModel
import QuartzCore

/// Over a session whose host is out of reach: the last frame stays where it
/// was, dimmed, with one quiet capsule that says what is happening and offers
/// the one thing to do. Never a blank sheet: on a remote link a drop is
/// routine, and the work should still be there to read while it comes back.
///
///                 ┌──────────────────────────────────────┐
///                 │ ◌  Reconnecting to MacBook Pro   Now │
///                 └──────────────────────────────────────┘
///
/// The one thing to do follows what is wrong: reconnect a dropped link, set
/// Axolotty up on a Mac that lacks it, update one that runs an older one;
/// nothing while that setup runs (the capsule says so).
///
/// Typing is not queued (a `y⏎` held through the gap could answer another
/// prompt); the capsule says so by being there, and clicks reach only it.
final class LinkVeil: NSView, DesignRefreshable {
    private let scrim = CALayer()
    private let capsule = Surface(elevation: .float, radius: Axo.Metric.controlLarge / 2)
    private let spinner = StatusGlyphView(frame: .zero)
    private let label = Label("", font: Axo.Font.smallStrong, color: Axo.Color.text)
    private let action = Button("Reconnect Now", variant: .ghost, size: .small)
    private var onAction: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(scrim)
        addSubview(capsule)
        capsule.addSubview(spinner)
        capsule.addSubview(label)
        capsule.addSubview(action)
        spinner.activity = .working
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
        spinner.activity = idle ? .idle : retrying ? .working : .blocked
        spinner.isHidden = idle
        setAccessibilityLabel(text)
        action.isHidden = title == nil
        if let title, action.title != title { action.title = title }
        onAction = handler
        needsLayout = true
    }

    func designDidChange() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            // The ground's own colour over the panes: they recede, they don't go grey.
            Axo.Motion.still { scrim.backgroundColor = Axo.Color.ground.withAlphaComponent(0.58).cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        designDidChange()
    }

    override func layout() {
        super.layout()
        Axo.Motion.still { scrim.frame = bounds }
        let h = Axo.Metric.controlLarge
        let pad = Axo.Space.sm
        let glyph = spinner.isHidden ? 0 : Axo.Metric.statusSlot
        let lead = spinner.isHidden ? pad + 2 : pad + glyph + Axo.Space.xs
        let text = ceil(label.intrinsicContentSize.width)
        let button = action.isHidden ? 0 : ceil(action.intrinsicContentSize.width)
        let tail = action.isHidden ? pad + 2 : Axo.Space.sm + button + 4
        let w = lead + text + tail
        // A third of the way down the stage: where the eye already is.
        let x = ((bounds.width - w) / 2).rounded()
        let y = max(Axo.Space.lg, (bounds.height * 0.32 - h / 2).rounded())
        capsule.frame = NSRect(x: x, y: y, width: w, height: h)
        spinner.frame = NSRect(x: pad, y: ((h - glyph) / 2).rounded(), width: glyph, height: glyph)
        let lh = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: lead, y: ((h - lh) / 2).rounded(), width: text, height: lh)
        let bh = Axo.Metric.controlSmall
        action.frame = NSRect(x: label.frame.maxX + Axo.Space.sm, y: ((h - bh) / 2).rounded(), width: button, height: bh)
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
}
