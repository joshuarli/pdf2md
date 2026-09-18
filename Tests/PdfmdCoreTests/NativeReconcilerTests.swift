import Testing
@testable import PdfmdCore

@Test func assessesQuality() {
    #expect(assessNativeQuality("") == .empty)
    #expect(assessNativeQuality("   \n ") == .empty)
    #expect(assessNativeQuality("The quick brown fox. See https://example.com/a?b=1, price $12.50!") == .trustworthy)
    #expect(assessNativeQuality("������ broken") == .broken)
    #expect(assessNativeQuality("ok\0bad") == .broken)
    #expect(assessNativeQuality("same\nsame\nsame\nsame") == .broken)
}

@Test func prefersExactNativeText() {
    let native = "Visit https://example.com/docs?version=3 for details, priced at $12.50."
    let (blocks, disagreement) = reconcileParagraphs(
        nativeText: native, quality: .trustworthy,
        blocks: [PageBlock(kind: .paragraph("Visit https://example.com/docs?version=3 for details, priced at $12.50."), region: .fullPage, source: .vision)]
    )
    #expect(!disagreement)
    guard case .paragraph(let text) = blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text == native)
    #expect(blocks[0].source == .reconciled)
}

@Test func garbageNativeNeverWins() {
    let blocks = [PageBlock(kind: .paragraph("clean ocr text here"), region: .fullPage, source: .vision)]
    let (kept, _) = reconcileParagraphs(nativeText: "���", quality: .broken, blocks: blocks)
    #expect(kept[0].source == .vision)
}

@Test func shortBlocksGetOneTokenAllowance() {
    let (blocks, _) = reconcileParagraphs(
        nativeText: "We hope you find AI 2027 helpful.", quality: .trustworthy,
        blocks: [PageBlock(kind: .paragraph("We hope you find Al 2027 helpful."), region: .fullPage, source: .vision)]
    )
    guard case .paragraph(let text) = blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text == "We hope you find AI 2027 helpful.")
    #expect(blocks[0].source == .reconciled)
}

@Test func mismatchedRegionsDoNotMerge() {
    let (blocks, disagreement) = reconcileParagraphs(
        nativeText: "Completely unrelated financial disclosure language.",
        quality: .trustworthy,
        blocks: [PageBlock(kind: .paragraph("A recipe for sourdough bread with olives"), region: .fullPage, source: .vision)]
    )
    #expect(blocks[0].source == .vision)
    #expect(disagreement)
}

// AI 2027 page 50: Vision emits the same garbled banner twice — once as
// `.title`, once as an overlapping `.paragraph` observation. Deduplication
// must run on the RAW blocks (while both copies still read identically)
// before the lenient title fallback rewrites one of them; fixing the title
// first makes its text diverge from the still-garbled paragraph copy, and
// text-overlap dedup no longer recognizes them as the same banner. This is
// the composition contract `Pipeline.convertWithPageDrafts` relies on.
@Test func dedupBeforeTitleFallbackMergesDuplicateGarbledBanner() throws {
    let native = "Body text.\nAppendix G - Why we forecast a superhuman coder in early 2027\nMore body."
    let region = NormalizedRect(x: 0.1, y: 0.1, width: 0.6, height: 0.05)
    let garbled = "APPENDIX C. WHY IVE FORECAST A SUPERBUMAN CODERIN FARLY 2027"
    let title = PageBlock(kind: .title(garbled), region: region, source: .vision)
    let duplicateParagraph = PageBlock(kind: .paragraph(garbled), region: region, source: .vision)

    let deduped = deduplicate([title, duplicateParagraph])
    try #require(deduped.count == 1)
    let fixed = reconcileParagraphs(nativeText: native, quality: .trustworthy, blocks: deduped)
    try #require(fixed.blocks.count == 1)
    guard case .title(let text) = fixed.blocks[0].kind else {
        Issue.record("expected title")
        return
    }
    #expect(text == "Appendix G - Why we forecast a superhuman coder in early 2027")
}

@Test func garbledTitleReconcilesToNativeLine() {
    let native = "Some body text here.\nAppendix G - Why we forecast a superhuman coder in early 2027\nMore body text."
    let (blocks, _) = reconcileParagraphs(
        nativeText: native, quality: .trustworthy,
        blocks: [PageBlock(kind: .title("APPENDIX C. WHY IVE FORECAST A SUPERBUMAN CODERIN FARLY 2027"), region: .fullPage, source: .vision)]
    )
    guard case .title(let text) = blocks[0].kind else {
        Issue.record("expected title")
        return
    }
    #expect(text == "Appendix G - Why we forecast a superhuman coder in early 2027")
    #expect(blocks[0].source == .reconciled)
}
