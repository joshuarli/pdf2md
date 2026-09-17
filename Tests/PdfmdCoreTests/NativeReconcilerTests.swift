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
