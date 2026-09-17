import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfmdCore

private struct NoModel: ModelRepairing {
    var modelAvailable: Bool { false }
    func repair(page: PageIR, draft: String, pageImage: CGImage?) async -> String? { nil }
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
