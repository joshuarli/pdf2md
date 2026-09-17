/// Deterministic Markdown renderer. Every page must produce useful Markdown
/// without Foundation Models (plan.md section 22); the repair stage only
/// ever revises this draft.

public func renderPage(_ page: PageIR) -> String {
    (page.blocks.map { renderBlock($0.kind) }
        + page.footnoteDefinitions.map { "[^\($0.marker)]: \($0.text)" })
        .joined(separator: "\n\n")
}

public func renderDocument(pages: [PageIR]) -> String {
    pages.map { renderPage($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
        + "\n"
}

func renderBlock(_ kind: BlockKind) -> String {
    switch kind {
    case .title(let text):
        return "# \(singleLine(text))"
    case .heading(let level, let text):
        return "\(String(repeating: "#", count: min(max(level, 1), 6))) \(singleLine(text))"
    case .paragraph(let text):
        return collapseHardWraps(text)
    case .list(let list):
        return renderList(list)
    case .table(let table):
        return renderTable(table)
    }
}

func renderList(_ list: ListBlock) -> String {
    list.items.enumerated().map { index, item in
        // Normalize bullets to `-`; keep ordered numbering meaningful.
        let marker = list.ordered ? "\(index + 1)." : "-"
        let text = stripDuplicatedMarker(item.text, marker: item.marker, ordered: list.ordered)
        return "\(marker) \(singleLine(text))"
    }.joined(separator: "\n")
}

/// OCR frequently repeats the list marker inside the item text ("• • item").
/// Strip one leading copy when it matches the reported marker shape.
public func stripDuplicatedMarker(_ text: String, marker: String, ordered: Bool) -> String {
    var rest = text.trimmingCharacters(in: .whitespaces)
    if ordered {
        // Strip a leading "1." / "1)" style marker regardless of exact number.
        var idx = rest.startIndex
        while idx < rest.endIndex, rest[idx].isNumber { idx = rest.index(after: idx) }
        if idx > rest.startIndex, idx < rest.endIndex, rest[idx] == "." || rest[idx] == ")" {
            let after = rest.index(after: idx)
            if after < rest.endIndex, rest[after].isWhitespace {
                rest = String(rest[after...]).trimmingCharacters(in: .whitespaces)
                return rest
            }
        }
        return rest
    }
    let bullets = [marker.trimmingCharacters(in: .whitespaces), "•", "·", "-", "*", "–", "—"]
    for bullet in bullets where !bullet.isEmpty {
        if rest.hasPrefix(bullet) {
            let after = rest.index(rest.startIndex, offsetBy: bullet.count)
            if after >= rest.endIndex || rest[after].isWhitespace {
                return String(rest[after...]).trimmingCharacters(in: .whitespaces)
            }
        }
    }
    return rest
}

func renderTable(_ table: TableBlock) -> String {
    guard !table.rows.isEmpty else { return "" }
    let widths = table.rows.map { $0.count }
    guard let columnCount = widths.max(), columnCount > 0 else { return "" }
    func cell(_ text: String) -> String {
        // Preserve all readable content: escape pipes, keep empty cells, fold
        // internal line breaks to <br> (plan.md section 22).
        singleLine(text).replacingOccurrences(of: "|", with: "\\|")
    }
    var lines: [String] = []
    for (index, row) in table.rows.enumerated() {
        var cells = row.map { cell($0.text) }
        while cells.count < columnCount { cells.append("") }
        lines.append("| " + cells.joined(separator: " | ") + " |")
        if index == 0 {
            lines.append("| " + [String](repeating: "---", count: columnCount).joined(separator: " | ") + " |")
        }
    }
    return lines.joined(separator: "\n")
}

func singleLine(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: "<br>")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Collapse hard line wraps into flowing text: newlines become spaces, except
/// a hyphenated break joins only on high confidence (lowercase-to-lowercase),
/// and CJK neighbors join with no space at all.
public func collapseHardWraps(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return "" }
    var result = lines[0]
    for line in lines.dropFirst() {
        if result.hasSuffix("-"), repairHyphenation(left: result, right: line) {
            result = String(result.dropLast()) + line
        } else if let last = result.last, let first = line.first,
            isCJK(last) && isCJK(first)
        {
            result += line
        } else if let last = result.last, isCJK(last), line.first.map({ $0.isLetter || $0.isNumber }) == true {
            result += line
        } else if result.last.map(isCJK) == true || line.first.map(isCJK) == true {
            // One side CJK: join directly to avoid "日本語 text" spacing damage.
            // A space is only inserted when both sides are non-CJK.
            if let last = result.last, let first = line.first, !last.isWhitespace,
                !(isCJK(last) || isCJK(first))
            {
                result += " " + line
            } else {
                result += line
            }
        } else {
            result += " " + line
        }
    }
    return result
}

func repairHyphenation(left: String, right: String) -> Bool {
    guard let before = left.dropLast().last, let after = right.first else { return false }
    // High confidence only: lowercase letter on both sides of the hyphen.
    // This correctly joins "exam- / ple" but cannot distinguish a hard hyphen
    // ("well- / known" → "wellknown"): without a lexicon the break is
    // ambiguous, and joining is right far more often in running prose.
    // Known limitation; revisit with benchmark evidence if it costs points.
    return before.isLowercase && before.isLetter && after.isLowercase && after.isLetter
}

func isCJK(_ scalar: Character) -> Bool {
    scalar.unicodeScalars.allSatisfy { value in
        switch value.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF,
            0x3040...0x309F, 0x30A0...0x30FF,
            0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F,
            0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}
