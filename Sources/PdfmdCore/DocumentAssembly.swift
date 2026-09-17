import Foundation

/// Document-level cleanup: repeated furniture, footnotes, heading inference
/// (plan.md sections 23-24). Small deterministic algorithms over lightweight
/// Page IR — never large enough to deserve the name "layout engine".

/// Remove high-confidence repeated page furniture. Compares normalized text
/// in the top/bottom margin bands across pages and drops blocks that repeat
/// on many pages in the same band. One-off titles survive: a block must
/// repeat on at least three pages and a third of the document.
public func stripRepeatedFurniture(
    pages: [[PageBlock]],
    marginFraction: Double = 0.12,
    minimumOccurrences: Int = 3
) -> [[PageBlock]] {
    guard pages.count >= 3 else { return pages }
    var counts: [String: Int] = [:]
    let keys = pages.map { $0.map { furnitureKey($0, marginFraction: marginFraction) } }
    for page in keys {
        for key in Set(page.compactMap { $0 }) { counts[key, default: 0] += 1 }
    }
    let threshold = max(minimumOccurrences, pages.count / 3)
    let furniture = Set(counts.filter { $0.value >= threshold }.map(\.key))
    guard !furniture.isEmpty else { return pages }
    return zip(pages, keys).map { page, pageKeys in
        zip(page, pageKeys).filter { _, key in
            guard let key else { return true }
            return !furniture.contains(key)
        }.map { $0.0 }
    }
}

/// Furniture key for a block in the top/bottom margin band: normalized text
/// with digits folded (page numbers vary) plus band identity. Page-number-only
/// blocks fold to a constant so `12`, `13`, … count as one repetition.
private func furnitureKey(_ block: PageBlock, marginFraction: Double) -> String? {
    let band: String
    if block.region.minY < marginFraction {
        band = "top"
    } else if block.region.maxY > 1 - marginFraction {
        band = "bottom"
    } else {
        return nil
    }
    var text: String
    switch block.kind {
    case .title, .heading, .table:
        // Titles, headings, and tables are content, never furniture.
        return nil
    case .paragraph(let value):
        text = value
    case .list(let value):
        text = value.items.map(\.text).joined(separator: " ")
    }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty, text.count < 200 else { return nil }
    // Fold all digits so running numbers match across pages.
    text = text.replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
    text = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    return "\(band):\(text)"
}

/// Likely footnote: short text hugging the bottom of the page, outside the
/// main flow. Exact marker association is Phase 3 work; this keeps footnote
/// text out of the middle of body paragraphs (plan.md section 23).
public func isFootnoteCandidate(_ block: PageBlock) -> Bool {
    switch block.kind {
    case .title, .table:
        return false
    case .heading, .paragraph, .list:
        break
    }
    guard block.region.minY > 0.78 else { return false }
    return block.kind.plainText.count < 500
}
