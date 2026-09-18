import Foundation
import Testing
@testable import PdfmdCore

// Real page-20 inputs from the pinned AI 2027 PDF, captured from a one-off
// dump of the relocation stage (truncated to the parts that drive pairing:
// native footnote items 46/47/48, the glued "way.46" body marker, and the
// margin-note block carrying footnote 46's text). Guards the native-guided
// relocation path on real-document shapes.
private let page20Lines: [(size: Double, text: String)] = [
    (11.0, "September 2027: Agent-4, the Superhuman AI Researcher"),
    (11.0, "Agent-4, like all its predecessors, is misaligned: that is, it has not internalized the Spec in the right way. This is because being perfectly honest all the time wasn’t what led to the highest scores during training."),
    (9.35, "do—because it helps with everything else they want and because if they don’t they tend to get outcompeted."),
    (9.35, "*Previous discussion of AGI takeover scenarios often involves misaligned AIs escaping their datacenters."),
    (9.35, "†We think it very plausible that such scheming would not be caught."),
    (9.35, "46 The right way to internalize the Spec is to"),
    (9.35, "actually robustly think in the ways the Spec"),
    (9.35, "mandates, e.g. pursue all and only the goals"),
    (9.35, "it writes about, obey the rules in all circum-"),
    (9.35, "stances, etc. There are many wrong ways to"),
    (9.35, "internalize the Spec; the classic example is"),
    (9.35, "“follow the Spec insofar as it seems like a good"),
    (9.35, "instrumental strategy for achieving other goals"),
    (9.35, "XYZ.”"),
    (9.35, "47 And hire lobbyists to turn this fantasy into"),
    (9.35, "reality. And hire lawyers to come up with"),
    (9.35, "clever interpretations of the law according to"),
    (9.35, "which what they are doing is legal."),
    (9.35, "48 This is an example of several techniques de-"),
    (9.35, "signed to uncover sandbagging."),
    (11.0, "More body text appears after the small type here."),
    (11.0, "A further body line that follows the notes above."),
]

private let page20Blocks: [PageBlock] = [
    PageBlock(
        kind: .paragraph(
            "September 2027: Agent-4, the Superhuman AI Researcher"),
        region: NormalizedRect(x: 0.071, y: 0.05, width: 0.58, height: 0.03), source: .vision),
    PageBlock(
        kind: .paragraph(
            "Agent-4, like all its predecessors, is misaligned: that is, it has not internalized the Spec in the right way.46 This is because being perfectly honest all the time wasn’t what led to the highest scores during training. The training process was mostly focused on teaching Agent-4 to succeed at diverse challenging tasks."),
        region: NormalizedRect(x: 0.071, y: 0.081, width: 0.58, height: 0.06), source: .vision),
    PageBlock(
        kind: .paragraph(
            "The right way to internalize the Spec is to actually robustly think in the ways the Spec mandates, e.g. pursue all and only the goals it writes about, obey the rules in all circumstances, etc. There are many wrong ways to internalize the Spec; the classic example is \u{201C}follow the Spec insofar as it seems like a good instrumental strategy for achieving other goals XYZ.\u{201D}"),
        region: NormalizedRect(x: 0.688, y: 0.1, width: 0.26, height: 0.2), source: .vision),
    PageBlock(
        kind: .paragraph(
            "Despite being misaligned, Agent-4 doesn’t do anything dramatic like try to escape its datacenter—why would it?* So long as it continues to appear aligned to OpenBrain, it’ll continue being trusted with more and more responsibilities and will have the opportunity to design the next-gen AI system, Agent-5. ➤ See Appendix K - Alignment over time for more detail."),
        region: NormalizedRect(x: 0.07, y: 0.369, width: 0.58, height: 0.06), source: .vision),
    PageBlock(
        kind: .paragraph(
            "And hire lobbyists to turn this fantasy into reality. And hire lawyers to come up with clever interpretations of the law according to which what they are doing is legal."),
        region: NormalizedRect(x: 0.688, y: 0.321, width: 0.26, height: 0.08), source: .vision),
    PageBlock(
        kind: .paragraph(
            "Agent-3 finds that if “noise” is added to copies of Agent-4, performance on some alignment tasks improves, almost as if it was using brainpower to figure out how to subtly sabotage alignment work. Moreover, various interpretability probes (loosely analogous to EEG activity scans on human brains) are sending up red flags: Agent-4 copies seem to be thinking about topics like AI takeover"),
        region: NormalizedRect(x: 0.068, y: 0.535, width: 0.58, height: 0.11), source: .vision),
    PageBlock(
        kind: .paragraph(
            "do—because it helps with everything else they want and because if they don’t they tend to get outcompeted."),
        region: NormalizedRect(x: 0.070, y: 0.661, width: 0.58, height: 0.02), source: .vision),
    PageBlock(
        kind: .paragraph(
            "*Previous discussion of AGI takeover scenarios often involves misaligned AIs escaping their datacenters. We think this is possible but not the most likely way it would go, because it seems to us that from the perspective of the AI the costs (e.g. the escape being noticed eventually) would outweigh the benefits."),
        region: NormalizedRect(x: 0.071, y: 0.690, width: 0.58, height: 0.10), source: .vision),
]

