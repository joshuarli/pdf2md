import Testing
@testable import PdfmdCore

// Real page-23 shape from the pinned AI 2027 PDF: a glued "*" marker sits in
// one body block, but two full unrelated paragraphs intervene before the
// Vision block that actually carries the footnote's body text. The greedy
// span scan used to accept a common word ("to") spuriously matched in the
// intervening paragraphs as the span's start, so the later blanking step
// erased both intervening paragraphs along with the real footnote text.
@Test func spuriousCommonWordDoesNotErodeInterveningParagraphs() throws {
    let markerBlock = PageBlock(
        kind: .paragraph("It needs to solve its own problem: how to align Agent-5 to Agent-4?*"),
        region: NormalizedRect(x: 0.07, y: 0.3, width: 0.58, height: 0.03), source: .vision)
    // Contains a standalone "to" that is not part of the footnote body, the
    // exact shape that anchored the span in the wrong place.
    let unrelatedA = PageBlock(
        kind: .paragraph("It starts off with only a small toolbox of ad hoc strategies to change them."),
        region: NormalizedRect(x: 0.07, y: 0.35, width: 0.58, height: 0.03), source: .vision)
    let unrelatedB = PageBlock(
        kind: .paragraph("It decides to punt on most of these open questions for another day entirely."),
        region: NormalizedRect(x: 0.07, y: 0.4, width: 0.58, height: 0.03), source: .vision)
    let footnoteBlock = PageBlock(
        kind: .paragraph("*To do this without being detected, it needs to disguise this research from the monitoring team that watches it closely every day."),
        region: NormalizedRect(x: 0.07, y: 0.7, width: 0.58, height: 0.1), source: .vision)
    let blocks = [markerBlock, unrelatedA, unrelatedB, footnoteBlock]
    let lines = nativeLines([
        (11.0, "It needs to solve its own problem: how to align Agent-5 to Agent-4?*"),
        (11.0, "It starts off with only a small toolbox of ad hoc strategies to change them."),
        (11.0, "It decides to punt on most of these open questions for another day entirely."),
        (9.4, "*To do this without being detected, it needs to disguise this research from"),
        (9.4, "the monitoring team that watches it closely every day."),
    ])
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    try #require(result.definitions.map(\.marker) == ["*"])
    #expect(result.definitions[0].text.contains("disguise this research"))
    #expect(result.blocks.contains { $0.kind.plainText.contains("ad hoc strategies to change them") })
    #expect(result.blocks.contains { $0.kind.plainText.contains("open questions for another day") })
}

// Real page-20 shape: two footnote bodies open with near-identical
// phrasing ("We think this is possible..." / "We think it very plausible
// ..."), so the greedy span scan burns the second item's leading tokens on
// the first (wrong, earlier) body and only re-syncs once the wording
// diverges. The recovered dense run then starts a few tokens into its own
// block, and the block-floor snap must pull it back to the block's true
// start — otherwise the body's own opening words are never blanked and
// survive as an orphaned lead-in ahead of the relocated reference.
@Test func nearIdenticalFootnoteOpeningsDoNotLeaveOrphanedLeadIn() throws {
    let markerA = PageBlock(kind: .paragraph("Some AIs might try to escape their datacenter*"),
        region: NormalizedRect(x: 0.07, y: 0.3, width: 0.58, height: 0.03), source: .vision)
    let markerB = PageBlock(kind: .paragraph("Interpretability probes send up red flags about takeover†"),
        region: NormalizedRect(x: 0.07, y: 0.35, width: 0.58, height: 0.03), source: .vision)
    let bodyA = PageBlock(
        kind: .paragraph("*We think this is possible but not the most likely way it would go, all things considered."),
        region: NormalizedRect(x: 0.07, y: 0.7, width: 0.58, height: 0.05), source: .vision)
    let bodyB = PageBlock(
        kind: .paragraph("†We think it very plausible that such scheming would not be caught by anyone watching."),
        region: NormalizedRect(x: 0.07, y: 0.8, width: 0.58, height: 0.05), source: .vision)
    let blocks = [markerA, markerB, bodyA, bodyB]
    let lines = nativeLines([
        (11.0, "Some AIs might try to escape their datacenter*"),
        (11.0, "Interpretability probes send up red flags about takeover†"),
        (9.4, "*We think this is possible but not the most likely way it"),
        (9.4, "would go, all things considered."),
        (9.4, "†We think it very plausible that such scheming would not"),
        (9.4, "be caught by anyone watching."),
    ])
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    try #require(Set(result.definitions.map(\.marker)) == Set(["*", "†"]))
    for def in result.definitions where def.marker == "†" {
        #expect(def.text.hasPrefix("We think it very plausible"))
    }
    #expect(!result.blocks.contains { $0.kind.plainText.hasPrefix("We think it very plausible") })
}
