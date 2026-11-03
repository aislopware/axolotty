import AppKit
import AxClient
import AxModel
import AxProtocol

/// The host a far pane runs on, as its links need it.
struct FarHost {
    /// The HostSession's id (what the host said is cached under).
    let id: UUID
    /// What ssh reaches the host by (the name it was dialled as), for an
    /// editor's Remote-SSH; nil when it isn't reached that way.
    let ssh: String?
    let connection: HostConnection
    /// What the person calls it ("Mac Studio").
    let name: String
}

/// Where a pane's printed paths live: relative ones resolve against `cwd`,
/// on this Mac or, with `far`, on that host.
struct LinkContext {
    var cwd = ""
    var far: FarHost?
}

/// Opens what a ⌘-click lands on. URLs go to their app; a file path is
/// resolved against the pane's directory and opens only if it exists, at its
/// line in a code editor when one is installed, else in the file's default
/// app. A far pane's path is checked on its host and opens there, in an editor
/// that edits over SSH (the VS Code family's Remote-SSH).
enum LinkOpener {
    /// Editors that open `file:line:column` by URL, in the order tried, and
    /// whether they open `vscode-remote` URLs (VS Code's own handler, which
    /// its forks keep; Zed's remote projects take no URL).
    private static let editors: [(bundle: String, scheme: String, remote: Bool)] = [
        ("com.todesktop.230313mzl4w4u92", "cursor", true),  // Cursor
        ("com.microsoft.VSCode", "vscode", true),
        ("com.microsoft.VSCodeInsiders", "vscode-insiders", true),
        ("dev.zed.Zed", "zed", false),
        ("com.exafunction.windsurf", "windsurf", true),
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
                if let url = URL(string: "\(editor.scheme)://file\(encoded)") {
                    open(url, in: editor.app)
                    return true
                }
            }
            return NSWorkspace.shared.open(URL(filePath: abs))
        }
    }

    /// An app counts as installed in an Applications folder: LaunchServices
    /// also knows copies in downloads, build folders and disk images, which
    /// are not the person's editor (and may not be safe to start).
    private static func installed(_ bundle: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let folders = ["/Applications/", "/System/Applications/", (home as NSString).appendingPathComponent("Applications") + "/"]
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundle).first { u in
            folders.contains { u.path(percentEncoded: false).hasPrefix($0) }
        }
    }

    private static func installedEditor(remote: Bool = false) -> (scheme: String, app: URL)? {
        for e in editors where e.remote || !remote {
            if let app = installed(e.bundle) { return (e.scheme, app) }
        }
        return nil
    }

    /// Opens an editor URL in that editor's copy (not whichever app claims the scheme).
    private static func open(_ url: URL, in app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The editor a folder opens in ("Cursor", "Visual Studio Code"); with
    /// `remote`, only one that opens a far folder over SSH.
    static func editorName(remote: Bool) -> String? {
        let app = remote ? installedEditor(remote: true)?.app : editorApp
        return app.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "") }
    }

    /// Whether a far host's paths can open here at all.
    static func opensFar(_ far: FarHost) -> Bool { far.ssh != nil && installedEditor(remote: true) != nil }

    /// Opens a web link a far program printed or asked to open. One to that
    /// Mac's own loopback (its dev server, a sign-in's callback) is carried
    /// there first, so it opens here as it would there: at the same port,
    /// or at the one this Mac gave it when its own is taken.
    static func openWeb(_ url: URL, from far: FarHost?) {
        var url = url
        if let far, far.connection.hostFeatures.contains("tunnel") {
            let own = Loopback.port(of: url)
            for port in Loopback.ports(in: url) {
                guard let here = try? far.connection.forward(port: port), port == own else { continue }
                url = Loopback.moved(url, to: here)
            }
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens a path found on a far host in the editor, over SSH.
    @discardableResult
    static func openFar(_ found: HostPath, line: Int? = nil, column: Int? = nil, on far: FarHost) -> Bool {
        guard let ssh = far.ssh, let editor = installedEditor(remote: true),
              let url = TerminalLinks.remoteEditorURL(scheme: editor.scheme, ssh: ssh, path: found.path, isFolder: found.isFolder,
                                  line: line, column: column)
        else { return false }
        open(url, in: editor.app)
        return true
    }

    /// The first installed code editor's app, for opening a folder.
    static var editorApp: URL? {
        for e in editors { if let u = installed(e.bundle) { return u } }
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

/// What far hosts said about printed paths, for a few seconds: ⌘-hover asks
/// once for every path on the screen, so the underline follows the pointer
/// as fast as a near pane's.
@MainActor
enum FarPaths {
    private static var known: [String: (found: HostPath?, at: ContinuousClock.Instant)] = [:]
    private static var asking: [String: Task<Bool, Never>] = [:]
    private static let fresh = Duration.seconds(5)

    private static func key(_ far: FarHost, _ cwd: String, _ candidate: String) -> String {
        candidate.hasPrefix("/") ? "\(far.id) \(candidate)" : "\(far.id) \(cwd) \(candidate)"
    }

    /// What the host said about `candidate`: `.none` when not asked lately.
    static func lookup(_ candidate: String, cwd: String, on far: FarHost) -> HostPath?? {
        guard let hit = known[key(far, cwd, candidate)], ContinuousClock.now - hit.at < fresh else { return nil }
        return .some(hit.found)
    }

    /// Asks the host about the candidates not known lately; `then` runs once
    /// they are answered, this ask's and any already on the way (not when
    /// all were known or the host gave no answer, so a `then` that asks
    /// again comes to rest).
    static func ask(_ candidates: [String], cwd: String, on far: FarHost, then: @escaping @MainActor () -> Void) {
        var seen = Set<String>(), waits: [Task<Bool, Never>] = [], wanted: [String] = []
        for c in candidates {
            let k = key(far, cwd, c)
            guard seen.insert(k).inserted, lookup(c, cwd: cwd, on: far) == nil else { continue }
            if let t = asking[k] { waits.append(t) } else if wanted.count < HostPath.maxBatch { wanted.append(c) }
        }
        if !wanted.isEmpty {
            let keys = wanted.map { key(far, cwd, $0) }
            let t = Task { @MainActor in
                let found = await far.connection.paths(wanted, cwd: cwd)
                for k in keys { asking[k] = nil }
                guard let found, found.count == keys.count else { return false }
                let now = ContinuousClock.now
                if known.count > 4096 { known = known.filter { now - $0.value.at < fresh } }
                for (k, f) in zip(keys, found) { known[k] = (f, now) }
                return true
            }
            for k in keys { asking[k] = t }
            waits.append(t)
        }
        guard !waits.isEmpty else { return }
        Task { @MainActor in
            // No answer (the link is down): nothing new to show, and no asking again.
            for t in waits { guard await t.value else { return } }
            then()
        }
    }
}
