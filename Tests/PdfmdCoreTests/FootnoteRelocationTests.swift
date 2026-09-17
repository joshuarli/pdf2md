import Testing
@testable import PdfmdCore

func footBlock(_ text: String, y: Double = 0.85, x: Double = 0.07, w: Double = 0.85) -> PageBlock {
    PageBlock(kind: .paragraph(text), region: NormalizedRect(x: x, y: y, width: w, height: 0.08), source: .vision)
}

func bodyBlock(_ text: String, y: Double = 0.2) -> PageBlock {
    PageBlock(kind: .paragraph(text), region: NormalizedRect(x: 0.07, y: y, width: 0.58, height: 0.1), source: .vision)
}

@Test func splitsFootnoteStarts() {
    #expect(splitFootnoteStart("5 Compute is measured here.")?.marker == "5")
    #expect(splitFootnoteStart("5 Compute is measured here.")?.rest == "Compute is measured here.")
    #expect(splitFootnoteStart("*For example, this.")?.marker == "*")
    #expect(splitFootnoteStart("†Recall that things.")?.rest == "Recall that things.")
    #expect(splitFootnoteStart("7 7 We consider things.")?.rest == "We consider things.")
    #expect(splitFootnoteStart("Ordinary body text.") == nil)
    #expect(splitFootnoteStart("29 1 is dealing with things.")?.marker == "29")
}

@Test func scansGluedBodyMarkers() {
    #expect(scanBodyMarkers("compute to train.5 OpenBrain") == ["5"])
    #expect(scanBodyMarkers("thefts.* Still, many") == ["*"])
    #expect(scanBodyMarkers("compute† in the") == ["†"])
    // Digit-before-dot needs the relaxed pass (decimals look identical).
    #expect(scanBodyMarkers("GPT-4.6 times more") == [])
    #expect(scanBodyMarkers("GPT-4.6 times more", relaxed: true) == ["6"])
    #expect(scanBodyMarkers("Agent-1 internally") == [])
    #expect(scanBodyMarkers("with 1027 FLOP of compute") == [])
    #expect(scanBodyMarkers("3,000 person company") == [])
}

@Test func relocatesPairedFootnotes() {
    let blocks = [
        bodyBlock("GPT-4 required much compute to train.5 OpenBrain leads."),
        footBlock("5 Compute is measured in operations."),
        footBlock("6 They could train it given time.", y: 0.93),
    ]
    let result = relocateFootnotes(blocks)
    // Paired footnote 5 relocates; unpaired footnote 6 stays in place.
    #expect(result.blocks.count == 2)
    guard case .paragraph(let text) = result.blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text.contains("[^5]"))
    #expect(!text.contains("Compute is measured"))
    #expect(result.definitions.count == 1)
    #expect(result.definitions[0].marker == "5")
}

@Test func unpairedFootnotesStayPut() {
    // No body marker: the text must survive in place, never vanish.
    let blocks = [bodyBlock("Plain body without markers."), footBlock("99 An orphaned note.")]
    let result = relocateFootnotes(blocks)
    #expect(result.blocks.count == 2)
    #expect(result.definitions.isEmpty)
}

@Test func absorbsSameColumnContinuations() {
    let blocks = [
        bodyBlock("Body text with marker.5"),
        footBlock("5 First line of the note.", y: 0.85),
        footBlock("continuation without marker.", y: 0.9),
    ]
    let result = relocateFootnotes(blocks)
    #expect(result.blocks.count == 1)
    #expect(result.definitions.count == 1)
    #expect(result.definitions[0].text.contains("continuation"))
}

@Test func sidebarNotesAreNotAbsorbed() {
    // Same-column gate: a right-column note after a footnote is not its
    // continuation.
    let blocks = [
        bodyBlock("Body text with marker.5"),
        footBlock("5 Footnote body here.", y: 0.85, x: 0.07, w: 0.5),
        footBlock("Sidebar note in another column.", y: 0.9, x: 0.68, w: 0.25),
    ]
    let result = relocateFootnotes(blocks)
    #expect(result.blocks.count == 2)
    #expect(result.definitions.count == 1)
    #expect(!result.definitions[0].text.contains("Sidebar"))
}

func nativeLines(_ rows: [(Double, String)]) -> [(size: Double, text: String)] {
    rows.map { (size: $0.0, text: $0.1) }
}

@Test func segmentsNativeFootnotesBySize() {
    let lines = nativeLines([
        (11.0, "Body text with marker.5"),
        (11.0, "More body text here again."),
        (11.0, "Even more body text here now."),
        (9.4, "5 Compute is measured in operations here."),
        (9.4, "and multiplication over the course."),
        (11.0, "Body continues."),
    ])
    let items = nativeFootnoteItems(lines)
    #expect(items.count == 1)
    #expect(items[0].marker == "5")
    #expect(items[0].text.contains("multiplication"))
}

@Test func nativeGuidedRelocationMovesSpans() {
    // Mega-paragraph with the footnote inline, as Vision emits it.
    let mega = "GPT-4 required much compute to train.5 OpenBrain leads in public 5 Compute is measured in floating point operations over time. The model is large."
    let blocks = [PageBlock(kind: .paragraph(mega), region: .fullPage, source: .vision)]
    let lines = nativeLines([
        (11.0, "GPT-4 required much compute to train.5 OpenBrain leads in public"),
        (9.4, "5 Compute is measured in floating point operations over time."),
        (11.0, "The model is large."),
    ])
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    #expect(result.definitions.count == 1)
    #expect(result.definitions[0].marker == "5")
    #expect(result.definitions[0].text.contains("floating point"))
    guard case .paragraph(let text) = result.blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text.contains("[^5]"))
    #expect(!text.contains("floating point"))
    #expect(text.contains("The model is large."))
}

@Test func nativeGuidedFallsBackWithoutItems() {
    let blocks = [bodyBlock("Plain body."), footBlock("5 An unpaired note.")]
    let lines = nativeLines([(11.0, "Plain body."), (11.0, "More body.")])
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    // Geometric fallback: unpaired footnote stays in place.
    #expect(result.blocks.count == 2)
    #expect(result.definitions.isEmpty)
}
