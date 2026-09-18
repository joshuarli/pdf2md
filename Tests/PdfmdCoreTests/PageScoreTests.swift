import Testing
@testable import PdfmdCore

@Test func perfectPagesEachScorePerfectly() {
    let page1 = ["a", "b", "c"]
    let page2 = ["d", "e", "f"]
    let scores = scorePages(gold: page1 + page2, candidatePages: [(1, page1), (2, page2)])
    #expect(scores.map(\.pageNumber) == [1, 2])
    #expect(scores.allSatisfy { $0.report.textMatch == 1 })
}

@Test func oneCatastrophicPageIsIsolatedFromNeighbors() {
    let good1 = (0..<40).map { "w\($0)" }
    let good2 = (40..<80).map { "w\($0)" }
    let gold = good1 + good2
    // Page "bad" contributes nothing recognizable; its neighbors still align.
    let scores = scorePages(
        gold: gold,
        candidatePages: [(1, good1), (2, ["garbled", "nonsense"]), (3, good2)]
    )
    #expect(scores[0].report.textMatch > 0.9)
    #expect(scores[2].report.textMatch > 0.9)
    #expect(scores[1].report.textMatch < 0.5)
}

@Test func worstSubstantivePageIgnoresTinyPages() {
    let scores = [
        PageScore(pageNumber: 1, report: scoreTokens(gold: ["only", "two"], candidate: [])),
        PageScore(pageNumber: 2, report: scoreTokens(gold: (0..<40).map { "w\($0)" }, candidate: Array((0..<30).map { "w\($0)" }))),
    ]
    let worst = worstSubstantivePage(scores)
    #expect(worst?.pageNumber == 2)
}

@Test func worstSubstantivePageIsNilWhenNoPageHasEnoughMatches() {
    let scores = [PageScore(pageNumber: 1, report: scoreTokens(gold: ["a", "b"], candidate: ["a"]))]
    #expect(worstSubstantivePage(scores) == nil)
}
