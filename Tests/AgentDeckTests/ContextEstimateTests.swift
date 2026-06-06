import XCTest
@testable import AgentDeckApp

final class ContextEstimateTests: XCTestCase {
    func testEstimatedTokensFromBytes() {
        XCTAssertEqual(ContextEstimate.estimatedTokens(""), 0)
        XCTAssertEqual(ContextEstimate.estimatedTokens("abcd"), 1)        // 4 bytes / 4
        XCTAssertEqual(ContextEstimate.estimatedTokens("a"), 1)           // 非空至少 1
        XCTAssertEqual(ContextEstimate.estimatedTokens("你好"), 1)        // 6 字节 / 4 = 1
    }

    func testSumsAcrossTexts() {
        XCTAssertEqual(ContextEstimate.estimatedTokens(forTexts: ["abcd", "abcd", ""]), 2)
    }

    func testUsageFractionClampedToZeroOne() {
        XCTAssertEqual(ContextEstimate.usageFraction(tokens: 100_000, window: 200_000), 0.5, accuracy: 0.001)
        XCTAssertEqual(ContextEstimate.usageFraction(tokens: 999_999, window: 200_000), 1.0)
        XCTAssertEqual(ContextEstimate.usageFraction(tokens: 10, window: 0), 0)
    }

    func testCompactFormatting() {
        XCTAssertEqual(ContextEstimate.compact(950), "950")
        XCTAssertEqual(ContextEstimate.compact(1234), "1.2k")
        XCTAssertEqual(ContextEstimate.compact(200_000), "200.0k")
    }
}
