/// Native-text quality assessment and Vision reconciliation (plan.md 16, 21).
///
/// Vision provides structure, regions, and reading order; it must not replace
/// trustworthy born-digital characters (punctuation, URLs, numbers,
/// identifiers). Matching stays conservative: a wrong native/Vision
/// association is worse than accepting OCR. Word-level geometric alignment is
/// Phase 2 work; this stage implements the quality gate and the text-level
/// preference policy it drives.
public func assessNativeQuality(_ text: String) -> NativeTextQuality {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .empty }
    let scalars = Array(trimmed.unicodeScalars)
    var printable = 0
    var replacement = 0
    var privateUse = 0
    var controls = 0
    for scalar in scalars {
        switch scalar.value {
        case 0xFFFD:
            replacement += 1
        case 0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD:
            privateUse += 1
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F:
            controls += 1
        default:
            // Whitespace and printable characters alike are representable.
            printable += 1
        }
    }
    let total = Double(scalars.count)
    let badRatio = Double(replacement + privateUse + controls) / total
    // Gross duplication check: a text layer repeating one short line is broken.
    let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }
    if let first = lines.first, lines.count > 3,
        lines.allSatisfy({ $0 == first })
    {
        return .broken
    }
    if badRatio > 0.02 || Double(printable) / total < 0.5 { return .broken }
    return .trustworthy
}

/// Decide whether a Vision block's text may be replaced by native text.
/// Both inputs are normalized before comparison; `minimumAgreement` is the
/// fraction of Vision tokens that must appear in order in the native string.
/// Short blocks (a closing line, a caption) get a one-token allowance: a
/// single OCR glyph error ("Al" for "AI") must not veto exact native text.
public func shouldPreferNative(
    nativeQuality: NativeTextQuality,
    nativeText: String,
    visionText: String,
    minimumAgreement: Double = 0.8
) -> Bool {
    guard nativeQuality == .trustworthy else { return false }
    let nativeTokens = tokenize(normalizeForScoring(nativeText))
    let visionTokens = tokenize(normalizeForScoring(visionText))
    guard !visionTokens.isEmpty, !nativeTokens.isEmpty else { return false }
    let matched = longestOrderedMatchCount(nativeTokens, visionTokens)
    if matched == visionTokens.count { return true }
    if visionTokens.count <= 8, matched + 1 >= visionTokens.count { return true }
    return Double(matched) / Double(visionTokens.count) >= minimumAgreement
}

