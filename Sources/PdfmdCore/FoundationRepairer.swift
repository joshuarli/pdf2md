import CoreGraphics
import FoundationModels

/// Selective Foundation Models repair (plan.md sections 25-28).
///
/// The model is a repair stage, never the OCR engine: it receives the
/// deterministic draft plus compact structured context and returns a revised
/// page. One attempt per page; the fidelity guard decides whether it survives.
///
/// macOS 26 vs 27 split (plan.md section 2.1): the page image reaches the
/// model only on macOS 27+, where image attachments exist. On macOS 26 the
/// same call repairs from structured context alone. The `ModelRepairing`
/// protocol is the testing seam — tests use a fake, never Apple Intelligence.
public protocol ModelRepairing: Sendable {
    var modelAvailable: Bool { get }
    /// Returns repaired Markdown, or nil when the model is unavailable,
    /// inference fails, or the page should keep its deterministic draft.
    /// `pageImage` is honored on macOS 27+ and ignored on macOS 26.
    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String?
}

public struct FoundationRepairer: ModelRepairing {
    public init() {}

    public var modelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? {
        guard modelAvailable else { return nil }
        // macOS 27 insertion point: attach `pageImage` to the prompt behind
        // `if #available(macOS 27, *)` once the Xcode 27 SDK provides the
        // image-attachment API, and pass imageAttached: true below so the
        // instruction's image clauses apply. Not referenced here because the
        // symbol does not exist in older SDKs.
        _ = pageImage
        let session = LanguageModelSession()
        // Bounded wait: an on-device stall must degrade to the deterministic
        // draft, never hang the conversion (plan.md section 34).
        let prompt = repairPrompt(page: page, draft: draft, imageAttached: false)
        do {
            let content = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await session.respond(to: prompt).content }
                group.addTask {
                    try await Task.sleep(for: .seconds(120))
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let trimmed = stripCodeFence(content.trimmingCharacters(in: .whitespacesAndNewlines))
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            // Model failure degrades to deterministic output, never an error.
            return nil
        }
    }
}

/// Compact repair prompt: strict reconstruction instruction, structured block
/// summary, deterministic draft. Kept small for the on-device context budget.
public func repairPrompt(page: PageIR, draft: String, imageAttached: Bool) -> String {
    var lines: [String] = []
    lines.append("You are reconstructing Markdown from a document page.")
    lines.append("")
    lines.append("Preserve the source text.")
    lines.append("")
    lines.append("Do not summarize.")
    lines.append("")
    lines.append("Do not explain.")
    lines.append("")
    lines.append("Do not add facts or prose.")
    lines.append("")
    lines.append("Do not silently omit readable textual content.")
    lines.append("")
    if imageAttached {
        lines.append("Use the page image only to resolve layout, reading order,")
        lines.append("hierarchy, table/list structure, and obvious OCR errors.")
        lines.append("")
        lines.append("Prefer exact supplied native text over guessing characters")
        lines.append("from the image.")
    } else {
        lines.append("Use the structured blocks only to resolve reading order,")
        lines.append("hierarchy, and table/list structure.")
        lines.append("")
        lines.append("Prefer exact supplied text over rewording.")
    }
    lines.append("")
    lines.append("Return only reconstructed Markdown for this page.")
    lines.append("")
    lines.append("Structured blocks:")
    let summary = page.blocks.prefix(40).map { block -> String in
        let label: String
        switch block.kind {
        case .title(let text): label = "title: \(text)"
        case .heading(let level, let text): label = "h\(level): \(text)"
        case .paragraph(let text): label = "p: \(text)"
        case .list(let list): label = "list: \(list.items.map(\.text).joined(separator: " | "))"
        case .table(let table):
            label = "table \(table.rowCount)x\(table.columnCount): "
                + table.rows.flatMap { $0 }.map(\.text).joined(separator: " | ")
        }
        return "- \(label.prefix(300))"
    }
    lines.append(contentsOf: summary)
    lines.append("")
    lines.append("Deterministic draft:")
    lines.append(String(draft.prefix(6000)))
    return lines.joined(separator: "\n")
}

/// The model sometimes wraps its answer in a ```markdown fence despite the
/// instruction; a fence is presentation, not content, so peel it off. Inner
/// code blocks (fences after the first line) are legitimate Markdown, and an
/// unclosed fence stays untouched — peeling only the opener would corrupt.
func stripCodeFence(_ text: String) -> String {
    var lines = text.components(separatedBy: "\n")
    guard let first = lines.first, first.hasPrefix("```"),
        let last = lines.last, last.trimmingCharacters(in: .whitespaces) == "```",
        lines.count >= 2
    else { return text }
    lines.removeFirst()
    lines.removeLast()
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}
