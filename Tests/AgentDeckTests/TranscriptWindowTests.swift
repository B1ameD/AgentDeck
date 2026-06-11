import XCTest
@testable import AgentDeckApp

final class TranscriptWindowTests: XCTestCase {
    func testTailWindowShortTranscriptFullyVisible() {
        let window = TranscriptWindow.tail(totalCount: 5)
        XCTAssertEqual(window, .init(start: 0, end: 5))
        XCTAssertEqual(window.hiddenAbove, 0)
        XCTAssertEqual(window.hiddenBelow(totalCount: 5), 0)
    }

    func testTailWindowLongTranscriptShowsOnlyTail() {
        let window = TranscriptWindow.tail(totalCount: 389)
        XCTAssertEqual(window, .init(start: 309, end: 389), "可见区=最近 \(TranscriptWindow.windowSize) 条")
        XCTAssertEqual(window.hiddenAbove, 309)
    }

    func testSlidUpMovesBothEdgesAndKeepsSize() {
        let slid = TranscriptWindow.slidUp(.init(start: 300, end: 380), totalCount: 389)
        XCTAssertEqual(slid, .init(start: 290, end: 370), "顶部放出一批、底部回收一批,渲染量不变")
    }

    func testSlidUpClampsAtStart() {
        let slid = TranscriptWindow.slidUp(.init(start: 5, end: 85), totalCount: 389)
        XCTAssertEqual(slid, .init(start: 0, end: 80))
        let again = TranscriptWindow.slidUp(slid, totalCount: 389)
        XCTAssertEqual(again, slid, "到顶后不再移动")
    }

    func testSlidDownMirrorsAndClampsAtTotal() {
        let slid = TranscriptWindow.slidDown(.init(start: 100, end: 180), totalCount: 389)
        XCTAssertEqual(slid, .init(start: 110, end: 190), "底部放出、顶部回收")
        let nearEnd = TranscriptWindow.slidDown(.init(start: 305, end: 385), totalCount: 389)
        XCTAssertEqual(nearEnd, .init(start: 309, end: 389), "封顶尾部并保持窗口大小")
    }

    func testAfterCountChangeFollowsTailWhenPinned() {
        // 贴尾(end==旧总数):新消息到来 → 窗口跟随新尾部
        let followed = TranscriptWindow.afterCountChange(.init(start: 20, end: 100), oldCount: 100, newCount: 101)
        XCTAssertEqual(followed, TranscriptWindow.tail(totalCount: 101))
    }

    func testAfterCountChangeStaysPutWhileBrowsingHistory() {
        // 翻历史中(窗口脱尾):新消息落在窗口外,渲染量不变
        let stayed = TranscriptWindow.afterCountChange(.init(start: 10, end: 90), oldCount: 200, newCount: 201)
        XCTAssertEqual(stayed, .init(start: 10, end: 90))
    }

    func testAfterCountChangeResetsOnShrink() {
        // 清空/重建(总数变小) → 重置为尾部
        let reset = TranscriptWindow.afterCountChange(.init(start: 10, end: 90), oldCount: 200, newCount: 0)
        XCTAssertEqual(reset, .init(start: 0, end: 0))
    }

    func testResolvedFallsBackToTailForInvalidWindows() {
        XCTAssertEqual(
            TranscriptWindow.resolved(.init(start: 0, end: 0), totalCount: 200),
            TranscriptWindow.tail(totalCount: 200),
            "未初始化 → 尾部"
        )
        XCTAssertEqual(
            TranscriptWindow.resolved(.init(start: 100, end: 300), totalCount: 200),
            TranscriptWindow.tail(totalCount: 200),
            "越界(切会话残留) → 尾部"
        )
        XCTAssertEqual(
            TranscriptWindow.resolved(.init(start: 10, end: 90), totalCount: 200),
            .init(start: 10, end: 90),
            "合法窗口原样保留"
        )
    }

    func testFullWindowCoversEverything() {
        // 「历史会话全部展开」开关:全量渲染、零隐藏
        let full = TranscriptWindow.full(totalCount: 389)
        XCTAssertEqual(full, .init(start: 0, end: 389))
        XCTAssertEqual(full.hiddenAbove, 0)
        XCTAssertEqual(full.hiddenBelow(totalCount: 389), 0)
        XCTAssertFalse(TranscriptWindow.expandAllDefault, "默认仍走浮动窗口")
    }
}
