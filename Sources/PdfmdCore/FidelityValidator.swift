/// Fidelity guard: never accept model output blindly (plan.md section 29).
///
/// The repaired Markdown, projected back to plain scoring text, is compared
/// against the deterministic extraction after tolerant normalization.
/// Formatting and legitimate reordering stay possible; fabrication and
/// catastrophic omission do not. One repair attempt per page — no recursive
/// self-fixing. Thresholds are explicit so benchmark evidence can move them.
public struct FidelityValidator: Sendable {
    /// Maximum fraction of repaired tokens that may be novel.
    public var maximumNovelRate: Double
    /// Minimum fraction of deterministic tokens the repair must retain.
    public var minimumRetention: Double

    public init(maximumNovelRate: Double = 0.05, minimumRetention: Double = 0.9) {
        self.maximumNovelRate = maximumNovelRate
        self.minimumRetention = minimumRetention
    }

    public func validate(deterministicText: String, repairedText: String) -> ValidationResult {
        let trimmed = repairedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(reason: "empty repair output")
        }
        let baseTokens = tokenize(normalizeForScoring(deterministicText))
        let repairedTokens = tokenize(normalizeForScoring(trimmed))
        guard !baseTokens.isEmpty else {
            // Nothing deterministic to guard; accept non-empty output.
            return .accepted
        }
        guard !repairedTokens.isEmpty else {
            return .rejected(reason: "repair erased all text")
        }
        if isSuspiciouslyRepetitive(repairedTokens) {
            return .rejected(reason: "repair repeats itself")
        }
        let report = scoreTokens(gold: baseTokens, candidate: repairedTokens)
        let retained = Double(report.matchingTokens + report.replacements) / Double(baseTokens.count)
        guard retained >= minimumRetention else {
            return .rejected(reason: "repair omits too much source text")
        }
        // Hallucination is about support, not order: a legitimately reordered
        // page reuses the same tokens, so novelty is measured against the
        // base multiset rather than the sequence diff (which would punish
        // every moved sentence as fabricated).
        guard novelTokenRate(base: baseTokens, candidate: repairedTokens) <= maximumNovelRate else {
            return .rejected(reason: "repair invents too much novel text")
        }
        return .accepted
    }

    /// Flags output dominated by one repeated sentence: no real transcription
    /// repeats the same 8-token run for a third of its length.
    private func isSuspiciouslyRepetitive(_ tokens: [String]) -> Bool {
        guard tokens.count >= 24 else { return false }
        var counts: [[String]: Int] = [:]
        for i in 0...(tokens.count - 8) {
            counts[Array(tokens[i..<(i + 8)]), default: 0] += 1
        }
        guard let best = counts.values.max() else { return false }
        return Double(best * 8) / Double(tokens.count) > 0.3
    }
}

public enum ValidationResult: Sendable, Equatable {
    case accepted
    case rejected(reason: String)
}

/// Fraction of candidate tokens with no support in the base multiset,
/// ignoring order. Reordered faithful text scores ~0; fabricated passages
/// score high even when they reuse a few source words.
func novelTokenRate(base: [String], candidate: [String]) -> Double {
    guard !candidate.isEmpty else { return 0 }
    var remaining: [String: Int] = [:]
    for token in base { remaining[token, default: 0] += 1 }
    var novel = 0
    for token in candidate {
        if let count = remaining[token], count > 0 {
            remaining[token] = count - 1
        } else {
            novel += 1
        }
    }
    return Double(novel) / Double(candidate.count)
}
