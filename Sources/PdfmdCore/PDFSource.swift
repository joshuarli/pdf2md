import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// PDFKit access: document opening, native-text evidence, page rasterization,
/// and raster-twin generation.
///
/// PDFKit types are not `Sendable` and carry thread affinity, so everything
/// here is synchronous and the pipeline calls it serially with no `await`
/// interleaved: each page's native text and bitmap are extracted into plain
/// `Sendable` values before any async Vision work begins.
public enum PDFSourceError: Error, CustomStringConvertible {
    case unreadable(String)
    case encrypted(String)
    case empty(String)
    case pageOutOfRange(page: Int, pageCount: Int)
    case renderFailed(page: Int)

    public var description: String {
        switch self {
        case .unreadable(let path): return "pdfmd: cannot open PDF: \(path)"
        case .encrypted(let path): return "pdfmd: encrypted PDF (passwords are out of scope): \(path)"
        case .empty(let path): return "pdfmd: PDF has no pages: \(path)"
        case .pageOutOfRange(let page, let count):
            return "pdfmd: page \(page) out of range (document has \(count) pages)"
        case .renderFailed(let page): return "pdfmd: failed to render page \(page)"
        }
    }
}

public func openPDF(at url: URL) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else {
        throw PDFSourceError.unreadable(url.path)
    }
    if document.isLocked {
        throw PDFSourceError.encrypted(url.path)
    }
    guard document.pageCount > 0 else {
        throw PDFSourceError.empty(url.path)
    }
    return document
}

/// Raw selectable text for a page, plus its media-box size in points.
public func nativeText(of page: PDFPage) -> (text: String, size: CGSize) {
    let text = page.string ?? ""
    let size = page.bounds(for: .mediaBox).size
    return (text, size)
}

/// Per-line dominant type size from the native attributed string. Headings
/// use display sizes, body uses one steady size, footnotes/captions use
/// small type — the three-way split golden curation (and later heading
/// inference) keys on. Sizes are 0 when no attributed string exists.
public func fontLines(of page: PDFPage) -> [(size: Double, text: String)] {
    guard let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else {
        return (page.string ?? "").components(separatedBy: .newlines).map { (size: 0, text: $0) }
    }
    // Per-line selections (`selectionsByLine`), not a newline split of the
    // whole page's linearized `attributedString`: a two-column page's
    // content stream can place a margin note's first line right after a
    // main-column line with no intervening newline in that flat string, so
    // splitting on newlines glues them into one "line" and the dominant
    // (main-column, body-sized) font run wins — the margin note's own
    // smaller size never surfaces (AI 2027 page 3: "...workflows.4" and "1
    // At first, most people..." merged, tagging the footnote's opening
    // words as 11pt body type instead of 9.35pt footnote type, which then
    // fails `nativeFootnoteItems`'s size gate and drops the footnote).
    // Asking each geometric line for its own `attributedString` keeps
    // column separation intact.
    return selection.selectionsByLine().compactMap { line -> (size: Double, text: String)? in
        guard let text = line.string, !text.isEmpty else { return nil }
        guard let attributed = line.attributedString else { return (0, text) }
        var best: (length: Int, size: Double) = (0, 0)
        unsafe attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if range.length > best.length {
                best = (range.length, Double((value as? NSFont)?.pointSize ?? 0))
            }
        }
        return (best.size, text)
    }
}

/// PDFKit line selections carry geometry independently of blank-line breaks
/// in `PDFPage.string` (which are usually absent in born-digital prose).
public func nativeTextLines(of page: PDFPage) -> [NativeTextLine] {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0,
        let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters))
    else { return [] }
    // Rotated PDF geometry needs an explicit transform before reconciliation.
    // Until then, accepting OCR is safer than associating the wrong region.
    guard page.rotation % 360 == 0 else { return [] }
    return selection.selectionsByLine().compactMap { line in
        guard let text = line.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let rect = line.bounds(for: page)
        guard !rect.isEmpty, !rect.isInfinite, !rect.isNull else { return nil }
        return NativeTextLine(text: text, region: NormalizedRect(
            x: Double((rect.minX - bounds.minX) / bounds.width),
            y: Double((bounds.maxY - rect.maxY) / bounds.height),
            width: Double(rect.width / bounds.width), height: Double(rect.height / bounds.height)))
    }
}

/// Render a page into memory as a `CGImage` at roughly `dpi`, preserving
/// aspect ratio. Tuned against the benchmark starting around 216-300 DPI;
/// the lowest resolution that holds quality wins (plan.md section 17).
public func renderCGImage(of page: PDFPage, dpi: CGFloat = 216) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let scale = max(0.5, dpi / 72.0)
    // Clamp pathological dimensions before allocating the bitmap.
    let width = min(Int(bounds.width * scale), 6000)
    let height = min(Int(bounds.height * scale), 6000)
    guard width > 0, height > 0 else { return nil }

    guard let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() as CGColorSpace?,
        let context = unsafe CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    context.interpolationQuality = .high
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.saveGState()
    // A raw bitmap context already uses PDF's bottom-left, y-up convention,
    // so no flip is needed — just scale into pixels and shift non-zero
    // origins. (An extra translate+flip here was verified to rotate output
    // 180°; variant-tested against the AI 2027 specimen.)
    context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
    context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    page.draw(with: .mediaBox, to: context)
    context.restoreGState()
    return context.makeImage()
}

/// Build a raster-only twin of `source`: each page re-rendered at `dpi` and
/// embedded as the sole page image, preserving order and approximate size.
/// The twin must expose no meaningful native text layer; verify with
/// `twinHasNativeText` before benchmarking (plan.md section 9).
public func buildRasterOnlyTwin(source: PDFDocument, dpi: CGFloat = 300) throws -> PDFDocument {
    let twin = PDFDocument()
    for index in 0..<source.pageCount {
        guard let page = source.page(at: index),
            let image = renderCGImage(of: page, dpi: dpi)
        else { throw PDFSourceError.renderFailed(page: index + 1) }
        guard let twinPage = PDFPage(image: NSImage(cgImage: image, size: NSSize(width: page.bounds(for: .mediaBox).width, height: page.bounds(for: .mediaBox).height))) else {
            throw PDFSourceError.renderFailed(page: index + 1)
        }
        twin.insert(twinPage, at: twin.pageCount)
    }
    return twin
}

/// True when PDFKit exposes a meaningful selectable-text layer, i.e. the
/// document is *not* a valid raster-only twin.
public func twinHasNativeText(_ document: PDFDocument, minimumCharacters: Int = 100) -> Bool {
    var total = 0
    for index in 0..<document.pageCount {
        guard let page = document.page(at: index) else { continue }
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        total += text.count
        if total >= minimumCharacters { return true }
    }
    return false
}
