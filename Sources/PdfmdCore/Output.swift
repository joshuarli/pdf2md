import Foundation

/// UTF-8 via a unique temporary sibling and atomic replacement, so independent
/// writers never share staging files or expose partially written Markdown.
public func writeAtomically(_ markdown: String, to url: URL) throws {
    let fileManager = FileManager.default
    let temporary = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
        try Data(markdown.utf8).write(to: temporary, options: .atomic)
        do {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } catch {
            // Replacement requires an existing destination. A sibling move
            // publishes a new file without crossing filesystem boundaries.
            guard !fileManager.fileExists(atPath: url.path) else { throw error }
            try fileManager.moveItem(at: temporary, to: url)
        }
    } catch {
        try? fileManager.removeItem(at: temporary)
        throw error
    }
}
