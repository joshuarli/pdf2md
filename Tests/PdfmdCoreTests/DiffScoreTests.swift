import Testing
@testable import PdfmdCore

@Test func identicalTextsScorePerfectly() {
    let report = scoreTokens(gold: ["a", "b", "c"], candidate: ["a", "b", "c"])
    #expect(report.textMatch == 1)
    #expect(report.novelText == 0)
    #expect(report.matchingTokens == 3)
}

@Test func substitutionCountsOnce() {
    let report = scoreTokens(gold: ["a", "b", "c"], candidate: ["a", "x", "c"])
    #expect(report.replacements == 1)
    #expect(report.deletions == 0 && report.insertions == 0)
}

@Test func movedBlockScoresAsChangeNotCatastrophe() {
    // Footnote at page end (gold) vs inline (candidate): patience anchors
    // around the move keep measurement feasible. Standard diff semantics
    // count a move twice (deletion here, insertion there) — only adjacent
    // delete+insert runs pair into replacements. This is precisely why the
    // pipeline must learn gold's footnote placement (plan.md Phase 3)
    // instead of the scorer pretending moves are free.
    let body = ["the", "quick", "brown", "fox", "jumps", "over", "over", "unique-anchor-one"]
    let note = ["see", "the", "supplement", "unique-anchor-two"]
    let gold = body + note
    let candidate = ["the", "quick"] + note + ["brown", "fox", "jumps", "over", "over", "unique-anchor-one"]
    let report = scoreTokens(gold: gold, candidate: candidate)
    #expect(report.matchingTokens == 8)
    #expect(report.deletions == 4 && report.insertions == 4)
    #expect(abs(report.textMatch - (1 - 8.0 / 12.0)) < 1e-9)
}

@Test func normalizationStripsMarkdown() {
    #expect(normalizeForScoring("# Hello **world**") == "Hello world")
    #expect(normalizeForScoring("[text](https://example.com)") == "text")
    #expect(normalizeForScoring("ﬁsh ­test") == "fish test")
    #expect(tokenize(normalizeForScoring("Price: $12.50!")) == ["price", ":", "$", "12", ".", "50", "!"])
}

@Test func insertionDrivesNovelText() {
    let gold = tokenize(normalizeForScoring("the cat sat"))
    let candidate = tokenize(normalizeForScoring("the cat sat on the mat"))
    let report = scoreTokens(gold: gold, candidate: candidate)
    #expect(report.insertions == 3)
    #expect(report.novelText > 0.3)
    #expect(report.textMatch < 1)
}

@Test func pathologicalInputAbortsInsteadOfExploding() {
    // Wildly different sizes: instant abort via the size gate.
    let gold = [String](repeating: "word", count: 100)
    let candidate = [String](repeating: "other", count: 100_000)
    let report = scoreTokens(gold: gold, candidate: candidate)
    #expect(report.textMatch == 0)
    #expect(report.goldTokens == 100 && report.candidateTokens == 100_000)
    // Same size, nothing in common: small enough to complete honestly.
    let report2 = scoreTokens(gold: ["a", "b", "c"], candidate: ["x", "y", "z", "w"])
    #expect(report2.textMatch == 0)
}
