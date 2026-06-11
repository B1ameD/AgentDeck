import XCTest
@testable import AgentDeckApp

final class TranscriptWindowTests: XCTestCase {
    // 50 行 × 高 100、行距 10:总高 = 50×100 + 49×10 = 5490
    private let uniform = [CGFloat](repeating: 100, count: 50)

    func testVirtualLayoutPicksRowsAroundViewport() {
        // 视口 [2000, 2500),margin 900 → 渲染窗 [1100, 3400)
        let layout = TranscriptWindow.virtualLayout(rowHeights: uniform, offset: 2000, viewportHeight: 500)
        XCTAssertEqual(layout.range, 10..<31, "行 i 起点 i×110:首个尾端>1100 的是 10,最后起点<3400 的是 30")
        XCTAssertEqual(layout.topInset, 10 * 100 + 9 * 10, "顶替 rows[0..<10] 含内部行距")
        XCTAssertEqual(layout.bottomInset, 19 * 100 + 18 * 10, "顶替 rows[31...] 含内部行距")
    }

    func testVirtualLayoutHeightInvariant() {
        // 占位 + 真身 + VStack 行距还原出完整内容高度(滚动条对应完整历史的关键)
        let layout = TranscriptWindow.virtualLayout(rowHeights: uniform, offset: 2000, viewportHeight: 500)
        let renderedHeights = uniform[layout.range].reduce(0, +)
        let gapCount = CGFloat(layout.range.count - 1) // 真身行之间
            + (layout.topInset > 0 ? 1 : 0)            // 顶占位—首行
            + (layout.bottomInset > 0 ? 1 : 0)         // 末行—底占位
        let total = layout.topInset + layout.bottomInset + renderedHeights + gapCount * TranscriptWindow.rowSpacing
        XCTAssertEqual(total, 50 * 100 + 49 * 10)
    }

    func testVirtualLayoutAtTopAndBottomEdges() {
        let top = TranscriptWindow.virtualLayout(rowHeights: uniform, offset: 0, viewportHeight: 500)
        XCTAssertEqual(top.range.lowerBound, 0)
        XCTAssertEqual(top.topInset, 0)
        XCTAssertGreaterThan(top.bottomInset, 0)

        let bottom = TranscriptWindow.virtualLayout(rowHeights: uniform, offset: 5490 - 500, viewportHeight: 500)
        XCTAssertEqual(bottom.range.upperBound, 50)
        XCTAssertEqual(bottom.bottomInset, 0)
        XCTAssertGreaterThan(bottom.topInset, 0)
    }

    func testVirtualLayoutSmallListFullyRendered() {
        // margin 900 远大于内容 → 全量真身、零占位
        let heights: [CGFloat] = [50, 80, 120]
        let layout = TranscriptWindow.virtualLayout(rowHeights: heights, offset: 0, viewportHeight: 400)
        XCTAssertEqual(layout.range, 0..<3)
        XCTAssertEqual(layout.topInset, 0)
        XCTAssertEqual(layout.bottomInset, 0)
    }

    func testVirtualLayoutDegenerateInputs() {
        let empty = TranscriptWindow.virtualLayout(rowHeights: [], offset: 0, viewportHeight: 500)
        XCTAssertEqual(empty.range, 0..<0)

        // 瞬态过滚(offset 超出内容):兜底渲染末行,不崩、不空区间
        let overscrolled = TranscriptWindow.virtualLayout(rowHeights: uniform, offset: 99999, viewportHeight: 500)
        XCTAssertFalse(overscrolled.range.isEmpty)
        XCTAssertEqual(overscrolled.range.upperBound, 50)
    }

    func testEstimatedRowHeightScalesWithText() {
        let oneLine = TranscriptWindow.estimatedRowHeight(characterCount: 10, newlineCount: 0)
        XCTAssertEqual(oneLine, 21 + 24, "单行 = 行高 + 气泡 padding")
        let multiLine = TranscriptWindow.estimatedRowHeight(characterCount: 10, newlineCount: 4)
        XCTAssertEqual(multiLine, 5 * 21 + 24, "换行符决定行数")
        let wrapped = TranscriptWindow.estimatedRowHeight(characterCount: 400, newlineCount: 0)
        XCTAssertEqual(wrapped, 5 * 21 + 24, "无换行时按 ~80 字/行折行")
        let huge = TranscriptWindow.estimatedRowHeight(characterCount: 1_000_000, newlineCount: 9999)
        XCTAssertEqual(huge, 60 * 21 + 24, "封顶 60 行")
    }

    func testTailLayoutCoversViewportPlusMarginFromEnd() {
        // 视口 500 + margin 900 = 需盖 1400;每行占 110 → 13 行 → lo = 37
        let (layout, bottomOffset) = TranscriptWindow.tailLayout(rowHeights: uniform, viewportHeight: 500)
        XCTAssertEqual(layout.range, 37..<50)
        XCTAssertEqual(layout.topInset, 37 * 100 + 36 * 10)
        XCTAssertEqual(layout.bottomInset, 0, "尾部布局必然贴到末行")
        XCTAssertEqual(bottomOffset, 5490 - 500, "贴底偏移 = 内容总高 − 视口")
    }

    func testTailLayoutShortTranscript() {
        let (layout, bottomOffset) = TranscriptWindow.tailLayout(rowHeights: [50, 80], viewportHeight: 500)
        XCTAssertEqual(layout.range, 0..<2, "盖不满视口时全量")
        XCTAssertEqual(layout.topInset, 0)
        XCTAssertEqual(bottomOffset, 0, "内容比视口矮时无偏移")
        let (empty, offset) = TranscriptWindow.tailLayout(rowHeights: [], viewportHeight: 500)
        XCTAssertEqual(empty.range, 0..<0)
        XCTAssertEqual(offset, 0)
    }

    func testExpandAllDefaultsOff() {
        XCTAssertFalse(TranscriptWindow.expandAllDefault, "默认走占位虚拟化")
    }
}
