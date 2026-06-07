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

    private func jsonObject(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
