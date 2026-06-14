import XCTest
@testable import AgentDeckApp

final class OpenCodeStreamingTests: XCTestCase {

    // MARK: - SSE 解析

    func testParseSSELineStripsDataPrefix() {
        XCTAssertEqual(OpenCodeStreamWire.parseSSELine(#"data: {"type":"x"}"#)?["type"] as? String, "x")
        XCTAssertEqual(OpenCodeStreamWire.parseSSELine(#"data:{"a":1}"#)?["a"] as? Int, 1)
    }

    func testParseSSELineIgnoresBlankAndNonJSON() {
        XCTAssertNil(OpenCodeStreamWire.parseSSELine(""))
        XCTAssertNil(OpenCodeStreamWire.parseSSELine("data: "))
        XCTAssertNil(OpenCodeStreamWire.parseSSELine(": heartbeat comment"))
        XCTAssertNil(OpenCodeStreamWire.parseSSELine("event: message"))
    }

    func testSSEChunkDecoderEmitsCompleteDataLinesImmediately() {
        var decoder = OpenCodeSSEChunkDecoder()

        let partial = #"data: {"type":"message.part.delta""#.data(using: .utf8)!
        XCTAssertTrue(decoder.append(partial).isEmpty)

        let rest = (#","properties":{"sessionID":"s","partID":"p","delta":"你"}}"# + "\n\n")
            .data(using: .utf8)!
        let events = decoder.append(rest)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.object["type"] as? String, "message.part.delta")
        let properties = events.first?.object["properties"] as? [String: Any]
        XCTAssertEqual(properties?["delta"] as? String, "你")
    }

    func testSSEChunkDecoderKeepsSplitUTF8CharactersIntact() {
        var decoder = OpenCodeSSEChunkDecoder()
        let line = #"data: {"type":"message.part.delta","properties":{"sessionID":"s","partID":"p","delta":"继续"}}"# + "\n"
        let bytes = Array(line.data(using: .utf8)!)
        let split = bytes.firstIndex(of: 0xE7)! + 1 // split inside the first CJK scalar

        XCTAssertTrue(decoder.append(Data(bytes[..<split])).isEmpty)
        let events = decoder.append(Data(bytes[split...]))

        let properties = events.first?.object["properties"] as? [String: Any]
        XCTAssertEqual(properties?["delta"] as? String, "继续")
    }

    // MARK: - 模型拆分

    func testSplitModel() {
        XCTAssertNil(OpenCodeStreamWire.splitModel("default"))
        XCTAssertNil(OpenCodeStreamWire.splitModel(""))
        XCTAssertNil(OpenCodeStreamWire.splitModel("noslash"))
        let parsed = OpenCodeStreamWire.splitModel("opencode-go/deepseek-v4-flash")
        XCTAssertEqual(parsed?.providerID, "opencode-go")
        XCTAssertEqual(parsed?.modelID, "deepseek-v4-flash")
        // 模型名里含 "/" 时只按第一个分隔，余下都归 modelID。
        let nested = OpenCodeStreamWire.splitModel("a/b/c")
        XCTAssertEqual(nested?.providerID, "a")
        XCTAssertEqual(nested?.modelID, "b/c")
    }

    // MARK: - 请求体构造

    func testMessageBodyOrdersAttachmentsBeforeText() {
        let file = URL(fileURLWithPath: "/tmp/note.txt")
        let body = OpenCodeStreamWire.messageBody(model: "p/m", variant: "high", prompt: "hi", attachments: [file])
        let parts = body["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 2)
        XCTAssertEqual(parts?.first?["type"] as? String, "file")
        XCTAssertEqual(parts?.first?["filename"] as? String, "note.txt")
        XCTAssertEqual(parts?.last?["type"] as? String, "text")
        XCTAssertEqual(parts?.last?["text"] as? String, "hi")
        let model = body["model"] as? [String: String]
        XCTAssertEqual(model?["providerID"], "p")
        XCTAssertEqual(model?["modelID"], "m")
        XCTAssertEqual(body["variant"] as? String, "high")
    }

    func testMessageBodyOmitsDefaultModelAndEmptyVariant() {
        let body = OpenCodeStreamWire.messageBody(model: "default", variant: nil, prompt: "hi", attachments: [])
        XCTAssertNil(body["model"])
        XCTAssertNil(body["variant"])
        let parts = body["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.count, 1)
        XCTAssertEqual(parts?.first?["text"] as? String, "hi")
    }

    func testSessionCreateBodyCarriesDenyRules() {
        let body = OpenCodeStreamWire.sessionCreateBody(title: "T")
        XCTAssertEqual(body["title"] as? String, "T")
        let rules = body["permission"] as? [[String: Any]]
        XCTAssertEqual(Set(rules?.compactMap { $0["permission"] as? String } ?? []),
                       ["question", "plan_enter", "plan_exit"])
        XCTAssertTrue(rules?.allSatisfy { ($0["action"] as? String) == "deny" } ?? false)
    }

    // MARK: - 累计 → 增量

    func testDeltaAccumulatorEmitsIncrements() {
        var acc = DeltaAccumulator()
        XCTAssertEqual(acc.delta(partID: "p", fullText: "Hel"), "Hel")
        XCTAssertEqual(acc.delta(partID: "p", fullText: "Hello"), "lo")
        XCTAssertEqual(acc.delta(partID: "p", fullText: "Hello"), "") // 无变化
    }

    func testDeltaAccumulatorSelfHealsOnMissedSnapshot() {
        var acc = DeltaAccumulator()
        XCTAssertEqual(acc.delta(partID: "p", fullText: "ab"), "ab")
        // 漏掉了中间快照 "abcd"，下一帧仍是累计全文 → 增量补回，累计仍等于全文。
        XCTAssertEqual(acc.delta(partID: "p", fullText: "abcdef"), "cdef")
    }

    func testDeltaAccumulatorTracksPartsIndependently() {
        var acc = DeltaAccumulator()
        XCTAssertEqual(acc.delta(partID: "a", fullText: "foo"), "foo")
        XCTAssertEqual(acc.delta(partID: "b", fullText: "bar"), "bar")
        XCTAssertEqual(acc.delta(partID: "a", fullText: "foobaz"), "baz")
    }

    // MARK: - 事件翻译

    func testTranslatesAssistantTextToIncrementalDeltas() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "m1", role: "assistant"))
        let first = t.translate(textPart(messageID: "m1", id: "p1", text: "Hel", hasTime: true))
        let second = t.translate(textPart(messageID: "m1", id: "p1", text: "Hello", hasTime: true))
        XCTAssertEqual(decodedPartText(first.lines.first), "Hel")
        XCTAssertEqual(decodedPartText(second.lines.first), "lo")
    }

    func testSeparatesDistinctTextPartsWithNewline() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "m1", role: "assistant"))
        let first = t.translate(textPart(messageID: "m1", id: "p1", text: "before", hasTime: true))
        // 工具调用后 opencode 开新的文本 part：第一段增量前应补换行，避免与上一段黏连。
        let second = t.translate(textPart(messageID: "m1", id: "p2", text: "after", hasTime: true))
        XCTAssertEqual(decodedPartText(first.lines.first), "before")
        XCTAssertEqual(decodedPartText(second.lines.first), "\nafter")
    }

