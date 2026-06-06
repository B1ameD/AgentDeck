import XCTest
@testable import AgentDeckApp

final class RecentModelsTests: XCTestCase {
    func testRecordDedupesMovesToFrontCapsAndIgnoresDefault() {
        let suite = "recent-models-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let agent = "claude-code"

        // default 不记。
        RecentModels.record("default", forAgent: agent, defaults: defaults)
        XCTAssertEqual(RecentModels.get(forAgent: agent, defaults: defaults), [])

        RecentModels.record("sonnet", forAgent: agent, defaults: defaults)
        RecentModels.record("opus", forAgent: agent, defaults: defaults)
        RecentModels.record("sonnet", forAgent: agent, defaults: defaults) // 去重 + 提到最前
        XCTAssertEqual(RecentModels.get(forAgent: agent, defaults: defaults), ["sonnet", "opus"])

        // 上限。
        for i in 0..<10 { RecentModels.record("m\(i)", forAgent: agent, defaults: defaults) }
        let recent = RecentModels.get(forAgent: agent, defaults: defaults)
        XCTAssertEqual(recent.count, RecentModels.limit)
        XCTAssertEqual(recent.first, "m9") // 最新在最前

        // 按 agent 隔离。
        XCTAssertEqual(RecentModels.get(forAgent: "opencode", defaults: defaults), [])
    }
}
