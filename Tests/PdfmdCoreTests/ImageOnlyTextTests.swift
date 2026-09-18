import Testing
@testable import PdfmdCore

/// `suppressImageOnlyText` (AI 2027 pages 47, 50, 15, 51: chart titles, axis
/// numbers, and a garbled diagram caption that gold excludes entirely
/// because the underlying PDF region is a raster image with no native text
/// of its own — plan.md section 8, section 51 "Chart furniture beyond
/// lists").
struct ImageOnlyTextTests {
    @Test func dropsVisionParagraphWithNoNativeTextAnywhereOnThePage() {
        let nativeText = "A completely unrelated sentence about the report's real subject."
        let block = PageBlock(
            kind: .paragraph("Length Of Coding Tasks AI Agents Can Complete Autonomously"),
            region: NormalizedRect(x: 0.15, y: 0.19, width: 0.58, height: 0.01),
            source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [], nativeText: nativeText, quality: .trustworthy)
        #expect(result.isEmpty)
    }

    @Test func keepsUnreconciledParagraphWhenNativeLinesGeometricallyUnderlieIt() {
        // AI 2027 page 13's footnote ("cype" for "type", "Al" for "AI") never
        // clears reconcileNativeLines's 0.85 threshold, but real native text
        // sits right where Vision drew the box — a footnote, not furniture.
        let region = NormalizedRect(x: 0.1, y: 0.9, width: 0.4, height: 0.03)
        let native = NativeTextLine(text: "32 See this paper for examples of this type of AI behavior.", region: region)
        let block = PageBlock(
            kind: .paragraph("» See this paper for examples of this cype of Al behavior."),
            region: region, source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [native], nativeText: native.text, quality: .trustworthy)
        #expect(result.count == 1)
    }

    @Test func keepsBlockWhoseTextExistsElsewhereOnThePageDespiteNoGeometricOverlap() {
        // A defensive allowance for a drifted Vision bounding box: the exact
        // words are still findable in the page's native text, just not
        // underneath this block's region.
        let nativeText = "The cover title reads Annual Forecast Report for the coming year."
        let block = PageBlock(
            kind: .title("Annual Forecast Report"),
            region: NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05),
            source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [], nativeText: nativeText, quality: .trustworthy)
        #expect(result.count == 1)
    }

    @Test func neverTouchesRasterOnlyPages() {
        // Raster-track pages have no trustworthy native layer at all; this
        // filter must stay a born-digital-only signal (plan.md's raster
        // footnote-marker item already covers the raster track separately).
        let block = PageBlock(
            kind: .paragraph("Some chart caption"),
            region: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.01),
            source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [], nativeText: "", quality: .broken)
        #expect(result.count == 1)
    }

    @Test func dropsCaptionWhoseGeometricOverlapIsWithUnrelatedText() {
        // Defensive: geometric overlap with a native line that shares
        // almost none of the block's own tokens must not count as real
        // backing (two captions can sit close enough that an unrelated
        // line's box brushes this one's).
        let region = NormalizedRect(x: 0.1, y: 0.3, width: 0.5, height: 0.02)
        let unrelated = NativeTextLine(
            text: "Figure from Hao et al., a 2024 paper from Meta implementing this idea.",
            region: region)
        let block = PageBlock(
            kind: .paragraph("gure1 1 comporiian of Chais of Coatinaous Thoaght (COCONUT) with Chain-of-Thooght (CoT)."),
            region: region, source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [unrelated], nativeText: unrelated.text, quality: .trustworthy)
        #expect(result.isEmpty)
    }

    @Test func aBlobPageDoesNotLetFillerWordsFakeExistenceViaOrderedSubsequence() {
        // AI 2027 page 47: this exact garbled caption has zero geometric
        // coverage (Vision drew no native line inside its box at all), and
        // the page's whole character stream is one blank-line-free blob
        // (`splitNativeParagraphs` returns a single giant "paragraph").
        // Before requiring a *contiguous* run, common filler words ("of",
        // "with", "the") let an ordered-subsequence match trivially clear
        // the existence threshold against thousands of unrelated
        // characters, keeping pure OCR fabrication in the output.
        let nativeText = """
            Traditional attention mechanisms allow later forward passes in a model to see intermediate \
            activations of the model for previous tokens. One can avoid this bottleneck by using \
            neuralese: passing an LLM's residual stream back to the early layers of the model, giving \
            it a high-dimensional chain of thought, potentially transmitting over 1,000 times more \
            information. Figure from Hao et al., a 2024 paper from Meta implementing this idea. We \
            call this "neuralese" because unlike English words, these high-dimensional vectors are \
            likely quite difficult for humans to interpret.
            """
        let block = PageBlock(
            kind: .paragraph("gure1 1 comporiian of Chais of Coatinaous Thoaght (COCONUT) with Chain-of-Thooght (CoT)."),
            region: NormalizedRect(x: 0.14, y: 0.5, width: 0.53, height: 0.0125),
            source: .vision)
        let result = suppressImageOnlyText(
            blocks: [block], nativeLines: [], nativeText: nativeText, quality: .trustworthy)
        #expect(result.isEmpty)
    }

    @Test func leavesListsAndTablesAndReconciledBlocksAlone() {
        let list = PageBlock(
            kind: .list(ListBlock(ordered: false, items: [ListItem(marker: "-", text: "GPT-4 8314")])),
            region: NormalizedRect(x: 0.2, y: 0.2, width: 0.05, height: 0.01), source: .vision)
        let reconciled = PageBlock(
            kind: .paragraph("Untethered from any native line but already trusted"),
            region: NormalizedRect(x: 0.2, y: 0.3, width: 0.05, height: 0.01), source: .reconciled)
        let result = suppressImageOnlyText(
            blocks: [list, reconciled], nativeLines: [], nativeText: "", quality: .trustworthy)
        #expect(result.count == 2)
    }
}
