import AppKit
import XCTest
@testable import AgentDeckApp

final class BundledCodeFontTests: XCTestCase {
    func testRegistersAllBundledCodeFonts() {
        BundledFontRegistrar.register()

        for font in BundledCodeFont.allCases {
            XCTAssertNotNil(
                NSFont(name: font.postScriptName, size: 13),
                "\(font.displayName) should be registered as \(font.postScriptName)"
            )
        }
    }
}
