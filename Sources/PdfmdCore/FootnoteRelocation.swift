import Foundation

/// Footnote relocation (plan.md section 23): footnote bodies move out of the
/// geometric flow to page-end definitions, with `[^marker]` references left
/// at the marker positions. Matches the golden layout, so order-sensitive
/// scoring stops punishing every footnote as a move.
///
/// Conservative throughout: unassociated footnote bodies stay where they are
/// (losing text is worse than misplacing it), unassociated body markers stay
/// literal, and exact marker mapping is never invented. Only entry
/// requirement is Vision geometry plus marker text — no font sizes needed.
public struct RelocatedFootnotes: Sendable {
    public var blocks: [PageBlock]
    /// Definitions in page order, rendered after the body.
    public var definitions: [FootnoteDefinition]

    public init(blocks: [PageBlock], definitions: [FootnoteDefinition]) {
        self.blocks = blocks
        self.definitions = definitions
    }
}

public struct FootnoteDefinition: Sendable {
    public var marker: String
    public var text: String

    public init(marker: String, text: String) {
        self.marker = marker
        self.text = text
    }
}

public func relocateFootnotes(_ blocks: [PageBlock]) -> RelocatedFootnotes {
    // Candidates: short text blocks low on the page (footnotes live at the
    // bottom) that open with a footnote marker.
    var footnoteIndices: [Int] = []
    var bodies: [(marker: String, text: String)] = []
    for (index, block) in blocks.enumerated() {
        let text: String
        switch block.kind {
        case .paragraph(let value):
            text = value
        case .title, .heading, .list, .table:
            continue
        }
        guard isFootnoteBlock(block) else { continue }
        guard let (marker, rest) = splitFootnoteStart(text), !rest.isEmpty else { continue }
        footnoteIndices.append(index)
        bodies.append((marker, rest))
    }
    guard !bodies.isEmpty else { return RelocatedFootnotes(blocks: blocks, definitions: []) }

    // Body markers available for pairing, in document order.
    var available: [String] = []
    for (index, block) in blocks.enumerated() {
        guard !footnoteIndices.contains(index) else { continue }
        guard case .paragraph(let text) = block.kind else { continue }
        available.append(contentsOf: scanBodyMarkers(text))
    }

    // Pair in order; each body occurrence is consumed once. A second pass
    // retries leftovers against relaxed scanning ("GPT-4.6" style markers).
    var remaining = available
    var definitions: [FootnoteDefinition] = []
    var moved = Set<Int>()
    // Blocks in reading order; index positions for adjacency checks.
    let order = blocks.indices.sorted {
        if blocks[$0].region.minY != blocks[$1].region.minY {
            return blocks[$0].region.minY < blocks[$1].region.minY
        }
        return blocks[$0].region.minX < blocks[$1].region.minX
    }
    var positionInOrder: [Int: Int] = [:]
    for (pos, idx) in order.enumerated() { positionInOrder[idx] = pos }
    func define(marker: String, text: String, position: Int) {
        let source = footnoteIndices[position]
        moved.insert(source)
        var fullText = text
        // Absorb continuation lines: markerless bottom-region blocks in the
        // same column immediately following the footnote body.
        var cursor = (positionInOrder[source] ?? 0) + 1
        while cursor < order.count {
            let next = order[cursor]
            guard !moved.contains(next), !footnoteIndices.contains(next) else { break }
            guard case .paragraph(let cont) = blocks[next].kind else { break }
            let region = blocks[next].region
            guard region.minY > 0.65, cont.count < 600,
                splitFootnoteStart(cont) == nil,
                region.xOverlapFraction(with: blocks[source].region) >= 0.5
            else { break }
            fullText += " " + cont.trimmingCharacters(in: .whitespaces)
            moved.insert(next)
            cursor += 1
        }
        definitions.append(FootnoteDefinition(marker: marker, text: fullText))
    }
    var leftovers: [(marker: String, text: String, position: Int)] = []
    for (position, (marker, text)) in bodies.enumerated() {
        guard remaining.contains(marker) else {
            leftovers.append((marker, text, position))
            continue
        }
        remaining.removeFirst(marker)
        define(marker: marker, text: text, position: position)
    }
    if !leftovers.isEmpty {
        // Relaxed inventory, minus everything the strict pass consumed.
        var pool: [String] = []
        for (index, block) in blocks.enumerated() {
            guard !footnoteIndices.contains(index) else { continue }
            guard case .paragraph(let text) = block.kind else { continue }
            pool.append(contentsOf: scanBodyMarkers(text, relaxed: true))
        }
        var consumed = available
        for marker in remaining { consumed.removeFirst(marker) }
        for marker in consumed { pool.removeFirst(marker) }
        for (marker, text, position) in leftovers {
            guard pool.contains(marker) else { continue }
            pool.removeFirst(marker)
            define(marker: marker, text: text, position: position)
        }
    }
    guard !definitions.isEmpty else { return RelocatedFootnotes(blocks: blocks, definitions: []) }

    // Rewrite body markers to references; drop moved footnote bodies.
    var referenced = definitions.map(\.marker)
    let rewritten = blocks.enumerated().compactMap { (index, block) -> PageBlock? in
        if moved.contains(index) { return nil }
        guard case .paragraph(let text) = block.kind else { return block }
        var out = text
        let strict = scanBodyMarkers(text)
        let extra = scanBodyMarkers(text, relaxed: true).filter { !strict.contains($0) }
        for marker in strict + extra {
            guard referenced.contains(marker) else { continue }
            referenced.removeFirst(marker)
            out = replaceFirstGluedMarker(out, marker: marker)
        }
        if out == text { return block }
        var copy = block
        copy.kind = .paragraph(out)
        copy.source = .reconciled
        return copy
    }
    return RelocatedFootnotes(blocks: rewritten, definitions: definitions)
}

