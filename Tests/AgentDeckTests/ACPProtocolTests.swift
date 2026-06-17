import XCTest
@testable import AgentDeckApp

// ACP 协议层单测:用 spike 阶段从真实 Claude 适配器(@agentclientprotocol/claude-agent-acp v0.46.0)
// 录到的真实 JSON-RPC 报文,验证帧编解码 + 语义投影 + 事件翻译。不依赖真适配器。

final class ACPProtocolTests: XCTestCase {

    // MARK: - 帧编解码

    func testEncodeRequestProducesValidJSONRPC() throws {
        let line = ACPCodec.encodeRequest(id: 1, method: "initialize", params: [
            "protocolVersion": .number(1)
        ])
        let frame = try ACPCodec.decodeFrame(line)
        XCTAssertEqual(frame?.method, "initialize")
        XCTAssertEqual(frame?.id, .number(1))
        XCTAssertEqual(frame?.params?["protocolVersion"]?.intValue, 1)
    }

    func testEncodeNotificationHasNoID() throws {
        let line = ACPCodec.encodeRequest(id: nil, method: "session/cancel",
                                          params: ["sessionId": .string("s1")])
        let frame = try ACPCodec.decodeFrame(line)
        XCTAssertNotNil(frame)
        XCTAssertTrue(frame!.isNotification)
        XCTAssertNil(frame!.id)
    }

    func testDecodeBlankLineReturnsNil() throws {
        XCTAssertNil(try ACPCodec.decodeFrame(""))
        XCTAssertNil(try ACPCodec.decodeFrame("   \n"))
    }

    func testClassifyResponseVsRequestVsNotification() throws {
        let response = try ACPCodec.decodeFrame(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)!
        XCTAssertTrue(response.isResponse)
        let request = try ACPCodec.decodeFrame(#"{"jsonrpc":"2.0","id":7,"method":"fs/read_text_file","params":{"path":"/x"}}"#)!
        XCTAssertTrue(request.isRequest)
        let note = try ACPCodec.decodeFrame(#"{"jsonrpc":"2.0","method":"session/update","params":{}}"#)!
        XCTAssertTrue(note.isNotification)
    }

    // MARK: - initialize 结果(真实报文)

    func testParseRealInitializeResult() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"agentCapabilities":{"promptCapabilities":{"image":true,"embeddedContext":true},"loadSession":true,"sessionCapabilities":{"resume":{},"list":{}}},"agentInfo":{"name":"@agentclientprotocol/claude-agent-acp","title":"Claude Agent","version":"0.46.0"},"authMethods":[]}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let caps = ACPAgentCapabilities(from: frame.result!)
        XCTAssertEqual(caps.protocolVersion, 1)
        XCTAssertTrue(caps.loadSession)
        XCTAssertEqual(caps.agentName, "@agentclientprotocol/claude-agent-acp")
        XCTAssertTrue(caps.authMethods.isEmpty)
    }

    // MARK: - session/new 结果(真实报文,含 plan/bypassPermissions 模式)

    func testParseRealNewSessionResultWithModes() throws {
        let line = #"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"844d2318-37c4-4e1f-84ea-a610e2bad3cc","modes":{"currentModeId":"default","availableModes":[{"id":"default","name":"Default","description":"Standard"},{"id":"plan","name":"Plan Mode","description":"Planning mode, no actual tool execution"},{"id":"bypassPermissions","name":"Bypass Permissions","description":"Bypass all permission checks"}]}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let session = ACPNewSession(from: frame.result!)
        XCTAssertEqual(session?.sessionId, "844d2318-37c4-4e1f-84ea-a610e2bad3cc")
        XCTAssertEqual(session?.currentModeId, "default")
        XCTAssertEqual(session?.availableModes.map(\.id), ["default", "plan", "bypassPermissions"])
        // plan/build 模式可由此映射:plan→plan,build→bypassPermissions
        XCTAssertTrue(session?.availableModes.contains { $0.id == "plan" } ?? false)
        XCTAssertTrue(session?.availableModes.contains { $0.id == "bypassPermissions" } ?? false)
    }

    // MARK: - 事件翻译

    func testTranslateAgentMessageChunk() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello"}}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.events.count, 1)
        XCTAssertEqual(t.events.first?.kind, .message)
        XCTAssertEqual(t.events.first?.text, "Hello")
    }

    func testTranslateThoughtChunkWrapsInThinkTags() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"reasoning"}}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.events.first?.text, "<think>reasoning</think>")
        XCTAssertEqual(t.events.first?.kind, .message)
    }

    func testTranslateRealUsageUpdate() throws {
        // 真实报文:{"sessionUpdate":"usage_update","used":0,"size":200000,"cost":{"amount":0,"currency":"USD"}}
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":12345,"size":200000,"cost":{"amount":0.042,"currency":"USD"}}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.usage?.inputTokens, 12345)
        XCTAssertEqual(t.usage?.costUSD ?? 0, 0.042, accuracy: 0.0001)
        XCTAssertNil(t.usage?.costCurrency) // USD → 用默认 $,不覆盖
    }

    func testTranslateNonUSDCurrencyIsCaptured() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":10,"size":100,"cost":{"amount":1.5,"currency":"CNY"}}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.usage?.costCurrency, "CNY")
    }

    func testTranslateToolCallSummary() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read foo.swift","status":"in_progress"}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.events.first?.kind, .tool)
        XCTAssertEqual(t.events.first?.text, "Read foo.swift · in_progress")
    }

    func testTranslateCurrentModeUpdate() throws {
        let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"current_mode_update","currentModeId":"plan"}}}"#
        let frame = try ACPCodec.decodeFrame(line)!
        let t = ACPEventTranslator.translate(updateParams: frame.params!)
        XCTAssertEqual(t.currentModeId, "plan")
        XCTAssertTrue(t.events.isEmpty)
    }

    func testTranslateIgnoredUpdateKindsProduceNoEvents() throws {
        for kind in ["plan", "available_commands_update", "session_info_update", "user_message_chunk"] {
            let line = #"{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"\#(kind)"}}}"#
            let frame = try ACPCodec.decodeFrame(line)!
            let t = ACPEventTranslator.translate(updateParams: frame.params!)
            XCTAssertTrue(t.events.isEmpty, "\(kind) 不应投递聊天事件")
        }
    }

    // MARK: - 权限选项

    func testPermissionOptionKindClassification() throws {
        let allowAlways = ACPPermissionOption(from: try jsonValue(#"{"optionId":"o1","name":"Allow always","kind":"allow_always"}"#))!
        XCTAssertTrue(allowAlways.isAllow)
        XCTAssertTrue(allowAlways.remembers)

        let rejectOnce = ACPPermissionOption(from: try jsonValue(#"{"optionId":"o2","name":"Reject","kind":"reject_once"}"#))!
        XCTAssertFalse(rejectOnce.isAllow)
        XCTAssertFalse(rejectOnce.remembers)
    }

    // helper:把一行 JSON 解成 JSONValue
    private func jsonValue(_ line: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: line.data(using: .utf8)!)
    }
}
