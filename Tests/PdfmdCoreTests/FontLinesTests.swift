import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PdfmdCore

/// Writes a one-page PDF with each string drawn as its own text line at the
/// given font size and baseline origin, via CoreGraphics' native PDF context
/// (real glyph runs, not a mocked PDFPage) — the same drawing primitive
/// `CGContext(url:mediaBox:)` uses internally.
private func writeTestPDF(to url: URL, lines: [(text: String, fontSize: CGFloat, origin: CGPoint)]) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 400)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw PDFSourceError.unreadable(url.path)
    }
    context.beginPDFPage(nil)
    for line in lines {
        let attributed = NSAttributedString(string: line.text, attributes: [.font: NSFont.systemFont(ofSize: line.fontSize)])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = line.origin
        CTLineDraw(ctLine, context)
    }
    context.endPDFPage()
    context.closePDF()
}

@Test func fontLinesReportsEachGeometricLinesOwnSize() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeTestPDF(to: url, lines: [
        (text: "This is the large body line.", fontSize: 18, origin: CGPoint(x: 20, y: 300)),
        (text: "This is the small footnote line.", fontSize: 8, origin: CGPoint(x: 20, y: 100)),
    ])
    guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
        Issue.record("failed to load test PDF")
        return
    }
    let lines = fontLines(of: page)
    let body = lines.first { $0.text.contains("large body") }
    let note = lines.first { $0.text.contains("small footnote") }
    try #require(body != nil && note != nil)
    #expect(body!.size > note!.size + 4)
}
