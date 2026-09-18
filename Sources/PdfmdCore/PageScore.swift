/// Approximate per-page fidelity for the catastrophic-page guardrail
/// (plan.md section 11: "no substantive page < 85%").
///
/// There is no independently curated per-page gold — `golden.md` is one
/// continuous frozen transcription (footnotes relocate across pages,
/// paragraphs join across the p70/p71 boundary) and plan.md accepts that:
/// "compute page-level fidelity where gold-page segmentation can be
/// established reasonably." We approximate the gold/page boundary by
/// linearly interpolating the whole-document alignment at each candidate
/// page's token cut point. Matches are monotonic in both gold and candidate
/// index, so the interpolated boundaries are monotonic too — each page gets
/// a genuine, non-overlapping gold slice, scored independently with the same
/// `scoreTokens` used for the whole document.
public struct PageScore: Sendable {
    public var pageNumber: Int
    public var report: ScoreReport
}

/// `candidatePages` are already-tokenized, normalized page drafts in
/// document order (1:1 with `pageNumbers`). `gold` is the whole-document
/// tokenized golden text.
public func scorePages(gold: [String], candidatePages: [(pageNumber: Int, tokens: [String])]) -> [PageScore] {
    let candidate = candidatePages.flatMap(\.tokens)
    let matches = alignTokens(gold: gold, candidate: candidate)

    var pageStarts: [Int] = [0]
    for page in candidatePages { pageStarts.append(pageStarts.last! + page.tokens.count) }

    // Gold index interpolated at each candidate cut point `pageStarts[i]`
    // from the nearest surrounding matches. `matches` is sorted by `c`.
    func interpolatedGoldBoundary(atCandidateIndex c: Int, searchFrom hint: Int) -> (gold: Int, matchIndex: Int) {
        var lo = hint
        while lo < matches.count, matches[lo].1 < c { lo += 1 }
        let next = lo < matches.count ? matches[lo] : nil
        let prev = lo > 0 ? matches[lo - 1] : nil
        switch (prev, next) {
        case (nil, nil):
            return (0, lo)
        case (nil, .some(let n)):
            return (c <= n.1 ? 0 : n.0, lo)
        case (.some(let p), nil):
            return (p.0 + 1, lo)
        case (.some(let p), .some(let n)):
            guard n.1 > p.1 else { return (p.0 + 1, lo) }
            let fraction = Double(c - p.1) / Double(n.1 - p.1)
            let g = p.0 + Int((Double(n.0 - p.0) * fraction).rounded())
            return (min(max(g, p.0), n.0), lo)
        }
    }

    var boundaries: [Int] = [0]
    var searchHint = 0
    for i in 1..<pageStarts.count - 1 {
        let (g, nextHint) = interpolatedGoldBoundary(atCandidateIndex: pageStarts[i], searchFrom: searchHint)
        boundaries.append(max(g, boundaries.last!))
        searchHint = nextHint
    }
    boundaries.append(gold.count)

    return candidatePages.indices.map { i in
        let goldSlice = Array(gold[boundaries[i]..<boundaries[i + 1]])
        let candidateSlice = candidatePages[i].tokens
        return PageScore(pageNumber: candidatePages[i].pageNumber, report: scoreTokens(gold: goldSlice, candidate: candidateSlice))
    }
}

/// The worst page whose report has at least `minimumAlignedTokens` matches,
/// so a near-empty page (a cover, a chart-only page) cannot claim the
/// "worst page" slot on the strength of a handful of tokens.
public func worstSubstantivePage(_ pages: [PageScore], minimumAlignedTokens: Int = 20) -> PageScore? {
    pages.filter { $0.report.matchingTokens >= minimumAlignedTokens }
        .min { $0.report.textMatch < $1.report.textMatch }
}
