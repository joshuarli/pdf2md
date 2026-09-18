import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfmdCore

private struct NoModel: ModelRepairing {
    var modelAvailable: Bool { false }
    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? { nil }
}

private actor UnavailableRepairer: ModelRepairing {
    nonisolated var modelAvailable: Bool { false }
    private var calls = 0

    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? {
        calls += 1
        return nil
    }

    func callCount() -> Int { calls }
}

private struct ComplexPageRecognizer: DocumentRecognizing {
    func extract(from image: CGImage, pageNumber: Int, pageSize: CGSize) async throws -> PageIR {
        var page = PageIR(pageNumber: pageNumber, pageWidth: Double(pageSize.width), pageHeight: Double(pageSize.height))
        page.complexity.fragmentedOCR = true
        page.blocks = [PageBlock(kind: .paragraph("A faithful source paragraph."), region: .fullPage, source: .vision)]
        return page
    }
}

// Repair is opt-in: text-only macOS 26 repair was measured against the
// deterministic baseline and changed the score by nothing measurable while
// costing ~15x wall-clock (Benchmarks/AI2027/README.md, baseline E). The
// default pipeline must never attempt it until re-proven.
@Test func defaultPipelineRepairerIsDisabled() {
    #expect(Pipeline().repairer.modelAvailable == false)
}

@Test func pipelineSkipsUnavailableRepairerForComplexPage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("page.pdf")
    let pdf = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 72, height: 72), for: .mediaBox)
    pdf.insert(page, at: 0)
    try #require(pdf.write(to: url))

    let repairer = UnavailableRepairer()
    let pipeline = Pipeline(vision: ComplexPageRecognizer(), repairer: repairer, dpi: 72)
    _ = try await pipeline.convert(pdfURL: url, options: CliOptions(input: url.path))
    #expect(await repairer.callCount() == 0)
}

private struct FormattingRepairer: ModelRepairing {
    var modelAvailable: Bool { true }
    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? {
        "**A faithful source paragraph.**"
    }
}

@Test func pipelineDebugPreservesDraftBeforeAcceptedRepair() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("page.pdf")
    let pdf = PDFDocument()
    let page = PDFPage()
    page.setBounds(CGRect(x: 0, y: 0, width: 72, height: 72), for: .mediaBox)
    pdf.insert(page, at: 0)
    try #require(pdf.write(to: url))
    let debug = directory.appendingPathComponent("debug")
    var options = CliOptions(input: url.path)
    options.debugDir = debug.path
    let pipeline = Pipeline(vision: ComplexPageRecognizer(), repairer: FormattingRepairer(), dpi: 72)
    let markdown = try await pipeline.convert(pdfURL: url, options: options)
    let record = try JSONDecoder().decode(PageDebug.self, from: Data(contentsOf: debug.appendingPathComponent("page-0001.json")))
    #expect(markdown.contains("**A faithful source paragraph.**"))
    #expect(record.repairAccepted == true)
    #expect(record.deterministicMarkdown.trimmingCharacters(in: .whitespacesAndNewlines) == "A faithful source paragraph.")
    #expect(record.repairedMarkdown == "**A faithful source paragraph.**")
}

private actor RasterLifetimeRecognizer: DocumentRecognizing {
    private weak var previous: CGImage?
    private var numbers: [Int] = []

    func extract(from image: CGImage, pageNumber: Int, pageSize: CGSize) async throws -> PageIR {
        #expect(previous == nil, "The previous page raster must be released before recognizing the next page")
        previous = image
        numbers.append(pageNumber)
        return PageIR(pageNumber: pageNumber, pageWidth: Double(pageSize.width), pageHeight: Double(pageSize.height))
    }

    func processedPages() -> [Int] { numbers }
    func hasRetainedRaster() -> Bool { previous != nil }
}

@Test func pipelineReleasesEachRasterBeforeNextPage() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("pages.pdf")
    // A tiny real PDF exercises PDFKit loading/rendering, not OCR or a model.
    let pdf = PDFDocument()
    for _ in 0..<3 {
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 72, height: 72), for: .mediaBox)
        pdf.insert(page, at: pdf.pageCount)
    }
    try #require(pdf.write(to: url))
    let recognizer = RasterLifetimeRecognizer()
    let pipeline = Pipeline(vision: recognizer, repairer: NoModel(), dpi: 72)
    _ = try await pipeline.convert(pdfURL: url, options: CliOptions(input: url.path))
    #expect(await recognizer.processedPages() == [1, 2, 3])
    #expect(await recognizer.hasRetainedRaster() == false)
}
