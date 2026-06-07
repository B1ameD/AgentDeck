import XCTest
@testable import AgentDeckApp

final class RightSidebarNavigationTests: XCTestCase {
    func testOpeningFileSelectsPreviewTab() {
        XCTAssertEqual(RightSidebarNavigation.destinationForOpenedFile, .preview)
    }

    func testTabOrderPlacesPreviewBesideFiles() {
        // 分段选择器的常驻标签顺序（子任务是上下文进入，不在其中）。
        XCTAssertEqual(RightSidebarMode.primaryCases, [.files, .preview, .browser, .review])
    }

    func testSubagentIsContextualNotInPrimaryTabs() {
        XCTAssertFalse(RightSidebarMode.primaryCases.contains(.subagent))
        XCTAssertTrue(RightSidebarMode.allCases.contains(.subagent))
    }
}
