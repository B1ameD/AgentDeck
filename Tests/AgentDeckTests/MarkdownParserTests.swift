import XCTest
@testable import AgentDeckApp

final class MarkdownParserTests: XCTestCase {
    func testSplitsTextAndFencedCodeWithLanguage() {
        let md = """
        Here is code:
        ```swift
        let x = 1
        print(x)
        ```
        Done.
        """
        XCTAssertEqual(MarkdownParser.segments(md), [
            .text("Here is code:"),
            .code(language: "swift", content: "let x = 1\nprint(x)"),
            .text("Done.")
        ])
    }

    func testPlainTextIsOneSegment() {
        XCTAssertEqual(MarkdownParser.segments("just a paragraph"), [.text("just a paragraph")])
    }

    func testFenceWithoutLanguage() {
        XCTAssertEqual(
            MarkdownParser.segments("```\nraw\n```"),
            [.code(language: nil, content: "raw")]
        )
    }

    func testUnterminatedFenceIsTreatedAsCode() {
        XCTAssertEqual(
            MarkdownParser.segments("```py\nx = 1"),
            [.code(language: "py", content: "x = 1")]
        )
    }

    func testWhitespaceOnlyTextSegmentsAreDropped() {
        // 代码块前后的空文本不产生空段。
        XCTAssertEqual(
            MarkdownParser.segments("```\ncode\n```\n\n"),
            [.code(language: nil, content: "code")]
        )
    }
}
