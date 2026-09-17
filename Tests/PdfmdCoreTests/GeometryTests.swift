import Testing
@testable import PdfmdCore

func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, text: String = "t") -> PageBlock {
    PageBlock(kind: .paragraph(text), region: NormalizedRect(x: x, y: y, width: w, height: h), source: .vision)
}

@Test func containmentThreshold() {
    let table = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
    let inside = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
    let straddling = NormalizedRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
    #expect(inside.isSubstantiallyContained(in: table))
    #expect(!straddling.isSubstantiallyContained(in: table))
    #expect(inside.intersectionFractionOfSmaller(table) == 1)
}

@Test func paragraphInsideTableIsSuppressed() {
    let table = PageBlock(kind: .table(TableBlock(rows: [[TableCell(text: "a")]])), region: NormalizedRect(x: 0, y: 0, width: 1, height: 0.5), source: .vision)
    let dup = block(0.1, 0.1, 0.5, 0.2, text: "a")
    let body = block(0.0, 0.6, 1.0, 0.2, text: "body")
    let result = deduplicate([table, dup, body])
    #expect(result.count == 2)
    #expect(result.contains { if case .table = $0.kind { return true }; return false })
    #expect(result.contains { $0.kind.plainText == "body" })
}

@Test func listInsideTableIsSuppressed() {
    let table = PageBlock(kind: .table(TableBlock(rows: [[TableCell(text: "x")]])), region: NormalizedRect(x: 0, y: 0, width: 1, height: 1), source: .vision)
    let list = PageBlock(
        kind: .list(ListBlock(ordered: false, items: [ListItem(marker: "•", text: "x")])),
        region: NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), source: .vision)
    #expect(deduplicate([table, list]).count == 1)
}

@Test func titlesSurviveDedup() {
    let title = PageBlock(kind: .title("Report"), region: NormalizedRect(x: 0, y: 0, width: 1, height: 0.1), source: .vision)
    #expect(deduplicate([title]).count == 1)
}

@Test func overlappingParagraphsKeepLongest() {
    // Vision's nested observations of the same prose (ai-2027.pdf p5).
    let inner = block(0.07, 0.08, 0.58, 0.08, text: "Late 2025: The World’s Most Expensive AI example")
    let outer = block(0.07, 0.08, 0.58, 0.30, text: "Late 2025: The World’s Most Expensive AI example, an agent that understands a task clearly")
    let other = block(0.07, 0.50, 0.58, 0.10, text: "Unrelated body text here.")
    let result = deduplicate([inner, outer, other])
    #expect(result.count == 2)
    #expect(result.contains { $0.kind.plainText.hasPrefix("Late 2025") && $0.kind.plainText.count > 60 })
}

@Test func adjacentParagraphsBothSurvive() {
    let a = block(0.0, 0.0, 1.0, 0.2, text: "First paragraph with enough words to matter here.")
    let b = block(0.0, 0.25, 1.0, 0.2, text: "Second paragraph with enough words to matter here.")
    #expect(deduplicate([a, b]).count == 2)
}

@Test func footnoteInsideBodyBoxSurvives() {
    // A footnote sitting inside its column's bounding box is not a
    // duplicate: containment without textual coverage must not suppress.
    let body = PageBlock(
        kind: .paragraph("The quick brown fox jumps over the lazy dog near the riverbank today."),
        region: NormalizedRect(x: 0.07, y: 0.1, width: 0.58, height: 0.6), source: .vision)
    let footnote = PageBlock(
        kind: .paragraph("See the supplement on fox behavior for details."),
        region: NormalizedRect(x: 0.07, y: 0.6, width: 0.5, height: 0.05), source: .vision)
    let result = deduplicate([body, footnote])
    #expect(result.count == 2)
}

@Test func identicalStripsCollapse() {
    // Cover page: disjoint strips carrying the same whole-page transcript.
    let cover = "AI AI Futures Project 2027 Daniel Kokotajlo Scott Alexander Thomas Larsen Eli Lifland"
    let strips = (0..<5).map { i in
        block(0.07, 0.1 + Double(i) * 0.15, 0.6, 0.1, text: cover)
    }
    #expect(deduplicate(strips).count == 1)
}

@Test func shortRepeatsSurvive() {
    let a = block(0.0, 0.0, 1.0, 0.05, text: "Yes.")
    let b = block(0.0, 0.5, 1.0, 0.05, text: "Yes.")
    #expect(deduplicate([a, b]).count == 2)
}

@Test func confettiFragmentsSuppressed() {
    let junk = PageBlock(kind: .paragraph("囵"), region: NormalizedRect(x: 0.7, y: 0.2, width: 0.02, height: 0.015), source: .vision)
    let label = PageBlock(kind: .paragraph("Dec 1024"), region: NormalizedRect(x: 0.86, y: 0.19, width: 0.035, height: 0.01), source: .vision)
    let caption = PageBlock(
        kind: .paragraph("One morning an agent misread a dashboard caption this badly here today"),
        region: NormalizedRect(x: 0.69, y: 0.26, width: 0.226, height: 0.017), source: .vision)
    let footnote = PageBlock(kind: .paragraph("A real footnote with enough words to matter here."), region: NormalizedRect(x: 0.07, y: 0.9, width: 0.85, height: 0.05), source: .vision)
    let result = deduplicate([junk, label, caption, footnote])
    #expect(result.count == 1)
    #expect(result[0].kind.plainText.hasPrefix("A real footnote"))
}

@Test func foreignScriptConfettiSuppressed() {
    let native = "An English document with no CJK characters at all."
    let cjk = PageBlock(kind: .title("良良。包良"), region: NormalizedRect(x: 0.1, y: 0.4, width: 0.5, height: 0.05), source: .vision)
    let body = PageBlock(kind: .paragraph("Genuine body text stays put."), region: .fullPage, source: .vision)
    let cleaned = suppressUnsupportedScript(blocks: [cjk, body], nativeText: native, quality: .trustworthy)
    #expect(cleaned.count == 1)
    // Genuinely mixed documents keep everything.
    let kept = suppressUnsupportedScript(blocks: [cjk, body], nativeText: native + " 日本語", quality: .trustworthy)
    #expect(kept.count == 2)
}

@Test func bandSortOrdersRows() {
    let a = block(0.0, 0.0, 0.4, 0.1, text: "left-top")
    let b = block(0.6, 0.0, 0.4, 0.1, text: "right-top")
    let c = block(0.0, 0.5, 1.0, 0.1, text: "below")
    let ordered = bandSort([c, b, a]).map(\.kind.plainText)
    #expect(ordered == ["left-top", "right-top", "below"])
}

@Test func twoColumnsReadColumnFirst() {
    var blocks: [PageBlock] = []
    for i in 0..<4 {
        blocks.append(block(0.02, 0.1 + Double(i) * 0.2, 0.44, 0.15, text: "L\(i)"))
        blocks.append(block(0.54, 0.1 + Double(i) * 0.2, 0.44, 0.15, text: "R\(i)"))
    }
    let ordered = orderBlocksForReading(blocks).map(\.kind.plainText)
    #expect(ordered == ["L0", "L1", "L2", "L3", "R0", "R1", "R2", "R3"])
}
