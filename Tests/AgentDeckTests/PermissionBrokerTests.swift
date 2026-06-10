import XCTest
@testable import AgentDeckApp

final class PermissionBrokerTests: XCTestCase {
    func testDefaultPolicyMapsRiskToExpectedDecision() {
        let broker = PermissionBroker()
        let cases: [(risk: PermissionRequest.Risk, expectedDecision: PermissionDecision)] = [
            (.normalAgentProcess, .allow),
            (.runsShellCommand, .ask),
            (.readsFiles, .ask),
            (.modifiesFiles, .ask)
        ]

        for testCase in cases {
            let request = PermissionRequest(
                agentName: "Codex",
                command: "codex",
                workingDirectory: "/Users/test/project",
                risk: testCase.risk
            )

            XCTAssertEqual(
                broker.defaultDecision(for: request),
                testCase.expectedDecision,
                "Unexpected default decision for risk \(testCase.risk)"
            )
        }
    }
}
