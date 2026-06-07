import XCTest
@testable import AgentDeckApp

final class FilePreviewPresentationTests: XCTestCase {
    func testMarkdownUsesRenderedMarkdownPresentation() {
        XCTAssertEqual(FilePreviewPresentation.presentation(for: .markdown), .markdown)
    }

    func testCodeCarriesDetectedLanguage() {
        XCTAssertEqual(
            FilePreviewPresentation.presentation(for: .code(language: "swift")),
            .code(language: "swift")
        )
    }

    func testPlainTextUsesTextPresentation() {
        XCTAssertEqual(FilePreviewPresentation.presentation(for: .plainText), .plainText)
    }

    func testUnsupportedUsesErrorPresentation() {
        XCTAssertEqual(FilePreviewPresentation.presentation(for: .unsupported), .unsupported)
    }
}
