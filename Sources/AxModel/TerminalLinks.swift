public import Foundation

/// Links in a line of terminal text: URLs, and file paths with an optional
/// `:line[:column]` (what compilers, test runners and agents print). Offsets
/// are in Characters of the line. Paths are candidates only: whoever opens one
/// checks it exists, so `a/b` in prose costs nothing.
public enum TerminalLinks {
    public enum Target: Equatable, Sendable {
        case url(URL)
        case path(String, line: Int?, column: Int?)
    }

    public struct Link: Equatable, Sendable {
        public var range: Range<Int>
        public var target: Target
    }

    /// Every link in `text`, left to right, not overlapping.
    public static func find(in text: String) -> [Link] {
        let chars = Array(text)
        var out: [Link] = []
        var taken = IndexSet()
        for (pattern, make) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let r = Range(m.range, in: text) else { continue }
                var lo = text.distance(from: text.startIndex, to: r.lowerBound)
                var hi = text.distance(from: text.startIndex, to: r.upperBound)
                hi = trimTrailing(chars, lo, hi)
                // A leading "(" / "[" around a path belongs to the prose.
                while lo < hi, "([{<\"'`".contains(chars[lo]) { lo += 1 }
                guard lo < hi, !taken.intersects(integersIn: lo ..< hi) else { continue }
                guard let target = make(String(chars[lo ..< hi])) else { continue }
                taken.insert(integersIn: lo ..< hi)
                out.append(Link(range: lo ..< hi, target: target))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// The URL that opens `path` on host `ssh` in an editor of the VS Code
    /// family (`scheme`: vscode, cursor, windsurf), over its Remote-SSH:
    /// `vscode://vscode-remote/ssh-remote+HOST/path`. VS Code opens a path
    /// ending in `:line[:column]` as a file and anything else as a folder,
    /// so a file always carries a line.
    public static func remoteEditorURL(scheme: String, ssh: String, path: String, isFolder: Bool,
                                       line: Int? = nil, column: Int? = nil) -> URL? {
        guard path.hasPrefix("/"), !ssh.isEmpty else { return nil }
        var spec = path
        if !isFolder {
            spec += ":\(line ?? 1)"
            if let column, line != nil { spec += ":\(column)" }
        }
        guard let host = ssh.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let encoded = spec.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(scheme)://vscode-remote/ssh-remote+\(host)\(encoded)")
    }

    /// The link covering character `offset`, if any.
    public static func link(in text: String, at offset: Int) -> Link? {
        find(in: text).first { $0.range.contains(offset) }
    }

    // MARK: Rules

    private static let rules: [(String, @Sendable (String) -> Target?)] = [
        (#"\b(?:https?|ftp|file|ssh|sftp|mailto|vscode|cursor|zed|x-devonthink-item):[^\s<>"'`]+"#, { s in
            URL(string: s).map { .url($0) }
        }),
        // Paths with a slash: absolute, ~/, ./, ../, or relative with a directory.
        (#"(?:~|\.{1,2})?/?(?:[\w.@+\-]+/)+[\w.@+\-]*[\w@+\-](?::\d+(?::\d+)?)?"#, { s in
            pathTarget(s, needsLine: false)
        }),
        // A bare file name only with a line number ("main.swift:42").
        (#"\b[\w.@+\-]+\.[A-Za-z0-9]{1,10}:\d+(?::\d+)?"#, { s in
            pathTarget(s, needsLine: true)
        }),
    ]

    private static func pathTarget(_ s: String, needsLine: Bool) -> Target? {
        var parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var line: Int?, column: Int?
        if parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) {
            line = l
            column = c
            parts.removeLast(2)
        } else if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
            line = l
            parts.removeLast()
        }
        let path = parts.joined(separator: ":")
        if needsLine, line == nil { return nil }
        // Not a path: version numbers ("1.2/3"), ratios, a lone "/".
        guard path.count > 1, path.contains(where: { $0.isLetter }) else { return nil }
        return .path(path, line: line, column: column)
    }

    /// Drops prose punctuation stuck to the end; keeps a ")" that closes a "(" inside.
    private static func trimTrailing(_ c: [Character], _ lo: Int, _ hi: Int) -> Int {
        var hi = hi
        while hi > lo {
            let last = c[hi - 1]
            if ".,;:!?'\"`>".contains(last) {
                hi -= 1
            } else if last == ")" || last == "]" || last == "}" {
                let open: Character = last == ")" ? "(" : last == "]" ? "[" : "{"
                let opens = c[lo ..< hi].filter { $0 == open }.count
                let closes = c[lo ..< hi].filter { $0 == last }.count
                if closes > opens { hi -= 1 } else { break }
            } else {
                break
            }
        }
        return hi
    }
}
