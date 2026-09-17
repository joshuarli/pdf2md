import Testing
@testable import PdfmdCore

func furniturePage(top: String, bottom: String, body: String) -> [PageBlock] {
    [
        PageBlock(kind: .paragraph(top), region: NormalizedRect(x: 0, y: 0.01, width: 1, height: 0.05), source: .vision),
        PageBlock(kind: .paragraph(body), region: NormalizedRect(x: 0, y: 0.3, width: 1, height: 0.4), source: .vision),
        PageBlock(kind: .paragraph(bottom), region: NormalizedRect(x: 0, y: 0.95, width: 1, height: 0.04), source: .vision),
    ]
}

@Test func recurringHeaderAndFooterRemoved() {
    let pages = (1...5).map { i in furniturePage(top: "AI 2027 Report", bottom: "Page \(i)", body: "Unique body \(i)") }
    let stripped = stripRepeatedFurniture(pages: pages)
    for (i, page) in stripped.enumerated() {
        #expect(page.count == 1)
        #expect(page[0].kind.plainText == "Unique body \(i + 1)")
    }
}

@Test func uniqueFirstPageTitleRetained() {
    let pages = [
        furniturePage(top: "Special Title", bottom: "1", body: "Body one"),
        furniturePage(top: "Running Head", bottom: "2", body: "Body two"),
        furniturePage(top: "Running Head", bottom: "3", body: "Body three"),
        furniturePage(top: "Running Head", bottom: "4", body: "Body four"),
    ]
    let stripped = stripRepeatedFurniture(pages: pages)
    #expect(stripped[0].contains { $0.kind.plainText == "Special Title" })
}

@Test func footnoteCandidatesDetected() {
    let footnote = PageBlock(kind: .paragraph("1 See appendix for details."), region: NormalizedRect(x: 0, y: 0.85, width: 0.9, height: 0.1), source: .vision)
    let body = PageBlock(kind: .paragraph("Main text."), region: NormalizedRect(x: 0, y: 0.2, width: 1, height: 0.3), source: .vision)
    #expect(isFootnoteCandidate(footnote))
    #expect(!isFootnoteCandidate(body))
}
