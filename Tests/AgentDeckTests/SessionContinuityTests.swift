import XCTest
@testable import AgentDeckApp

/// SessionContinuity 直测(#25 第一步抽出;此前这些逻辑只能经 AgentSession 集成测试间接覆盖)。
final class SessionContinuityTests: XCTestCase {
    // MARK: - modelKey

    func testModelKeyTrimsAndDefaultsEmpty() {
        XCTAssertEqual(SessionContinuity.modelKey("  opus  "), "opus")
        XCTAssertEqual(SessionContinuity.modelKey(""), "default")
        XCTAssertEqual(SessionContinuity.modelKey("   "), "default")
    }

    // MARK: - 会话 id 捕获

    func testCapturesClaudeSessionIDAcrossChunkBoundary() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: #"{"type":"system","session_id":"abc"#, modelKey: "default")
        XCTAssertNil(continuity.backendSessionID, "行未完整(无换行)不应解析")
        continuity.captureBackendSessionID(from: "-123\"}\n", modelKey: "default")
        XCTAssertEqual(continuity.backendSessionID, "abc-123")
        XCTAssertEqual(continuity.backendSessionModel, "default")
    }

    func testFlushCapturesTrailingLineWithoutNewline() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: #"{"session_id":"tail-1"}"#, modelKey: "default")
        XCTAssertNil(continuity.backendSessionID)
        continuity.flushBackendSessionCapture(modelKey: "default")
        XCTAssertEqual(continuity.backendSessionID, "tail-1")
    }

    func testCapturesOpenCodeAndCodexSessionIDs() {
        var openCode = SessionContinuity(agentKind: .openCode)
        openCode.captureBackendSessionID(from: "{\"sessionID\":\"ses_x\"}\n", modelKey: "default")
        XCTAssertEqual(openCode.backendSessionID, "ses_x")

        var codex = SessionContinuity(agentKind: .codex)
        codex.captureBackendSessionID(from: "{\"type\":\"other\",\"thread_id\":\"no\"}\n", modelKey: "default")
        XCTAssertNil(codex.backendSessionID, "codex 仅认 thread.started")
        codex.captureBackendSessionID(from: "{\"type\":\"thread.started\",\"thread_id\":\"th_1\"}\n", modelKey: "default")
        XCTAssertEqual(codex.backendSessionID, "th_1")
    }

    func testPiKindNeverCaptures() {
        var continuity = SessionContinuity(agentKind: .pi)
        continuity.captureBackendSessionID(from: "{\"session_id\":\"x\"}\n", modelKey: "default")
        continuity.flushBackendSessionCapture(modelKey: "default")
        XCTAssertNil(continuity.backendSessionID)
    }

    func testFirstCapturedSessionIDWins() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: "{\"session_id\":\"first\"}\n{\"session_id\":\"second\"}\n", modelKey: "default")
        XCTAssertEqual(continuity.backendSessionID, "first")
    }

    // MARK: - resolvedModel 捕获

    func testResolvedModelFromTopLevelAndMessageFallback() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: "{\"message\":{\"model\":\"mimo-v2.5\"}}\n", modelKey: "default")
        XCTAssertEqual(continuity.resolvedModel, "mimo-v2.5", "回退 assistant 的 message.model")

        var top = SessionContinuity(agentKind: .claudeCode)
        top.captureBackendSessionID(from: "{\"model\":\"claude-opus-4-8\",\"session_id\":\"s\"}\n", modelKey: "default")
        XCTAssertEqual(top.resolvedModel, "claude-opus-4-8")

        top.clearResolvedModel()
        XCTAssertNil(top.resolvedModel)
    }

    func testResolvedModelOnlyForClaude() {
        var continuity = SessionContinuity(agentKind: .openCode)
        continuity.captureBackendSessionID(from: "{\"model\":\"x\",\"sessionID\":\"s\"}\n", modelKey: "default")
        XCTAssertNil(continuity.resolvedModel)
    }

    // MARK: - 模型切换失效

    func testModelSwitchInvalidatesSessionAndPendingBufferForCodex() {
        var continuity = SessionContinuity(agentKind: .codex)
        continuity.captureBackendSessionID(
            from: "{\"type\":\"thread.started\",\"thread_id\":\"keep\"}\n",
            modelKey: "gpt-5"
        )
        XCTAssertEqual(continuity.externalSessionIDForInvocation(modelKey: "gpt-5"), "keep", "同模型可续用")

        // 残留半行 + 切换模型 → 会话 id 与缓冲都应作废(codex 会话与模型的绑定关系未证实,保守失效)
        continuity.captureBackendSessionID(from: "{\"type\":\"thread.started\",\"thread_id\":\"sta", modelKey: "gpt-5")
        XCTAssertNil(continuity.externalSessionIDForInvocation(modelKey: "gpt-5-mini"))
        XCTAssertEqual(continuity.backendSessionModel, "gpt-5-mini")
        continuity.captureBackendSessionID(from: "le\"}\n", modelKey: "gpt-5-mini")
        XCTAssertNil(continuity.backendSessionID, "切换后旧缓冲不应拼出 stale id")
    }

    func testClaudeModelSwitchKeepsBackendSession() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: "{\"session_id\":\"keep\"}\n", modelKey: "opus")
        XCTAssertEqual(
            continuity.externalSessionIDForInvocation(modelKey: "haiku"),
            "keep",
            "claude --resume 跨模型合法(2026-06-10 实测同 id 续聊成功),切模型不应丢上下文"
        )
        XCTAssertEqual(continuity.backendSessionModel, "haiku", "key 跟随新模型,避免之后每轮重复走切换分支")
    }

    // MARK: - Claude 续聊策略

    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    func testStrategyIsNoneForNonClaudeOrNonNewCommand() {
        var openCode = SessionContinuity(agentKind: .openCode)
        XCTAssertEqual(
            openCode.claudeStrategy(for: "hi", command: .new, modelKey: "default", messages: [message(.user, "old")]),
            .none
        )
        var claude = SessionContinuity(agentKind: .claudeCode)
        XCTAssertEqual(
            claude.claudeStrategy(for: "hi", command: .resume, modelKey: "default", messages: [message(.user, "old")]),
            .none
        )
    }

    func testStrategyPrefersNativeResume() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        continuity.captureBackendSessionID(from: "{\"session_id\":\"live\"}\n", modelKey: "default")
        let strategy = continuity.claudeStrategy(
            for: "下一步?",
            command: .new,
            modelKey: "default",
            messages: [message(.user, "之前的问题"), message(.assistant, "之前的回答")]
        )
        XCTAssertEqual(strategy, .nativeResume("live"))
        XCTAssertEqual(strategy.externalSessionID, "live")
    }

    func testStrategyFallsBackToLocalReplayThenNone() {
        var continuity = SessionContinuity(agentKind: .claudeCode)
        XCTAssertEqual(
            continuity.claudeStrategy(
                for: "下一步?",
                command: .new,
                modelKey: "default",
                messages: [message(.user, "之前的问题"), message(.assistant, "之前的回答")]
            ),
            .localTranscriptReplay,
            "无后端会话但有本地历史 → 回放"
        )
        XCTAssertEqual(
            continuity.claudeStrategy(for: "你好", command: .new, modelKey: "default", messages: []),
            .none,
            "无任何历史 → 全新开场"
        )
        XCTAssertEqual(
            continuity.claudeStrategy(
                for: "你好",
                command: .new,
                modelKey: "default",
                messages: [message(.user, "你好")]
            ),
            .none,
            "历史只剩当前这条 prompt → 不算可回放历史"
        )
    }

    // MARK: - 本地转录

    func testTranscriptExcludesCurrentPromptDedupsAndOrders() {
        let messages = [
            message(.user, "第一问"),
            message(.assistant, "第一答"),
            message(.assistant, "第一答"), // 重复应去重
            message(.system, "系统噪声不该进转录"),
            message(.user, "当前问题")
        ]
        let transcript = SessionContinuity.localHistoryTranscript(
            messages: messages,
            excludingUserPrompt: "当前问题"
        )
        XCTAssertNotNil(transcript)
        let text = transcript ?? ""
        XCTAssertTrue(text.contains("user:\n第一问"))
        XCTAssertTrue(text.contains("assistant:\n第一答"))
        XCTAssertFalse(text.contains("当前问题"))
        XCTAssertFalse(text.contains("系统噪声"))
        XCTAssertEqual(text.components(separatedBy: "第一答").count, 2, "重复消息只保留一份")
        XCTAssertLessThan(
            text.range(of: "第一问")!.lowerBound,
            text.range(of: "第一答")!.lowerBound,
            "时间顺序应为先问后答"
        )
    }

    func testTranscriptStripsThinkingBlocksAndKeepsTail() {
        let messages = [
            message(.assistant, "<think>内心戏</think>结论在此"),
            message(.user, "当前")
        ]
        let transcript = SessionContinuity.localHistoryTranscript(messages: messages, excludingUserPrompt: "当前")
        XCTAssertEqual(transcript, "assistant:\n结论在此")
    }

    func testTranscriptHonorsMaxMessagesAndTruncation() {
        let many = (1...12).map { message(.user, "消息\($0)") }
        let capped = SessionContinuity.localHistoryTranscript(
            messages: many,
            excludingUserPrompt: "当前",
            maxMessages: 3
        ) ?? ""
        XCTAssertFalse(capped.contains("消息9"), "只保留最近 maxMessages 条")
        XCTAssertTrue(capped.contains("消息12"))

        let long = [message(.assistant, String(repeating: "长", count: 600))]
        let truncated = SessionContinuity.localHistoryTranscript(
            messages: long,
            excludingUserPrompt: "当前",
            maxCharacters: 100
        ) ?? ""
        XCTAssertTrue(truncated.hasPrefix("[Earlier local transcript truncated]\n"))
    }

    // MARK: - promptForInvocation

    func testPromptWrapsHistoryOnlyForLocalReplay() {
        let messages = [message(.user, "旧问"), message(.assistant, "旧答")]
        let wrapped = SessionContinuity.promptForInvocation(
            "新问题",
            strategy: .localTranscriptReplay,
            agentKind: .claudeCode,
            command: .new,
            messages: messages
        )
        XCTAssertTrue(wrapped.contains("<agentdeck_history>"))
        XCTAssertTrue(wrapped.contains("旧答"))
        XCTAssertTrue(wrapped.hasSuffix("新问题"))

        XCTAssertEqual(
            SessionContinuity.promptForInvocation(
                "新问题",
                strategy: .nativeResume("id"),
                agentKind: .claudeCode,
                command: .new,
                messages: messages
            ),
            "新问题",
            "原生 resume 不包历史"
        )
    }

    // MARK: - opencode 会话标题

    func testConversationTitleOnlyForNewOpenCodeWithoutExternalID() {
        let uuid = UUID()
        let openCode = SessionContinuity(agentKind: .openCode)
        XCTAssertEqual(
            openCode.conversationTitle(externalSessionID: nil, command: .new, sessionUUID: uuid),
            "AgentDeck \(uuid.uuidString)"
        )
        XCTAssertNil(openCode.conversationTitle(externalSessionID: "ses", command: .new, sessionUUID: uuid))
        XCTAssertNil(openCode.conversationTitle(externalSessionID: nil, command: .continueLast, sessionUUID: uuid))
        let claude = SessionContinuity(agentKind: .claudeCode)
        XCTAssertNil(claude.conversationTitle(externalSessionID: nil, command: .new, sessionUUID: uuid))
    }
}
