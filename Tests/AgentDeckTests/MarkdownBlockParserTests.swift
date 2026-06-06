import XCTest
@testable import AgentDeckApp

final class MarkdownBlockParserTests: XCTestCase {
    func testHeadingLevels() {
        XCTAssertEqual(MarkdownBlockParser.blocks("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownBlockParser.blocks("### Deep"), [.heading(level: 3, text: "Deep")])
    }

    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(MarkdownBlockParser.blocks("#nothashtag"), [.paragraph("#nothashtag")])
    }

    func testUnorderedListItems() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks("- one\n- two"),
            [.listItem(ordered: false, marker: "•", depth: 0, text: "one"),
             .listItem(ordered: false, marker: "•", depth: 0, text: "two")]
        )
    }

    func testNestedListDepthFromLeadingSpaces() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks("- top\n  - child"),
            [.listItem(ordered: false, marker: "•", depth: 0, text: "top"),
             .listItem(ordered: false, marker: "•", depth: 1, text: "child")]
        )
    }

    func testOrderedListKeepsNumber() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks("1. first\n2. second"),
            [.listItem(ordered: true, marker: "1.", depth: 0, text: "first"),
             .listItem(ordered: true, marker: "2.", depth: 0, text: "second")]
        )
    }

    func testBlockquoteMergesConsecutiveLines() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks("> a\n> b"),
            [.quote("a\nb")]
        )
    }

    func testHorizontalRule() {
        XCTAssertEqual(MarkdownBlockParser.blocks("---"), [.rule])
        XCTAssertEqual(MarkdownBlockParser.blocks("***"), [.rule])
    }

    func testParagraphsSeparatedByBlankLine() {
        XCTAssertEqual(
            MarkdownBlockParser.blocks("para one\n\npara two"),
            [.paragraph("para one"), .paragraph("para two")]
        )
    }

    func testMixedDocument() {
        let md = """
        # Heading
        intro line
        - bullet
        > quote
        """
        XCTAssertEqual(MarkdownBlockParser.blocks(md), [
            .heading(level: 1, text: "Heading"),
            .paragraph("intro line"),
            .listItem(ordered: false, marker: "•", depth: 0, text: "bullet"),
            .quote("quote")
        ])
    }

    func testTableParsing() {
        let md = """
        | Name | Age |
        | --- | --- |
        | Alice | 30 |
        | Bob | 25 |
        """
        XCTAssertEqual(MarkdownBlockParser.blocks(md), [
            .table(header: ["Name", "Age"], rows: [["Alice", "30"], ["Bob", "25"]])
        ])
    }

    func testTableWithoutOuterPipes() {
        let md = """
        Name | Age
        --- | ---
        Alice | 30
        """
        XCTAssertEqual(MarkdownBlockParser.blocks(md), [
            .table(header: ["Name", "Age"], rows: [["Alice", "30"]])
        ])
    }

    func testDashRuleNotMistakenForTable() {
        XCTAssertEqual(MarkdownBlockParser.blocks("---"), [.rule])
    }
}