/// Block-level native/Vision reconciliation.
///
/// When the native layer is trustworthy, each Vision paragraph is matched
/// against native paragraphs (split on blank lines, wraps collapsed). A
/// native paragraph with token agreement >= 0.9 replaces the OCR text, so
/// exact punctuation, URLs, numbers, and identifiers survive while Vision
/// keeps ownership of structure and order. Conservative by design: below
/// threshold the OCR text stands.
///
/// Returns the reconciled blocks plus whether the layers structurally
/// disagree (a routing signal, not a failure).
public func reconcileParagraphs(
    nativeText: String,
    quality: NativeTextQuality,
    blocks: [PageBlock],
    minimumAgreement: Double = 0.9
) -> (blocks: [PageBlock], disagreement: Bool) {
    guard quality == .trustworthy else { return (blocks, false) }
    let nativeParas = splitNativeParagraphs(nativeText)
    guard !nativeParas.isEmpty else { return (blocks, false) }
    let nativeTokenized = nativeParas.map { tokenize(normalizeForScoring($0)) }
    // Titles/headings match against native LINES: a display title sits on
    // one line, while paragraph grouping would glue it to its body.
    let nativeLines = nativeText.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    let nativeLineTokenized = nativeLines.map { tokenize(normalizeForScoring($0)) }

    /// Title/heading match against native lines. Titles are short and OCR
    /// mangles them hard ("CODERIN FARLY"), so the threshold is lower — but
    /// the native line must be about the same length, otherwise a two-word
    /// title would happily adopt a whole sentence that shares its words
    /// ("AI 2027" must not become "AI 2027 We predict..."). Very short
    /// titles stay strict: one shared word must not retitle a stub.
    func bestTitleMatch(_ visionTokens: [String]) -> String? {
        guard !visionTokens.isEmpty else { return nil }
        let found = findBest(visionTokens, candidates: Array(zip(nativeLines, nativeLineTokenized)))
        let threshold = visionTokens.count <= 4 ? 0.75 : 0.4
        guard found.ratio >= threshold else { return nil }
        let nativeCount = tokenize(normalizeForScoring(found.text)).count
        guard abs(nativeCount - visionTokens.count) <= max(3, visionTokens.count / 2) else { return nil }
        return found.text
    }

    /// Best native candidate regardless of threshold, so the disagreement
    /// signal sees misses as well as hits.
    func findBest(
        _ visionTokens: [String],
        candidates: [(String, [String])]
    ) -> (text: String, ratio: Double) {
        guard !visionTokens.isEmpty else { return ("", 0) }
        var bestRatio = 0.0
        var bestText = ""
        for (text, tokens) in candidates {
            guard !tokens.isEmpty else { continue }
            // Agreement must be reciprocal: a caption can be a perfect
            // subsequence of an entire page without describing that page.
            guard tokens.count <= visionTokens.count + max(2, visionTokens.count / 5) else { continue }
            let ratio = Double(longestOrderedMatchCount(tokens, visionTokens)) / Double(visionTokens.count)
            if ratio > bestRatio {
                bestRatio = ratio
                bestText = text
            }
        }
        return (bestText, bestRatio)
    }

    var ratios: [Double] = []
    let reconciled = blocks.map { block -> PageBlock in
        switch block.kind {
        case .paragraph(let visionText):
            let visionTokens = tokenize(normalizeForScoring(visionText))
            guard !visionTokens.isEmpty else { return block }
            let found = findBest(visionTokens, candidates: Array(zip(nativeParas, nativeTokenized)))
            ratios.append(found.ratio)
            let ok = found.ratio >= minimumAgreement
                || (visionTokens.count <= 8
                    && found.ratio * Double(visionTokens.count) + 1 >= Double(visionTokens.count))
            guard ok else { return block }
            var swapped = block
            swapped.kind = .paragraph(found.text)
            swapped.source = .reconciled
            return swapped
        case .title(let visionText):
            let visionTokens = tokenize(normalizeForScoring(visionText))
            guard let match = bestTitleMatch(visionTokens) else { return block }
            var swapped = block
            swapped.kind = .title(match)
            swapped.source = .reconciled
            return swapped
        case .heading(let level, let visionText):
            let visionTokens = tokenize(normalizeForScoring(visionText))
            guard let match = bestTitleMatch(visionTokens) else { return block }
            var swapped = block
            swapped.kind = .heading(level: level, text: match)
            swapped.source = .reconciled
            return swapped
        case .list, .table:
            return block
        }
    }
    let mean = ratios.isEmpty ? 1 : ratios.reduce(0, +) / Double(ratios.count)
    return (reconciled, mean < 0.6)
}

