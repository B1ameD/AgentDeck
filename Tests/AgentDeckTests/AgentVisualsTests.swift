import XCTest
@testable import AgentDeckApp

@MainActor
final class AgentVisualsTests: XCTestCase {
    func testBundledBrandIconsLoadForKnownAgents() {
        // 随包内置的官方图标应能从资源包加载（claude/codex/opencode）。
        XCTAssertNotNil(AgentVisuals.iconImage(for: .claudeCode), "缺少 claude 图标资源")
        XCTAssertNotNil(AgentVisuals.iconImage(for: .codex), "缺少 codex 图标资源")
        XCTAssertNotNil(AgentVisuals.iconImage(for: .openCode), "缺少 opencode 图标资源")
    }

    func testPiAndCustomHaveNoBrandIconAndFallBackToSymbol() {
        XCTAssertNil(AgentVisuals.iconImage(for: .pi))
        XCTAssertNil(AgentVisuals.iconImage(for: .custom))
        XCTAssertEqual(AgentVisuals.icon(for: .pi), "function")
        XCTAssertEqual(AgentVisuals.icon(for: .custom), "terminal")
    }
}
