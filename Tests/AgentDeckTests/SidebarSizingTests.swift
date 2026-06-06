import XCTest
@testable import AgentDeckApp

final class SidebarSizingTests: XCTestCase {
    func testWindowGrowthExpandsSidebarFirst() {
        XCTAssertEqual(
            SidebarSizing.widthAfterWindowResize(
                currentWidth: 380,
                oldContainerWidth: 1_000,
                newContainerWidth: 1_180
            ),
            560
        )
    }

    func testSidebarGrowthKeepsMinimumChatWidth() {
        XCTAssertEqual(
            SidebarSizing.widthAfterWindowResize(
                currentWidth: 700,
                oldContainerWidth: 1_000,
                newContainerWidth: 1_300
            ),
            880
        )
    }

    func testWindowShrinkClampsSidebarToAvailableWidth() {
        XCTAssertEqual(
            SidebarSizing.widthAfterWindowResize(
                currentWidth: 880,
                oldContainerWidth: 1_300,
                newContainerWidth: 900
            ),
            480
        )
    }
}
