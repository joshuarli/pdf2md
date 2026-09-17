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

    var ratios: [Double] = []
    let reconciled = blocks.map { block -> PageBlock in
        guard case .paragraph(let visionText) = block.kind else { return block }
        let visionTokens = tokenize(normalizeForScoring(visionText))
        guard !visionTokens.isEmpty else { return block }
        var bestRatio = 0.0
        var bestPara = ""
        for (para, tokens) in zip(nativeParas, nativeTokenized) {
            guard !tokens.isEmpty else { continue }
            let matched = longestOrderedMatchCount(tokens, visionTokens)
            let ratio = Double(matched) / Double(visionTokens.count)
            if ratio > bestRatio {
                bestRatio = ratio
                bestPara = para
            }
        }
        ratios.append(bestRatio)
        // Short blocks get a one-token allowance (see shouldPreferNative).
        if bestRatio >= minimumAgreement
            || (visionTokens.count <= 8 && bestRatio * Double(visionTokens.count) + 1 >= Double(visionTokens.count))
        {
            var swapped = block
            swapped.kind = .paragraph(bestPara)
            swapped.source = .reconciled
            return swapped
        }
        return block
    }
    let mean = ratios.isEmpty ? 1 : ratios.reduce(0, +) / Double(ratios.count)
    return (reconciled, mean < 0.6)
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
