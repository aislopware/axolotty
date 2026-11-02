import Foundation

/// What Quick Select labels in a line of terminal text: everything someone
/// copies out of a terminal by hand. URLs and paths (`TerminalLinks`), git
/// hashes (7–40 hex digits with a letter and a digit), and IPv4 addresses
/// with an optional port. Offsets are Characters of the line.
public enum TerminalHints {
    public enum Kind: Equatable, Sendable { case url, path, hash, address }

    public struct Hit: Equatable, Sendable {
        public var range: Range<Int>
        public var text: String
        public var kind: Kind
        /// What opening it means, when it can be opened.
        public var target: TerminalLinks.Target?
    }

    /// Every hit in `text`, left to right, not overlapping.
    public static func find(in text: String) -> [Hit] {
        let chars = Array(text)
        var out: [Hit] = []
        var taken = IndexSet()
        for link in TerminalLinks.find(in: text) {
            let kind: Kind = if case .url = link.target { .url } else { .path }
            out.append(Hit(range: link.range, text: String(chars[link.range]), kind: kind, target: link.target))
            taken.insert(integersIn: link.range)
        }
        for (pattern, kind) in extra {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                guard let r = Range(m.range, in: text) else { continue }
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                let hi = text.distance(from: text.startIndex, to: r.upperBound)
                guard lo < hi, !taken.intersects(integersIn: lo ..< hi) else { continue }
                let s = String(chars[lo ..< hi])
                if kind == .hash, !(s.contains(where: \.isLetter) && s.contains(where: \.isNumber)) { continue }
                if kind == .address, !validAddress(s) { continue }
                taken.insert(integersIn: lo ..< hi)
                out.append(Hit(range: lo ..< hi, text: s, kind: kind, target: nil))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static let extra: [(String, Kind)] = [
        (#"\b[0-9a-f]{7,40}\b"#, .hash),
        (#"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b"#, .address),
    ]

    private static func validAddress(_ s: String) -> Bool {
        let host = s.split(separator: ":").first ?? ""
        return host.split(separator: ".").allSatisfy { (Int($0) ?? 999) <= 255 }
    }

    /// Labels for `count` hits: one key each while they last, then two.
    /// Home-row keys first, the nearest hit (the last) gets the first label.
    public static func labels(_ count: Int) -> [String] {
        let keys = Array("asdfghjklqwertyuiopzxcvbnm").map(String.init)
        guard count > keys.count else { return Array(keys.prefix(count)) }
        // Keep the first `single` keys as one-letter labels; the rest prefix pairs.
        var single = keys.count
        while single > 0, single + (keys.count - single) * keys.count < count { single -= 1 }
        var out = Array(keys.prefix(single))
        for p in keys.dropFirst(single) {
            for k in keys where out.count < count { out.append(p + k) }
        }
        return Array(out.prefix(count))
    }
}
