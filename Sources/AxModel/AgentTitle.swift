/// Trims what an agent writes into its terminal title that a row with the
/// agent's own mark and state badge already says.
///
/// - Leading status glyphs: Claude Code's "✳", the braille spinner frames
///   (U+2800–28FF) and bullets.
/// - A leading vendor name, but only when a real separator follows it:
///   "Codex · Fix login" becomes "Fix login"; "Claude docs" is a title and stays.
///
/// Never returns empty: a title that is nothing but the name stays whole.
public enum AgentTitle {
    public static func trimmed(_ full: String, names: [String]) -> String {
        var t = Substring(full).drop { ch in
            guard let c = ch.unicodeScalars.first else { return false }
            return c.properties.generalCategory == .otherSymbol || (0x2800...0x28FF).contains(c.value)
                || c.properties.isWhitespace || "·•*".unicodeScalars.contains(c)
        }
        let seps = Set(" ·—–-:|")
        for n in names where t.lowercased().hasPrefix(n) {
            let run = t.dropFirst(n.count).prefix { seps.contains($0) }
            if run.contains(where: { $0 != " " }) { t = t.dropFirst(n.count + run.count) }
            break
        }
        let out = t.trimmingWhitespace()
        return out.isEmpty ? Substring(full).trimmingWhitespace() : out
    }
}

private extension Substring {
    func trimmingWhitespace() -> String {
        String(drop { $0.isWhitespace }.reversed().drop { $0.isWhitespace }.reversed())
    }
}