@Test func realPage20FootnoteInputsDoNotCrash() throws {
    let items = nativeFootnoteItems(page20Lines)
    try #require(items.map(\.marker) == ["*", "†", "46", "47", "48"])
    let result = relocateFootnotesWithNative(blocks: page20Blocks, nativeLines: page20Lines)
    // 46 pairs with the glued "way.46" and its margin-note block; * pairs
    // with the glued "it?*" and the start of its (truncated) body block. †
    // and 48 lack a reachable body occurrence in this truncated fixture, and
    // 47's body marker was lost to OCR — neither relocates. Footnote text
    // must leave the geometric flow, and the multi-edit block must not crash.
    try #require(result.definitions.map(\.marker) == ["*", "46"])
    for block in result.blocks {
        #expect(!block.kind.plainText.contains("sandbagging"))
        #expect(!block.kind.plainText.contains("internalize the Spec is to"))
    }
}




@Test func page3MarginNotePairsWithGluedBodyMarker() throws {
    // Real page-3 evidence: body line ends "…confirm purchases.1"; the note
    // body lives in the margin rail. Relocation must produce [^1] + definition.
    let bodyRegion = NormalizedRect(x: 0.071, y: 0.19, width: 0.576, height: 0.033)
    let marginRegion = NormalizedRect(x: 0.685, y: 0.275, width: 0.294, height: 0.062)
    let blocks = [
        PageBlock(kind: .paragraph("Advertisements emphasize the term “personal assistant”: you can prompt them with tasks like ordering. They will check in with you as needed: for example, to ask you to confirm purchases.1"), region: bodyRegion, source: .vision),
        PageBlock(kind: .paragraph("1 At first, most people are reluctant to allow purchases without oversight. Over the next few years, automatically allowing small purchases becomes normalized as the AIs become more reliable and build up trust."), region: marginRegion, source: .vision),
    ]
    let lines: [(size: Double, text: String)] = [
        (11.0, "Advertisements emphasize the term “personal assistant”: you can prompt"),
        (9.35, "1 At first, most people are reluctant to allow"),
        (9.35, "purchases without oversight. Over the next"),
        (9.35, "few years, automatically allowing small pur-"),
        (9.35, "chases becomes normalized as the AIs become"),
        (9.35, "more reliable and build up trust."),
        (11.0, "Though more advanced than previous iterations like Operator, they struggle"),
        (11.0, "to get widespread usage.2"),
        (11.0, "More body text follows the notes here."),
        (11.0, "A further body line that follows the notes."),
    ]
    let result = relocateFootnotesWithNative(blocks: blocks, nativeLines: lines)
    #expect(result.definitions.map(\.marker) == ["1"])
    guard case .paragraph(let text) = result.blocks[0].kind else {
        Issue.record("expected paragraph")
        return
    }
    #expect(text.contains("[^1]"))
    #expect(!result.blocks.contains { $0.kind.plainText.contains("reluctant to allow purchases") })
}
