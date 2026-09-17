import Testing
@testable import PdfmdCore

@Test func nativeParagraphMustNotExpandASmallOCRRegion() {
    let native = "An exact caption. A completely separate paragraph on the other side of the page."
    let block = PageBlock(kind: .paragraph("An exact caption."), region: .fullPage, source: .vision)
    let result = reconcileParagraphs(nativeText: native, quality: .trustworthy, blocks: [block])
    #expect(result.blocks[0].kind.plainText == "An exact caption.")
}

@Test func spatialNativeLinesRepairOnlyTheMatchingParagraph() {
    let body = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1)
    let sidebar = NormalizedRect(x: 0.7, y: 0.2, width: 0.2, height: 0.1)
    let native = [
        NativeTextLine(text: "The AI report costs $12.50.", region: body),
        NativeTextLine(text: "The AI report costs $99.00.", region: sidebar),
    ]
    let blocks = [PageBlock(kind: .paragraph("The Al report costs $12.50."), region: body, source: .vision)]
    let result = reconcileNativeLines(native, quality: .trustworthy, blocks: blocks)
    #expect(result.blocks[0].kind.plainText == native[0].text)
    #expect(result.blocks[0].source == .reconciled)
}

@Test func spatialNativeReconciliationRejectsDisjointAndBrokenEvidence() {
    let block = PageBlock(kind: .paragraph("The Al report costs $12.50."), region: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1), source: .vision)
    let line = NativeTextLine(text: "The AI report costs $12.50.", region: NormalizedRect(x: 0.6, y: 0.7, width: 0.3, height: 0.1))
    #expect(reconcileNativeLines([line], quality: .trustworthy, blocks: [block]).blocks[0].source == .vision)
    let sameRegion = NativeTextLine(text: line.text, region: block.region)
    #expect(reconcileNativeLines([sameRegion], quality: .broken, blocks: [block]).blocks[0].source == .vision)
}

@Test func spatialNativeReconciliationDoesNotAbsorbWholeLineForPartialBlock() {
    let line = NativeTextLine(text: "Caption here. A different paragraph across the page.", region: .fullPage)
    let block = PageBlock(kind: .paragraph("Caption here."), region: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), source: .vision)
    #expect(reconcileNativeLines([line], quality: .trustworthy, blocks: [block]).blocks[0].kind.plainText == "Caption here.")
}
