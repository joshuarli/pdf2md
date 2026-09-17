/// Deterministic geometry-based reading order (plan.md section 20).
///
/// Container array order is not trustworthy, so blocks are ordered from
/// geometry: blocks sharing a horizontal band go left-to-right, otherwise
/// top-to-bottom. A real two-column page must read column-by-column, not
/// row-by-row, so an explicit column check runs first: when the blocks split
/// cleanly around a vertical gutter spanning most of the page height, the
/// left column precedes the right one. Genuinely ambiguous layouts keep
/// band order and set `ComplexitySignals.multiColumn` for the repair stage
/// instead of pretending certainty.
public func orderBlocksForReading(_ blocks: [PageBlock]) -> [PageBlock] {
    guard blocks.count > 1 else { return blocks }
    if let columns = splitColumns(blocks) {
        return columns.flatMap { bandSort($0) }
    }
    return bandSort(blocks)
}

/// Sort top-to-bottom, breaking ties left-to-right within a shared band.
public func bandSort(_ blocks: [PageBlock]) -> [PageBlock] {
    blocks.sorted { a, b in
        if a.region.sharesHorizontalBand(with: b.region) {
            if abs(a.region.minX - b.region.minX) > 1e-6 { return a.region.minX < b.region.minX }
            return a.region.minY < b.region.minY
        }
        return a.region.minY < b.region.minY
    }
}

/// Detect an obvious two-column layout. Returns left/right groups when a
/// vertical gutter separates the blocks into two sets, each of substantial
/// vertical extent or (the AI 2027 margin-rail shape) a minority rail beside
/// a majority column with no straddlers; otherwise nil.
public func splitColumns(_ blocks: [PageBlock], gutterWidth: Double = 0.03) -> [[PageBlock]]? {
    guard blocks.count >= 4 else { return nil }
    // Candidate gutters come from empty horizontal strips: the midpoint of
    // one block's right edge and the next left edge above it. Midline pairs
    // alone miss wide-body/narrow-rail pages because the rail's midlines sit
    // inside the body's span (an AI 2027 page: body ends at 0.65, rail starts
    // at 0.685, rail midlines ~0.83 — no adjacent-midline pair lands between
    // 0.653 and 0.685).
    var candidates: Set<Double> = []
    let edges = blocks.flatMap { [$0.region.maxX, $0.region.minX] }.sorted()
    for (index, edge) in edges.enumerated() where edge > 0.1 && edge < 0.9 {
        let gaps = edges[(index + 1)...].filter { $0 > edge + 0.005 }
        if let next = gaps.first {
            candidates.insert((edge + next) / 2)
        }
    }
    for gutter in candidates.sorted() {
        let left = blocks.filter { $0.region.maxX <= gutter }
        let right = blocks.filter { $0.region.minX >= gutter }
        guard left.count >= 2, right.count >= 2,
            left.count + right.count == blocks.count
        else { continue }
        let span: ([PageBlock]) -> Double = { group in
            let ys = group.flatMap { [$0.region.minY, $0.region.maxY] }
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        // Either side is a full column (spans most of the page) or the side
        // is a narrow rail: two-plus blocks separated vertically, occupying
        // a minority of the page height. A rail still reads as a column.
        func isColumn(_ group: [PageBlock]) -> Bool { span(group) > 0.4 }
        func isRail(_ group: [PageBlock]) -> Bool {
            guard span(group) >= 0.1 else { return false }
            let ys = group.map(\.region.minY).sorted()
            for i in 1..<ys.count where ys[i] - ys[i - 1] < 0.02 { return false }
            return true
        }
        let leftOk = isColumn(left) || isRail(left)
        let rightOk = isColumn(right) || isRail(right)
        if leftOk, rightOk { return [left, right] }
    }
    return nil
}
