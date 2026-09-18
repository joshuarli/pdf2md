import CoreGraphics
import Foundation
import PDFKit

/// Conversion pipeline (plan.md sections 15, 30-31).
///
/// Serial, bounded memory. Pass 1 keeps only lightweight Page IR plus one
/// in-flight bitmap; Pass 4 re-renders just the routed pages rather than
/// retaining hundreds of images. No worker pools until profiling demands
/// them — correctness and benchmark quality first.
public struct Pipeline: Sendable {
    public var vision: any DocumentRecognizing
    public var repairer: any ModelRepairing
    public var router: ComplexityRouter
    public var validator: FidelityValidator
    public var dpi: CGFloat

    public init(
        vision: any DocumentRecognizing = VisionExtractor(),
        repairer: any ModelRepairing = NoRepair(),
        router: ComplexityRouter = ComplexityRouter(),
        validator: FidelityValidator = FidelityValidator(),
        dpi: CGFloat = 216
    ) {
        self.vision = vision
        self.repairer = repairer
        self.router = router
        self.validator = validator
        self.dpi = dpi
    }

    /// One page's synchronous PDFKit payload. Plain `Sendable` values cross
    /// into async Vision work; `PDFDocument` never does.
    struct PagePayload: Sendable {
        var pageNumber: Int
        var nativeText: String
        var image: CGImage
        var size: CGSize
        /// Native lines with dominant type size, for footnote segmentation.
        var fontLines: [(size: Double, text: String)]
        var nativeLines: [NativeTextLine]
    }

