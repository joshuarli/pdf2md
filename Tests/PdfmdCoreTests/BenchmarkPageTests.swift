import Testing
@testable import PdfmdCore

// Page-level comparisons require independently curated page gold. Candidate
// tokens cannot supply the denominator: a perfectly matching fragment still
// represents a catastrophic omission from a substantive page.
@Test func pageScorePenalizesOmissionOfMatchingText() {
    let gold = (0..<100).map { "word\($0)" }
    let report = scoreTokens(gold: gold, candidate: Array(gold.prefix(25)))
    #expect(report.textMatch == 0.25)
    #expect(report.deletions == 75)
    #expect(scoreTokens(gold: gold, candidate: []).textMatch == 0)
}
