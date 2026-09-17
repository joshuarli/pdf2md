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
/// vertical gutter separates the blocks into two sets that each span a
/// substantial vertical range with minimal horizontal overlap; otherwise nil.
public func splitColumns(_ blocks: [PageBlock], gutterWidth: Double = 0.03) -> [[PageBlock]]? {
    guard blocks.count >= 4 else { return nil }
    let sorted = blocks.sorted { $0.region.midX < $1.region.midX }
    // Candidate gutters between adjacent block midlines.
    for i in 1..<sorted.count {
        let gutter = (sorted[i - 1].region.midX + sorted[i].region.midX) / 2
        let left = blocks.filter { $0.region.maxX < gutter - gutterWidth / 2 }
        let right = blocks.filter { $0.region.minX > gutter + gutterWidth / 2 }
        // Both sides must own most blocks with none straddling the gutter.
        guard left.count >= 2, right.count >= 2,
            left.count + right.count == blocks.count
        else { continue }
        let span: ([PageBlock]) -> Double = { group in
            let ys = group.flatMap { [$0.region.minY, $0.region.maxY] }
            return (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        guard span(left) > 0.4, span(right) > 0.4 else { continue }
        return [left, right]
    }
    return nil
}