    public func convertWithPageDrafts(
        pdfURL: URL,
        options: CliOptions,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> (markdown: String, pageDrafts: [String]) {
        let requested = try selectedPages(pdfURL: pdfURL, pages: options.pages)

        // PDFKit stays inside the synchronous loader. Only one payload owns
        // a raster at a time; the document-wide state contains text and IR.
        var document: [PageIR] = []
        var nativeLinesByNumber: [Int: [(size: Double, text: String)]] = [:]
        document.reserveCapacity(requested.count)
        for pageNumber in requested {
            let payload = try loadPayload(pdfURL: pdfURL, pageNumber: pageNumber, dpi: dpi)
            nativeLinesByNumber[pageNumber] = payload.fontLines
            progress("pdfmd: page \(payload.pageNumber) (\(document.count + 1)/\(requested.count))")
            var page = try await vision.extract(from: payload.image, pageNumber: payload.pageNumber, pageSize: payload.size)
            let quality = assessNativeQuality(payload.nativeText)
            page.nativeTextQuality = quality
            let reconciled = reconcileNativeLines(payload.nativeLines, quality: quality, blocks: page.blocks)
            page.blocks = reconciled.blocks
            if reconciled.disagreement { page.complexity.nativeVisionDisagreement = true }
            // Vision sometimes emits a title/heading's text a second time as
            // an ordinary paragraph (the same banner read once as document
            // title, once as a paragraph observation). Dedup runs here,
            // before the lenient title fallback below, while both copies
            // still carry identical (possibly still-garbled) OCR text —
            // fixing only the title copy first would leave the paragraph
            // copy's now-different wording looking like distinct content
            // and defeat text-overlap dedup entirely.
            page.blocks = deduplicate(page.blocks)
            // Geometric line reconciliation is precise but strict (0.85
            // reciprocal token agreement); a heavily garbled display-type
            // title/heading ("APPENDIX C. WHY IVE FORECAST A SUPERBUMAN
            // CODERIN FARLY 2027") can fail that bar even though whole-page
            // text search (`reconcileParagraphs`, no geometry, a lower
            // threshold built for exactly this) still finds the true native
            // line. Only titles/headings the geometric pass left as `.vision`
            // get this fallback — ordinary paragraphs keep the geometric
            // result, which already has positional confidence.
            let textReconciled = reconcileParagraphs(nativeText: payload.nativeText, quality: quality, blocks: page.blocks)
            for index in page.blocks.indices {
                guard page.blocks[index].source != .reconciled else { continue }
                switch page.blocks[index].kind {
                case .title, .heading: page.blocks[index] = textReconciled.blocks[index]
                case .paragraph, .list, .table: continue
                }
            }
            page.blocks = suppressUnsupportedScript(blocks: page.blocks, nativeText: payload.nativeText, quality: quality)
            page.blocks = orderBlocksForReading(page.blocks)
            page.complexity = detectComplexity(page)
            document.append(page)
        }

        // Pass 2: document-level cleanup over lightweight IR.
        let stripped = stripRepeatedFurniture(pages: document.map(\.blocks))
        for index in document.indices { document[index].blocks = stripped[index] }

        // Footnote relocation to page-end definitions (gold layout §23).
        // Native-guided when the layer is trustworthy, geometric otherwise.
        for index in document.indices {
            let relocated: RelocatedFootnotes
            if let lines = nativeLinesByNumber[document[index].pageNumber],
                document[index].nativeTextQuality == .trustworthy
            {
                relocated = relocateFootnotesWithNative(
                    blocks: document[index].blocks, nativeLines: lines)
            } else {
                relocated = relocateFootnotes(document[index].blocks)
            }
            document[index].blocks = relocated.blocks
            document[index].footnoteDefinitions = relocated.definitions
        }

        // Pass 3: deterministic Markdown for every page.
        var drafts = document.map { renderPage($0) }

        // An unavailable (or benchmark-disabled) model must not trigger a
        // second rasterization pass just to return nil from every repair.
        let modelAvailable = repairer.modelAvailable
        // Pass 4: selective repair. Re-render routed pages on demand.
        var debugs: [PageDebug] = []
        let collectDebug = options.debugDir != nil
        for index in document.indices {
            let page = document[index]
            let deterministicDraft = drafts[index]
            var repaired: String?
            var accepted: Bool?
            var reason: String?
            if modelAvailable && router.routesToRepair(page) {
                let repairStart = Date()
                progress("pdfmd: repairing page \(page.pageNumber)")
                let image = try renderOnePage(pdfURL: pdfURL, pageNumber: page.pageNumber, dpi: dpi)
                if let attempt = await repairer.repair(page: page, draft: drafts[index], pageImage: image) {
                    progress("pdfmd: repaired page \(page.pageNumber) in \((Date().timeIntervalSince(repairStart) * 10).rounded() / 10)s")
                    switch validator.validate(deterministicText: page.plainText, repairedText: attempt) {
                    case .accepted:
                        drafts[index] = attempt
                        repaired = attempt
                        accepted = true
                    case .rejected(let why):
                        repaired = attempt
                        accepted = false
                        reason = why
                    }
                }
            }
            if collectDebug {
                debugs.append(PageDebug(
                    pageNumber: page.pageNumber,
                    nativeTextQuality: page.nativeTextQuality.rawValue,
                    nativeCharacters: page.plainText.count,
                    blocks: page.blocks.map(debugBlock),
                    deterministicMarkdown: deterministicDraft,
                    repairedMarkdown: repaired,
                    repairAccepted: accepted,
                    repairReason: reason
                ))
            }
        }

        if let debugDir = options.debugDir {
            try writeDebugPages(
                debugs,
                manifest: ["pages": "\(document.count)", "repaired": "\(debugs.filter { $0.repairAccepted == true }.count)"],
                to: URL(fileURLWithPath: debugDir)
            )
        }
        return (drafts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n", drafts)
    }

    /// Convenience wrapper for the CLI: only the joined Markdown.
    public func convert(
        pdfURL: URL,
        options: CliOptions,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        try await convertWithPageDrafts(pdfURL: pdfURL, options: options, progress: progress).0
    }

    // MARK: - Pass internals

    func selectedPages(pdfURL: URL, pages: [Int]?) throws -> [Int] {
        let document = try openPDF(at: pdfURL)
        if let pages {
            for page in pages {
                guard page >= 1, page <= document.pageCount else {
                    throw PDFSourceError.pageOutOfRange(page: page, pageCount: document.pageCount)
                }
            }
            return Array(Set(pages)).sorted()
        }
        return Array(1...document.pageCount)
    }

    func loadPayload(pdfURL: URL, pageNumber: Int, dpi: CGFloat) throws -> PagePayload {
        try autoreleasepool {
            let document = try openPDF(at: pdfURL)
            guard let pdfPage = document.page(at: pageNumber - 1) else {
                throw PDFSourceError.pageOutOfRange(page: pageNumber, pageCount: document.pageCount)
            }
            let (text, size) = nativeText(of: pdfPage)
            guard let image = renderCGImage(of: pdfPage, dpi: dpi) else {
                throw PDFSourceError.renderFailed(page: pageNumber)
            }
            return PagePayload(
                pageNumber: pageNumber, nativeText: text, image: image, size: size,
                fontLines: fontLines(of: pdfPage), nativeLines: nativeTextLines(of: pdfPage)
            )
        }
    }

    func renderOnePage(pdfURL: URL, pageNumber: Int, dpi: CGFloat) throws -> CGImage {
        let document = try openPDF(at: pdfURL)
        guard let pdfPage = document.page(at: pageNumber - 1),
            let image = renderCGImage(of: pdfPage, dpi: dpi)
        else { throw PDFSourceError.renderFailed(page: pageNumber) }
        return image
    }

    /// Heuristic complexity signals from the reconciled page. Named flags,
    /// no hidden weights; the router and the benchmark judge each one.
    func detectComplexity(_ page: PageIR) -> ComplexitySignals {
        var signals = page.complexity
        if page.blocks.contains(where: { if case .table(let t) = $0.kind { return t.hasSpans } else { return false } }) {
            signals.mergedCells = true
        }
        if splitColumns(page.blocks) != nil { signals.multiColumn = true }
        let paragraphs = page.blocks.compactMap { if case .paragraph(let t) = $0.kind { return t } else { return nil } }
        if paragraphs.count >= 8 {
            let mean = Double(paragraphs.map(\.count).reduce(0, +)) / Double(paragraphs.count)
            if mean < 60 { signals.fragmentedOCR = true }
        }
        var overlaps = 0
        var pairs = 0
        for i in page.blocks.indices {
            for j in page.blocks.indices where j > i {
                pairs += 1
                if page.blocks[i].region.intersectionFractionOfSmaller(page.blocks[j].region) > 0.3 {
                    overlaps += 1
                }
            }
        }
        if pairs > 0, Double(overlaps) / Double(pairs) > 0.25 { signals.denseOverlap = true }
        return signals
    }
}

// MARK: - CLI entry

/// Run the CLI. Returns a conventional exit code; stdout carries Markdown
/// only, diagnostics go to stderr, and normal errors print one line.
public func runCLI(arguments: [String], pipeline: Pipeline = Pipeline()) async -> Int32 {
    let action: CliAction
    do {
        action = try parseArguments(arguments)
    } catch let error as CliError {
        writeStderr(error.description + "\n")
        return 2
    } catch {
        writeStderr("pdfmd: \(error)\n")
        return 2
    }
    switch action {
    case .help:
        print(usageText)
        return 0
    case .version:
        print("pdfmd \(pdfmdVersion)")
        return 0
    case .run(let options):
        do {
            let markdown = try await pipeline.convert(
                pdfURL: URL(fileURLWithPath: options.input),
                options: options,
                progress: { writeStderr($0 + "\n") }
            )
            if let output = options.output {
                try writeAtomically(markdown, to: URL(fileURLWithPath: output))
            } else {
                writeStdout(markdown)
            }
            return 0
        } catch let error as PDFSourceError {
            writeStderr(error.description + "\n")
            return 1
        } catch let error as CliError {
            writeStderr(error.description + "\n")
            return 2
        } catch {
            writeStderr("pdfmd: conversion failed: \(error)\n")
            return 1
        }
    }
}

/// UTF-8 via a unique temporary sibling and atomic replacement: see
/// `writeAtomically` in `Output.swift` (kept out of Pipeline for clarity).


func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
