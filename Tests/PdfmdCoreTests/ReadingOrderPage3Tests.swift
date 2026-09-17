import Testing
@testable import PdfmdCore

// Real Vision block regions from page 3 of the pinned AI 2027 PDF (captured
// via --debug-dir). The margin rail (footnote bodies at x≈0.685) must split
// off as a column so body prose reads before margin notes.
@Test func splitColumnsHandlesBodyPlusMarginRail() {
    func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String) -> PageBlock {
        PageBlock(kind: .paragraph(text), region: NormalizedRect(x: x, y: y, width: w, height: h), source: .vision)
    }
    let blocks = [
        block(0.071, 0.083, 0.282, 0.015, "title"),
        block(0.071, 0.117, 0.332, 0.015, "p1"),
        block(0.071, 0.142, 0.582, 0.065, "p2"),
        block(0.071, 0.208, 0.576, 0.033, "p3"),
        block(0.071, 0.250, 0.576, 0.031, "p4"),
        block(0.071, 0.290, 0.582, 0.085, "p5"),
        block(0.685, 0.275, 0.294, 0.062, "m1"),
        block(0.068, 0.375, 0.579, 0.033, "p5b"),
        block(0.685, 0.350, 0.297, 0.050, "m2"),
        block(0.071, 0.417, 0.582, 0.083, "p6"),
        block(0.685, 0.412, 0.294, 0.050, "m3"),
        block(0.071, 0.554, 0.418, 0.015, "h"),
        block(0.071, 0.585, 0.579, 0.058, "p7"),
        block(0.071, 0.646, 0.459, 0.015, "p8"),
        block(0.068, 0.752, 0.579, 0.065, "f*"),
        block(0.079, 0.817, 0.559, 0.052, "f2"),
        block(0.068, 0.865, 0.582, 0.031, "f3"),
        block(0.071, 0.894, 0.576, 0.027, "f4"),
    ]
    let order = orderBlocksForReading(blocks)
    let labels = order.map(\.kind.plainText)
    // Body prose (all 12 body blocks incl. footnotes living at page bottom)
    // reads before the three margin-rail notes.
    #expect(labels.first == "title")
    #expect(Array(labels.suffix(3)) == ["m1", "m2", "m3"])
    #expect(Array(labels.dropLast(3)) == [
        "title", "p1", "p2", "p3", "p4", "p5", "p5b", "p6", "h", "p7", "p8", "f*", "f2", "f3", "f4",
    ])
}

/// A genuine two-column page still reads column-first.
@Test func splitColumnsStillHandlesTrueTwoColumn() {
    func block(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String) -> PageBlock {
        PageBlock(kind: .paragraph(text), region: NormalizedRect(x: x, y: y, width: w, height: h), source: .vision)
    }
    let blocks = [
        block(0.05, 0.05, 0.42, 0.4, "L1"),
        block(0.05, 0.5, 0.42, 0.4, "L2"),
        block(0.55, 0.05, 0.4, 0.4, "R1"),
        block(0.55, 0.55, 0.4, 0.4, "R2"),
    ]
    let order = orderBlocksForReading(blocks)
    #expect(order.map(\.kind.plainText) == ["L1", "L2", "R1", "R2"])
}

