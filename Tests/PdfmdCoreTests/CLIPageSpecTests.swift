import Testing
@testable import PdfmdCore

@Test func parsesSinglePagesAndRanges() throws {
    #expect(try parsePageSpec("1") == [1])
    #expect(try parsePageSpec("1,3-7,12") == [1, 3, 4, 5, 6, 7, 12])
}

@Test func deduplicatesAndSorts() throws {
    #expect(try parsePageSpec("5,1,3-4,3") == [1, 3, 4, 5])
}

@Test func rejectsBadSpecs() {
    for spec in ["", "0", "-3", "5-2", "a", "1,,2", "1-", "1.5"] {
        #expect(throws: CliError.self) { try parsePageSpec(spec) }
    }
}

@Test func parsesFullCLI() throws {
    let action = try parseArguments(["in.pdf", "-o", "out.md", "--pages", "1,2", "--debug-dir", "dbg"])
    #expect(action == .run(CliOptions(input: "in.pdf", output: "out.md", pages: [1, 2], debugDir: "dbg")))
}

@Test func helpAndVersion() throws {
    #expect(try parseArguments(["--help"]) == .help)
    #expect(try parseArguments(["--version"]) == .version)
    #expect(throws: CliError.self) { try parseArguments([]) }
}

@Test func missingInputFails() {
    #expect(throws: CliError.self) { try parseArguments(["-o", "out.md"]) }
    #expect(throws: CliError.self) { try parseArguments(["a.pdf", "b.pdf"]) }
    #expect(throws: CliError.self) { try parseArguments(["a.pdf", "--bogus"]) }
}
