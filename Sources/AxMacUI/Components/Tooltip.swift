import AppKit

/// Design-system tooltips, drawn in the window's overlay layer (no system
/// tooltip windows). First one waits 500 ms; while "warm" (another tooltip
/// shown within the last 600 ms) the next appears at once. In on Tick, out
/// fast. Placed below the anchor, clamped inside the window.
@MainActor final class Tooltip {
    static let shared = Tooltip()

    enum Placement { case below, trailing }
    private var pending: (view: NSView, make: () -> NSView, placement: Placement)?
    private var timer: Timer?
    private var shown: (anchor: NSView, view: NSView, placement: Placement)?
    private var lastHidden = Date.distantPast
    /// While a menu is open nothing else explains itself.
    var suppressed = false { didSet { if suppressed { dismiss() } } }

    /// `delay`: 450 ms for controls; rows use a longer 550 ms hover-card delay.
    func hover(_ view: NSView, text: String, placement: Placement = .below, delay: TimeInterval = 0.5) {
        hover(view, make: { TooltipView(text) }, placement: placement, delay: delay)
    }

    /// A row's hover card (structured facts with marks).
    func hover(_ view: NSView, card: HoverCard, placement: Placement = .trailing, delay: TimeInterval = 0.55) {
        hover(view, make: { HoverCardView(card) }, placement: placement, delay: delay)
    }

    /// Replaces the card on screen for `view`, if one is, without fading:
    /// facts that arrive late (git, ports) slot into the open card.
    func refresh(_ view: NSView, card: HoverCard) {
        if pending?.view === view { pending?.make = { HoverCardView(card) } }
        guard let s = shown, s.anchor === view, let host = s.view.superview else { return }
        let tip = HoverCardView(card)
        place(tip, anchor: view, in: host, placement: s.placement)
        host.replaceSubview(s.view, with: tip)
        shown = (view, tip, s.placement)
    }

    private func hover(_ view: NSView, make: @escaping () -> NSView, placement: Placement, delay: TimeInterval) {
        timer?.invalidate()
        guard !suppressed else { return }
        pending = (view, make, placement)
        let warm = shown != nil || Date().timeIntervalSince(lastHidden) < 0.4
        if warm {
            present()
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { Tooltip.shared.present() }
        }
    }

    func leave(_ view: NSView) {
        if pending?.view === view {
            timer?.invalidate()
            pending = nil
        }
        if shown?.anchor === view { hide() }
    }

    func dismiss() {
        timer?.invalidate()
        pending = nil
        hide()
    }

    private func present() {
        guard let (anchor, make, placement) = pending, let window = anchor.window, window.isKeyWindow,
              let host = (window.contentView as? ShellView)?.overlay
        else { return }
        pending = nil
        if let s = shown {
            s.view.removeFromSuperview()
            shown = nil
        }
        let tip = make()
        place(tip, anchor: anchor, in: host, placement: placement)
        host.addSubview(tip)
        shown = (anchor, tip, placement)
        tip.alphaValue = 0
        Axo.Motion.run(Axo.Motion.tick) { tip.animator().alphaValue = 1 }
    }

    private func place(_ tip: NSView, anchor: NSView, in host: NSView, placement: Placement) {
        let size = tip.fittingSize
        let a = host.convert(anchor.bounds, from: anchor)
        var x: CGFloat, y: CGFloat
        switch placement {
        case .below:
            x = (a.midX - size.width / 2).rounded()
            y = a.maxY + 6
            if y + size.height > host.bounds.height - 8 { y = a.minY - 6 - size.height }
        case .trailing:
            x = a.maxX + 8
            y = (a.midY - size.height / 2).rounded()
        }
        x = min(max(8, x), host.bounds.width - size.width - 8)
        y = min(max(8, y), host.bounds.height - size.height - 8)
        tip.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func hide() {
        guard let s = shown else { return }
        shown = nil
        lastHidden = Date()
        let v = s.view
        Axo.Motion.run(Axo.Motion.tickOut, { v.animator().alphaValue = 0 }) { v.removeFromSuperview() }
    }
}

/// The tooltip body: a small float surface with caption text.
final class TooltipView: Surface {
    private let label: Label

    /// Multi-line text is a hover card: the first line is its title (semibold,
    /// full ink), the rest are facts (secondary ink, 2 pt apart).
    init(_ text: String) {
        let l = Label("", font: Axo.Font.caption, color: Axo.Color.text)
        let lines = text.components(separatedBy: "\n")
        if lines.count > 1 {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 2
            para.lineBreakMode = .byTruncatingMiddle
            let s = NSMutableAttributedString(string: lines[0], attributes: [
                .font: Axo.Font.captionTitle, .foregroundColor: Axo.Color.text, .paragraphStyle: para,
            ])
            s.append(NSAttributedString(string: "\n" + lines.dropFirst().joined(separator: "\n"), attributes: [
                .font: Axo.Font.caption, .foregroundColor: Axo.Color.textSecondary, .paragraphStyle: para,
            ]))
            l.attributedStringValue = s
        } else {
            l.stringValue = text
        }
        l.maximumNumberOfLines = 5
        l.lineBreakMode = .byClipping
        l.usesSingleLineMode = false
        label = l
        super.init(elevation: .float, radius: lines.count > 1 ? Axo.Radius.md : Axo.Metric.tooltipRadius)
        content.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let s = label.intrinsicContentSize
        let multi = label.attributedStringValue.string.contains("\n")
        let w = min(ceil(s.width), 320)
        let h = multi ? ceil(label.attributedStringValue.boundingRect(with: NSSize(width: w, height: 400),
                                                                       options: [.usesLineFragmentOrigin]).height) : ceil(s.height)
        let padY = multi ? Axo.Space.md : Axo.Space.xs
        return NSSize(width: w + Axo.Space.md * 2 + (multi ? 4 : 0), height: max(22, h + padY * 2))
    }

    override func layout() {
        super.layout()
        let multi = label.attributedStringValue.string.contains("\n")
        let padX = Axo.Space.md + (multi ? 2 : 0)
        let w = bounds.width - padX * 2
        let h = multi ? ceil(label.attributedStringValue.boundingRect(with: NSSize(width: w, height: 400),
                                                                       options: [.usesLineFragmentOrigin]).height)
            : label.intrinsicContentSize.height
        label.frame = NSRect(x: padX, y: ((bounds.height - h) / 2).rounded(), width: w, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