/// Short text low on the page. Mirrors `isFootnoteCandidate` but additionally
/// requires a parseable leading marker — geometry alone relocates nothing.
func isFootnoteBlock(_ block: PageBlock) -> Bool {
    guard block.region.minY > 0.7 else { return false }
    let text = block.kind.plainText
    guard text.count < 600 else { return false }
    return splitFootnoteStart(text) != nil
}

/// Split "5 Compute is..." / "*For example..." / "†Recall..." into marker
/// and body. Numbers need a sentence start after them; symbols may glue.
func splitFootnoteStart(_ text: String) -> (marker: String, rest: String)? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if let match = trimmed.range(of: #"^(\*+|[†‡])(?=\S)"#, options: .regularExpression) {
        let marker = String(trimmed[match])
        let rest = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        return (marker, rest)
    }
    if let match = trimmed.range(of: #"^(\d{1,3})\s+(?=[A-Z"“'(\d])"#, options: .regularExpression) {
        let marker = String(trimmed[match]).trimmingCharacters(in: .whitespaces)
        var rest = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        // Fused orphan: body marker glued onto the footnote start
        // ("7 7 We consider") — drop one copy.
        if rest.hasPrefix(marker + " ") {
            rest = String(rest.dropFirst(marker.count + 1))
            guard !rest.isEmpty else { return nil }
        }
        return (marker, rest)
    }
    return nil
}

/// Glued footnote markers inside body text ("train.5", "thefts.*",
/// "compute†"), in order. Same conservative filters as golden curation:
/// digit runs that belong to longer numbers, hyphen compounds (Agent-1),
/// thousands separators, and decimals are not markers. The relaxed pass
/// additionally allows digit-before-dot ("GPT-4.6" style markers), used only
/// when strict pairing leaves a footnote unmatched.
func scanBodyMarkers(_ text: String, relaxed: Bool = false) -> [String] {
    var found: [String] = []
    guard let pattern = try? NSRegularExpression(pattern: #"(?<=\S)(\*+|[†‡]|\d{1,3})(?=\s|$)"#) else {
        return found
    }
    let ns = text as NSString
    for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let marker = ns.substring(with: match.range(at: 1))
        let start = match.range(at: 1).location
        if let first = marker.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) {
            let prevScalar: Unicode.Scalar? = start > 0 ? Unicode.Scalar(ns.character(at: start - 1)) : nil
            if let p = prevScalar {
                if CharacterSet.decimalDigits.contains(p) { continue }
                if "-/,–—".unicodeScalars.contains(p) { continue }
                if p == "," {
                    let before: Unicode.Scalar? = start >= 2 ? Unicode.Scalar(ns.character(at: start - 2)) : nil
                    if let b = before, CharacterSet.decimalDigits.contains(b) { continue }
                }
                if p == "." {
                    // Decimal ("1.5") vs marker ("train.5"): a digit before
                    // the dot means a number; a letter means a marker. The
                    // relaxed pass allows both ("GPT-4.6" style markers).
                    if !relaxed, start >= 2, let b = Unicode.Scalar(ns.character(at: start - 2)),
                        CharacterSet.decimalDigits.contains(b)
                    {
                        continue
                    }
                }
            }
        }
        found.append(marker)
    }
    return found
}

