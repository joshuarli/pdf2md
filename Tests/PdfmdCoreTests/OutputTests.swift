import Foundation
import Testing
@testable import PdfmdCore

struct OutputTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test func createsNewFileWithExactUTF8Content() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("output.md")
            let markdown = "# Résumé 🌍\n\n日本語 — café\n"

            try writeAtomically(markdown, to: destination)

            #expect(try Data(contentsOf: destination) == Data(markdown.utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["output.md"])
        }
    }

    @Test func replacesExistingFileContent() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("output.md")
            try Data("A much longer original document\n".utf8).write(to: destination)
            let markdown = "# New\n"

            try writeAtomically(markdown, to: destination)

            #expect(try Data(contentsOf: destination) == Data(markdown.utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["output.md"])
        }
    }

    @Test func missingDestinationDirectoryLeavesNoTemporaryResidue() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("missing/output.md")

            #expect(throws: (any Error).self) {
                try writeAtomically("# Cannot publish\n", to: destination)
            }

            let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(remaining.isEmpty)
        }
    }

    @Test func repeatedWritesToSameDestinationKeepCompleteLatestContent() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("output.md")
            let first = String(repeating: "First document é\n", count: 100)
            let second = "# Second document 日本語\n"

            try writeAtomically(first, to: destination)
            #expect(try Data(contentsOf: destination) == Data(first.utf8))
            try writeAtomically(second, to: destination)

            #expect(try Data(contentsOf: destination) == Data(second.utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["output.md"])
        }
    }
}
