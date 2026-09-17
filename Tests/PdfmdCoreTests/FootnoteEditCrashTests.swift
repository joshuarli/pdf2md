import Testing
@testable import PdfmdCore

/// Regression: a page whose Vision mega-paragraph carries two candidate
/// positions for one native footnote item ("train.7" glued, "7 Compute"
/// floated) must relocate exactly once. Guards the greedy span retry: a
/// failed span attempt must not consume the marker for a later page run.
@Test func multipleEditsPerBlockNeverCrash() {
    // Body carries marker 7 twice: once glued ("train.7"), once floated
    // before the footnote body. Both edits land in the same block.
    let mega = "Models needed compute to train.7 OpenBrain leads in public 7 Compute is measured in floating point operations over time and is large."
    let blocks = [PageBlock(kind: .paragraph(mega), region: .fullPage, source: .vision)]
    let lines = nativeLines([
        (11.0, "Models needed compute to train.7 OpenBrain leads in public"),
        (9.4, "7 Compute is measured in floating point operations over time."),
        (11.0, "The model is large."),
        (11.0, "More body text follows here."),
        (11.0, "Even more body text here now."),
    ])
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    #expect(result.definitions.map(\.marker) == ["7"])
    guard case .paragraph(let text) = result.blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text.contains("[^7]"))
    #expect(!text.contains("floating point"))
}

/// Stress pass over repeated markers: end-to-start edit application must stay
/// correct for every pairing, not just the common single-edit case.
@Test func editApplicationStressOverRepeatedMarkers() {
    let note = "7 Note about the floating point operations over time."
    for _ in 0..<40 {
        let body = "Models needed compute to train.7 OpenBrain leads in public 7 Note about the floating point operations over time. The end."
        let blocks = [PageBlock(kind: .paragraph(body), region: .fullPage, source: .vision)]
        let lines = nativeLines([
            (11.0, "Models needed compute to train.7 OpenBrain leads in public"),
            (9.4, note),
            (11.0, "The model is large."),
            (11.0, "More body text follows here."),
            (11.0, "Even more body text here now."),
        ])
        let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
        #expect(result.definitions.count == 1)
        for block in result.blocks {
            #expect(!block.kind.plainText.contains("floating point"))
        }
    }
}