/// Replace the first glued occurrence of `marker` with a `[^marker]`
/// reference, preserving the preceding character.
func replaceFirstGluedMarker(_ text: String, marker: String) -> String {
    guard let pattern = try? NSRegularExpression(
        pattern: "(?<=\\S)(" + NSRegularExpression.escapedPattern(for: marker) + ")(?=\\s|$)"),
        !marker.isEmpty
    else {
        return text
    }
    let ns = text as NSString
    guard let match = pattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
        return text
    }
    return ns.replacingCharacters(in: match.range(at: 1), with: "[^\(marker)]")
}

extension NormalizedRect {
    /// Horizontal overlap as a fraction of the narrower rect. Footnote
    /// continuations share their footnote's column; sidebar notes do not.
    func xOverlapFraction(with other: NormalizedRect) -> Double {
        let overlap = min(maxX, other.maxX) - max(minX, other.minX)
        guard overlap > 0 else { return 0 }
        let narrower = min(width, other.width)
        guard narrower > 0 else { return 0 }
        return overlap / narrower
    }
}

extension Array where Element: Equatable {
    mutating func removeFirst(_ element: Element) {
        if let index = firstIndex(of: element) { remove(at: index) }
    }
}

// MARK: - Native-guided relocation

/// A footnote item segmented from size-labeled native lines: exact marker
/// plus exact body text. The oracle for moving Vision spans.
public struct NativeFootnoteItem: Sendable {
    public var marker: String
    public var text: String
}

