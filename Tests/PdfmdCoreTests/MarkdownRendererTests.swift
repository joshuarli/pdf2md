import Testing
@testable import PdfmdCore

@Test func collapsesHardWraps() {
    #expect(collapseHardWraps("first\nsecond") == "first second")
    #expect(collapseHardWraps("para one\n\npara two") == "para one para two")
}

@Test func joinsHyphenationConfidently() {
    #expect(collapseHardWraps("exam-\nple") == "example")
    // Ambiguous hard-hyphen case joins too (documented limitation in
    // repairHyphenation); caps, digits, and compounds with spaces never join.
    #expect(collapseHardWraps("well-\nknown") == "wellknown")
    #expect(collapseHardWraps("US-\nbased") == "US- based")
    #expect(collapseHardWraps("3-\n4") == "3- 4")
}

@Test func joinsCJKWithoutSpaces() {
    #expect(collapseHardWraps("日本語\nテスト") == "日本語テスト")
    #expect(collapseHardWraps("hello\nworld") == "hello world")
}

@Test func normalizesBulletsAndStripsDuplication() {
    let list = ListBlock(ordered: false, items: [
        ListItem(marker: "•", text: "• apples"),
        ListItem(marker: "-", text: "oranges"),
    ])
    #expect(renderList(list) == "- apples\n- oranges")
}

@Test func keepsOrderedNumbering() {
    let list = ListBlock(ordered: true, items: [
        ListItem(marker: "1.", text: "1) first"),
        ListItem(marker: "2.", text: "second"),
    ])
    #expect(renderList(list) == "1. first\n2. second")
}

@Test func rendersSimpleTable() {
    let table = TableBlock(rows: [
        [TableCell(text: "a"), TableCell(text: "b")],
        [TableCell(text: "c|d"), TableCell(text: "")],
    ])
    #expect(renderTable(table) == "| a | b |\n| --- | --- |\n| c\\|d |  |")
}

@Test func multilineCellsUseBreaks() {
    let table = TableBlock(rows: [[TableCell(text: "line1\nline2")]])
    #expect(renderTable(table) == "| line1<br>line2 |\n| --- |")
}

@Test func rendersTitleAndHeadings() {
    #expect(renderBlock(.title("Doc")) == "# Doc")
    #expect(renderBlock(.heading(level: 2, text: "Sec")) == "## Sec")
}