/// Suppress Vision text that floats over page regions with no native PDF
/// text at all: an embedded chart, diagram, or infographic image rendered
/// without its own selectable text layer (AI 2027 pages 47, 50, 15, 51 —
/// figure captions, chart titles, axis numbers). Genuine document prose on
/// a trustworthy-native page always has real characters geometrically
/// underneath it, even when OCR quality keeps `reconcileNativeLines` from
/// swapping in the exact native string (a footnote with a couple of
/// misread words still has native lines inside its box) — so geometric
/// coverage is the first signal this checks, and the covering line(s) must
/// also share a meaningful fraction of the block's own tokens rather than
/// merely occupy the same space (two captions can sit close enough that an
/// unrelated line's box brushes this one's).
///
/// When geometry finds nothing, it falls back to asking whether the text
/// exists *anywhere* on the page — but as a **contiguous run** of matching
/// tokens, not an ordered subsequence: `splitNativeParagraphs` collapses a
/// blank-line-free page into one giant blob (AI 2027 page 47's whole
/// character stream has no paragraph breaks at all), and against a blob
/// that large an ordered-subsequence match trivially strings together
/// common filler words ("of", "the", "in", "with") from all over the page
/// regardless of real content — only a run of several tokens *in a row*
/// distinguishes a genuinely drifted-bbox caption (which still has real
/// words in sequence) from fabricated OCR of an image (which does not).
///
/// A block that fails every check has no native-text backing whatsoever
/// and is exactly the "graph-axis clutter" / "tiny infographic dashboard
/// labels" plan.md section 8 excludes from gold — unlike
/// `suppressFragments`'s area/token shape heuristic, this needs no size
/// threshold because it reads a fact reconciliation already established
/// rather than guessing from geometry.
public func suppressImageOnlyText(
    blocks: [PageBlock],
    nativeLines: [NativeTextLine],
    nativeText: String,
    quality: NativeTextQuality,
    minimumExistenceRatio: Double = 0.4,
    minimumCoverageRatio: Double = 0.2
) -> [PageBlock] {
    guard quality == .trustworthy else { return blocks }
    let nativeParagraphTokens = splitNativeParagraphs(nativeText).map { tokenize(normalizeForScoring($0)) }
    return blocks.filter { block in
        guard block.source != .reconciled else { return true }
        switch block.kind {
        case .list, .table: return true
        case .title, .heading, .paragraph: break
        }
        let visionTokens = tokenize(normalizeForScoring(block.kind.plainText))
        guard !visionTokens.isEmpty else { return true }
        let coveringLines = nativeLines.filter {
            $0.region.isSubstantiallyContained(in: block.region, threshold: 0.75)
        }
        if !coveringLines.isEmpty {
            let coveringTokens = tokenize(normalizeForScoring(coveringLines.map(\.text).joined(separator: " ")))
            let coverageRatio = Double(longestOrderedMatchCount(coveringTokens, visionTokens)) / Double(visionTokens.count)
            if coverageRatio >= minimumCoverageRatio { return true }
        }
        let bestRatio = nativeParagraphTokens
            .map { Double(longestCommonRunLength($0, visionTokens)) / Double(visionTokens.count) }
            .max() ?? 0
        return bestRatio >= minimumExistenceRatio
    }
}

/// Length of the longest contiguous run shared by `a` and `b`, in order and
/// unbroken (classic longest-common-substring over token arrays, not the
/// longest-common-*subsequence* `longestOrderedMatchCount` computes — a gap
/// of even one token ends the run).
func longestCommonRunLength(_ a: [String], _ b: [String]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var prev = [Int](repeating: 0, count: b.count + 1)
    var curr = [Int](repeating: 0, count: b.count + 1)
    var best = 0
    for i in 1...a.count {
        for j in 1...b.count {
            curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : 0
            best = max(best, curr[j])
        }
        (prev, curr) = (curr, prev)
    }
    return best
}

func splitNativeParagraphs(_ text: String) -> [String] {
    // Group lines on blank-line boundaries, then collapse hard wraps the
    // same way the renderer does so comparisons are like-for-like.
    var groups: [[String]] = [[]]
    for line in text.components(separatedBy: .newlines) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            groups.append([])
        } else {
            groups[groups.count - 1].append(line)
        }
    }
    return groups
        .map { $0.joined(separator: "\n") }
        .map { collapseHardWraps($0) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Count of Vision tokens appearing in order inside native tokens (LCS length
/// via small DP; inputs here are single blocks, so quadratic is fine).
func longestOrderedMatchCount(_ a: [String], _ b: [String]) -> Int {
    guard !a.isEmpty, !b.isEmpty else { return 0 }
    var prev = [Int](repeating: 0, count: b.count + 1)
    var curr = [Int](repeating: 0, count: b.count + 1)
    for i in 1...a.count {
        for j in 1...b.count {
            curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : max(prev[j], curr[j - 1])
        }
        (prev, curr) = (curr, prev)
    }
    return prev[b.count]
}