    func testSkipsUserEchoTextPart() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "mu", role: "user"))
        // 用户消息的文本 part（角色 user、无 time）必须被过滤，不能回显为助手内容。
        let result = t.translate(textPart(messageID: "mu", id: "pu", text: "my prompt", hasTime: false))
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testReasoningGatedByThinkingFlag() {
        var on = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = on.translate(messageUpdated(id: "m1", role: "assistant"))
        let withThinking = on.translate(reasoningPart(messageID: "m1", id: "r1", text: "pondering"))
        XCTAssertEqual(withThinking.lines.first.map { OpenCodeStreamWire.parseSSELine($0)?["type"] as? String }, "reasoning")

        var off = OpenCodeEventTranslator(sessionID: "s", thinking: false)
        _ = off.translate(messageUpdated(id: "m1", role: "assistant"))
        let withoutThinking = off.translate(reasoningPart(messageID: "m1", id: "r1", text: "pondering"))
        XCTAssertTrue(withoutThinking.lines.isEmpty)
    }

    func testToolPartEmittedOnlyWhenSettled() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        let running = t.translate(toolPart(id: "t1", status: "running"))
        XCTAssertTrue(running.lines.isEmpty)
        let completed = t.translate(toolPart(id: "t1", status: "completed"))
        XCTAssertEqual(completed.lines.first.map { OpenCodeStreamWire.parseSSELine($0)?["type"] as? String }, "tool_use")
    }

    func testQuestionAskedEmitsQuestionLineWithRequestIDAndKeepsRunning() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        // opencode 的 question.asked：转成 question 事件交上层渲染卡片；不结束、不拒绝（run 保持运行等回答）。
        let result = t.translate(questionAsked(requestID: "que_1"))
        XCTAssertFalse(result.finished)
        XCTAssertNil(result.rejectPermissionID)
        let line = result.lines.first.flatMap { OpenCodeStreamWire.parseSSELine($0) }
        XCTAssertEqual(line?["type"] as? String, "question")
        XCTAssertEqual(line?["requestID"] as? String, "que_1")
        let questions = (line?["input"] as? [String: Any])?["questions"] as? [[String: Any]]
        XCTAssertEqual(questions?.first?["question"] as? String, "继续吗？")
    }

    func testQuestionAskedForeignSessionIgnored() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        let foreign: [String: Any] = ["type": "question.asked", "properties": [
            "id": "que_1", "sessionID": "OTHER", "questions": []
        ]]
        XCTAssertTrue(t.translate(foreign).lines.isEmpty)
    }

    func testStreamsAnswerViaPartDelta() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "m1", role: "assistant"))
        _ = t.translate(partUpdated(messageID: "m1", id: "p1", type: "text", text: "")) // 注册 part 类型
        // 真·逐 token：message.part.delta 各自携带增量，原样发出。
        XCTAssertEqual(decodedPartText(t.translate(partDelta(partID: "p1", delta: "Hel")).lines.first), "Hel")
        XCTAssertEqual(decodedPartText(t.translate(partDelta(partID: "p1", delta: "lo")).lines.first), "lo")
    }

    func testStreamsReasoningViaPartDelta() {
        var on = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = on.translate(partUpdated(messageID: "m1", id: "r1", type: "reasoning", text: ""))
        let line = on.translate(partDelta(partID: "r1", delta: "hmm")).lines.first
        XCTAssertEqual(line.map { OpenCodeStreamWire.parseSSELine($0)?["type"] as? String }, "reasoning")

        var off = OpenCodeEventTranslator(sessionID: "s", thinking: false)
        _ = off.translate(partUpdated(messageID: "m1", id: "r1", type: "reasoning", text: ""))
        XCTAssertTrue(off.translate(partDelta(partID: "r1", delta: "hmm")).lines.isEmpty)
    }

    func testPartDeltaThenFinalUpdatedDoesNotDuplicate() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(partUpdated(messageID: "m1", id: "p1", type: "text", text: ""))
        _ = t.translate(partDelta(partID: "p1", delta: "Hel"))
        _ = t.translate(partDelta(partID: "p1", delta: "lo"))
        // 收尾的全量快照已被 delta 覆盖 → 不应再重复发出。
        let final = t.translate(partUpdated(messageID: "m1", id: "p1", type: "text", text: "Hello"))
        XCTAssertTrue(final.lines.isEmpty)
    }

    func testNonStreamingProviderFallsBackToFullSnapshot() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "m1", role: "assistant"))
        // provider 不发 delta，只有全量 part.updated → 兜底发出完整文本（否则答案丢失）。
        let result = t.translate(partUpdated(messageID: "m1", id: "p1", type: "text", text: "whole answer"))
        XCTAssertEqual(decodedPartText(result.lines.first), "whole answer")
    }

    func testSessionIdleEventFinishes() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        XCTAssertTrue(t.translate(["type": "session.idle", "properties": ["sessionID": "s"]]).finished)
        XCTAssertFalse(t.translate(["type": "session.idle", "properties": ["sessionID": "OTHER"]]).finished)
    }

    func testSessionStatusIdleFinishes() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        XCTAssertFalse(t.translate(sessionStatus(type: "busy")).finished)
        XCTAssertTrue(t.translate(sessionStatus(type: "idle")).finished)
    }

    func testForeignSessionEventsIgnored() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        _ = t.translate(messageUpdated(id: "m1", role: "assistant"))
        // 同一全局事件流里别的会话的 part 必须被忽略。
        let other = t.translate([
            "type": "message.part.updated",
            "properties": ["part": ["sessionID": "OTHER", "type": "text", "id": "x", "text": "nope", "time": ["start": 1]]]
        ])
        XCTAssertTrue(other.lines.isEmpty)
    }

    func testPermissionAskedRequestsReject() {
        var t = OpenCodeEventTranslator(sessionID: "s", thinking: true)
        let asked = t.translate(["type": "permission.asked", "properties": ["sessionID": "s", "id": "perm_1"]])
        XCTAssertEqual(asked.rejectPermissionID, "perm_1")
    }

    // MARK: - AgentSession 集成（注入假流式通道）

    @MainActor
    func testAgentSessionStreamsOpenCodeDeltas() async {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_abc","part":{}}"#,
            #"{"type":"text","sessionID":"ses_abc","part":{"type":"text","text":"Hel"}}"#,
            #"{"type":"text","sessionID":"ses_abc","part":{"type":"text","text":"lo"}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "SHOULD_NOT_APPEAR"),
            openCodeStreamer: streamer
        )

        await session.send("hi")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.last?.text, "Hello") // 两段增量拼成完整答案
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.backendSessionID, "ses_abc") // 从 step_start 捕获后端会话以便续接
        let request = streamer.firstRequest
        XCTAssertEqual(request?.prompt, "hi")
        XCTAssertNil(request?.continueSessionID) // 首轮新建
        XCTAssertTrue(request?.thinking ?? false) // jsonLines → 展开思考
    }

    @MainActor
    func testOpenCodePlanModeInjectsHintIntoStreamingPrompt() async {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_plan","part":{}}"#,
            #"{"type":"text","sessionID":"ses_plan","part":{"type":"text","text":"ok"}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )
        session.interactionMode = .plan

        await session.send("分析这段代码")

        // 流式（默认生产路径）不经过 CLIInvocationBuilder，必须在此注入 planModeHint，
        // 否则切 plan 对流式 opencode 是空操作。
        let prompt = streamer.firstRequest?.prompt ?? ""
        XCTAssertTrue(prompt.contains("[Plan Mode]"))
        XCTAssertTrue(prompt.hasSuffix("分析这段代码"))
    }

    @MainActor
    func testOpenCodeBuildModeStreamingPromptHasNoHint() async {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_build","part":{}}"#,
            #"{"type":"text","sessionID":"ses_build","part":{"type":"text","text":"ok"}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )
        session.interactionMode = .build

        await session.send("继续")

        XCTAssertEqual(streamer.firstRequest?.prompt, "继续")
    }

    @MainActor
    func testOpenCodeQuestionAskedRendersCardAndAnswerRepliesInSession() async throws {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_abc","part":{}}"#,
            #"{"type":"question","sessionID":"ses_abc","requestID":"que_1","input":{"questions":[{"question":"主题色?","header":"主题","options":[{"label":"蓝","description":""},{"label":"绿","description":""}],"multiple":false}]}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )

        await session.send("配色")

        // 渲染成 assistant 时间线里的可点选询问，并带上 opencode 回传句柄 requestID。
        let assistant = try XCTUnwrap(session.messages.first { $0.role == .assistant })
        let record = try XCTUnwrap(assistant.questionTools.first)
        let question = record.question
        XCTAssertEqual(question.requestID, "que_1")
        XCTAssertEqual(question.questions.first?.options.map(\.label), ["蓝", "绿"])

        // 作答 → 经 streamer.reply 把答案回传给运行中的 agent（requestID + 选中 label 数组）。
        await session.answerQuestion(recordID: record.id, question: question, selections: [["蓝"]])
        XCTAssertEqual(streamer.replies.first?.requestID, "que_1")
        XCTAssertEqual(streamer.replies.first?.answers, [["蓝"]])
        XCTAssertEqual(
            session.messages.first { $0.id == assistant.id }?.questionTools.first?.resolution,
            .answered([["蓝"]])
        )
    }

    @MainActor
    func testOpenCodeQuestionStaysBetweenEarlierAndLaterAssistantText() async throws {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_order","part":{}}"#,
            #"{"type":"text","sessionID":"ses_order","part":{"text":"提问之前。"}}"#,
            #"{"type":"question","sessionID":"ses_order","requestID":"que_order","input":{"questions":[{"question":"继续吗？","header":"确认","options":[{"label":"继续"},{"label":"停止"}],"multiple":false}]}}"#,
            #"{"type":"text","sessionID":"ses_order","part":{"text":"提问之后。"}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )

        await session.send("测试顺序")

        let assistant = try XCTUnwrap(session.messages.first { $0.role == .assistant })
        let record = try XCTUnwrap(assistant.questionTools.first)
        XCTAssertEqual(MessagePresentation.assistantTimelineBlocks(in: assistant.text), [
            .init(block: .text("提问之前。"), count: 1),
            .init(block: .questionRef(id: record.id), count: 1),
            .init(block: .text("提问之后。"), count: 1)
        ])
    }

    @MainActor
    func testAgentSessionFallsBackToCLIWhenStreamingUnavailable() async {
        let streamer = FakeOpenCodeStreamer(.fail(OpenCodeStreamingError.unavailable("serve down")))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: #"{"type":"text","part":{"text":"FALLBACK"}}"# + "\n"),
            openCodeStreamer: streamer
        )

        await session.send("hi")

        // 流式建立失败 → 回退非流式 opencode run（runner）→ 拿到 CLI 路径产出的答案。
        XCTAssertEqual(session.messages.last?.role, .assistant)
        XCTAssertEqual(session.messages.last?.text, "FALLBACK")
        XCTAssertEqual(session.status, .idle)
    }

    @MainActor
    func testAgentSessionPassesContinueSessionIDOnSecondTurn() async {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_abc","part":{}}"#,
            #"{"type":"text","sessionID":"ses_abc","part":{"type":"text","text":"ok"}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: ""),
            openCodeStreamer: streamer
        )
        await session.send("one")
        await session.send("two")
        XCTAssertEqual(streamer.requests.count, 2)
        XCTAssertNil(streamer.requests.first?.continueSessionID)
        XCTAssertEqual(streamer.requests.last?.continueSessionID, "ses_abc") // 第二轮续接首轮会话
    }

    @MainActor
    func testOpenCodeSubagentBecomesClickableDetail() async throws {
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_sub","part":{}}"#,
            #"{"type":"text","sessionID":"ses_sub","part":{"type":"text","text":"我来委派一个子代理。"}}"#,
            #"{"type":"tool_use","sessionID":"ses_sub","part":{"type":"tool","id":"prt_1","callID":"call_1","tool":"task","state":{"status":"completed","input":{"subagent_type":"Explore","description":"检查项目结构","prompt":"统计模块并总结"},"output":"项目包含 3 个模块"}}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )

        await session.send("调用一个 Explore subagent 检查当前项目结构")

        let assistant = try XCTUnwrap(session.messages.first { $0.role == .assistant })
        XCTAssertEqual(assistant.subagentTasks.count, 1)
        let task = try XCTUnwrap(assistant.subagentTasks.first)
        XCTAssertEqual(task.id, "prt_1")
        XCTAssertEqual(task.agentType, "Explore")
        XCTAssertEqual(task.taskDescription, "检查项目结构")
        XCTAssertEqual(task.prompt, "统计模块并总结")
        XCTAssertEqual(task.result, "项目包含 3 个模块")
        XCTAssertFalse(task.isError)

        // 展示层据标记解析出可点击的委派行；且没有重复的普通「委派任务」工具行。
        let blocks = MessagePresentation.assistantBlocks(in: assistant.text)
        XCTAssertTrue(blocks.contains(.subagentRef(id: "prt_1", label: task.rowLabel)))
        XCTAssertFalse(blocks.contains(.toolCall("委派任务")))
    }

    @MainActor
    func testOpenCodeSubagentCompletedTwiceDoesNotDuplicate() async throws {
        // opencode 可能为同一 tool part 发两次 completed 快照：upsert 应只保留一行、仅更新结果。
        let streamer = FakeOpenCodeStreamer(.yield([
            #"{"type":"step_start","sessionID":"ses_dup","part":{}}"#,
            #"{"type":"tool_use","sessionID":"ses_dup","part":{"type":"tool","id":"prt_9","tool":"task","state":{"status":"completed","input":{"subagent_type":"Explore","description":"D","prompt":"P"},"output":"first"}}}"#,
            #"{"type":"tool_use","sessionID":"ses_dup","part":{"type":"tool","id":"prt_9","tool":"task","state":{"status":"completed","input":{"subagent_type":"Explore","description":"D","prompt":"P"},"output":"second"}}}"#
        ]))
        let session = AgentSession(
            agent: Self.openCodeConfig(),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: StubRunner(stdout: "X"),
            openCodeStreamer: streamer
        )

        await session.send("委派")

        let assistant = try XCTUnwrap(session.messages.first { $0.role == .assistant })
        XCTAssertEqual(assistant.subagentTasks.count, 1) // 不重复建任务
        XCTAssertEqual(assistant.subagentTasks.first?.result, "second") // 后一次结果覆盖
        let refs = MessagePresentation.assistantBlocks(in: assistant.text).filter {
            if case .subagentRef = $0 { return true }
            return false
        }
        XCTAssertEqual(refs.count, 1) // 只有一行委派
    }

    // MARK: - 真·端到端（默认跳过；设 AGENTDECK_LIVE_OPENCODE=1 且本机装了 opencode 才跑）

    func testLiveStreamingEndToEnd() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGENTDECK_LIVE_OPENCODE"] == "1",
            "实弹测试默认跳过（需联网 + provider）"
        )
        let executable = "/opt/homebrew/bin/opencode"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: executable), "本机未安装 opencode")

        let client = OpenCodeStreamingClient(server: OpenCodeServer())
        let request = OpenCodeStreamRequest(
            executable: executable,
            environment: [:],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            prompt: "Count from 1 to 30 separated by commas, then on a new line write the word DONE.",
            model: "opencode-go/deepseek-v4-flash",
            variant: nil,
            attachments: [],
            continueSessionID: nil,
            title: "agentdeck-live-test",
            thinking: false,
            stopSignal: .interrupt
        )

        let stream = try await client.stream(request)
        var answer = ""
        var textChunks = 0
        var sawSessionID = false
        let start = Date()
        var firstChunkAt: TimeInterval = 0
        var lastChunkAt: TimeInterval = 0
        for try await event in stream {
            guard case .stdout(let chunk) = event else { continue }
            for raw in chunk.split(separator: "\n") {
                guard let object = OpenCodeStreamWire.parseSSELine(String(raw)) else { continue }
                if object["sessionID"] != nil { sawSessionID = true }
                if object["type"] as? String == "text",
                   let part = object["part"] as? [String: Any],
                   let text = part["text"] as? String {
                    if textChunks == 0 { firstChunkAt = Date().timeIntervalSince(start) }
                    lastChunkAt = Date().timeIntervalSince(start)
                    answer += text
                    textChunks += 1
                }
            }
        }

        // 辅助观察真实 provider 的到达时间；短回答可能本身生成很快，不作为硬断言。
        print(String(format: "LIVE STREAM: textChunks=%d answerLen=%d first@%.2fs last@%.2fs span=%.2fs",
                     textChunks, answer.count, firstChunkAt, lastChunkAt, lastChunkAt - firstChunkAt))
        XCTAssertTrue(sawSessionID, "应至少捕获到一次 sessionID")
        XCTAssertTrue(answer.contains("DONE"), "流式累计文本应含 DONE，实际：\(answer)")
        // 真·流式的判据：答案应分多段增量到达，而不是一次性整段。
        XCTAssertGreaterThan(textChunks, 1, "应为多段增量(逐 token)，而非一次性整段；实测 \(textChunks) 段")
    }

    // MARK: - 用量计费(#28)

    func testTranslatorEmitsUsageResultLineOnIdle() {
        var translator = OpenCodeEventTranslator(sessionID: "s", thinking: false)
        let info: [String: Any] = [
            "sessionID": "s", "id": "m1", "role": "assistant", "cost": 0.0123,
            "tokens": ["input": 100, "output": 50, "reasoning": 5, "cache": ["read": 7, "write": 3]]
        ]
        _ = translator.translate(["type": "message.updated", "properties": ["info": info]])

        let idle = translator.translate(["type": "session.idle", "properties": ["sessionID": "s"]])
        XCTAssertTrue(idle.finished)
        XCTAssertEqual(idle.lines.count, 1)
        let turn = UsageCapture.turnUsage(fromJSONLine: idle.lines.first ?? "")
        XCTAssertEqual(turn?.inputTokens, 100)
        XCTAssertEqual(turn?.outputTokens, 55, "reasoning 计入输出")
        XCTAssertEqual(turn?.cacheReadTokens, 7)
        XCTAssertEqual(turn?.cacheCreationTokens, 3)
        XCTAssertEqual(turn?.costUSD ?? 0, 0.0123, accuracy: 0.000_001)

        let again = translator.translate(["type": "session.idle", "properties": ["sessionID": "s"]])
        XCTAssertTrue(again.lines.isEmpty, "发出即清空,不重复计量")
    }

    func testTranslatorIgnoresUserMessageUsageAndOtherSessions() {
        var translator = OpenCodeEventTranslator(sessionID: "s", thinking: false)
        let userInfo: [String: Any] = [
            "sessionID": "s", "id": "u1", "role": "user",
            "cost": 9.9, "tokens": ["input": 1, "output": 1, "reasoning": 0]
        ]
        let foreignInfo: [String: Any] = [
            "sessionID": "other", "id": "m9", "role": "assistant",
            "cost": 9.9, "tokens": ["input": 1, "output": 1, "reasoning": 0]
        ]
        _ = translator.translate(["type": "message.updated", "properties": ["info": userInfo]])
        _ = translator.translate(["type": "message.updated", "properties": ["info": foreignInfo]])
        let idle = translator.translate(["type": "session.idle", "properties": ["sessionID": "s"]])
        XCTAssertTrue(idle.lines.isEmpty)
    }

    // MARK: - 测试夹具

    static func openCodeConfig() -> AgentConfig {
        AgentConfig(
            id: "opencode", name: "OpenCode", command: "/usr/bin/opencode", args: ["run"], env: [:],
            workingDirectoryPolicy: .workspace, inputMode: .oneShotArgument, outputMode: .jsonLines,
            supportsStop: true, stopSignal: .interrupt
        )
    }

    private func messageUpdated(id: String, role: String) -> [String: Any] {
        ["type": "message.updated", "properties": ["info": ["sessionID": "s", "id": id, "role": role]]]
    }

    private func textPart(messageID: String, id: String, text: String, hasTime: Bool) -> [String: Any] {
        var part: [String: Any] = ["sessionID": "s", "type": "text", "id": id, "messageID": messageID, "text": text]
        if hasTime { part["time"] = ["start": 1, "end": 2] }
        return ["type": "message.part.updated", "properties": ["part": part]]
    }

    private func reasoningPart(messageID: String, id: String, text: String) -> [String: Any] {
        let part: [String: Any] = [
            "sessionID": "s", "type": "reasoning", "id": id, "messageID": messageID,
            "text": text, "time": ["start": 1, "end": 2]
        ]
        return ["type": "message.part.updated", "properties": ["part": part]]
    }

    private func toolPart(id: String, status: String) -> [String: Any] {
        let part: [String: Any] = [
            "sessionID": "s", "type": "tool", "id": id, "messageID": "m1", "tool": "read",
            "state": ["status": status, "input": ["filePath": "/tmp/x"]]
        ]
        return ["type": "message.part.updated", "properties": ["part": part]]
    }

    private func questionAsked(requestID: String) -> [String: Any] {
        ["type": "question.asked", "properties": [
            "id": requestID, "sessionID": "s",
            "questions": [[
                "question": "继续吗？", "header": "确认",
                "options": [["label": "是", "description": ""], ["label": "否", "description": ""]],
                "multiple": false
            ]]
        ]]
    }

    private func sessionStatus(type: String) -> [String: Any] {
        ["type": "session.status", "properties": ["sessionID": "s", "status": ["type": type]]]
    }

    /// 通用的 message.part.updated（可指定部件类型），用于注册 partID→type 及全量兜底。
    private func partUpdated(messageID: String, id: String, type: String, text: String) -> [String: Any] {
        let part: [String: Any] = [
            "sessionID": "s", "type": type, "id": id, "messageID": messageID,
            "text": text, "time": ["start": 1]
        ]
        return ["type": "message.part.updated", "properties": ["part": part]]
    }

    /// 逐 token 流式事件：field 恒为 "text"，delta 为增量。
    private func partDelta(partID: String, delta: String) -> [String: Any] {
        ["type": "message.part.delta",
         "properties": ["sessionID": "s", "partID": partID, "field": "text", "delta": delta]]
    }

    private func decodedPartText(_ line: String?) -> String? {
        guard let line, let object = OpenCodeStreamWire.parseSSELine(line),
              let part = object["part"] as? [String: Any] else { return nil }
        return part["text"] as? String
    }
}

