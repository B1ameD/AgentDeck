import XCTest
@testable import AgentDeckApp

// ACP 阶段 1:AgentSession 经注入的假 ACPTransporting 跑通「聊天 / 流式 / usage / 取消」,
// 不依赖真适配器子进程。

@MainActor
final class ACPSessionTests: XCTestCase {

    private func acpAgent() -> AgentConfig {
        AgentConfig(
            id: "claude-acp",
            name: "Claude (ACP)",
            command: "npx",
            args: ["-y", "@agentclientprotocol/claude-agent-acp"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt,
            transport: .acp
        )
    }

    private func update(_ kind: String, extra: [String: JSONValue] = [:]) -> JSONValue {
        var inner: [String: JSONValue] = ["sessionUpdate": .string(kind)]
        for (k, v) in extra { inner[k] = v }
        return .object(["sessionId": .string("s1"), "update": .object(inner)])
    }

    func testACPStreamsAssistantTextAndReachesIdle() async {
        let scripted: [ACPPromptEvent] = [
            .update(update("agent_message_chunk", extra: ["content": .object(["type": .string("text"), "text": .string("Hel")])])),
            .update(update("agent_message_chunk", extra: ["content": .object(["type": .string("text"), "text": .string("lo")])])),
            .update(update("usage_update", extra: ["used": .number(1200), "size": .number(200000),
                                                   "cost": .object(["amount": .number(0.01), "currency": .string("USD")])])),
            .completed(stopReason: "end_turn")
        ]
        let transport = FakeACPTransport(scripted: scripted)
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("hi")

        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.last?.text, "Hello") // 两个 chunk 累加到同一气泡
        XCTAssertEqual(session.usage.inputTokens, 1200)
        XCTAssertEqual(session.usage.costUSD, 0.01, accuracy: 0.0001)
        // 生命周期:首轮 start→initialize→newSession 各一次
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.initializeCount, 1)
        XCTAssertEqual(transport.newSessionCount, 1)
        XCTAssertEqual(transport.lastPromptText, "hi")
    }

    func testACPReusesSessionAcrossTurns() async {
        let transport = FakeACPTransport(scripted: [
            .update(update("agent_message_chunk", extra: ["content": .object(["type": .string("text"), "text": .string("ok")])])),
            .completed(stopReason: "end_turn")
        ])
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("first")
        await session.send("second")

        // 适配器进程与 sessionId 跨轮复用:start/initialize/newSession 仍各一次,prompt 两次。
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(transport.newSessionCount, 1)
        XCTAssertEqual(transport.promptCount, 2)
    }

    func testACPMapsPlanModeWhenAdvertised() async {
        let transport = FakeACPTransport(
            scripted: [.completed(stopReason: "end_turn")],
            availableModes: [ACPMode(from: .object(["id": .string("plan"), "name": .string("Plan")]))!,
                             ACPMode(from: .object(["id": .string("bypassPermissions"), "name": .string("Bypass")]))!]
        )
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )
        session.interactionMode = .plan

        await session.send("plan it")

        XCTAssertEqual(transport.lastModeID, "plan")
    }

    /// 实时端到端:AgentSession + 真 ACPClient + 真 Claude 适配器。默认跳过。
    ///   ACPDECK_LIVE=1 swift test --filter testLiveACPThroughAgentSession
    /// 用 agent.env 覆盖成真实模型(绕开本进程可能残留的 mimo-* 默认)。
    func testLiveACPThroughAgentSession() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ACPDECK_LIVE"] == "1",
                          "设 ACPDECK_LIVE=1 启用实时 ACP 端到端测试")
        var agent = acpAgent()
        agent.env = [
            "ANTHROPIC_MODEL": "claude-haiku-4-5-20251001",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5-20251001"
        ]
        let session = AgentSession(
            agent: agent,
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow }
        )

        await session.send("Reply with exactly the token ACP_OK and nothing else.")

        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(
            (session.messages.last?.text ?? "").contains("ACP_OK"),
            "实时 ACP 回答应含 ACP_OK,实际:\(session.messages.last?.text ?? "<空>")"
        )
    }

    func testACPBuildModeMapsToAcceptEditsWhenAdvertised() async {
        let transport = FakeACPTransport(
            scripted: [.completed(stopReason: "end_turn")],
            availableModes: [ACPMode(from: .object(["id": .string("acceptEdits"), "name": .string("Accept Edits")]))!,
                             ACPMode(from: .object(["id": .string("plan"), "name": .string("Plan")]))!]
        )
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )
        session.interactionMode = .build

        await session.send("edit it")

        XCTAssertEqual(transport.lastModeID, "acceptEdits")
    }

    func testACPPermissionCardSetsPendingAndResolves() async {
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow }
        )
        let allow = ACPPermissionOption(from: .object(["optionId": .string("o-allow"), "name": .string("允许一次"), "kind": .string("allow_once")]))!
        let reject = ACPPermissionOption(from: .object(["optionId": .string("o-reject"), "name": .string("拒绝"), "kind": .string("reject_once")]))!

        let task = Task {
            await session.requestACPPermission(
                toolCall: .object(["title": .string("Run ls -la")]),
                options: [allow, reject]
            )
        }
        // 等卡片出现
        for _ in 0..<100 where session.pendingACPPermission == nil { await Task.yield() }

        XCTAssertEqual(session.pendingACPPermission?.title, "Run ls -la")
        XCTAssertEqual(session.pendingACPPermission?.options.map(\.optionId), ["o-allow", "o-reject"])

        session.resolveACPPermission(optionId: "o-allow")
        let chosen = await task.value

        XCTAssertEqual(chosen, "o-allow")
        XCTAssertNil(session.pendingACPPermission)
    }

    func testACPPermissionCancelReturnsNil() async {
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow }
        )
        let allow = ACPPermissionOption(from: .object(["optionId": .string("o1"), "name": .string("允许"), "kind": .string("allow_once")]))!

        let task = Task {
            await session.requestACPPermission(toolCall: .object([:]), options: [allow])
        }
        for _ in 0..<100 where session.pendingACPPermission == nil { await Task.yield() }

        session.resolveACPPermission(optionId: nil) // 用户取消
        let chosen = await task.value

        XCTAssertNil(chosen)
        XCTAssertNil(session.pendingACPPermission)
    }

    func testACPCapturesConfigOptionsAndCurrentMode() async {
        let transport = FakeACPTransport(
            scripted: [.completed(stopReason: "end_turn")],
            availableModes: [ACPMode(from: .object(["id": .string("plan"), "name": .string("Plan")]))!],
            configOptions: [ACPConfigOption(from: .object(["id": .string("model"), "name": .string("Model")]))!],
            currentModeId: "plan"
        )
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("hi")

        XCTAssertEqual(session.acpConfigOptions.map(\.id), ["model"])
        XCTAssertEqual(session.acpCurrentModeID, "plan")
    }

    func testACPCurrentModeUpdateRefreshesState() async {
        let modeUpdate = update("current_mode_update", extra: ["currentModeId": .string("acceptEdits")])
        let transport = FakeACPTransport(scripted: [.update(modeUpdate), .completed(stopReason: "end_turn")],
                                         currentModeId: "default")
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("go")

        XCTAssertEqual(session.acpCurrentModeID, "acceptEdits") // current_mode_update 覆盖了初值 default
    }

    func testACPSetConfigOptionForwardsToTransport() async {
        let transport = FakeACPTransport(
            scripted: [.completed(stopReason: "end_turn")],
            configOptions: [ACPConfigOption(from: .object(["id": .string("model"), "name": .string("Model")]))!]
        )
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("hi") // 建立会话
        await session.setACPConfigOption(configId: "model", value: "claude-opus-4-8")

        XCTAssertEqual(transport.lastConfig?.configId, "model")
        XCTAssertEqual(transport.lastConfig?.value, "claude-opus-4-8")
    }

    func testACPErrorSurfacesAsErrorMessage() async {
        let transport = FakeACPTransport(scripted: [], failPromptWith: ACPClientError.requestFailed(code: -32603, message: "model_not_found"))
        let session = AgentSession(
            agent: acpAgent(),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            acpTransport: transport
        )

        await session.send("hi")

        XCTAssertTrue(session.messages.contains { $0.role == .error })
        if case .failed = session.status {} else { XCTFail("应进入 failed 状态") }
    }
}

