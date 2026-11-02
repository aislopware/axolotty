/// Fuzzy matching for the command palette: an optimal-alignment DP in the style of
/// fzf v2. Each matched character scores a base, plus a bonus for starting a word
/// or camelCase hump; characters in a consecutive run inherit the bonus of the
/// run's first character, and every skipped character between matches costs.
/// Candidates are short (titles, commands), so O(query × candidate) is fine.
public enum Fuzzy {
    public struct Match: Equatable, Sendable {
        public var score: Int
        /// Indices (in `Character`s) of the candidate that matched, for highlighting.
        public var positions: [Int]
    }

    static let base = 16
    static let bonusFirst = 32
    static let bonusWord = 28
    static let bonusCamel = 20
    static let bonusConsecutive = 24
    static let gap = 3

    public static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return Match(score: 0, positions: []) }
        let c = Array(candidate)
        let n = c.count, m = q.count
        guard m <= n else { return nil }
        let lower = c.map { Character($0.lowercased()) }

        let bonus: [Int] = (0 ..< n).map { j in
            if j == 0 { return bonusFirst }
            let p = c[j - 1]
            if p == " " || p == "/" || p == "-" || p == "_" || p == "." || p == ":" { return bonusWord }
            if c[j].isUppercase, p.isLowercase { return bonusCamel }
            if c[j].isNumber, !p.isNumber { return bonusCamel }
            return 0
        }

        let none = Int.min / 4
        // score[i][j]: best score with q[i] matched at c[j]; run[i][j]: bonus of the
        // run's first char when that best path ends in a consecutive run.
        var score = [[Int]](repeating: [Int](repeating: none, count: n), count: m)
        var runBonus = [[Int]](repeating: [Int](repeating: 0, count: n), count: m)
        var from = [[Int]](repeating: [Int](repeating: -1, count: n), count: m)

        for i in 0 ..< m {
            // Best of score[i-1][k] - gap*(j-k-1) over k < j-1, maintained incrementally.
            var bestGapped = none, bestGappedAt = -1
            for j in i ..< n {
                guard lower[j] == q[i] else {
                    if i > 0, j >= 1 { updateGapped(&bestGapped, &bestGappedAt, score[i - 1], j - 1) }
                    continue
                }
                if i == 0 {
                    score[i][j] = base + bonus[j]
                    runBonus[i][j] = bonus[j]
                } else {
                    var best = none, parent = -1, rb = bonus[j]
                    // Consecutive: q[i-1] at j-1.
                    if j >= 1, score[i - 1][j - 1] > none {
                        let inherited = max(bonusConsecutive, runBonus[i - 1][j - 1], bonus[j])
                        let s = score[i - 1][j - 1] + base + inherited
                        if s > best {
                            best = s
                            parent = j - 1
                            rb = max(runBonus[i - 1][j - 1], bonus[j])
                        }
                    }
                    // Gapped: q[i-1] at some k < j-1.
                    if bestGappedAt >= 0 {
                        let s = score[i - 1][bestGappedAt] - gap * (j - bestGappedAt - 1) + base + bonus[j]
                        if s > best {
                            best = s
                            parent = bestGappedAt
                            rb = bonus[j]
                        }
                    }
                    score[i][j] = best
                    from[i][j] = parent
                    runBonus[i][j] = rb
                }
                if i > 0, j >= 1 { updateGapped(&bestGapped, &bestGappedAt, score[i - 1], j - 1) }
            }
        }

        var endJ = -1, endScore = none
        for j in 0 ..< n where score[m - 1][j] > endScore {
            endScore = score[m - 1][j]
            endJ = j
        }
        guard endJ >= 0, endScore > none else { return nil }
        var positions = [Int](repeating: 0, count: m)
        var j = endJ
        for i in stride(from: m - 1, through: 0, by: -1) {
            positions[i] = j
            j = from[i][j]
        }
        return Match(score: endScore - n / 8, positions: positions)
    }

    /// Keeps the k (≤ j) maximizing score[k] + gap*k, i.e. the best gapped parent
    /// for any later j (the -gap*(j-k-1) term then only depends on j).
    @inline(__always)
    private static func updateGapped(_ best: inout Int, _ at: inout Int, _ prev: [Int], _ k: Int) {
        // Only k ≤ j-2 may be a gapped parent of j; callers pass k = j-1 *after*
        // using bestGapped for j, so the invariant holds for j+1.
        let none = Int.min / 4
        guard prev[k] > none else { return }
        let v = prev[k] + gap * k
        if at < 0 || v > best {
            best = v
            at = k
        }
    }

    /// Ranks candidates; stable for equal scores.
    public static func rank<T>(_ query: String, _ items: [T], key: (T) -> String) -> [(item: T, match: Match)] {
        items.enumerated()
            .compactMap { i, item in match(query, in: key(item)).map { (i, item, $0) } }
            .sorted { $0.2.score != $1.2.score ? $0.2.score > $1.2.score : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
}
