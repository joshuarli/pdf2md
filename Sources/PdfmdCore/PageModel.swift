/// Canonical per-page intermediate representation.
///
/// Every stage speaks `PageIR`: small `Sendable` value types carrying block
/// kind, text or structure, normalized region, and source evidence. Tables
/// stay structured until the renderer; nothing passes loose strings.
public struct PageIR: Sendable {
    /// 1-based page number as presented to users.
    public var pageNumber: Int
    public var pageWidth: Double
    public var pageHeight: Double
    public var nativeTextQuality: NativeTextQuality
    public var blocks: [PageBlock]
    public var complexity: ComplexitySignals

    public init(
        pageNumber: Int,
        pageWidth: Double,
        pageHeight: Double,
        nativeTextQuality: NativeTextQuality = .empty,
        blocks: [PageBlock] = [],
        complexity: ComplexitySignals = ComplexitySignals()
    ) {
        self.pageNumber = pageNumber
        self.pageWidth = pageWidth
        self.pageHeight = pageHeight
        self.nativeTextQuality = nativeTextQuality
        self.blocks = blocks
        self.complexity = complexity
    }
}

public enum NativeTextQuality: String, Sendable, Codable {
    case trustworthy
    case empty
    case broken
}

public enum BlockSource: String, Sendable, Codable {
    case native
    case vision
    case reconciled
}

public struct PageBlock: Sendable {
    public var kind: BlockKind
    public var region: NormalizedRect
    public var source: BlockSource

    public init(kind: BlockKind, region: NormalizedRect, source: BlockSource) {
        self.kind = kind
        self.region = region
        self.source = source
    }
}

public enum BlockKind: Sendable {
    case title(String)
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ListBlock)
    case table(TableBlock)
}

public struct ListBlock: Sendable {
    public var ordered: Bool
    public var items: [ListItem]

    public init(ordered: Bool, items: [ListItem]) {
        self.ordered = ordered
        self.items = items
    }
}

public struct ListItem: Sendable {
    /// Original marker text (e.g. "•", "1."), retained for debugging; the
    /// renderer normalizes markers.
    public var marker: String
    public var text: String

    public init(marker: String, text: String) {
        self.marker = marker
        self.text = text
    }
}

public struct TableBlock: Sendable {
    public var rows: [[TableCell]]

    public init(rows: [[TableCell]]) {
        self.rows = rows
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// True when any cell spans multiple rows/columns. Markdown pipe tables
    /// cannot represent spans, so these pages are flagged for repair while
    /// the renderer degrades to content-preserving output.
    public var hasSpans: Bool {
        rows.flatMap { $0 }.contains { $0.rowSpan > 1 || $0.columnSpan > 1 }
    }
}

public struct TableCell: Sendable {
    public var text: String
    public var rowSpan: Int
    public var columnSpan: Int

    public init(text: String, rowSpan: Int = 1, columnSpan: Int = 1) {
        self.text = text
        self.rowSpan = rowSpan
        self.columnSpan = columnSpan
    }
}

/// Named complexity signals (plan.md section 26). A handful of explicit flags
/// rather than a weighted heuristic, so routing stays auditable. Set during
/// extraction/reconciliation; read by `ComplexityRouter`.
public struct ComplexitySignals: Sendable, Codable {
    public var multiColumn: Bool = false
    public var mergedCells: Bool = false
    public var nativeVisionDisagreement: Bool = false
    public var fragmentedOCR: Bool = false
    public var denseOverlap: Bool = false
    public var uncertainHeadings: Bool = false

    public init() {}

    public var isEmpty: Bool {
        !multiColumn && !mergedCells && !nativeVisionDisagreement
            && !fragmentedOCR && !denseOverlap && !uncertainHeadings
    }
}

extension BlockKind {
    /// Plain-text projection used for fidelity checks, furniture detection,
    /// and scoring. Never rendered directly.
    public var plainText: String {
        switch self {
        case .title(let text), .paragraph(let text):
            return text
        case .heading(_, let text):
            return text
        case .list(let list):
            return list.items.map(\.text).joined(separator: " ")
        case .table(let table):
            return table.rows.flatMap { $0 }.map(\.text).joined(separator: " ")
        }
    }
}

extension PageIR {
    /// Plain-text projection of the page in block order.
    public var plainText: String {
        blocks.map(\.kind.plainText).joined(separator: "\n")
    }
}
