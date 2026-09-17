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
    public var vision: VisionExtractor
    public var repairer: any ModelRepairing
    public var router: ComplexityRouter
    public var validator: FidelityValidator
    public var dpi: CGFloat

    public init(
        vision: VisionExtractor = VisionExtractor(),
        repairer: any ModelRepairing = FoundationRepairer(),
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
    }

    public func convert(
        pdfURL: URL,
        options: CliOptions,
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> String {
        // Pass 1 (sync): native text + bitmaps, then immediately release the
        // document. No await interleaved with PDFKit access.
        let payloads = try loadPayloads(pdfURL: pdfURL, pages: options.pages, dpi: dpi)

        // Pass 1 (async): Vision structure, reconciliation, ordering.
        var document: [PageIR] = []
        document.reserveCapacity(payloads.count)
        for payload in payloads {
            progress("pdfmd: page \(payload.pageNumber) (\(document.count + 1)/\(payloads.count))")
            var page = try await vision.extract(from: payload.image, pageNumber: payload.pageNumber, pageSize: payload.size)
            let quality = assessNativeQuality(payload.nativeText)
            page.nativeTextQuality = quality
            let reconciled = reconcileParagraphs(nativeText: payload.nativeText, quality: quality, blocks: page.blocks)
            page.blocks = reconciled.blocks
            if reconciled.disagreement { page.complexity.nativeVisionDisagreement = true }
            page.blocks = deduplicate(page.blocks)
            page.blocks = orderBlocksForReading(page.blocks)
            page.complexity = detectComplexity(page)
            document.append(page)
        }

        // Pass 2: document-level cleanup over lightweight IR.
        let stripped = stripRepeatedFurniture(pages: document.map(\.blocks))
        for index in document.indices { document[index].blocks = stripped[index] }

        // Pass 3: deterministic Markdown for every page.
        var drafts = document.map { renderPage($0) }

        // Pass 4: selective repair. Re-render routed pages on demand.
        var debugs: [PageDebug] = []
        let collectDebug = options.debugDir != nil
        for index in document.indices {
            let page = document[index]
            var repaired: String?
            var accepted: Bool?
            var reason: String?
            if router.routesToRepair(page) {
                progress("pdfmd: repairing page \(page.pageNumber)")
                let image = try renderOnePage(pdfURL: pdfURL, pageNumber: page.pageNumber, dpi: dpi)
                if let attempt = await repairer.repair(page: page, draft: drafts[index], pageImage: image) {
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
                    deterministicMarkdown: drafts[index],
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
        return drafts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Pass internals

    func loadPayloads(pdfURL: URL, pages: [Int]?, dpi: CGFloat) throws -> [PagePayload] {
        let document = try openPDF(at: pdfURL)
        let requested: [Int]
        if let pages {
            for page in pages {
                guard page >= 1, page <= document.pageCount else {
                    throw PDFSourceError.pageOutOfRange(page: page, pageCount: document.pageCount)
                }
            }
            requested = pages.sorted()
        } else {
            requested = Array(1...document.pageCount)
        }
        var payloads: [PagePayload] = []
        payloads.reserveCapacity(requested.count)
        for pageNumber in requested {
            guard let pdfPage = document.page(at: pageNumber - 1) else {
                throw PDFSourceError.pageOutOfRange(page: pageNumber, pageCount: document.pageCount)
            }
            let (text, size) = nativeText(of: pdfPage)
            guard let image = renderCGImage(of: pdfPage, dpi: dpi) else {
                throw PDFSourceError.renderFailed(page: pageNumber)
            }
            payloads.append(PagePayload(pageNumber: pageNumber, nativeText: text, image: image, size: size))
        }
        return payloads
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

/// UTF-8 via a temporary sibling + atomic replace, so a failure never leaves
/// a deceptively complete truncated output.
public func writeAtomically(_ markdown: String, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp")
    do {
        try Data(markdown.utf8).write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
}
