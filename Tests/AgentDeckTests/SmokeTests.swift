import XCTest
@testable import AgentDeckApp

final class SmokeTests: XCTestCase {
    func testPackageLoads() {
        XCTAssertEqual("AgentDeck", "AgentDeck")
    }
}