// MARK: - 测试替身

/// 假的 opencode 流式通道：要么按给定的 JSON 行逐条产出，要么在建立阶段抛错（验证回退）。
private final class FakeOpenCodeStreamer: OpenCodeStreaming, @unchecked Sendable {
    enum Behavior {
        case yield([String])
        case fail(Error)
    }

    private let behavior: Behavior
    private let lock = NSLock()
    private var storedRequests: [OpenCodeStreamRequest] = []
    private var storedReplies: [(requestID: String, answers: [[String]])] = []
    private var storedRejects: [String] = []

    init(_ behavior: Behavior) { self.behavior = behavior }

    var requests: [OpenCodeStreamRequest] { lock.withLock { storedRequests } }
    var firstRequest: OpenCodeStreamRequest? { requests.first }
    var replies: [(requestID: String, answers: [[String]])] { lock.withLock { storedReplies } }
    var rejects: [String] { lock.withLock { storedRejects } }

    func stream(_ request: OpenCodeStreamRequest) async throws -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        lock.withLock { storedRequests.append(request) }
        switch behavior {
        case .fail(let error):
            throw error
        case .yield(let lines):
            return AsyncThrowingStream { continuation in
                for line in lines { continuation.yield(.stdout(line + "\n")) }
                continuation.yield(.exit(0))
                continuation.finish()
            }
        }
    }

    func replyToQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String, answers: [[String]]
    ) async {
        lock.withLock { storedReplies.append((requestID, answers)) }
    }

    func rejectQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String
    ) async {
        lock.withLock { storedRejects.append(requestID) }
    }
}

/// 最小 runner 替身：只实现 runOneShot，stream 走协议默认「伪流式」。用于验证回退路径。
private struct StubRunner: AgentRunning {
    let stdout: String

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
