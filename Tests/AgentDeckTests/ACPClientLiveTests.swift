import XCTest
@testable import AgentDeckApp

// ACPClient 进程壳的**实时集成测试**:对真实 Claude ACP 适配器
// (`npx -y @agentclientprotocol/claude-agent-acp`)跑通 initialize → session/new。
//
// 默认跳过(需联网 + 适配器 + 首次 npx 下载),只在显式开启时跑:
//     ACPDECK_LIVE=1 swift test --filter ACPClientLiveTests
// 不验证 session/prompt——那依赖底层模型可用(本机若默认模型损坏会失败,与传输层无关)。

final class ACPClientLiveTests: XCTestCase {

    private var live: Bool { ProcessInfo.processInfo.environment["ACPDECK_LIVE"] == "1" }

    func testLiveInitializeAndNewSession() async throws {
        try XCTSkipUnless(live, "设 ACPDECK_LIVE=1 启用实时 ACP 适配器测试")

        let client = ACPClient()
        try await client.start(
            command: "npx",
            args: ["-y", "@agentclientprotocol/claude-agent-acp"],
            environment: [:],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
        defer { Task { await client.shutdown() } }

        let caps = try await client.initialize()
        XCTAssertEqual(caps.protocolVersion, 1)
        XCTAssertTrue(caps.loadSession, "Claude 适配器应支持 session/load")

        let session = try await client.newSession(cwd: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(session.sessionId.isEmpty)
        XCTAssertTrue(
            session.availableModes.contains { $0.id == "plan" },
            "应自报 plan 模式(映射 AgentDeck plan)"
        )
    }
}
