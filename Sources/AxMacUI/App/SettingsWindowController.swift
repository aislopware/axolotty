import AppKit
import AxModel

/// Settings (⌘,): a single native form; every change applies live. It
/// wears the app's appearance, not the system's: an "Always Dark" app
/// doesn't open a white window.
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private var themeToken: SignalToken?

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true  // one ground, title bar and form
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        window.center()
        applyTheme()
        themeToken = model.themeChanged.observe { [weak self] in self?.applyTheme() }
    }

    private func applyTheme() {
        let t = model.theme
        window?.appearance = NSAppearance(named: t.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = Axo.Color.rgb(t.background)  // the main window's ground
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
                       _ set: @escaping (String) -> Void) -> NSPopUpButton {
        let p = NSPopUpButton()
        for v in values {
            p.addItem(withTitle: v)
            if let t = title(v) { p.lastItem?.attributedTitle = t }
        }
        p.selectItem(at: values.firstIndex(of: current) ?? 0)
        p.target = self
        p.action = #selector(popupChanged(_:))
        handlers[ObjectIdentifier(p)] = { i in set(values[i]) }
        return p
    }

    private var handlers: [ObjectIdentifier: (Int) -> Void] = [:]

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        handlers[ObjectIdentifier(sender)]?(sender.indexOfSelectedItem)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        let p = model.prefs
        let theme = popup(p.themeMode, titles: [.system: "Match System", .night: "Always Dark", .day: "Always Light"]) {
            [weak self] v in
            self?.model.prefs.themeMode = v
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
        let option = popup(p.optionAsAlt, titles: [.off: "Types special characters", .left: "Left Option is Alt",
                                                   .right: "Right Option is Alt", .both: "Both Options are Alt"]) {
            [weak self] v in self?.model.prefs.optionAsAlt = v
        }

        let grid = NSGridView(views: [
            [label("Appearance:"), theme],
            [label("Font:"), family],
            [label("Option key:"), option],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        // One column of controls, one width: the longest choice sets it.
        for p in [theme, family] { p.widthAnchor.constraint(equalTo: option.widthAnchor).isActive = true }
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
        // The window is as tall as its three rows, never taller.
        window?.setContentSize(NSSize(width: max(400, content.fittingSize.width), height: content.fittingSize.height))
    }
}