/// 脚本化的假 ACP 传输:prompt 按预设事件流逐条产出;记录调用次数供断言。
final class FakeACPTransport: ACPTransporting, @unchecked Sendable {
    private let scripted: [ACPPromptEvent]
    private let availableModes: [ACPMode]
    private let failPromptWith: Error?

    private(set) var startCount = 0
    private(set) var initializeCount = 0
    private(set) var newSessionCount = 0
    private(set) var promptCount = 0
    private(set) var lastPromptText: String?
    private(set) var lastModeID: String?

    private let configOptions: [ACPConfigOption]
    private let currentModeId: String?

    init(scripted: [ACPPromptEvent], availableModes: [ACPMode] = [], failPromptWith: Error? = nil,
         configOptions: [ACPConfigOption] = [], currentModeId: String? = nil) {
        self.scripted = scripted
        self.availableModes = availableModes
        self.failPromptWith = failPromptWith
        self.configOptions = configOptions
        self.currentModeId = currentModeId
    }

    func start(command: String, args: [String], environment: [String: String], workingDirectory: URL) async throws {
        startCount += 1
    }

    func initialize() async throws -> ACPAgentCapabilities {
        initializeCount += 1
        return ACPAgentCapabilities(from: .object([
            "protocolVersion": .number(1),
            "agentCapabilities": .object(["loadSession": .bool(true)])
        ]))
    }

    func newSession(cwd: URL, mcpServers: [JSONValue]) async throws -> ACPNewSession {
        newSessionCount += 1
        var result: [String: JSONValue] = ["sessionId": .string("s1")]
        if !availableModes.isEmpty {
            result["modes"] = .object([
                "currentModeId": .string(currentModeId ?? "default"),
                "availableModes": .array(availableModes.map { .object(["id": .string($0.id), "name": .string($0.name)]) })
            ])
        }
        if !configOptions.isEmpty {
            result["configOptions"] = .array(configOptions.map {
                .object(["id": .string($0.id), "name": .string($0.name)])
            })
        }
        return ACPNewSession(from: .object(result))!
    }

    func setMode(sessionId: String, modeId: String) async throws {
        lastModeID = modeId
    }

    private(set) var lastConfig: (configId: String, value: String)?
    func setConfigOption(sessionId: String, configId: String, value: String) async throws {
        lastConfig = (configId, value)
    }

    func prompt(sessionId: String, content: [JSONValue]) -> AsyncThrowingStream<ACPPromptEvent, Error> {
        promptCount += 1
        lastPromptText = content.first?["text"]?.stringValue
        let scripted = self.scripted
        let failPromptWith = self.failPromptWith
        return AsyncThrowingStream { continuation in
            if let failPromptWith {
                continuation.finish(throwing: failPromptWith)
                return
            }
            for event in scripted { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(sessionId: String) async {}
    func shutdown() async {}
}
