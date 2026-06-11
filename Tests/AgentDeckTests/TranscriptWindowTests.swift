import XCTest
@testable import AgentDeckApp

final class TranscriptWindowTests: XCTestCase {
    func testShortTranscriptFullyVisible() {
        let (hidden, start) = TranscriptWindow.slice(totalCount: 5, limit: 40)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(start, 0)
    }

    func testLongTranscriptShowsOnlyTail() {
        let (hidden, start) = TranscriptWindow.slice(totalCount: 389, limit: 40)
        XCTAssertEqual(hidden, 349)
        XCTAssertEqual(start, 349, "可见区=最近 40 条")
    }

    func testNewMessagesStayInsideWindow() {
        // 流式追加:总数增长,窗口仍取尾部 → 新消息始终可见
        let before = TranscriptWindow.slice(totalCount: 100, limit: 40)
        let after = TranscriptWindow.slice(totalCount: 101, limit: 40)
        XCTAssertEqual(after.hiddenCount, before.hiddenCount + 1)
    }

    func testScrollExpandReleasesOneBatchAndCapsAtTotal() {
        XCTAssertEqual(TranscriptWindow.scrollExpandedLimit(current: 40, totalCount: 389), 50)
        XCTAssertEqual(TranscriptWindow.scrollExpandedLimit(current: 385, totalCount: 389), 389, "封顶全量")
        let (hidden, _) = TranscriptWindow.slice(totalCount: 389, limit: 389)
        XCTAssertEqual(hidden, 0)
    }

    func testExpandAllLimitShowsEverythingWithoutOverflow() {
        // 「历史会话全部展开」开关用 Int.max 旁路窗口:不溢出、零隐藏、从头渲染
        let (hidden, start) = TranscriptWindow.slice(totalCount: 389, limit: Int.max)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(start, 0)
        XCTAssertFalse(TranscriptWindow.expandAllDefault, "默认仍走尾部窗口")
    }

    func testDegenerateLimits() {
        XCTAssertEqual(TranscriptWindow.slice(totalCount: 10, limit: 0).hiddenCount, 9, "limit 夹紧到 ≥1")
        XCTAssertEqual(TranscriptWindow.slice(totalCount: 0, limit: 40).hiddenCount, 0)
        XCTAssertEqual(TranscriptWindow.scrollExpandedLimit(current: 0, totalCount: 5), 5)
    }
}
