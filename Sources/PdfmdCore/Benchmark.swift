import CryptoKit
import Foundation

/// Benchmark manifest and scoring entry points (plan.md sections 7, 10, 38).
/// The source PDF and golden Markdown stay local/untracked; the repository
/// carries only this manifest shape, the scoring code, and methodology notes.

public struct BenchmarkManifest: Codable, Sendable {
    public var sourceFilename: String
    public var sourceURL: String
    public var sha256: String
    public var byteSize: Int
    public var pageCount: Int
    public var goldenFilename: String
    public var rasterFilename: String
    public var bornDigitalTextMatch: Double
    public var rasterTextMatch: Double
    public var rasterNovelText: Double
    public var pageFloor: Double

    public init(
        sourceFilename: String,
        sourceURL: String,
        sha256: String,
        byteSize: Int,
        pageCount: Int,
        goldenFilename: String = "golden.md",
        rasterFilename: String = "ai-2027-raster.pdf",
        bornDigitalTextMatch: Double = 0.99,
        rasterTextMatch: Double = 0.95,
        rasterNovelText: Double = 0.01,
        pageFloor: Double = 0.85
    ) {
        self.sourceFilename = sourceFilename
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.byteSize = byteSize
        self.pageCount = pageCount
        self.goldenFilename = goldenFilename
        self.rasterFilename = rasterFilename
        self.bornDigitalTextMatch = bornDigitalTextMatch
        self.rasterTextMatch = rasterTextMatch
        self.rasterNovelText = rasterNovelText
        self.pageFloor = pageFloor
    }
}

public enum BenchmarkError: Error, CustomStringConvertible {
    case hashMismatch(filename: String, expected: String, actual: String)
    case unreadable(String)

    public var description: String {
        switch self {
        case .hashMismatch(let filename, let expected, let actual):
            return "pdfmd-bench: \(filename) SHA-256 mismatch (expected \(expected), got \(actual)); refusing to benchmark a changed upstream document"
        case .unreadable(let path):
            return "pdfmd-bench: cannot read \(path)"
        }
    }
}

public func sha256Hex(of url: URL) throws -> String {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
        throw BenchmarkError.unreadable(url.path)
    }
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    let digits = Array("0123456789abcdef")
    var hex = ""
    hex.reserveCapacity(SHA256.Digest.byteCount * 2)
    for byte in hasher.finalize() {
        hex.append(digits[Int(byte >> 4)])
        hex.append(digits[Int(byte & 0xF)])
    }
    return hex
}

public func validateBenchmarkSource(at url: URL, manifest: BenchmarkManifest) throws {
    let actual = try sha256Hex(of: url)
    guard actual == manifest.sha256.lowercased() else {
        throw BenchmarkError.hashMismatch(filename: url.lastPathComponent, expected: manifest.sha256, actual: actual)
    }
}

public func scoreMarkdown(candidate: String, golden: String) -> ScoreReport {
    scoreTokens(
        gold: tokenize(normalizeForScoring(golden)),
        candidate: tokenize(normalizeForScoring(candidate))
    )
}

public func formatScoreReport(title: String, report: ScoreReport) -> String {
    func percent(_ value: Double) -> String {
        String(((value * 10000).rounded() / 100).description)
    }
    return """
        \(title)
          text match:       \(percent(report.textMatch))%
          novel text:       \(percent(report.novelText))%
          gold tokens:      \(report.goldTokens)
          candidate tokens: \(report.candidateTokens)
          matching:         \(report.matchingTokens)
          deletions:        \(report.deletions)
          insertions:       \(report.insertions)
          replacements:    \(report.replacements)
        """
}
