/// Minimal CLI parsing. The interface is small enough to parse directly;
/// swift-argument-parser is an explicit non-goal (plan.md section 14).

public let pdfmdVersion = "0.1.0"

public let usageText = """
    pdfmd — extract a PDF into clean Markdown, fully on-device

    Usage:

      pdfmd INPUT.pdf
      pdfmd INPUT.pdf -o OUTPUT.md
      pdfmd INPUT.pdf --pages 1,3-7,12
      pdfmd INPUT.pdf --debug-dir DIR

      pdfmd --help
      pdfmd --version

    Defaults: the whole document; Markdown to stdout when -o is omitted
    (diagnostics go to stderr); 1-based page numbers.
    """

public struct CliOptions: Sendable, Equatable {
    public var input: String
    public var output: String?
    public var pages: [Int]?
    public var debugDir: String?

    public init(input: String, output: String? = nil, pages: [Int]? = nil, debugDir: String? = nil) {
        self.input = input
        self.output = output
        self.pages = pages
        self.debugDir = debugDir
    }
}

public enum CliAction: Sendable, Equatable {
    case run(CliOptions)
    case help
    case version
}

public struct CliError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public func parseArguments(_ args: [String]) throws -> CliAction {
    var input: String?
    var output: String?
    var pagesSpec: String?
    var debugDir: String?

    var i = args.startIndex
    while i < args.endIndex {
        let arg = args[i]
        switch arg {
        case "-h", "--help", "help":
            return .help
        case "--version", "-V":
            return .version
        case "-o", "--output":
            i = args.index(after: i)
            guard i < args.endIndex else { throw CliError("pdfmd: \(arg) requires a value") }
            guard output == nil else { throw CliError("pdfmd: \(arg) given twice") }
            output = args[i]
        case "--pages":
            i = args.index(after: i)
            guard i < args.endIndex else { throw CliError("pdfmd: --pages requires a value") }
            guard pagesSpec == nil else { throw CliError("pdfmd: --pages given twice") }
            pagesSpec = args[i]
        case "--debug-dir":
            i = args.index(after: i)
            guard i < args.endIndex else { throw CliError("pdfmd: --debug-dir requires a value") }
            guard debugDir == nil else { throw CliError("pdfmd: --debug-dir given twice") }
            debugDir = args[i]
        default:
            if arg.hasPrefix("-") {
                throw CliError("pdfmd: unknown flag: \(arg)\nTry `pdfmd --help`.")
            }
            guard input == nil else { throw CliError("pdfmd: unexpected argument: \(arg)") }
            input = arg
        }
        i = args.index(after: i)
    }

    guard let input else { throw CliError("pdfmd: missing input PDF\nTry `pdfmd --help`.") }
    let pages = try pagesSpec.map { try parsePageSpec($0) }
    return .run(CliOptions(input: input, output: output, pages: pages, debugDir: debugDir))
}

/// Parse a page specification like `1,3-7,12` into sorted, deduplicated
/// 1-based page numbers. Upper bounds are validated later against the actual
/// document; here only shape is checked (positive integers, lo <= hi).
public func parsePageSpec(_ spec: String) throws -> [Int] {
    var result = Set<Int>()
    let tokens = spec.split(separator: ",", omittingEmptySubsequences: false)
    guard !tokens.isEmpty else { throw CliError("pdfmd: empty --pages specification") }
    for raw in tokens {
        let token = raw.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { throw CliError("pdfmd: empty entry in --pages specification") }
        if let dash = token.firstIndex(of: "-") {
            let loText = String(token[..<dash]).trimmingCharacters(in: .whitespaces)
            let hiText = String(token[token.index(after: dash)...]).trimmingCharacters(in: .whitespaces)
            guard let lo = Int(loText), let hi = Int(hiText), lo >= 1, hi >= 1 else {
                throw CliError("pdfmd: invalid page range: \(token)")
            }
            guard lo <= hi else { throw CliError("pdfmd: reversed page range: \(token)") }
            for page in lo...hi { result.insert(page) }
        } else {
            guard let page = Int(token), page >= 1 else {
                throw CliError("pdfmd: invalid page number: \(token)")
            }
            result.insert(page)
        }
    }
    return result.sorted()
}
