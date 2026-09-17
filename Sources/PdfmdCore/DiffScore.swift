/// Order-sensitive edit scoring (plan.md section 10).
///
/// `match = 1 - edit_cost(candidate, gold) / token_count(gold)` using Myers
/// O(ND) diff over scoring tokens. Insertions are reported separately from
/// the aggregate so recall-by-hallucination cannot hide: the raster gate
/// pairs a >=95% match with a <1% novel-text rate.
public struct ScoreReport: Sendable {
    public var goldTokens: Int
    public var candidateTokens: Int
    public var matchingTokens: Int
    public var deletions: Int
    public var insertions: Int
    public var replacements: Int
    public var textMatch: Double
    public var novelText: Double

    public init(goldTokens: Int, candidateTokens: Int, matchingTokens: Int, deletions: Int, insertions: Int, replacements: Int) {
        self.goldTokens = goldTokens
        self.candidateTokens = candidateTokens
        self.matchingTokens = matchingTokens
        self.deletions = deletions
        self.insertions = insertions
        self.replacements = replacements
        let editCost = Double(deletions + insertions + replacements)
        self.textMatch = goldTokens > 0 ? max(0, 1 - editCost / Double(goldTokens)) : (candidateTokens == 0 ? 1 : 0)
        self.novelText = candidateTokens > 0 ? Double(insertions + replacements) / Double(candidateTokens) : 0
    }
}

public func scoreTokens(gold: [String], candidate: [String]) -> ScoreReport {
    let matches = myersMatches(gold: gold, candidate: candidate)
    var deletions = 0
    var insertions = 0
    var replacements = 0
    var matching = 0
    var gi = 0
    var ci = 0
    for (mg, mc) in matches {
        let del = mg - gi
        let ins = mc - ci
        // A hunk deleting and inserting together is a substitution, not an
        // independent omission plus fabrication.
        let paired = min(del, ins)
        replacements += paired
        deletions += del - paired
        insertions += ins - paired
        matching += 1
        gi = mg + 1
        ci = mc + 1
    }
    let del = gold.count - gi
    let ins = candidate.count - ci
    replacements += min(del, ins)
    deletions += del - min(del, ins)
    insertions += ins - min(del, ins)
    return ScoreReport(
        goldTokens: gold.count, candidateTokens: candidate.count,
        matchingTokens: matching, deletions: deletions,
        insertions: insertions, replacements: replacements
    )
}

/// Myers greedy LCS: returns matched (goldIndex, candidateIndex) pairs in
/// order. Two phases: a forward-only pass finds the edit distance with O(D)
/// memory, then a second pass records the trace for backtracking. Inputs
/// whose distance exceeds `maximumD` (or whose sizes already prove it)
/// abort to no matches instead of exploding time/memory, and the report
/// still shows the honest token counts with a 0% match. Legitimate
/// candidate-vs-gold comparisons of the same document stay far below the
/// cap; catastrophic drafts fail loudly instead of hanging the runner.
func myersMatches(gold: [String], candidate: [String], maximumD: Int = 5_000) -> [(Int, Int)] {
    let n = gold.count
    let m = candidate.count
    if n == 0 || m == 0 { return [] }
    if abs(n - m) > maximumD { return [] }
    let cap = min(maximumD, n + m)
    let offset = cap
    // Phase 1: forward only, no trace.
    var v = [Int](repeating: -1, count: 2 * cap + 1)
    v[offset + 1] = 0
    var distance = -1
    outer: for d in 0...cap {
        var k = -d
        while k <= d {
            let idx = offset + k
            var x: Int
            if k == -d || (k != d && v[idx - 1] < v[idx + 1]) {
                x = v[idx + 1]
            } else {
                x = v[idx - 1] + 1
            }
            var y = x - k
            while x < n, y < m, gold[x] == candidate[y] {
                x += 1
                y += 1
            }
            v[idx] = x
            if x >= n, y >= m {
                distance = d
                break outer
            }
            k += 2
        }
    }
    guard distance >= 0 else { return [] }
    // Phase 2: rerun with trace for backtracking.
    v = [Int](repeating: -1, count: 2 * cap + 1)
    v[offset + 1] = 0
    var trace: [[Int]] = []
    trace.reserveCapacity(distance + 1)
    for d in 0...distance {
        trace.append(v)
        var k = -d
        while k <= d {
            let idx = offset + k
            var x: Int
            if k == -d || (k != d && v[idx - 1] < v[idx + 1]) {
                x = v[idx + 1]
            } else {
                x = v[idx - 1] + 1
            }
            var y = x - k
            while x < n, y < m, gold[x] == candidate[y] {
                x += 1
                y += 1
            }
            v[idx] = x
            k += 2
        }
    }
    let foundD = distance
    // Backtrack through the trace to recover the match path.
    var matches: [(Int, Int)] = []
    var x = n
    var y = m
    var d = foundD
    while d > 0 {
        let vPrev = trace[d]
        let k = x - y
        let idx = offset + k
        let prevK: Int
        if k == -d || (k != d && vPrev[idx - 1] < vPrev[idx + 1]) {
            prevK = k + 1
        } else {
            prevK = k - 1
        }
        let prevX = vPrev[offset + prevK]
        let prevY = prevX - prevK
        while x > prevX, y > prevY {
            x -= 1
            y -= 1
            matches.append((x, y))
        }
        x = prevX
        y = prevY
        d -= 1
    }
    while x > 0, y > 0 {
        x -= 1
        y -= 1
        matches.append((x, y))
    }
    return matches.reversed()
}
