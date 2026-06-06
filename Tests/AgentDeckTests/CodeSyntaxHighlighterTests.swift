import AppKit
import XCTest
@testable import AgentDeckApp

final class CodeSyntaxHighlighterTests: XCTestCase {
    private let palette = CodeSyntaxPalette(
        keyword: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
        type: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
        string: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
        number: NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1),
        comment: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    )

    private func spans(_ code: String, language: String?) -> [(text: String, color: NSColor)] {
        let ns = code as NSString
        return CodeSyntaxHighlighter.highlights(code: code, language: language, palette: palette)
            .map { (ns.substring(with: $0.range), $0.color) }
    }

    func testSwiftKeywordsNumbersAndComments() {
        let result = spans("let n = 42 // note", language: "swift")
        XCTAssertTrue(result.contains { $0.text == "let" && $0.color == palette.keyword })
        XCTAssertTrue(result.contains { $0.text == "42" && $0.color == palette.number })
        XCTAssertTrue(result.contains { $0.text == "// note" && $0.color == palette.comment })
    }

    func testStringSwallowsKeywordsInside() {
        let result = spans("let s = \"let x\"", language: "swift")
        XCTAssertTrue(result.contains { $0.text == "\"let x\"" && $0.color == palette.string })
        // 字符串里的 let 不应再单独被标成关键字（只有最外层那个 let 是关键字）。
        XCTAssertEqual(result.filter { $0.text == "let" }.count, 1)
    }

    func testPythonUsesHashLineComment() {
        let result = spans("x = 1  # 注释", language: "python")
        XCTAssertTrue(result.contains { $0.text == "# 注释" && $0.color == palette.comment })
    }

    func testUppercaseIdentifierTreatedAsTypeButLowercaseUntouched() {
        let result = spans("let v: Foo = bar", language: "swift")
        XCTAssertTrue(result.contains { $0.text == "Foo" && $0.color == palette.type })
        XCTAssertFalse(result.contains { $0.text == "bar" }) // 普通小写标识符不染色
    }

    func testUnterminatedStringStopsAtLineEnd() {
        // 未闭合引号不应把后续整段染成字符串。
        let result = spans("a = \"oops\nb = 2", language: "swift")
        XCTAssertTrue(result.contains { $0.text == "\"oops" && $0.color == palette.string })
        XCTAssertTrue(result.contains { $0.text == "2" && $0.color == palette.number })
    }

    func testShellHashCommentAndNoTypeHighlighting() {
        let result = spans("echo Hi # done", language: "bash")
        XCTAssertTrue(result.contains { $0.text == "echo" && $0.color == palette.keyword })
        XCTAssertTrue(result.contains { $0.text == "# done" && $0.color == palette.comment })
        XCTAssertFalse(result.contains { $0.text == "Hi" }) // shell 不做「大写＝类型」高亮
    }
}
