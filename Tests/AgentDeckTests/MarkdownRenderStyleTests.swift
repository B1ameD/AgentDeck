import AppKit
import XCTest
@testable import AgentDeckApp

final class MarkdownRenderStyleTests: XCTestCase {
    func testCodeBlockLanguageDisplayNamesAreNormalized() {
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("swift"), "Swift")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("py"), "Python")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("js"), "JavaScript")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("ts"), "TypeScript")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("bash"), "Shell")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("objc"), "Objective-C")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage("  Rust  "), "Rust")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage(nil), "Code")
        XCTAssertEqual(MarkdownCodeBlockPresentation.displayLanguage(""), "Code")
    }

    func testCodeBlockWidthAndHeaderSizingMatchDesign() {
        XCTAssertEqual(MarkdownCodeBlockPresentation.widthFraction, 0.8, accuracy: 0.001)
        XCTAssertEqual(MarkdownCodeBlockPresentation.headerFontSize(baseCodeSize: 14), 15)
        XCTAssertEqual(MarkdownCodeBlockPresentation.headerFontSize(baseCodeSize: 20), 21)
    }
}
