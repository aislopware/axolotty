import AppKit
import AxModel

/// Every terminal theme the person can pick: Axolotty's own two, then the
/// Ghostty themes on this Mac (their own `~/.config/ghostty/themes` first,
/// then the ones Ghostty.app ships), read once and kept. Ghostty's files use
/// the same keys as `TerminalTheme`, so nothing is converted by hand.
enum ThemeLibrary {
    static let builtIn: [TerminalTheme] = [.night, .day]

    /// Built-ins first, then Ghostty's, by name; a name appears once (the
    /// person's own file wins).
    static let all: [TerminalTheme] = {
        var seen = Set(builtIn.map(\.name))
        var found: [TerminalTheme] = []
        for dir in directories {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            where !name.hasPrefix(".") && seen.insert(name).inserted {
                guard let text = try? String(contentsOf: dir.appending(path: name), encoding: .utf8),
                      let t = TerminalTheme.ghostty(name: name, text: text)
                else { continue }
                found.append(t)
            }
        }
        return builtIn + found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func named(_ name: String) -> TerminalTheme? {
        if let t = builtIn.first(where: { $0.name == name }) { return t }
        return all.first { $0.name == name }
    }

    private static var directories: [URL] {
        var dirs: [URL] = []
        let env = ProcessInfo.processInfo.environment
        let config = env["XDG_CONFIG_HOME"].map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config")
        dirs.append(config.appending(path: "ghostty/themes"))
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") {
            dirs.append(app.appending(path: "Contents/Resources/ghostty/themes"))
        }
        return dirs
    }
}
