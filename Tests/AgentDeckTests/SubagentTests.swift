import XCTest
@testable import AgentDeckApp

final class SubagentTests: XCTestCase {
    func testSubagentMarkerRoundTrips() {
        let marker = SubagentMarker.encode(id: "toolu_9", label: "Explore · 找 X")
        let decoded = SubagentMarker.decode(marker)
        XCTAssertEqual(decoded?.id, "toolu_9")
        XCTAssertEqual(decoded?.label, "Explore · 找 X")
        // 普通工具摘要不会被误判为子任务。
        XCTAssertNil(SubagentMarker.decode("读取 foo.swift"))
    }

    func testParserEmitsSubagentDelegationThenResult() throws {
        let parser = OutputParser(mode: .jsonLines)
        let delegation = parser.parse(
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"Task","input":{}}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"subagent_type\":\"Explore\",\"description\":\"Find X\",\"prompt\":\"do the thing\"}"}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"# + "\n"
        )
        XCTAssertEqual(delegation.count, 1)
        XCTAssertEqual(delegation.first?.kind, .subagent)
        let dObj = try XCTUnwrap(jsonObject(delegation.first?.text))
        XCTAssertEqual(dObj["id"] as? String, "toolu_1")
        XCTAssertEqual(dObj["agentType"] as? String, "Explore")
        XCTAssertEqual(dObj["description"] as? String, "Find X")
        XCTAssertEqual(dObj["prompt"] as? String, "do the thing")
        XCTAssertNil(dObj["done"]) // 派发态

        // 同一 parser 实例记下了 toolu_1；其 tool_result 转成「结果态」委派事件。
        let result = parser.parse(
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"the final report"}]}}"# + "\n"
        )
        XCTAssertEqual(result.first?.kind, .subagent)
        let rObj = try XCTUnwrap(jsonObject(result.first?.text))
        XCTAssertEqual(rObj["done"] as? Bool, true)
        XCTAssertEqual(rObj["id"] as? String, "toolu_1")
        XCTAssertEqual(rObj["result"] as? String, "the final report")
    }

    func testNonSubagentToolResultStillDropped() {
        let parser = OutputParser(mode: .jsonLines)
        // 没记过的 tool_use_id 的正常结果仍丢弃（不刷屏）。
        let r = parser.parse(
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"other","content":"huge output"}]}}"# + "\n"
        )
        XCTAssertTrue(r.isEmpty)
    }

    func testAssistantBlocksDecodesSubagentMarkerInline() {
        let marker = ToolActivity.marker(SubagentMarker.encode(id: "t1", label: "Explore · X"))
        let blocks = MessagePresentation.assistantBlocks(in: "前文" + marker + "后文")
        XCTAssertTrue(blocks.contains(.subagentRef(id: "t1", label: "Explore · X")))
        XCTAssertTrue(blocks.contains(.text("前文")))
        XCTAssertTrue(blocks.contains(.text("后文")))
    }

    // MARK: - OpenCode task 工具 → 结构化委派

    func testOpenCodeTaskToolParsedAsSubagentNotPlainTool() throws {
        let parser = OutputParser(mode: .jsonLines)
        // opencode 在 task 子代理完成时一次性给出整条 tool part（状态 + input + output）。
        let line = #"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","id":"prt_1","callID":"call_1","tool":"task","state":{"status":"completed","input":{"subagent_type":"Explore","description":"检查项目","prompt":"统计模块并总结"},"output":"项目包含若干模块"}}}"# + "\n"
        let events = parser.parse(line)
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.kind, .subagent) // 关键：结构化委派，而非普通 .tool
        let obj = try XCTUnwrap(jsonObject(event.text))
        XCTAssertEqual(obj["id"] as? String, "prt_1")
        XCTAssertEqual(obj["agentType"] as? String, "Explore")
        XCTAssertEqual(obj["description"] as? String, "检查项目")
        XCTAssertEqual(obj["prompt"] as? String, "统计模块并总结")
        XCTAssertEqual(obj["result"] as? String, "项目包含若干模块")
        XCTAssertEqual(obj["isError"] as? Bool, false)
        XCTAssertEqual(obj["done"] as? Bool, true) // 完成态一次性 upsert
    }

    func testOpenCodeTaskToolErrorParsedAsSubagentError() throws {
        let parser = OutputParser(mode: .jsonLines)
        let line = #"{"type":"tool_use","sessionID":"ses_1","part":{"type":"tool","id":"prt_2","tool":"task","state":{"status":"error","input":{"subagent_type":"Explore","description":"X","prompt":"Y"},"error":"agent failed"}}}"# + "\n"
        let event = try XCTUnwrap(parser.parse(line).first)
        XCTAssertEqual(event.kind, .subagent)
        let obj = try XCTUnwrap(jsonObject(event.text))
        XCTAssertEqual(obj["id"] as? String, "prt_2")
        XCTAssertEqual(obj["isError"] as? Bool, true)
        XCTAssertEqual(obj["result"] as? String, "agent failed") // 出错时结果取自 state.error
        XCTAssertEqual(obj["done"] as? Bool, true)
    }

    func testOpenCodeNonSubagentToolStaysPlainSummary() {
        let parser = OutputParser(mode: .jsonLines)
        // 普通工具（read）仍压成一行摘要，不走委派路径。
        let line = #"{"type":"tool_use","part":{"type":"tool","id":"prt_3","tool":"read","state":{"status":"completed","input":{"filePath":"/tmp/x"},"output":"..."}}}"# + "\n"
        XCTAssertEqual(parser.parse(line).first?.kind, .tool)
    }

    // MARK: - 持久化（重开会话仍可点击）

    func testChatMessageSubagentTasksSurviveCodableRoundTrip() throws {
        let task = SubagentTask(
            id: "prt_1", agentType: "Explore", taskDescription: "检查项目",
            prompt: "统计模块", result: "完成", isError: false
        )
        let marker = ToolActivity.marker(SubagentMarker.encode(id: task.id, label: task.rowLabel))
        let message = ChatMessage(role: .assistant, text: "前文" + marker, subagentTasks: [task])

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.subagentTasks, [task])
        // 解码后文本仍含标记 → 展示层仍解析出可点击的委派行（即重开会话后仍能查看详情）。
        XCTAssertTrue(
            MessagePresentation.assistantBlocks(in: decoded.text)
                .contains(.subagentRef(id: "prt_1", label: task.rowLabel))
        )
    }

    private func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
