import AppKit
import AxModel
import Observation

/// Person-level settings, persisted in UserDefaults. One instance per app.
@Observable
final class Preferences {
    enum ThemeMode: String, CaseIterable { case system, night, day }
    enum OptionAsAlt: String, CaseIterable { case off, left, right, both }

    @ObservationIgnored private let defaults: UserDefaults

    var fontSize: CGFloat { didSet { defaults.set(Double(fontSize), forKey: "fontSize") } }
    /// The terminal font's family; empty is the system's (SF Mono).
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "fontFamily") } }
    var themeMode: ThemeMode { didSet { defaults.set(themeMode.rawValue, forKey: "themeMode") } }
    var optionAsAlt: OptionAsAlt { didSet { defaults.set(optionAsAlt.rawValue, forKey: "optionAsAlt") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "fontSize": Double(Axo.Font.terminalSize), "themeMode": ThemeMode.system.rawValue,
            "optionAsAlt": OptionAsAlt.off.rawValue, "fontFamily": "",
        ])
        fontFamily = defaults.string(forKey: "fontFamily") ?? ""
        let size = CGFloat(defaults.double(forKey: "fontSize"))
        fontSize = min(max(size, Axo.Font.terminalRange.lowerBound), Axo.Font.terminalRange.upperBound)
        themeMode = ThemeMode(rawValue: defaults.string(forKey: "themeMode") ?? "") ?? .system
        optionAsAlt = OptionAsAlt(rawValue: defaults.string(forKey: "optionAsAlt") ?? "") ?? .off
    }

    /// The theme in use for an effective system appearance.
    func theme(systemDark: Bool) -> TerminalTheme {
        let dark = switch themeMode {
        case .system: systemDark
        case .night: true
        case .day: false
        }
        return dark ? .night : .day
    }
}
