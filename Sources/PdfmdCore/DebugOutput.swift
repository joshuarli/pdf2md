import Foundation

/// Debug artifacts (`--debug-dir DIR`, plan.md section 32). Codable snapshots
/// per page plus a document manifest. The production path never depends on
/// these types. Raster images are not saved: no demonstrated need, and a
/// large PDF would explode into hundreds of giant files.
public struct PageDebug: Codable {
    public var pageNumber: Int
    public var nativeTextQuality: String
    public var nativeCharacters: Int
    public var blocks: [BlockDebug]
    public var deterministicMarkdown: String
    public var repairedMarkdown: String?
    public var repairAccepted: Bool?
    public var repairReason: String?

    public init(
        pageNumber: Int,
        nativeTextQuality: String,
        nativeCharacters: Int,
        blocks: [BlockDebug],
        deterministicMarkdown: String,
        repairedMarkdown: String? = nil,
        repairAccepted: Bool? = nil,
        repairReason: String? = nil
    ) {
        self.pageNumber = pageNumber
        self.nativeTextQuality = nativeTextQuality
        self.nativeCharacters = nativeCharacters
        self.blocks = blocks
        self.deterministicMarkdown = deterministicMarkdown
        self.repairedMarkdown = repairedMarkdown
        self.repairAccepted = repairAccepted
        self.repairReason = repairReason
    }
}

public struct BlockDebug: Codable {
    public var kind: String
    public var source: String
    public var text: String
    public var region: [Double]

    public init(kind: String, source: String, text: String, region: [Double]) {
        self.kind = kind
        self.source = source
        self.text = text
        self.region = region
    }
}

public func debugBlock(_ block: PageBlock) -> BlockDebug {
    let kind: String
    switch block.kind {
    case .title: kind = "title"
    case .heading(let level, _): kind = "heading-\(level)"
    case .paragraph: kind = "paragraph"
    case .list: kind = "list"
    case .table: kind = "table"
    }
    let r = block.region
    return BlockDebug(
        kind: kind, source: block.source.rawValue,
        text: String(block.kind.plainText.prefix(2000)),
        region: [r.x, r.y, r.width, r.height]
    )
}

public func writeDebugPages(_ pages: [PageDebug], manifest: [String: String], to directory: URL) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for page in pages {
        let padded = String(repeating: "0", count: max(0, 4 - String(page.pageNumber).count)) + String(page.pageNumber)
        try encoder.encode(page).write(to: directory.appendingPathComponent("page-\(padded).json"))
    }
    try encoder.encode(manifest).write(to: directory.appendingPathComponent("document.json"))
}
