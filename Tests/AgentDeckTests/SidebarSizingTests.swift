import XCTest
@testable import AgentDeckApp

final class SidebarSizingTests: XCTestCase {
    func testMaxSidebarReservesChatWidthOrFallsBackToMin() {
        XCTAssertEqual(SidebarSizing.maxSidebarWidth(for: 1_000), 648) // 1000 - 352
        XCTAssertEqual(SidebarSizing.maxSidebarWidth(for: 400), 320)   // 太窄 → 至少 minWidth
    }

    func testWidthFromRatioDefaultsAndClamps() {
        // 比例 0（未保存）→ 默认 600（1200 容器里 chat 仍够，不被夹）。
        XCTAssertEqual(SidebarSizing.width(forRatio: 0, container: 1_200), 600)
        // 0.5 * 1000 = 500，落在 [320, 648] → 500。
        XCTAssertEqual(SidebarSizing.width(forRatio: 0.5, container: 1_000), 500)
        // 过宽 0.9*1000=900 → 夹到 648（给 chat 留 352）。
        XCTAssertEqual(SidebarSizing.width(forRatio: 0.9, container: 1_000), 648)
        // 过窄 0.1*1000=100 → 夹到 320。
        XCTAssertEqual(SidebarSizing.width(forRatio: 0.1, container: 1_000), 320)
    }

    func testRatioRoundTripsAndGuardsZeroContainer() {
        XCTAssertEqual(SidebarSizing.ratio(forWidth: 500, container: 1_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(SidebarSizing.ratio(forWidth: 600, container: 0), 0) // 容器未知
    }

    func testCloseWhileDraggingBelowMin() {
        XCTAssertTrue(SidebarSizing.shouldCloseWhileDragging(rawWidth: 280))
        XCTAssertFalse(SidebarSizing.shouldCloseWhileDragging(rawWidth: 320))
        XCTAssertFalse(SidebarSizing.shouldCloseWhileDragging(rawWidth: 500))
    }
}
