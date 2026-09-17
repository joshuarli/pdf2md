import Testing
@testable import PdfmdCore

func simplePage() -> PageIR {
    PageIR(pageNumber: 1, pageWidth: 612, pageHeight: 792, blocks: [
        PageBlock(kind: .paragraph("Plain prose. Nothing ambiguous."), region: .fullPage, source: .vision)
    ])
}

@Test func simpleProseNeverRoutes() {
    #expect(!ComplexityRouter().routesToRepair(simplePage()))
}

@Test func irregularTablesRoute() {
    var page = simplePage()
    page.complexity.mergedCells = true
    #expect(ComplexityRouter().routesToRepair(page))
}

@Test func severeDisagreementRoutes() {
    var page = simplePage()
    page.complexity.nativeVisionDisagreement = true
    #expect(ComplexityRouter().routesToRepair(page))
}
