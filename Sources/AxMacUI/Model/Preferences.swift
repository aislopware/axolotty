import AppKit
import AxModel
import Observation

/// Person-level settings, persisted in UserDefaults. One instance per app.
@Observable
final class Preferences {
    enum ThemeMode: String, CaseIterable { case system, night, day }
    enum OptionAsAlt: String, CaseIterable { case off, left, right, both }
    enum CursorShape: String, CaseIterable { case bar, block, underline }

    @ObservationIgnored private let defaults: UserDefaults

    var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }
    /// The terminal font's family; empty is the system's (SF Mono).
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "fontFamily") } }
    /// Terminal themes by name (`ThemeLibrary`) for dark and light appearance.
    var darkTheme: String { didSet { defaults.set(darkTheme, forKey: "darkTheme") } }
    var lightTheme: String { didSet { defaults.set(lightTheme, forKey: "lightTheme") } }
    var themeMode: ThemeMode { didSet { defaults.set(themeMode.rawValue, forKey: "themeMode") } }
    var optionAsAlt: OptionAsAlt { didSet { defaults.set(optionAsAlt.rawValue, forKey: "optionAsAlt") } }
    var cursorShape: CursorShape { didSet { defaults.set(cursorShape.rawValue, forKey: "cursorShape") } }
    var cursorBlink: Bool { didSet { defaults.set(cursorBlink, forKey: "cursorBlink") } }
    var showStatusBar: Bool { didSet { defaults.set(showStatusBar, forKey: "showStatusBar") } }
    var dimUnfocusedPanes: Bool { didSet { defaults.set(dimUnfocusedPanes, forKey: "dimUnfocusedPanes") } }
    var confirmUnsafePaste: Bool { didSet { defaults.set(confirmUnsafePaste, forKey: "confirmUnsafePaste") } }
    /// A mouse selection goes to the pasteboard when the button comes up.
    var copyOnSelect: Bool { didSet { defaults.set(copyOnSelect, forKey: "copyOnSelect") } }
    /// Claude Code started from Axolotty gets `axolotty mcp` (see the panes, start and drive agents).
    var agentTools: Bool { didSet { defaults.set(agentTools, forKey: "agentTools") } }
    /// How Axolotty starts Claude Code: `--permission-mode`, `--model`,
    /// `--effort` values; empty leaves each to Claude Code's own settings.
    var claudeMode: String { didSet { defaults.set(claudeMode, forKey: "claudeMode") } }
    var claudeModel: String { didSet { defaults.set(claudeModel, forKey: "claudeModel") } }
    var claudeEffort: String { didSet { defaults.set(claudeEffort, forKey: "claudeEffort") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "fontSize": Double(Axo.Font.terminalSize), "themeMode": ThemeMode.system.rawValue,
            "optionAsAlt": OptionAsAlt.off.rawValue, "cursorShape": CursorShape.bar.rawValue, "cursorBlink": true,
            "showStatusBar": false, "dimUnfocusedPanes": true, "confirmUnsafePaste": true, "agentTools": true,
            "fontFamily": "", "darkTheme": TerminalTheme.night.name, "lightTheme": TerminalTheme.day.name,
        ])
        fontFamily = defaults.string(forKey: "fontFamily") ?? ""
        claudeMode = defaults.string(forKey: "claudeMode") ?? ""
        claudeModel = defaults.string(forKey: "claudeModel") ?? ""
        claudeEffort = defaults.string(forKey: "claudeEffort") ?? ""
        darkTheme = defaults.string(forKey: "darkTheme") ?? TerminalTheme.night.name
        lightTheme = defaults.string(forKey: "lightTheme") ?? TerminalTheme.day.name
        let size = CGFloat(defaults.double(forKey: "fontSize"))
        fontSize = min(max(size, Axo.Font.terminalRange.lowerBound), Axo.Font.terminalRange.upperBound)
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        optionAsAlt = OptionAsAlt(rawValue: defaults.string(forKey: "optionAsAlt") ?? "") ?? .off
        cursorShape = CursorShape(rawValue: defaults.string(forKey: "cursorShape") ?? "") ?? .bar
        cursorBlink = defaults.bool(forKey: "cursorBlink")
        showStatusBar = defaults.bool(forKey: "showStatusBar")
        dimUnfocusedPanes = defaults.bool(forKey: "dimUnfocusedPanes")
        confirmUnsafePaste = defaults.bool(forKey: "confirmUnsafePaste")
        copyOnSelect = defaults.bool(forKey: "copyOnSelect")
        agentTools = defaults.bool(forKey: "agentTools")
    }

    /// The theme in use for an effective system appearance.
    func theme(systemDark: Bool) -> TerminalTheme {
        let dark = switch themeMode {
        case .system: systemDark
        case .night: true
        case .day: false
        }
        return dark ? ThemeLibrary.named(darkTheme) ?? .night : ThemeLibrary.named(lightTheme) ?? .day
    }
}
