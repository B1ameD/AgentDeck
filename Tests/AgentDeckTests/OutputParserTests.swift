import XCTest
@testable import AgentDeckApp

final class OutputParserTests: XCTestCase {
    func testStreamParserEmitsTextChunk() {
        let parser = OutputParser(mode: .stream)
        XCTAssertEqual(parser.parse("hello").map(\.text), ["hello"])
    }

    func testANSIParserStripsEscapeCodes() {
        let parser = OutputParser(mode: .ansiStream)
        XCTAssertEqual(parser.parse("\u{001B}[31mred\u{001B}[0m").map(\.text), ["red"])
    }

    func testJSONLinesParserReadsTextField() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(#"{"type":"message","text":"hello"}"# + "\n")
        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "hello")])
    }

    func testJSONLinesParserReportsInvalidLine() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse("{not-json}\n")
        XCTAssertEqual(events, [OutputEvent(kind: .error, text: "{not-json}")])
    }

    func testJSONLinesParserBuffersPartialChunksUntilNewline() {
        let parser = OutputParser(mode: .jsonLines)

        XCTAssertEqual(parser.parse(#"{"type":"message","te"#), [])
        XCTAssertEqual(parser.parse(#"xt":"hi"}"# + "\n"), [OutputEvent(kind: .message, text: "hi")])
    }

    func testJSONLinesParserEmitsMultipleRecordsFromOneChunk() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"message","text":"one"}"# + "\n" +
            #"{"type":"status","text":"two"}"# + "\n"
        )

        XCTAssertEqual(
            events,
            [
                OutputEvent(kind: .message, text: "one"),
                OutputEvent(kind: .status, text: "two"),
            ]
        )
    }

    func testJSONLinesParserFlushesTrailingValidRecordWithoutNewline() {
        let parser = OutputParser(mode: .jsonLines)

        XCTAssertEqual(parser.parse(#"{"type":"message","text":"tail"}"#), [])
        XCTAssertEqual(parser.flush(), [OutputEvent(kind: .message, text: "tail")])
    }

    func testJSONLinesParserFlushesInvalidTrailingRecordAsError() {
        let parser = OutputParser(mode: .jsonLines)

        XCTAssertEqual(parser.parse("{not-json"), [])
        XCTAssertEqual(parser.flush(), [OutputEvent(kind: .error, text: "{not-json")])
    }

    func testJSONLinesParserEmitsOpenCodeTextPartAndIgnoresSessionEvents() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"step_start","sessionID":"ses_123","part":{}}"# + "\n" +
            #"{"type":"text","part":{"text":"hello"}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "hello")])
    }

    func testJSONLinesParserEmitsCodexAgentMessageAndIgnoresThreadEvents() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"thread.started","thread_id":"thread_123"}"# + "\n" +
            #"{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "hello")])
    }

    func testJSONLinesParserExtractsStructuredErrorMessage() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(#"{"error":{"message":"quota exceeded"}}"# + "\n")

        XCTAssertEqual(events, [OutputEvent(kind: .error, text: "quota exceeded")])
    }

    func testJSONLinesParserWrapsReasoningEventsAsThinkingBlock() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(#"{"type":"reasoning","part":{"text":"checking context"}}"# + "\n")

        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "<think>checking context</think>")])
    }

    func testJSONLinesParserWrapsCodexReasoningItemContentArray() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"item.completed","item":{"type":"reasoning","content":[{"text":"checking"},{"text":"then answering"}]}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "<think>checking\nthen answering</think>")])
    }

    func testJSONLinesParserEmitsClaudeStreamEventDeltasAndIgnoresFinalSummaries() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"system","subtype":"init","session_id":"claude-session"}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"checking context"},"index":0}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"},"index":1}}"# + "\n" +
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}"# + "\n" +
            #"{"type":"result","subtype":"success","result":"ok"}"# + "\n"
        )

        XCTAssertEqual(events, [
            OutputEvent(kind: .message, text: "<think>checking context</think>"),
            OutputEvent(kind: .message, text: "ok")
        ])
    }

    // MARK: - 非流式后端兜底（第三方 Anthropic 兼容中转站只给整段 assistant、不发 content_block_delta）

    func testSurfacesNonStreamedAssistantAnswer() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"system","subtype":"init","session_id":"s"}"# + "\n" +
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"HTTP 是应用层协议。"}]}}"# + "\n" +
            #"{"type":"result","subtype":"success","result":"HTTP 是应用层协议。"}"# + "\n"
        )

        // 没有 content_block_delta 时，答案从最终 assistant 事件兜底产出（且 result 不再重复）。
        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "HTTP 是应用层协议。")])
    }

    func testSurfacesReadableResultErrorText() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"result","subtype":"error","is_error":true,"result":"Failed to authenticate. API Error: 401"}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .error, text: "Failed to authenticate. API Error: 401")])
    }

    func testNonStreamedAssistantThenErrorResultDoesNotDuplicate() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: 401 no access"}]}}"# + "\n" +
            #"{"type":"result","is_error":true,"result":"API Error: 401 no access"}"# + "\n"
        )

        // assistant 已兜底产出该文本（会被渲染为内联错误），result 的 is_error 不再重复。
        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "API Error: 401 no access")])
    }

    // MARK: - 工具调用紧凑摘要（不刷屏：只摘要调用，不灌结果）

    func testToolSummaryUsesChineseActionVerbs() {
        XCTAssertEqual(OutputParser.toolSummary(name: "Read", inputJSON: #"{"file_path":"/tmp/README.md"}"#), "读取 /tmp/README.md")
        XCTAssertEqual(OutputParser.toolSummary(name: "Write", inputJSON: #"{"file_path":"/tmp/new.swift"}"#), "创建 /tmp/new.swift")
        XCTAssertEqual(OutputParser.toolSummary(name: "Edit", inputJSON: #"{"file_path":"/tmp/a.ts"}"#), "编辑 /tmp/a.ts")
        XCTAssertEqual(OutputParser.toolSummary(name: "Bash", inputJSON: #"{"command":"ls -la"}"#), "运行 ls -la")
        XCTAssertEqual(OutputParser.toolSummary(name: "Grep", inputJSON: #"{"pattern":"TODO"}"#), "搜索 TODO")
        // 未知工具名（无动词映射）回落「名：参数」；无参数回落原名。
        XCTAssertEqual(OutputParser.toolSummary(name: "Mcp__weird", inputJSON: #"{"query":"x"}"#), "Mcp__weird：x")
        XCTAssertEqual(OutputParser.toolSummary(name: "Read", inputJSON: ""), "Read")
        XCTAssertEqual(OutputParser.toolSummary(name: "", inputJSON: "{}"), "工具")
    }

    func testToolSummaryTruncatesLongDetail() {
        let long = String(repeating: "a", count: 200)
        let summary = OutputParser.toolSummary(name: "Bash", inputJSON: #"{"command":""# + long + #""}"#)
        XCTAssertTrue(summary.hasPrefix("运行 "))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThan(summary.count, 100)
    }

    func testStreamingToolUseEmitsCompactStatusAndDropsResultBody() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Read","input":{}}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"file_path\":\"/tmp/a.swift\"}"}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .tool, text: "读取 /tmp/a.swift")])
    }

    func testAskUserQuestionToolUseEmitsQuestionEventWithInputJSON() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"questions\":[{\"header\":\"Auth\",\"question\":\"Which?\",\"multiSelect\":false,\"options\":[{\"label\":\"OAuth\"},{\"label\":\"API key\"}]}]}"}}}"# + "\n" +
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"# + "\n"
        )

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.kind, .question)
        // text 是该工具的 input JSON，可被会话层解析成结构化问题。
        let parsed = AskUserQuestionParser.parse(inputJSON: events.first?.text ?? "")
        XCTAssertEqual(parsed?.questions.first?.options.map(\.label), ["OAuth", "API key"])
    }

    func testOpenCodeReasoningPartFoldsAsThinking() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(#"{"type":"message.part.updated","part":{"type":"reasoning","text":"weighing options"}}"# + "\n")

        XCTAssertEqual(events, [OutputEvent(kind: .message, text: "<think>weighing options</think>")])
    }

    func testOpenCodeToolUseEmitsCompactStatus() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"tool_use","part":{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"/tmp/a.swift"},"output":"large output"}}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .tool, text: "读取 /tmp/a.swift")])
    }

    func testOpenCodeToolUseErrorEmitsCompactStatus() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"error","input":{"command":"rm nope"},"error":"permission denied"}}}"# + "\n"
        )

        XCTAssertEqual(events, [OutputEvent(kind: .tool, text: "工具出错：bash permission denied")])
    }

    // MARK: - 工具结果回灌不刷屏（Claude `type:"user"` tool_result）

    func testToolResultUserEventDoesNotFloodChat() {
        let parser = OutputParser(mode: .jsonLines)
        let huge = String(repeating: "file content line; ", count: 500)
        let events = parser.parse(
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":""# + huge + #""}]}}"# + "\n"
        )
        // 正常工具结果整段丢弃，不灌进聊天（避免刷屏）。
        XCTAssertEqual(events, [])
    }

    func testToolResultErrorIsSurfacedAsInlineToolActivity() {
        let parser = OutputParser(mode: .jsonLines)
        let events = parser.parse(
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"File not found: x.swift"}]}}"# + "\n"
        )
        XCTAssertEqual(events, [OutputEvent(kind: .tool, text: "工具出错：File not found: x.swift")])
    }
}
