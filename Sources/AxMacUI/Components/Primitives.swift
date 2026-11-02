import AppKit
import AxModel
import QuartzCore

/// A text label bound to a type style and a colour token. Colours are
/// dynamic, so appearance and theme changes need no code here.
final class Label: NSTextField {
    init(_ text: String = "", font: NSFont = Axo.Font.body, color: NSColor = Axo.Color.text) {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        self.font = font
        textColor = color
        stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Measured from the attributed string itself (NSTextField's own figure
    /// comes up short for mixed-weight strings and truncates them).
    override var intrinsicContentSize: NSSize {
        let s = attributedStringValue.size()
        return NSSize(width: ceil(s.width) + 4, height: max(super.intrinsicContentSize.height, ceil(s.height)))
    }

    override var stringValue: String { didSet { invalidateIntrinsicContentSize() } }
    override var attributedStringValue: NSAttributedString { didSet { invalidateIntrinsicContentSize() } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An SF Symbol tinted with a colour token, drawn at the size of the text it
/// sits beside (never smaller than 12.5 pt: SF swaps in thinner designs).
final class Symbol: NSImageView {
    init(_ name: String, size: CGFloat = Axo.Metric.iconGlyph, weight: NSFont.Weight = .medium,
         color: NSColor = Axo.Color.textSecondary) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbolConfiguration = .init(pointSize: size, weight: weight)
        contentTintColor = color
        imageScaling = .scaleNone
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Key caps for a chord: one cap per key (`⌘` `⇧` `P`), ink on a faint plate,
/// no ring (Raycast/Linear style; bordered caps read as dated).
final class Keycaps: NSView {
    private var caps: [(layer: ShapeLayer, label: NSTextField)] = []
    var chord = "" {
        didSet {
            guard chord != oldValue else { return }
            rebuild()
        }
    }

    /// Inverted caps for use on the solid or the accent.
    var onSolid = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    convenience init(_ chord: String) {
        self.init(frame: .zero)
        self.chord = chord
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Splits `⌃⌥⇧⌘K` into its keys; a trailing word (`Tab`, `↩`) stays whole.
    static func keys(_ chord: String) -> [String] {
        var out: [String] = []
        var rest = Substring(chord)
        while let c = rest.first, "⌃⌥⇧⌘".contains(c) {
            out.append(String(c))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }

    private func rebuild() {
        for c in caps {
            c.layer.removeFromSuperlayer()
            c.label.removeFromSuperview()
        }
        caps = Self.keys(chord).map { key in
            let l = ShapeLayer()
            layer?.addSublayer(l)
            let t = Label(key, font: Axo.Font.keycap, color: Axo.Color.textSecondary)
            t.alignment = .center
            addSubview(t)
            return (l, t)
        }
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private static let gap: CGFloat = 3

    private func width(_ t: NSTextField) -> CGFloat {
        max(Axo.Metric.keycapHeight, ceil(t.intrinsicContentSize.width) + 8)
    }

    override var intrinsicContentSize: NSSize {
        let w = caps.reduce(0) { $0 + width($1.label) } + CGFloat(max(0, caps.count - 1)) * Self.gap
        return NSSize(width: w, height: Axo.Metric.keycapHeight)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let h = Axo.Metric.keycapHeight
        let y = ((bounds.height - h) / 2).rounded()
        Axo.Motion.still {
            for c in caps {
                let w = width(c.label)
                let f = NSRect(x: x, y: y, width: w, height: h)
                c.layer.frame = f
                c.layer.radius = Axo.Radius.xs
                let ls = c.label.intrinsicContentSize
                c.label.frame = NSRect(x: f.minX, y: f.minY + ((h - ls.height) / 2).rounded(), width: w, height: ls.height)
                x += w + Self.gap
            }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { restyle() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Axo.Motion.still {
                for c in caps {
                    c.layer.fillColor = (onSolid ? Axo.Color.solidInk.withAlphaComponent(0.14) : Axo.Color.selected).cgColor
                    c.label.textColor = onSolid ? Axo.Color.solidInk : Axo.Color.textSecondary
                }
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A borderless search/query field: no box, no focus ring, accent caret,
/// tertiary placeholder. The caret is the only focus indicator (a field that
/// turns accent on focus reads as a form).
final class SearchField: NSTextField {
    init(placeholder: String, font: NSFont = Axo.Font.field) {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        self.font = font
        textColor = Axo.Color.text
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font, .foregroundColor: Axo.Color.textTertiary,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = Axo.Color.accent
            editor.selectedTextAttributes = [.backgroundColor: Axo.Color.accentWash]
        }
        return ok
    }
}

/// A status chip: glyph + short text in a capsule (`◜ Claude · 2m`). Tinted
/// for states that need attention, neutral otherwise.
final class Chip: NSView {
    private let glyph = StatusGlyphView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let label = Label("", font: Axo.Font.captionStrong, color: Axo.Color.text)
    private let plate = Plate(radius: Axo.Metric.chipHeight / 2)
    private(set) var activity: Activity = .idle
    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(plate.layer)
        addSubview(glyph)
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(_ a: Activity, text: String) {
        activity = a
        glyph.activity = a
        label.stringValue = text
        setAccessibilityLabel(text)
        restyle()
        needsLayout = true
    }

    override var fittingSize: NSSize {
        NSSize(width: Axo.Space.sm + 16 + Axo.Space.xs + ceil(label.intrinsicContentSize.width) + Axo.Space.md + 2,
               height: Axo.Metric.chipHeight)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        Axo.Motion.still {
            plate.layer.frame = bounds
            plate.layer.radius = h / 2
        }
        glyph.frame = NSRect(x: Axo.Space.sm, y: (h - 16) / 2, width: 16, height: 16)
        let ls = label.intrinsicContentSize
        label.frame = NSRect(x: glyph.frame.maxX + Axo.Space.xs, y: ((h - ls.height) / 2).rounded(), width: ceil(ls.width),
                             height: ls.height)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { restyle() }

    private func restyle() {
        let attention = activity == .blocked || activity == .error
        plate.rest = attention ? Axo.Color.statusWash(activity) : Axo.Color.hover
        plate.hover = attention ? Axo.Color.status(activity).withAlphaComponent(0.24) : Axo.Color.selected
        plate.pressed = attention ? Axo.Color.status(activity).withAlphaComponent(0.30) : Axo.Color.pressed
        label.textColor = attention ? Axo.Color.status(activity) : Axo.Color.text
        plate.refresh(effectiveAppearance)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { plate.set(.hover, appearance: effectiveAppearance) }
    override func mouseExited(with event: NSEvent) { plate.set(.rest, appearance: effectiveAppearance) }
    override func mouseDown(with event: NSEvent) { plate.set(.pressed, appearance: effectiveAppearance) }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        plate.set(inside ? .hover : .rest, appearance: effectiveAppearance)
        if inside { onClick?() }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