/// Segment native footnote items using type sizes (body vs small), the same
/// evidence golden curation keys on. Markerless small lines (margin notes,
/// chart data) are ignored here — only paired markers relocate anything.
public func nativeFootnoteItems(_ lines: [(size: Double, text: String)]) -> [NativeFootnoteItem] {
    var counts: [Double: Int] = [:]
    for (size, _) in lines where size >= 9 && size <= 13 {
        counts[(size * 10).rounded() / 10, default: 0] += 1
    }
    // Body type is the largest well-represented size (footnotes and margin
    // notes run smaller; the mode can misfire on footnote-heavy pages).
    // Two body lines suffice on short pages; requiring three prevents even
    // an exact, paired note from relocating in a short paragraph.
    guard let bodySize = counts.filter({ $0.value >= 2 }).keys.max() else { return [] }
    var items: [NativeFootnoteItem] = []
    var curMarker: String?
    var curLines: [String] = []
    func flush() {
        if let marker = curMarker {
            let text = collapseHardWraps(curLines.joined(separator: "\n"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { items.append(NativeFootnoteItem(marker: marker, text: text)) }
        }
        curMarker = nil
        curLines = []
    }
    for (size, text) in lines {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { flush(); continue }
        guard size < bodySize - 0.75 else { flush(); continue }
        // Lone superscript markers belong to body text, never to a note.
        if s.range(of: #"^(\*+|[†‡]|\d{1,3})$"#, options: .regularExpression) != nil { continue }
        if let (marker, rest) = splitFootnoteStart(s) {
            flush()
            curMarker = marker
            curLines = [rest]
        } else if curMarker != nil {
            curLines.append(s)
        }
    }
    flush()
    return items
}

/// Token with its character range, for mapping fuzzy matches back onto the
/// original Vision text. Splitting mirrors `tokenize` (letters/digits runs
/// vs single punctuation, whitespace dropped) without lowercasing.
struct RangedToken: Sendable {
    var lower: String
    var range: Range<String.Index>
}

func rangedTokens(_ text: String) -> [RangedToken] {
    var out: [RangedToken] = []
    var current = ""
    var currentStart = text.startIndex
    func flush(at end: String.Index) {
        if !current.isEmpty {
            out.append(RangedToken(lower: current.lowercased(), range: currentStart..<end))
            current = ""
        }
    }
    var index = text.startIndex
    while index < text.endIndex {
        let char = text[index]
        if char.isLetter || char.isNumber {
            if current.isEmpty { currentStart = index }
            current.append(char)
        } else if char.isWhitespace {
            flush(at: index)
        } else {
            flush(at: index)
            out.append(RangedToken(lower: String(char), range: index..<text.index(after: index)))
        }
        index = text.index(after: index)
    }
    flush(at: text.endIndex)
    return out
}

/// Fuzzy token equality: exact, or a shared prefix of at least four
/// characters (OCR truncation "opermodel"/"oper", wrap splits
/// "align"/"alignment"). Short tokens must match exactly.
func fuzzyEqual(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    guard min(a.count, b.count) >= 4 else { return false }
    return a.hasPrefix(b) || b.hasPrefix(a)
}

/// Native-guided relocation: native footnote items (exact marker + exact
/// text) locate their Vision counterparts, which move to page-end
/// definitions while the paired body marker becomes a `[^marker]`
/// reference. Falls back to geometric relocation when native segmentation
/// finds nothing (raster pages, covers).
public func relocateFootnotesWithNative(
    blocks: [PageBlock],
    nativeLines: [(size: Double, text: String)]
) -> RelocatedFootnotes {
    let items = nativeFootnoteItems(nativeLines)
    guard !items.isEmpty else { return relocateFootnotes(blocks) }

    // Flat token stream over paragraph blocks, remembering provenance.
    struct StreamToken: Sendable {
        var block: Int
        var lower: String
        var range: Range<String.Index>
        var text: String
    }
    var stream: [StreamToken] = []
    var blockTokens: [[RangedToken]] = []
    for (index, block) in blocks.enumerated() {
        guard case .paragraph(let text) = block.kind else {
            blockTokens.append([])
            continue
        }
        let tokens = rangedTokens(text)
        blockTokens.append(tokens)
        for token in tokens {
            stream.append(StreamToken(block: index, lower: token.lower, range: token.range, text: text))
        }
    }
    // Block boundaries in stream coordinates.
    var blockStart: [Int: Int] = [:]
    var cursor = 0
    for (index, tokens) in blockTokens.enumerated() {
        blockStart[index] = cursor
        cursor += tokens.count
    }
    func tokenChar(_ block: Int, _ token: Int, before: Bool) -> Character? {
        let tokens = blockTokens[block]
        guard token >= 0, token < tokens.count else { return nil }
        let text: String
        switch blocks[block].kind {
        case .paragraph(let value): text = value
        default: return nil
        }
        let edge = before ? tokens[token].range.lowerBound : tokens[token].range.upperBound
        if before {
            guard edge > text.startIndex else { return nil }
            return text[text.index(before: edge)]
        } else {
            guard edge < text.endIndex else { return nil }
            return text[edge]
        }
    }

    struct Occurrence {
        var streamIndex: Int
        var replacement: Range<String.Index>
    }
    // Occurrences of one wanted marker, in stream order: glued body markers
    // ("train.5"), orphans after terminal punctuation or at block starts
    // ("26 OpenBrain"), and single-prefix suffix splits ("229" -> "29").
    // Digit filters reject longer numbers, hyphen compounds, and thousands
    // separators. Notably there is NO decimal rule: span coverage rejects a
    // wrong occurrence ("version 2.0" never matches footnote text), and the
    // retry loop moves on to the true marker.
    func occurrences(of marker: String, after consumeThrough: Int, skipping: Set<Int>) -> [Occurrence] {
        var out: [Occurrence] = []
        var index = 0
        while index < stream.count {
            defer { index += 1 }
            if index <= consumeThrough || skipping.contains(index) { continue }
            let token = stream[index]
            guard case .paragraph = blocks[token.block].kind else { continue }
            if token.lower == marker.lowercased() {
                let local = blockTokenIndex(block: token.block, streamIndex: index)
                let before = tokenChar(token.block, local, before: true)
                let after = tokenChar(token.block, local, before: false)
                let gluedBefore = before.map { !$0.isWhitespace } ?? false
                let boundaryAfter = after.map { $0.isWhitespace } ?? true
                if gluedBefore, boundaryAfter,
                    digitFiltersPass(block: token.block, token: local, marker: marker)
                {
                    out.append(Occurrence(streamIndex: index, replacement: token.range))
                    continue
                }
                if isOrphanPosition(block: token.block, streamIndex: index, requireTerminal: true) {
                    out.append(Occurrence(streamIndex: index, replacement: token.range))
                }
            } else if token.lower.allSatisfy({ $0.isNumber }),
                token.lower.count == marker.count + 1,
                token.lower.hasSuffix(marker.lowercased()),
                isOrphanPosition(block: token.block, streamIndex: index, requireTerminal: false)
            {
                let drop = token.lower.count - marker.count
                var start = token.range.lowerBound
                for _ in 0..<drop { start = token.text.index(after: start) }
                out.append(Occurrence(streamIndex: index, replacement: start..<token.range.upperBound))
            }
        }
        return out
    }
    func blockTokenIndex(block: Int, streamIndex: Int) -> Int {
        (blockStart[block] ?? 0) <= streamIndex ? streamIndex - (blockStart[block] ?? 0) : 0
    }
    func isOrphanPosition(block: Int, streamIndex: Int, requireTerminal: Bool) -> Bool {
        // Next token starts a sentence; previous ends one (or starts block).
        // Single-prefix suffix splits ("to 2.[29]") bypass the terminal
        // requirement: the fused prefix already proves flotation.
        let local = blockTokenIndex(block: block, streamIndex: streamIndex)
        guard local + 1 < blockTokens[block].count else { return true }
        let next = blockTokens[block][local + 1].lower
        guard next.first.map({ $0.isUppercase || !$0.isLetter }) ?? false else { return false }
        if local == 0 { return true }
        guard requireTerminal else { return true }
        let prev = blockTokens[block][local - 1].lower
        return prev.last.map { ".!?…:;".contains($0) } ?? false
    }
    func digitFiltersPass(block: Int, token: Int, marker: String) -> Bool {
        guard let first = marker.unicodeScalars.first,
            CharacterSet.decimalDigits.contains(first)
        else { return true }
        let tokens = blockTokens[block]
        guard token >= 0, token < tokens.count else { return false }
        let text: String
        switch blocks[block].kind {
        case .paragraph(let value): text = value
        default: return false
        }
        let start = tokens[token].range.lowerBound
        guard start > text.startIndex else { return true }
        guard let prev = text[text.index(before: start)].unicodeScalars.first else { return true }
        if CharacterSet.decimalDigits.contains(prev) { return false }
        if "-/,–—".unicodeScalars.contains(prev) { return false }
        if prev == "," {
            let beforeDot = text[text.startIndex..<text.index(before: start)]
            if let b = beforeDot.last?.unicodeScalars.first, CharacterSet.decimalDigits.contains(b) {
                return false
            }
        }
        return true
    }

    struct Edit {
        var block: Int
        var range: Range<String.Index>
        var replacement: String
    }
    var edits: [Edit] = []
    var definitions: [FootnoteDefinition] = []
    var consumedThrough = -1
    var consumedOccurrences = Set<Int>()

    for item in items {
        let itemTokens = rangedTokens(item.text).map(\.lower).filter { !$0.isEmpty }
        guard !itemTokens.isEmpty else { continue }
        // Each occurrence is tried in stream order until one matches;
        // wrong early occurrences fail span coverage and are skipped.
        var attempts = occurrences(of: item.marker, after: consumedThrough, skipping: consumedOccurrences)
        var paired = false
        while !paired, let occ = attempts.first {
            attempts.removeFirst()
            consumedOccurrences.insert(occ.streamIndex)
            // Greedy span forward with caps.
            let maxScan = occ.streamIndex + 1 + itemTokens.count * 3 + 10
            var matched: [Int] = []
            var need = 0
            var scan = occ.streamIndex + 1
            while need < itemTokens.count, scan < min(stream.count, maxScan) {
                if fuzzyEqual(stream[scan].lower, itemTokens[need]) {
                    matched.append(scan)
                    need += 1
                }
                scan += 1
            }
            let coverage = Double(matched.count) / Double(itemTokens.count)
            guard coverage >= 0.6, let first = matched.first, let last = matched.last,
                last - first <= itemTokens.count * 2 + 8
            else { continue }
            // Extend start back over an unmatched same-marker token (floated
            // footnote-start marker: "public 5 Compute" -> drop the "5").
            var spanStart = first
            while spanStart - 1 > occ.streamIndex {
                let t = stream[spanStart - 1].lower
                if t == item.marker.lowercased() && !matched.contains(spanStart - 1) {
                    spanStart -= 1
                } else {
                    break
                }
            }
            // Character ranges on original block texts.
            let firstBlock = stream[spanStart].block
            let lastBlock = stream[last].block
            // Cut inside a truncated last token ("opermodel" keeps "model").
            var spanEnd = stream[last].range.upperBound
            let lastLower = stream[last].lower
            let wantLast = itemTokens[matched.count - 1]
            if lastLower != wantLast, lastLower.hasPrefix(wantLast), wantLast.count >= 4 {
                var cut = stream[last].range.lowerBound
                for _ in 0..<wantLast.count {
                    cut = stream[last].text.index(after: cut)
                }
                spanEnd = cut
            }
            var byBlock: [Int: [Range<String.Index>]] = [:]
            var b = firstBlock
            var tokenCursor = spanStart
            while b <= lastBlock {
                let lo = b == firstBlock ? spanStart : (blockStart[b] ?? tokenCursor)
                let hi = b == lastBlock ? last : ((blockStart[b + 1] ?? (tokenCursor + 1)) - 1)
                if lo <= hi {
                    let text: String
                    switch blocks[b].kind {
                    case .paragraph(let value): text = value
                    default: text = ""
                    }
                    if !text.isEmpty {
                        let r0 = blockTokens[b][lo - (blockStart[b] ?? 0)].range.lowerBound
                        var r1 = blockTokens[b][hi - (blockStart[b] ?? 0)].range.upperBound
                        if b == lastBlock { r1 = spanEnd }
                        if r0 < r1 { byBlock[b, default: []].append(r0..<r1) }
                    }
                }
                tokenCursor = hi + 1
                b += 1
            }
            for (block, ranges) in byBlock {
                for range in ranges {
                    edits.append(Edit(block: block, range: range, replacement: " "))
                }
            }
            // Occurrence becomes the reference.
            let occBlock = stream[occ.streamIndex].block
            edits.append(Edit(block: occBlock, range: occ.replacement, replacement: "[^\(item.marker)]"))
            definitions.append(FootnoteDefinition(marker: item.marker, text: item.text))
            consumedThrough = max(consumedThrough, occ.streamIndex)
            paired = true
        }
    }

    guard !definitions.isEmpty else { return relocateFootnotes(blocks) }

    // Apply edits per block. Every edit range indexes the block's ORIGINAL
    // text, so the only safe application is strictly end-to-start against an
    // untouched copy (a page-20 span once shifted a pending range and crashed
    // in replaceSubrange). Overlapping edits skip rather than corrupt.
    var texts: [String?] = blocks.map {
        if case .paragraph(let text) = $0.kind { return text }
        return nil
    }
    let grouped = Dictionary(grouping: edits, by: \.block)
    for (block, blockEdits) in grouped {
        guard let original = texts[block] else { continue }
        let sorted = blockEdits.sorted {
            original.utf16.distance(from: original.startIndex, to: $0.range.lowerBound)
                > original.utf16.distance(from: original.startIndex, to: $1.range.lowerBound)
        }
        var text = original
        var appliedUpTo = original.endIndex
        for edit in sorted {
            guard edit.range.upperBound <= appliedUpTo else { continue }
            appliedUpTo = edit.range.lowerBound
            text.replaceSubrange(edit.range, with: edit.replacement)
        }
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        texts[block] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let rebuilt = blocks.enumerated().compactMap { (index, block) -> PageBlock? in
        guard case .paragraph = block.kind else { return block }
        guard let text = texts[index], !text.isEmpty else { return nil }
        var copy = block
        copy.kind = .paragraph(text)
        copy.source = .reconciled
        return copy
    }
    return RelocatedFootnotes(blocks: rebuilt, definitions: definitions)
}
