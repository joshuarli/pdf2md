import CoreGraphics
import Foundation
import Vision

/// Vision document extraction: rendered page bitmaps become structured blocks.
///
/// Uses the current `RecognizeDocumentsRequest` API (not the older
/// line-oriented `VNRecognizeTextRequest`) with automatic language detection
/// and language correction, per plan.md section 18. The returned `Container`
/// already separates title/paragraphs/tables/lists, but surfaces table/list
/// text redundantly through `paragraphs` too — see `StructureDedup`.
public struct VisionExtractor: Sendable {
    public var automaticallyDetectLanguage: Bool
    public var useLanguageCorrection: Bool

    public init(automaticallyDetectLanguage: Bool = true, useLanguageCorrection: Bool = true) {
        self.automaticallyDetectLanguage = automaticallyDetectLanguage
        self.useLanguageCorrection = useLanguageCorrection
    }

    public func extract(from image: CGImage, pageNumber: Int, pageSize: CGSize) async throws -> PageIR {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = automaticallyDetectLanguage
        request.textRecognitionOptions.useLanguageCorrection = useLanguageCorrection
        let observations = try await request.perform(on: image)
        guard let document = observations.first?.document else {
            return PageIR(pageNumber: pageNumber, pageWidth: Double(pageSize.width), pageHeight: Double(pageSize.height))
        }
        var page = PageIR(pageNumber: pageNumber, pageWidth: Double(pageSize.width), pageHeight: Double(pageSize.height))
        page.blocks = mapDocument(document)
        return page
    }

    func mapDocument(_ document: DocumentObservation.Container) -> [PageBlock] {
        var blocks: [PageBlock] = []
        if let title = document.title, !title.transcript.isEmpty {
            blocks.append(PageBlock(kind: .title(title.transcript), region: flip(title.boundingRegion.boundingBox.cgRect), source: .vision))
        }
        for table in document.tables {
            blocks.append(PageBlock(kind: .table(mapTable(table)), region: flip(table.boundingRegion.boundingBox.cgRect), source: .vision))
        }
        for list in document.lists {
            blocks.append(PageBlock(kind: .list(mapList(list)), region: flip(list.boundingRegion.boundingBox.cgRect), source: .vision))
        }
        for paragraph in document.paragraphs {
            let text = paragraph.transcript
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            blocks.append(PageBlock(kind: .paragraph(text), region: flip(paragraph.boundingRegion.boundingBox.cgRect), source: .vision))
        }
        return blocks
    }

    private func mapTable(_ table: DocumentObservation.Container.Table) -> TableBlock {
        TableBlock(rows: table.rows.map { row in
            row.map { cell in
                TableCell(
                    text: cell.content.text.transcript,
                    rowSpan: cell.rowRange.count,
                    columnSpan: cell.columnRange.count
                )
            }
        })
    }

    private func mapList(_ list: DocumentObservation.Container.List) -> ListBlock {
        let ordered = list.items.contains { item in
            guard let marker = item.markerType else { return false }
            switch marker {
            case .bullet, .hyphen: return false
            case .lowercaseLatin, .uppercaseLatin, .decimal, .decorativeDecimal, .compositeDecimal: return true
            @unknown default: return false
            }
        }
        return ListBlock(
            ordered: ordered,
            items: list.items.map { ListItem(marker: $0.markerString, text: $0.itemString) }
        )
    }

    /// Vision normalized rects use a bottom-left origin; the canonical IR is
    /// top-left. One flip, here, nowhere else.
    private func flip(_ rect: CGRect) -> NormalizedRect {
        NormalizedRect(x: Double(rect.minX), y: Double(1 - rect.maxY), width: Double(rect.width), height: Double(rect.height))
    }
}
