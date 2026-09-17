import Foundation

/// Scoring normalization (plan.md section 10). Candidate and gold go through
/// the identical pipeline before tokenization: Unicode/ligature/soft-hyphen
/// handling, Markdown syntax reduction to visible text, and whitespace
/// collapse. Normalization must never erase meaningful words, numbers, or
/// punctuation to flatter the score.
public func normalizeForScoring(_ text: String) -> String {
    var result = text.precomposedStringWithCanonicalMapping
    result = result.replacingOccurrences(of: "­", with: "")
    result = expandLigatures(result)
    result = normalizeSuperscripts(result)
    result = reduceMarkdown(result)
    // Collapse all whitespace runs (line wraps, page breaks) to single spaces.
    result = result.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    return result
}

private let ligatureMap: [(String, String)] = [
    ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"),
    ("ﬃ", "ffi"), ("ﬄ", "ffl"), ("ﬅ", "st"), ("ﬆ", "st"),
    ("æ", "ae"), ("œ", "oe"), ("Æ", "AE"), ("Œ", "OE"),
    ("“", "\""), ("”", "\""), ("‘", "'"), ("’", "'"),
    ("–", "-"), ("—", "-"), ("…", "..."),
]

func expandLigatures(_ text: String) -> String {
    var result = text
    for (from, to) in ligatureMap {
        result = result.replacingOccurrences(of: from, with: to)
    }
    return result
}

private let superscriptMap: [Character: Character] = [
    "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
    "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
]

func normalizeSuperscripts(_ text: String) -> String {
    String(text.map { superscriptMap[$0] ?? $0 })
}

func reduceMarkdown(_ text: String) -> String {
    var result = text
    // Footnote markers first so link reduction cannot eat them.
    result = result.replacingOccurrences(of: #"\[\^([^\]]+)\]"#, with: " ", options: .regularExpression)
    // [visible](url) -> visible
    result = result.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    // Heading markers, emphasis, code ticks, table pipes, blockquotes, <br>.
    result = result.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"(?m)^\s{0,3}[-*+]\s+"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"(?m)^\s{0,3}\d+[.)]\s+"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"(?m)^\s{0,3}>\s?"#, with: "", options: .regularExpression)
    result = result.replacingOccurrences(of: #"\|"#, with: " ", options: .regularExpression)
    result = result.replacingOccurrences(of: #"(\*\*|__|\*|_|`{1,3}|~~|<br\s*/?>)"#, with: " ", options: .regularExpression)
    return result
}

/// Tokenize into words, numbers, and meaningful punctuation. Words fold to
/// lowercase (fidelity is about content, not caps); numbers and punctuation
/// stay exact because `12,500` vs `12500` is a real error.
public func tokenize(_ normalized: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    func flush() {
        if !current.isEmpty {
            tokens.append(current.lowercased())
            current = ""
        }
    }
    for char in normalized {
        if char.isLetter || char.isNumber {
            current.append(char)
        } else if char.isWhitespace {
            flush()
        } else {
            flush()
            tokens.append(String(char))
        }
    }
    flush()
    return tokens
}
