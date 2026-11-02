import AppKit
import AxModel

/// Opens what a ⌘-click lands on. URLs go to their app; a file path is
/// resolved against the pane's directory and opens only if it exists (on this
/// Mac: a remote pane's paths are not ours to open), at its line in a code
/// editor when one is installed, else in the file's default app.
enum LinkOpener {
    /// Editors that open `file:line:column` by URL, in the order tried.
    private static let editors: [(bundle: String, scheme: String)] = [
        ("com.todesktop.230313mzl4w4u92", "cursor"),  // Cursor
        ("com.microsoft.VSCode", "vscode"),
        ("com.microsoft.VSCodeInsiders", "vscode-insiders"),
        ("dev.zed.Zed", "zed"),
        ("com.exafunction.windsurf", "windsurf"),
    ]

    /// The absolute path a candidate names, if it exists here.
    static func resolve(_ path: String, cwd: String) -> String? {
        var p = path
        if p.hasPrefix("~") { p = NSHomeDirectory() + p.dropFirst() }
        if !p.hasPrefix("/") {
            guard !cwd.isEmpty else { return nil }
            p = (cwd as NSString).appendingPathComponent(p)
        }
        p = (p as NSString).standardizingPath
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Whether `target` would open (paths must exist).
    static func canOpen(_ target: TerminalLinks.Target, cwd: String, local: Bool) -> Bool {
        switch target {
        case .url: true
        case let .path(p, _, _): local && resolve(p, cwd: cwd) != nil
        }
    }

    @discardableResult
    static func open(_ target: TerminalLinks.Target, cwd: String, local: Bool) -> Bool {
        switch target {
        case let .url(url):
            return NSWorkspace.shared.open(url)
        case let .path(p, line, column):
            guard local, let abs = resolve(p, cwd: cwd) else { return false }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: abs, isDirectory: &isDir)
            if !isDir.boolValue, let line, let editor = installedEditor() {
                var spec = abs + ":\(line)"
                if let column { spec += ":\(column)" }
                let encoded = spec.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? spec
                if let url = URL(string: "\(editor)://file\(encoded)"), NSWorkspace.shared.open(url) { return true }
            }
            return NSWorkspace.shared.open(URL(filePath: abs))
        }
    }

    private static func installedEditor() -> String? {
        editors.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundle) != nil }?.scheme
    }

    /// The first installed code editor's app, for opening a folder.
    static var editorApp: URL? {
        for e in editors { if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: e.bundle) { return u } }
        return nil
    }

    /// The repository holding `dir` (its top, where `.git` is), else `dir`.
    static func projectRoot(_ dir: String) -> String {
        var url = URL(filePath: dir, directoryHint: .isDirectory)
        for _ in 0 ..< 32 {
            if FileManager.default.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false)) {
                return url.path(percentEncoded: false)
            }
            let up = url.deletingLastPathComponent()
            if up.path(percentEncoded: false) == url.path(percentEncoded: false) { break }
            url = up
        }
        return dir
    }

    /// Opens a folder in the person's code editor, or Finder when none is installed.
    static func openFolder(_ dir: String) {
        let url = URL(filePath: dir, directoryHint: .isDirectory)
        if let app = editorApp {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
