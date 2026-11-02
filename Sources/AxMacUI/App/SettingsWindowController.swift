import AppKit
import AxModel

/// Settings (⌘,): a single native form; every change applies live.
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let fontSize = NSStepper()
    private let fontLabel = NSTextField(labelWithString: "")

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func popup<T: RawRepresentable & CaseIterable>(_ current: T, titles: [T: String],
                                                           _ set: @escaping (T) -> Void) -> NSPopUpButton
        where T.RawValue == String, T: Hashable
    {
        let p = NSPopUpButton()
        let all = Array(T.allCases)
        for v in all { p.addItem(withTitle: titles[v] ?? v.rawValue.capitalized) }
        p.selectItem(at: all.firstIndex(of: current) ?? 0)
        p.target = self
        p.action = #selector(popupChanged(_:))
        handlers[ObjectIdentifier(p)] = { i in set(all[i]) }
        return p
    }

    /// A popup over plain strings, each item optionally drawn its own way.
    private func popup(_ values: [String], current: String, title: (String) -> NSAttributedString?,
                       image: (String) -> NSImage? = { _ in nil }, _ set: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        for v in values {
            p.addItem(withTitle: v)
            if let t = title(v) { p.lastItem?.attributedTitle = t }
            p.lastItem?.image = image(v)
        }
        p.selectItem(at: values.firstIndex(of: current) ?? 0)
        p.target = self
        p.action = #selector(popupChanged(_:))
        handlers[ObjectIdentifier(p)] = { i in set(values[i]) }
        return p
    }

    /// A theme's swatch for its menu item: its background with its
    /// foreground and four ANSI colours as dots.
    private static func swatch(_ t: TerminalTheme) -> NSImage {
        // 34 wide plus a 6 pt gap before the name (menus set images flush).
        let img = NSImage(size: NSSize(width: 40, height: 14), flipped: false) { full in
            let r = NSRect(x: 0, y: 0, width: 34, height: full.height)
            let plate = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            Axo.Color.rgb(t.background).setFill()
            plate.fill()
            NSColor(white: 0.5, alpha: 0.35).setStroke()
            plate.lineWidth = 0.5
            plate.stroke()
            for (i, c) in [t.foreground, t.ansi[1], t.ansi[2], t.ansi[4], t.ansi[5]].enumerated() {
                Axo.Color.rgb(c).setFill()
                NSBezierPath(ovalIn: NSRect(x: 4 + CGFloat(i) * 5.5, y: 5, width: 4, height: 4)).fill()
            }
            return true
        }
        return img
    }

    private var handlers: [ObjectIdentifier: (Int) -> Void] = [:]
    private var toggles: [ObjectIdentifier: (Bool) -> Void] = [:]

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        handlers[ObjectIdentifier(sender)]?(sender.indexOfSelectedItem)
    }

    private func check(_ title: String, _ on: Bool, _ set: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(toggled(_:)))
        b.state = on ? .on : .off
        toggles[ObjectIdentifier(b)] = set
        return b
    }

    @objc private func toggled(_ sender: NSButton) { toggles[ObjectIdentifier(sender)]?(sender.state == .on) }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        let p = model.prefs
        fontSize.minValue = Double(Axo.Font.terminalRange.lowerBound)
        fontSize.maxValue = Double(Axo.Font.terminalRange.upperBound)
        fontSize.increment = 1
        fontSize.doubleValue = Double(p.fontSize)
        fontSize.target = self
        fontSize.action = #selector(fontChanged)
        fontLabel.stringValue = "\(Int(p.fontSize)) pt"
        fontLabel.font = Axo.Font.caption
        let fontRow = NSStackView(views: [fontLabel, fontSize])
        fontRow.spacing = 8

        let theme = popup(p.themeMode, titles: [.system: "Match System", .night: "Always Dark", .day: "Always Light"]) {
            [weak self] v in
            self?.model.prefs.themeMode = v
            self?.model.applyTheme()
        }
        let themes = ThemeLibrary.all
        let byName = Dictionary(themes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let darkNames = themes.filter(\.isDark).map(\.name)
        let lightNames = themes.filter { !$0.isDark }.map(\.name)
        let darkTheme = popup(darkNames, current: p.darkTheme, title: { _ in nil },
                              image: { byName[$0].map(Self.swatch) }) { [weak self] v in
            self?.model.prefs.darkTheme = v
            self?.model.applyTheme()
        }
        let lightTheme = popup(lightNames, current: p.lightTheme, title: { _ in nil },
                               image: { byName[$0].map(Self.swatch) }) { [weak self] v in
            self?.model.prefs.lightTheme = v
            self?.model.applyTheme()
        }
        let system = "SF Mono"
        let families = [system] + Axo.Font.monospacedFamilies.filter { $0 != "SF Mono" }
        let family = popup(families, current: p.fontFamily.isEmpty ? system : p.fontFamily, title: { name in
            let f = Axo.Font.terminal(size: 13, family: name == system ? "" : name)
            return NSAttributedString(string: name, attributes: [.font: f])
        }) { [weak self] v in
            self?.model.prefs.fontFamily = v == system ? "" : v
            self?.model.fontChanged.emit()
        }
        let cursor = popup(p.cursorShape, titles: [:]) { [weak self] v in self?.model.prefs.cursorShape = v }
        let option = popup(p.optionAsAlt, titles: [.off: "Types special characters", .left: "Left Option is Alt",
                                                   .right: "Right Option is Alt", .both: "Both Options are Alt"]) {
            [weak self] v in self?.model.prefs.optionAsAlt = v
        }
        let blink = check("Blink cursor", p.cursorBlink) { [weak self] v in self?.model.prefs.cursorBlink = v }
        let dim = check("Dim unfocused panes", p.dimUnfocusedPanes) { [weak self] v in
            self?.model.prefs.dimUnfocusedPanes = v
            self?.model.fontChanged.emit()
        }
        let paste = check("Confirm pastes that could run commands", p.confirmUnsafePaste) { [weak self] v in
            self?.model.prefs.confirmUnsafePaste = v
        }

        let tools = check("Give Claude Code Axolotty’s tools (MCP)", p.agentTools) { [weak self] v in
            self?.model.prefs.agentTools = v
        }
        tools.toolTip = "Claude sessions started from Axolotty can list panes, start agents, hand them prompts and wait for them"
        // Claude Code's start preset: shown by their names, stored as flags.
        let modes = ["": "Its usual mode", "plan": "Plan", "acceptEdits": "Accept edits", "auto": "Auto"]
        let mode = popup(["", "plan", "acceptEdits", "auto"], current: p.claudeMode,
                         title: { NSAttributedString(string: modes[$0] ?? $0) }) { [weak self] v in self?.model.prefs.claudeMode = v }
        let models = ["": "Its usual model", "opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku"]
        let modelPick = popup(["", "opus", "sonnet", "haiku"], current: p.claudeModel,
                              title: { NSAttributedString(string: models[$0] ?? $0) }) { [weak self] v in self?.model.prefs.claudeModel = v }
        let efforts = ["", "low", "medium", "high", "xhigh", "max"]
        let effort = popup(efforts, current: p.claudeEffort,
                           title: { NSAttributedString(string: $0.isEmpty ? "Its usual effort" : $0 == "xhigh" ? "Extra high" : $0.capitalized) }) {
            [weak self] v in self?.model.prefs.claudeEffort = v
        }

        let grid = NSGridView(views: [
            [label("Appearance:"), theme],
            [label("Dark theme:"), darkTheme],
            [label("Light theme:"), lightTheme],
            [label("Font:"), family],
            [label("Size:"), fontRow],
            [label("Cursor:"), cursor],
            [NSGridCell.emptyContentView, blink],
            [label("Option key:"), option],
            [label("Panes:"), dim],
            [label("Paste:"), paste],
            [label("Agents:"), tools],
            [label("Claude starts in:"), mode],
            [label("Claude model:"), modelPick],
            [label("Claude effort:"), effort],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        window?.contentView = content
    }

    @objc private func fontChanged() {
        model.setFontSize(CGFloat(fontSize.doubleValue))
        fontLabel.stringValue = "\(Int(model.prefs.fontSize)) pt"
    }
}
