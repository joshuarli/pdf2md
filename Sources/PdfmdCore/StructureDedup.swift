/// Structured-text deduplication (plan.md section 19).
///
/// Vision surfaces table/list text redundantly: once inside table cells and
/// list items, and again as ordinary entries in `document.paragraphs`. The
/// baseline, following docOCR's demonstrated approach:
///
/// 1. keep table blocks
/// 2. keep list blocks not substantially inside a table
/// 3. keep paragraph/heading blocks not substantially inside a surviving
///    table or list
/// 4. sort survivors in reading order (the caller runs `ReadingOrder`)
///
/// Containment thresholds are explicit parameters so benchmark failures can
/// tune them with evidence rather than vibes.
public func deduplicate(
    _ blocks: [PageBlock],
    tableListThreshold: Double = 0.6,
    paragraphThreshold: Double = 0.6
) -> [PageBlock] {
    let tables = blocks.filter {
        if case .table = $0.kind { return true }
        return false
    }
    let lists = blocks.filter {
        if case .list = $0.kind { return true }
        return false
    }
    let others = blocks.filter {
        switch $0.kind {
        case .table, .list: return false
        case .title, .heading, .paragraph: return true
        }
    }

    let survivingLists = lists.filter { list in
        !tables.contains { list.region.isSubstantiallyContained(in: $0.region, threshold: tableListThreshold) }
    }
    let containers = tables.map(\.region) + survivingLists.map(\.region)
    let survivingOthers = others.filter { block in
        // Titles are document-level, not duplicates of body structure.
        if case .title = block.kind { return true }
        return !containers.contains {
            block.region.isSubstantiallyContained(in: $0, threshold: paragraphThreshold)
        }
    }
    let keptStructural = tables + survivingLists + survivingOthers
    let keptText = deduplicateIdenticalText(suppressFragments(keptStructural))
    return deduplicateOverlappingText(keptText, threshold: paragraphThreshold)
}

/// Suppress near-duplicate text blocks: Vision emits the same prose at
/// multiple granularities (nested/overlapping paragraph observations), so a
/// title/heading/paragraph substantially contained in another surviving text
/// block with at least as much text is dropped. Keeps the longest witness;
/// ties keep document order. Runs after structural suppression so table/list
/// evidence is never the thing being deduplicated away.
public func deduplicateOverlappingText(_ blocks: [PageBlock], threshold: Double = 0.6) -> [PageBlock] {
    let indexed = blocks.enumerated().filter { _, block in
        switch block.kind {
        case .title, .heading, .paragraph: return true
        case .list, .table: return false
        }
    }
    // Largest text first so containers survive their contents.
    let ordered = indexed.sorted {
        if $0.element.kind.plainText.count != $1.element.kind.plainText.count {
            return $0.element.kind.plainText.count > $1.element.kind.plainText.count
        }
        return $0.offset < $1.offset
    }
    var suppressed = Set<Int>()
    for (i, a) in ordered {
        guard !suppressed.contains(i) else { continue }
        for (j, b) in ordered where j != i && !suppressed.contains(j) {
            if b.region.isSubstantiallyContained(in: a.region, threshold: threshold) {
                suppressed.insert(j)
            }
        }
    }
    return blocks.enumerated().filter { !suppressed.contains($0.offset) }.map(\.element)
}

/// Suppress textually redundant blocks regardless of geometry. Vision emits
/// whole-page transcripts once per strip/region (ai-2027.pdf cover: eleven
/// disjoint strips, identical text), which geometric containment cannot see.
/// Keeps the first occurrence; drops a later title/heading/paragraph when at
/// least `coverage` of its tokens already appeared in kept text. Short
/// repeats stay (a twice-used "Yes." is not duplication evidence).
public func deduplicateIdenticalText(
    _ blocks: [PageBlock],
    minimumTokens: Int = 8,
    coverage: Double = 0.9
) -> [PageBlock] {
    var keptCounts: [String: Int] = [:]
    return blocks.filter { block in
        let tokens: [String]
        switch block.kind {
        case .title(let text), .heading(_, let text), .paragraph(let text):
            tokens = tokenize(normalizeForScoring(text))
        case .list, .table:
            return true
        }
        guard tokens.count >= minimumTokens else { return true }
        var covered = 0
        var remaining = keptCounts
        for token in tokens {
            if let count = remaining[token], count > 0 {
                remaining[token] = count - 1
                covered += 1
            }
        }
        guard Double(covered) / Double(tokens.count) >= coverage else {
            for token in tokens { keptCounts[token, default: 0] += 1 }
            return true
        }
        return false
    }
}

/// Suppress OCR confetti: small regions carrying little text (a misread
/// dashboard caption, "囵", "E", axis labels) from graphics Vision tried to
/// read as prose. Footnotes, margin notes, headings, and real one-line
/// paragraphs all span far more area, so the gate keeps them. The benchmark
/// gold excludes the same dashboard furniture (plan.md section 8).
public func suppressFragments(_ blocks: [PageBlock], maximumArea: Double = 0.004, maximumTokens: Int = 12) -> [PageBlock] {
    blocks.filter { block in
        switch block.kind {
        case .title(let text), .heading(_, let text), .paragraph(let text):
            let tokens = tokenize(normalizeForScoring(text))
            if block.region.area < maximumArea, tokens.count <= maximumTokens {
                return false
            }
            return true
        case .list, .table:
            return true
        }
    }
}
