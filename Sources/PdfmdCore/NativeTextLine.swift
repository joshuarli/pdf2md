/// Native line evidence in the same top-left normalized coordinates as Vision.
/// Kept separate from OCR blocks so matching cannot accidentally adopt text
/// from another column with similar words.
public struct NativeTextLine: Sendable {
    public var text: String
    public var region: NormalizedRect

    public init(text: String, region: NormalizedRect) {
        self.text = text
        self.region = region
    }
}

public func reconcileNativeLines(
    _ lines: [NativeTextLine], quality: NativeTextQuality, blocks: [PageBlock]
) -> (blocks: [PageBlock], disagreement: Bool) {
    guard quality == .trustworthy else { return (blocks, false) }
    var disagreements = 0
    let result = blocks.map { block -> PageBlock in
        switch block.kind {
        case .paragraph, .title, .heading: break
        case .list, .table: return block
        }
        let selected = lines.filter {
            $0.region.isSubstantiallyContained(in: block.region, threshold: 0.75)
        }.sorted {
            if abs($0.region.midY - $1.region.midY) < min($0.region.height, $1.region.height) / 2 {
                return $0.region.minX < $1.region.minX
            }
            return $0.region.minY < $1.region.minY
        }
        guard !selected.isEmpty else { return block }
        let text = collapseHardWraps(selected.map(\.text).joined(separator: "\n"))
        let nativeTokens = tokenize(normalizeForScoring(text))
        let visionTokens = tokenize(normalizeForScoring(block.kind.plainText))
        guard !nativeTokens.isEmpty, !visionTokens.isEmpty else { return block }
        let matches = longestOrderedMatchCount(nativeTokens, visionTokens)
        // Reciprocal coverage prevents replacing a small matching fragment
        // with a full native line, or dropping OCR-only text on mixed pages.
        let allowance = max(nativeTokens.count, visionTokens.count) <= 12 ? 1 : 0
        guard Double(matches + allowance) / Double(nativeTokens.count) >= 0.85,
            Double(matches + allowance) / Double(visionTokens.count) >= 0.85
        else {
            disagreements += 1
            return block
        }
        var copy = block
        switch block.kind {
        case .paragraph: copy.kind = .paragraph(text)
        case .title: copy.kind = .title(text)
        case .heading(let level, _): copy.kind = .heading(level: level, text: text)
        case .list, .table: return block
        }
        copy.source = .reconciled
        return copy
    }
    return (result, disagreements > 0)
}
