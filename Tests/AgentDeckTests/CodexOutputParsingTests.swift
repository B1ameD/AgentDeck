import XCTest
@testable import AgentDeckApp

/// codex exec --json 的 item 事件解析:思考块、工具行(用户反馈:思考/工具均不显示)。
final class CodexOutputParsingTests: XCTestCase {
    private func parse(_ line: String) -> [OutputEvent] {
        let parser = OutputParser(mode: .jsonLines)
        return parser.parse(line + "\n")
    }

    func testReasoningItemBecomesThinkingBlock() {
        let events = parse(#"{"type":"item.completed","item":{"id":"i1","type":"reasoning","text":"先看测试"}}"#)
        XCTAssertEqual(events.map(\.text), ["<think>先看测试</think>"])

        // 摘要数组形态(messageTextValue 兼容数组拼接)
        let summary = parse(#"{"type":"item.completed","item":{"id":"i6","type":"reasoning","summary":["a","b"]}}"#)
        XCTAssertEqual(summary.first?.text, "<think>a\nb</think>")
    }

    func testCommandExecutionShowsOnStartAndOnlyFailureOnComplete() {
        let parser = OutputParser(mode: .jsonLines)
        let started = parser.parse(#"{"type":"item.started","item":{"id":"i2","type":"command_execution","command":"ls -la"}}"# + "\n")
        XCTAssertEqual(started.first?.kind, .tool)
        XCTAssertEqual(started.first?.text, "运行 ls -la")

        let updated = parser.parse(#"{"type":"item.updated","item":{"id":"i2","type":"command_execution","command":"ls -la"}}"# + "\n")
        XCTAssertTrue(updated.isEmpty, "updated 不重复出行")

        let succeeded = parser.parse(#"{"type":"item.completed","item":{"id":"i2","type":"command_execution","command":"ls -la","exit_code":0}}"# + "\n")
        XCTAssertTrue(succeeded.isEmpty, "成功完成不再出行")

        let failed = parser.parse(#"{"type":"item.completed","item":{"id":"i3","type":"command_execution","command":"false","exit_code":1}}"# + "\n")
        XCTAssertEqual(failed.first?.text, "⚠️ 命令失败（exit 1）：false")
    }

    func testFileChangeAndWebSearchAndMCPToolRows() {
        let change = parse(#"{"type":"item.completed","item":{"id":"i4","type":"file_change","changes":[{"path":"/a/b/Foo.swift","kind":"modify"},{"path":"/a/Bar.swift","kind":"add"}]}}"#)
        XCTAssertEqual(change.first?.text, "修改 Foo.swift、Bar.swift")

        let search = parse(#"{"type":"item.started","item":{"id":"i5","type":"web_search","query":"swift textkit"}}"#)
        XCTAssertEqual(search.first?.text, "搜索 swift textkit")

        let mcp = parse(#"{"type":"item.started","item":{"id":"i7","type":"mcp_tool_call","server":"agentdeck","tool":"ask_user"}}"#)
        XCTAssertEqual(mcp.first?.text, "工具 agentdeck.ask_user")
    }

    func testAgentMessageStillRendersAsAnswer() {
        let events = parse(#"{"type":"item.completed","item":{"id":"i8","type":"agent_message","text":"答案"}}"#)
        XCTAssertEqual(events.first?.kind, .message)
        XCTAssertEqual(events.first?.text, "答案")
    }
}
