import XCTest
@testable import AgentDeckApp

@MainActor
final class AgentSessionTests: XCTestCase {
    func testSessionAppendsUserAndAssistantMessages() async {
        let config = AgentConfig(
            id: "echo",
            name: "Echo",
            command: "/bin/echo",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "hello\n", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("hello")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["hello", "hello\n"])
        XCTAssertEqual(session.status, .idle)
    }

    func testAssistantMessageRecordsRunTiming() async {
        let config = AgentConfig(
            id: "timed",
            name: "Timed",
            command: "/bin/echo",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(stdout: "<think>working</think>done", stderr: "", exitCode: 0)
        )

        await session.send("time this")

        let assistant = session.messages.first { $0.role == .assistant }
        XCTAssertNotNil(assistant?.runStartedAt)
        XCTAssertNotNil(assistant?.runEndedAt)
        XCTAssertGreaterThanOrEqual(
            assistant?.runEndedAt?.timeIntervalSince(assistant?.runStartedAt ?? .distantFuture) ?? -1,
            0
        )
    }

    func testSessionAppendsChangedFileLinksAfterRun() async {
        let config = AgentConfig(
            id: "echo",
            name: "Echo",
            command: "/bin/echo",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: URL(filePath: "/tmp/project"),
            runner: RecordingAgentRunner(stdout: "done", stderr: "", exitCode: 0),
            changeTracker: StaticChangeTracker(paths: ["Sources/App.swift", "README.md"])
        )

        await session.send("change files")

        let linkMessage = session.messages.last
        XCTAssertEqual(linkMessage?.role, .system)
        XCTAssertEqual(linkMessage?.fileLinks, ["README.md", "Sources/App.swift"])
        XCTAssertEqual(linkMessage?.text, "改动文件：\n- README.md\n- Sources/App.swift")
    }

    func testSessionOnlyReportsFilesChangedDuringCurrentRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try runGit(["init"], in: root)
        try runGit(["config", "user.email", "agentdeck@example.test"], in: root)
        try runGit(["config", "user.name", "AgentDeck Tests"], in: root)
        try "base".write(to: root.appending(path: "committed.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "committed.md"], in: root)
        try runGit(["commit", "-m", "initial"], in: root)

        try "preexisting".write(to: root.appending(path: "old.md"), atomically: true, encoding: .utf8)

        let config = AgentConfig(
            id: "writer",
            name: "Writer",
            command: "/bin/echo",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: root,
            runner: WritingAgentRunner(relativePath: "new.md", contents: "current run"),
            changeTracker: GitWorkspaceChangeTracker()
        )

        await session.send("write a file")

        XCTAssertEqual(session.messages.last?.role, .system)
        XCTAssertEqual(session.messages.last?.fileLinks, ["new.md"])
        XCTAssertEqual(session.messages.last?.text, "改动文件：\n- new.md")
    }

    func testEmptyPromptDoesNotAppendOrRun() async {
        let config = AgentConfig(
            id: "empty",
            name: "Empty",
            command: "/bin/echo",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send(" \n\t ")

        XCTAssertEqual(session.messages, [])
        XCTAssertEqual(session.status, .idle)
        let calls = await runner.calls()
        XCTAssertEqual(calls, [])
    }

    func testStdinInputModeSendsPromptViaStdin() async {
        let config = AgentConfig(
            id: "stdin",
            name: "Stdin",
            command: "/usr/bin/agent",
            args: ["--model", "test"],
            env: ["AGENT": "1"],
            workingDirectoryPolicy: .workspace,
            inputMode: .stdin,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "response", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("explain this")

        let calls = await runner.calls()
        XCTAssertEqual(calls, [
            AgentRunCall(
                command: "/usr/bin/agent",
                args: ["--model", "test"],
                environment: ["AGENT": "1"],
                workingDirectory: FileManager.default.temporaryDirectory,
                stdin: "explain this"
            )
        ])
    }

    func testOneShotArgumentAppendsPromptAndDoesNotPassStdin() async {
        let config = AgentConfig(
            id: "argv",
            name: "Argv",
            command: "/usr/bin/agent",
            args: ["--json"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "response", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("summarize")

        let calls = await runner.calls()
        XCTAssertEqual(calls.map(\.args), [["--json", "summarize"]])
        XCTAssertEqual(calls.map(\.stdin), [nil])
    }

    func testSendBuildsCodexCLIOptionsForModelReasoningAndCommand() async {
        // id "codex" → kind .codex，使用 codex exec 的参数约定。
        let config = AgentConfig(
            id: "codex",
            name: "Codex",
            command: "/usr/bin/codex",
            args: ["exec"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "response", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )
        session.model = "gpt-5"
        session.reasoningEffort = .high
        session.interactionMode = .plan
        session.command = .resume

        await session.send("continue this")

        let calls = await runner.calls()
        XCTAssertEqual(calls.map(\.args), [[
            "exec",
            "resume",
            "-m", "gpt-5",
            "-c", "model_reasoning_effort=high",
            "continue this"
        ]])
    }

    func testClaudeSendDoesNotPinAgentDeckConversationID() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let runner = RecordingAgentRunner(stdout: "ok", stderr: "", exitCode: 0)
        let session = AgentSession(
            id: sessionID,
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("first")
        await session.send("second")

        let calls = await runner.calls()
        XCTAssertEqual(calls.first?.args, [
            "-p", "--permission-mode", "bypassPermissions", "first"
        ])
        XCTAssertEqual(calls[1].args.first, "-p")
        XCTAssertFalse(calls[1].args.contains("--session-id"))
        XCTAssertFalse(calls[1].args.contains(sessionID.uuidString))
        XCTAssertTrue((calls[1].args.last ?? "").contains("Current user request:\nsecond"))
    }

    func testClaudeSecondSendResumesCapturedClaudeSessionID() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p", "--output-format", "stream-json", "--verbose"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = ClaudeSessionIDRunner(sessionID: "claude-session-abc")
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("first")
        await session.send("second")

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].args, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions", "first"
        ])
        XCTAssertEqual(calls[1].args, [
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--permission-mode",
            "bypassPermissions",
            "--resume",
            "claude-session-abc",
            "second"
        ])
        XCTAssertFalse(calls[1].args.contains("--session-id"))
        XCTAssertEqual(session.backendSessionID, "claude-session-abc")
        // 从 system/init 行捕获实际解析到的模型（别名/默认运行时才解析为具体版本）。
        XCTAssertEqual(session.resolvedModel, "claude-opus-4-8")
    }

    func testClaudeWithoutBackendSessionReplaysLocalHistoryOnNextSend() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = ClaudeSessionIDRunner(sessionID: "claude-session-replayed")
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            messages: [
                ChatMessage(role: .user, text: "first question"),
                ChatMessage(role: .assistant, text: "first answer")
            ],
            runner: runner
        )

        await session.send("second question")

        let calls = await runner.calls()
        let sentPrompt = calls.first?.args.last ?? ""
        XCTAssertEqual(calls.first?.args.first, "-p")
        XCTAssertTrue(sentPrompt.contains("<agentdeck_history>"))
        XCTAssertTrue(sentPrompt.contains("user:\nfirst question"))
        XCTAssertTrue(sentPrompt.contains("assistant:\nfirst answer"))
        XCTAssertTrue(sentPrompt.contains("Current user request:\nsecond question"))
        XCTAssertEqual(session.backendSessionID, "claude-session-replayed")
        XCTAssertEqual(Array(session.messages.map(\.text).prefix(3)), ["first question", "first answer", "second question"])
    }

    func testClaudeResumeFailureFallsBackToLocalHistoryReplay() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p", "--output-format", "stream-json", "--verbose"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = ClaudeResumeFailureThenReplayRunner()
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("first")
        await session.send("second")

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 3)
        guard calls.count == 3 else { return }
        XCTAssertEqual(calls[0].args, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions", "first"
        ])
        XCTAssertEqual(calls[1].args, [
            "-p", "--output-format", "stream-json", "--verbose",
            "--permission-mode", "bypassPermissions",
            "--resume", "stale-claude-session", "second"
        ])
        XCTAssertFalse(calls[2].args.contains("--resume"))
        let fallbackPrompt = calls[2].args.last ?? ""
        XCTAssertTrue(fallbackPrompt.contains("<agentdeck_history>"))
        XCTAssertTrue(fallbackPrompt.contains("user:\nfirst"))
        XCTAssertTrue(fallbackPrompt.contains("assistant:\nok"))
        XCTAssertTrue(fallbackPrompt.contains("Current user request:\nsecond"))
        XCTAssertFalse(session.messages.contains { $0.role == .error && $0.text.contains("No conversation found") })
        XCTAssertEqual(session.backendSessionID, "fresh-claude-session")
        XCTAssertEqual(session.status, .idle)
    }

    func testClaudeLocalHistoryReplayStripsThinkingAndSkipsDuplicateCurrentPrompt() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = ClaudeSessionIDRunner(sessionID: "claude-session-sanitized")
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            messages: [
                ChatMessage(role: .user, text: "repeat prompt"),
                ChatMessage(role: .assistant, text: "<think>hidden chain</think>visible answer"),
                ChatMessage(role: .user, text: "repeat prompt")
            ],
            runner: runner
        )

        await session.send("repeat prompt")

        let calls = await runner.calls()
        let sentPrompt = calls.first?.args.last ?? ""
        XCTAssertTrue(sentPrompt.contains("assistant:\nvisible answer"))
        XCTAssertFalse(sentPrompt.contains("hidden chain"))
        XCTAssertFalse(sentPrompt.contains("user:\nrepeat prompt"))
    }

    func testClaudeLocalHistoryReplayIsCapped() async {
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = ClaudeSessionIDRunner(sessionID: "claude-session-capped")
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            messages: [
                ChatMessage(role: .user, text: "prior"),
                ChatMessage(role: .assistant, text: String(repeating: "a", count: 8_000))
            ],
            runner: runner
        )

        await session.send("next")

        let calls = await runner.calls()
        let sentPrompt = calls.first?.args.last ?? ""
        XCTAssertLessThan(sentPrompt.count, 5_000)
        XCTAssertTrue(sentPrompt.contains("[Earlier local transcript truncated]"))
        XCTAssertTrue(sentPrompt.contains("Current user request:\nnext"))
    }

    func testOpenCodeSecondSendUsesCapturedSessionIDInsteadOfGlobalContinue() async {
        let config = AgentConfig(
            id: "opencode",
            name: "OpenCode",
            command: "/usr/bin/opencode",
            args: ["run"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let sessionID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
        let externalTitle = "AgentDeck \(sessionID.uuidString)"
        let runner = OpenCodeSessionRunner(sessionID: "ses_agentdeck_window")
        let session = AgentSession(
            id: sessionID,
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("first")
        await session.send("second")

        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].args, ["run", "--format", "json", "--thinking", "--title", externalTitle, "first"])
        XCTAssertEqual(calls[1].args, ["run", "--format", "json", "--thinking", "-s", "ses_agentdeck_window", "second"])
        XCTAssertFalse(calls[1].args.contains("-c"))
    }

    func testCodexSecondSendUsesCapturedThreadIDInsteadOfLastSession() async {
        let config = AgentConfig(
            id: "codex",
            name: "Codex",
            command: "/usr/bin/codex",
            args: ["exec"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let runner = CodexThreadRunner(threadID: "thread_agentdeck_window")
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("first")
        await session.send("second")

        let calls = await runner.calls()
        XCTAssertEqual(calls.map(\.args), [
            ["exec", "--json", "first"],
            ["exec", "resume", "--json", "thread_agentdeck_window", "second"]
        ])
        XCTAssertFalse(calls[1].args.contains("--last"))
    }

    func testZeroExitWithStderrOnlyCreatesAssistantMessage() async {
        let config = AgentConfig(
            id: "stderr",
            name: "Stderr",
            command: "/bin/sh",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(stdout: "", stderr: "warning\n", exitCode: 0)
        )

        await session.send("hello")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["hello", "warning\n"])
        XCTAssertEqual(session.status, .idle)
    }

    func testThrownRunnerErrorSetsFailed() async {
        let config = AgentConfig(
            id: "throwing",
            name: "Throwing",
            command: "/missing",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(error: TestRunnerError.failed)
        )

        await session.send("hello")

        XCTAssertEqual(session.status, .failed("runner failed"))
    }

    func testSessionReportsNonzeroExit() async {
        let config = AgentConfig(
            id: "bad",
            name: "Bad",
            command: "/bin/sh",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(stdout: "", stderr: "failed", exitCode: 2)
        )

        await session.send("hello")

        XCTAssertEqual(session.status, .failed("Exited with code 2: failed"))
    }

    func testNonzeroExitFallsBackToStdoutWhenStderrIsEmpty() async {
        let config = AgentConfig(
            id: "bad-stdout",
            name: "Bad Stdout",
            command: "/bin/sh",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(stdout: "stdout detail", stderr: "", exitCode: 3)
        )

        await session.send("hello")

        XCTAssertEqual(session.status, .failed("Exited with code 3: stdout detail"))
    }

    func testNonzeroExitAppendsErrorRoleMessage() async {
        let config = AgentConfig(
            id: "bad-msg", name: "Bad", command: "/bin/sh", args: [], env: [:],
            workingDirectoryPolicy: .workspace, inputMode: .oneShotArgument, outputMode: .stream,
            supportsStop: true, stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: RecordingAgentRunner(stdout: "", stderr: "boom", exitCode: 1)
        )

        await session.send("go")

        // 失败原因作为 .error 角色消息进入聊天（UI 渲染为红色）。
        XCTAssertTrue(session.messages.contains { $0.role == .error && $0.text.contains("boom") })
    }

    func testJSONLinesErrorEventUsesErrorRole() async {
        let runner = ChunkedRunner(events: [
            .stdout("{\"type\":\"error\",\"text\":\"模型不可用\"}\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: streamingConfig(id: "jsonl-err", outputMode: .jsonLines),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            runner: runner
        )

        await session.send("go")

        XCTAssertTrue(session.messages.contains { $0.role == .error && $0.text == "模型不可用" })
    }

    func testAskUserQuestionStreamAppendsQuestionCardMessage() async {
        let runner = ChunkedRunner(events: [
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"q1","name":"AskUserQuestion","input":{}}}}"# + "\n"),
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"questions\":[{\"header\":\"鉴权\",\"question\":\"用哪种？\",\"multiSelect\":false,\"options\":[{\"label\":\"OAuth\"},{\"label\":\"API Key\"}]}]}"}}}"# + "\n"),
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"# + "\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: streamingConfig(id: "ask-q", outputMode: .jsonLines),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            runner: runner
        )

        await session.send("go")

        let questionMessage = session.messages.first { $0.kind == .question }
        XCTAssertNotNil(questionMessage, "AskUserQuestion 应渲染为一条 question 卡片消息")
        XCTAssertEqual(questionMessage?.question?.questions.first?.options.map(\.label), ["OAuth", "API Key"])
    }

    func testSubagentDelegationAndResultPopulateMessageTasks() async {
        let runner = ChunkedRunner(events: [
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_7","name":"Task","input":{}}}}"# + "\n"),
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"subagent_type\":\"Explore\",\"description\":\"调研\",\"prompt\":\"去查\"}"}}}"# + "\n"),
            .stdout(#"{"type":"stream_event","event":{"type":"content_block_stop","index":0}}"# + "\n"),
            .stdout(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_7","content":"调研结果"}]}}"# + "\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: streamingConfig(id: "sub", outputMode: .jsonLines),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            runner: runner
        )

        await session.send("帮我委派")

        let assistant = session.messages.first { $0.role == .assistant }
        let task = assistant?.subagentTasks.first
        XCTAssertEqual(task?.id, "toolu_7")
        XCTAssertEqual(task?.agentType, "Explore")
        XCTAssertEqual(task?.taskDescription, "调研")
        XCTAssertEqual(task?.prompt, "去查")
        XCTAssertEqual(task?.result, "调研结果") // tool_result 回填到任务
        // 文本里嵌了子任务标记（展示层据此解出可点击的「委派任务」行）。
        XCTAssertTrue(assistant?.text.contains("\u{1F}sub\u{1F}toolu_7") ?? false)
    }

    func testStopDuringStartupSnapshotCancelsBeforeLaunchingRunner() async {
        let tracker = SlowSnapshotChangeTracker()
        let runner = RecordingAgentRunner(stdout: "should not launch", stderr: "", exitCode: 0)
        let session = AgentSession(
            agent: streamingConfig(id: "startup-stop", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner,
            changeTracker: tracker
        )

        let sendTask = Task { await session.send("go") }
        await tracker.waitUntilSnapshotStarted()
        XCTAssertTrue(session.isRunning)

        session.stop()
        await tracker.releaseSnapshot()
        await sendTask.value

        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty, "Stop during baseline capture must not launch the agent process")
        XCTAssertEqual(session.messages.map(\.role), [.user, .system])
        XCTAssertEqual(session.messages.map(\.text), ["go", "已停止。"])
        XCTAssertEqual(session.status, .failed("已停止。"))
        XCTAssertEqual(session.lastChangedPaths, [])
        XCTAssertNil(session.lastTurnDiffSummary)
    }

    func testSendWhileRunningIsIgnored() async {
        let config = AgentConfig(
            id: "slow",
            name: "Slow",
            command: "/bin/sleep",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let runner = RecordingAgentRunner(stdout: "done", stderr: "", exitCode: 0, suspendsUntilReleased: true)
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )
        let firstSend = Task {
            await session.send("first")
        }
        await runner.waitUntilCalled()

        await session.send("second")

        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.messages.map(\.text), ["first"])
        let calls = await runner.calls()
        XCTAssertEqual(calls.map(\.args), [["first"]])

        await runner.release()
        await firstSend.value
        XCTAssertEqual(session.messages.map(\.text), ["first", "done"])
        XCTAssertEqual(session.status, .idle)
    }

    func testStreamingChunksAccumulateIntoSingleAssistantMessage() async {
        let config = streamingConfig(id: "stream-agent", outputMode: .stream)
        let runner = ChunkedRunner(events: [.stdout("Hel"), .stdout("lo, "), .stdout("world"), .exit(0)])
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("hi")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["hi", "Hello, world"])
        XCTAssertEqual(session.status, .idle)
    }

    func testJSONLinesStreamSplitsStatusAndMessageBubbles() async {
        let config = streamingConfig(id: "jsonl-agent", outputMode: .jsonLines)
        let runner = ChunkedRunner(events: [
            .stdout("{\"type\":\"status\",\"text\":\"working\"}\n"),
            .stdout("{\"type\":\"message\",\"text\":\"Hello\"}\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("hi")

        XCTAssertEqual(session.messages.map(\.role), [.user, .system, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["hi", "working", "Hello"])
        XCTAssertEqual(session.status, .idle)
    }

    func testJSONLinesToolEventsAttachToCurrentAssistantMessage() async {
        let config = streamingConfig(id: "jsonl-tool-agent", outputMode: .jsonLines)
        let runner = ChunkedRunner(events: [
            .stdout(#"{"type":"reasoning","part":{"text":"checking files"}}"# + "\n"),
            .stdout(#"{"type":"tool_use","part":{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"/tmp/a.swift"},"output":"large output"}}}"# + "\n"),
            .stdout(#"{"type":"message","text":"Done"}"# + "\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("inspect")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        // 工具调用以内联标记嵌进文本流，按时间顺序穿插在思考块与正文之间（不再单列 toolCalls）。
        XCTAssertTrue(session.messages[1].toolCalls.isEmpty)
        XCTAssertEqual(MessagePresentation.assistantBlocks(in: session.messages[1].text), [
            .thinking("checking files"),
            .toolCall("读取 /tmp/a.swift"),
            .text("Done")
        ])
        XCTAssertEqual(session.status, .idle)
    }

    func testClaudeToolResultErrorStaysAtChronologicalAssistantPosition() async {
        let config = streamingConfig(id: "claude-tool-error-agent", outputMode: .jsonLines)
        let runner = ChunkedRunner(events: [
            .stdout(#"{"type":"message","text":"准备运行。"}"# + "\n"),
            .stdout(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Exit code 1"}]}}"# + "\n"),
            .stdout(#"{"type":"message","text":"改用 zsh 后成功。"}"# + "\n"),
            .exit(0)
        ])
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner
        )

        await session.send("package")

        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(MessagePresentation.assistantBlocks(in: session.messages[1].text), [
            .text("准备运行。"),
            .toolCall("工具出错：Exit code 1"),
            .text("改用 zsh 后成功。")
        ])
        XCTAssertEqual(session.status, .idle)
    }

    func testAskDecisionStashesPendingUntilApprovedThenRemembers() async {
        let runner = ChunkedRunner(events: [.stdout("done"), .exit(0)])
        let session = AgentSession(
            agent: streamingConfig(id: "ask-agent", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .ask },
            runner: runner
        )

        await session.send("hi")

        XCTAssertEqual(session.pendingPermission?.prompt, "hi")
        XCTAssertEqual(session.messages, [])
        XCTAssertEqual(session.status, .idle)

        await session.approvePending(remember: true)

        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done"])

        // 记住授权后第二次直接运行，不再暂存。
        await session.send("again")
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done", "again", "done"])
    }

    /// 回归：confirmationDialog 关闭时 isPresented 绑定会先同步清空 pendingPermission，
    /// 早于按钮动作里的异步 Task。按钮必须用捕获的 pending 值授权（session.approve），
    /// 否则会读到 nil 而静默丢掉发送（表现为「允许后无消息、再点又弹窗」）。
    func testApproveWithCapturedPendingSendsEvenAfterDialogClearsPending() async {
        let runner = ChunkedRunner(events: [.stdout("done"), .exit(0)])
        let session = AgentSession(
            agent: streamingConfig(id: "captured-approve", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .ask },
            runner: runner
        )

        await session.send("hi")
        guard let pending = session.pendingPermission else {
            return XCTFail("应已暂存待授权请求")
        }

        // 模拟弹窗关闭：绑定的 set(false) 会先把 pendingPermission 清空。
        session.cancelPending()
        XCTAssertNil(session.pendingPermission)

        // 按钮动作用捕获的 pending 值授权，仍应真正发送。
        await session.approve(pending, remember: true)

        XCTAssertEqual(session.messages.map(\.text), ["hi", "done"])
        XCTAssertEqual(session.status, .idle)

        // 记住授权后下一次直接运行，不再暂存。
        await session.send("again")
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done", "again", "done"])
    }

    /// P1：记住的授权只对授权时所在目录有效。切到别的目录后须重新征询，
    /// 不能把对 A 目录的许可静默用到 B 目录；切回 A 则沿用原授权。
    func testRememberedApprovalDoesNotCarryToADifferentWorkingDirectory() async {
        let runner = ChunkedRunner(events: [.stdout("done"), .exit(0)])
        let dirA = FileManager.default.temporaryDirectory
        let dirB = dirA.appendingPathComponent("sub", isDirectory: true)
        let session = AgentSession(
            agent: streamingConfig(id: "dir-scoped", outputMode: .stream),
            workingDirectory: dirA,
            permissionDecider: { _ in .ask },
            runner: runner
        )

        // 在 dirA 记住授权并运行。
        await session.send("hi")
        await session.approvePending(remember: true)
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done"])

        // 切到 dirB：记住的授权不应继续生效，应重新征询且未经批准不发送。
        session.workingDirectory = dirB
        await session.send("again")
        XCTAssertEqual(session.pendingPermission?.prompt, "again")
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done"])

        // 切回 dirA：沿用之前对该目录的授权，直接运行。
        session.cancelPending()
        session.workingDirectory = dirA
        await session.send("back")
        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.text), ["hi", "done", "back", "done"])
    }

    func testDenyDecisionBlocksRunWithSystemMessage() async {
        let runner = ChunkedRunner(events: [.stdout("should not run"), .exit(0)])
        let session = AgentSession(
            agent: streamingConfig(id: "deny-agent", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .deny },
            runner: runner
        )

        await session.send("hi")

        XCTAssertNil(session.pendingPermission)
        XCTAssertEqual(session.messages.map(\.role), [.system])
        XCTAssertEqual(session.status, .idle)
    }

    func testStopTerminatesRunningProcess() async {
        // 真实 ProcessRunner + /bin/sh sleep：等脚本写出 marker 后再 stop，
        // 避免把「已进入 running 但 runTask 尚未创建」的启动窗口混入本用例。
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let config = AgentConfig(
            id: "sleeper",
            name: "Sleeper",
            command: "/bin/sh",
            args: ["-c", "printf started > \"$0\"; sleep 5", marker.path],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .terminate
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let sendTask = Task { await session.send("go") }
        while !FileManager.default.fileExists(atPath: marker.path) { await Task.yield() }
        session.stop()
        await sendTask.value

        guard case .failed(let message) = session.status else {
            return XCTFail("停止后应为 failed，实际为 \(session.status)")
        }
        XCTAssertEqual(message, "已停止。")
    }

    func testStopIsNoOpWhenAgentDoesNotSupportStop() async {
        // supportsStop == false：stop() 不应终止运行；进程自然跑完后转 idle。
        let config = AgentConfig(
            id: "no-stop",
            name: "No Stop",
            command: "/bin/sleep",
            args: ["1"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .stdin,
            outputMode: .stream,
            supportsStop: false,
            stopSignal: .interrupt
        )
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            runner: ProcessRunner()
        )

        let runTask = Task { await session.send("go") }
        while !session.isRunning { await Task.yield() }

        session.stop()
        XCTAssertTrue(session.isRunning, "不支持停止的 agent 调用 stop() 后应仍在运行")

        await runTask.value
        XCTAssertEqual(session.status, .idle)
    }

    func testCustomStopSignalRunsConfiguredStopCommand() async {
        let runner = OpenStreamRunner()
        var config = streamingConfig(id: "custom-stop", outputMode: .stream)
        config.stopSignal = .customCommand
        config.stopCommand = ["/usr/bin/agentctl", "stop", "--now"]
        let session = AgentSession(
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            permissionDecider: { _ in .allow },
            runner: runner
        )

        let runTask = Task { await session.send("go") }
        await runner.waitUntilStreamStarted()

        session.stop()
        await runTask.value // stop() 取消 consume 任务 → 运行结束

        // 自定义停止命令是 fire-and-forget，轮询等待其被记录。
        var spins = 0
        while !runner.recordedOneShotInvocations().contains(["/usr/bin/agentctl", "stop", "--now"]), spins < 2000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(runner.recordedOneShotInvocations().contains(["/usr/bin/agentctl", "stop", "--now"]))
        XCTAssertEqual(session.status, .failed("已停止。"))
    }

    func testTimeoutCancelsRunAndMarksItTimedOut() async {
        // stream 永不结束；看门狗到点应取消并标记为超时。
        let runner = OpenStreamRunner()
        let session = AgentSession(
            agent: streamingConfig(id: "timeout", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            timeout: .milliseconds(100),
            permissionDecider: { _ in .allow },
            runner: runner
        )

        await session.send("go")

        XCTAssertEqual(session.status, .failed("运行超时，已终止。"))
    }

    func testOptimizedPromptUsesIndependentOptimizerWithoutTouchingChat() async {
        let improved = "任务：实现登录表单校验，覆盖空值与格式错误，并补单测。"
        let runner = RecordingAgentRunner(stdout: "chat should not run", stderr: "", exitCode: 0)
        let optimizer = MockPromptOptimizer(result: .success(improved))
        let session = AgentSession(
            agent: streamingConfig(id: "opt", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner,
            promptOptimizer: optimizer
        )

        let out = await session.optimizedPrompt(from: "登录加校验")

        XCTAssertEqual(out, improved)
        XCTAssertTrue(session.messages.isEmpty)   // 不进聊天
        XCTAssertEqual(session.status, .idle)      // 不改状态
        let calls = await runner.calls()
        XCTAssertEqual(calls.count, 0)             // 不复用当前聊天 agent
        let optimizeCalls = await optimizer.calls()
        XCTAssertEqual(optimizeCalls.map(\.text), ["登录加校验"])
    }

    func testOptimizedPromptReturnsNilForEmptyInputWithoutRunning() async {
        let runner = RecordingAgentRunner(stdout: "x", stderr: "", exitCode: 0)
        let optimizer = MockPromptOptimizer(result: .success("x"))
        let session = AgentSession(
            agent: streamingConfig(id: "opt-empty", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            runner: runner,
            promptOptimizer: optimizer
        )

        let out = await session.optimizedPrompt(from: "   \n ")

        XCTAssertNil(out)
        let calls = await runner.calls()
        XCTAssertTrue(calls.isEmpty) // 空输入不调用 agent
        let optimizeCalls = await optimizer.calls()
        XCTAssertTrue(optimizeCalls.isEmpty)
    }

    func testOptimizedPromptReturnsNilOnNonzeroExit() async {
        let optimizer = MockPromptOptimizer(result: .failure("boom"))
        let session = AgentSession(
            agent: streamingConfig(id: "opt-fail", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            promptOptimizer: optimizer
        )

        let out = await session.optimizedPrompt(from: "do something")

        XCTAssertNil(out)
    }

    func testOptimizePromptResultIncludesFailureDetail() async {
        let optimizer = MockPromptOptimizer(result: .failure("API Error: 403 quota"))
        let session = AgentSession(
            agent: streamingConfig(id: "opt-detail", outputMode: .stream),
            workingDirectory: FileManager.default.temporaryDirectory,
            promptOptimizer: optimizer
        )

        let result = await session.optimizePromptResult(from: "do something")

        XCTAssertEqual(result, .failure("API Error: 403 quota"))
    }

    func testOptimizedPromptReturnsIndependentOptimizerText() async {
        let improved = "请实现登录校验，并覆盖空值、格式错误和回归测试。"
        let optimizer = MockPromptOptimizer(result: .success(improved))
        let session = AgentSession(
            agent: streamingConfig(id: "opt-raw-fallback", outputMode: .jsonLines),
            workingDirectory: FileManager.default.temporaryDirectory,
            promptOptimizer: optimizer
        )

        let out = await session.optimizedPrompt(from: "登录校验")

        XCTAssertEqual(out, improved)
    }

    func testChangeReviewMessagePersistsTurnDiffSummary() throws {
        let summary = TurnDiffSummary(
            workingDirectory: "/tmp/project",
            generatedAt: Date(timeIntervalSince1970: 100),
            files: [
                TurnFileDiff(
                    path: "Sources/App.swift",
                    status: .modified,
                    diff: FileDiff(hunks: [
                        DiffHunk(header: "@@ -1,1 +1,1 @@", lines: [
                            DiffLine(kind: .deletion, oldNumber: 1, newNumber: nil, text: "old"),
                            DiffLine(kind: .addition, oldNumber: nil, newNumber: 1, text: "new")
                        ])
                    ], isBinary: false),
                    note: "本轮修改"
                )
            ]
        )
        let message = ChatMessage(
            role: .system,
            text: "改动文件：\n- Sources/App.swift",
            fileLinks: ["Sources/App.swift"],
            kind: .changeReview,
            turnDiffSummary: summary
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.turnDiffSummary, summary)
        let session = AgentSession(
            agent: streamingConfig(id: "restored-review", outputMode: .stream),
            workingDirectory: URL(filePath: "/tmp/project"),
            messages: [decoded],
            runner: RecordingAgentRunner()
        )
        XCTAssertEqual(session.lastTurnDiffSummary, summary)
    }

    func testChatMessagePersistsRunTiming() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let endedAt = Date(timeIntervalSince1970: 1_042)
        let message = ChatMessage(
            role: .assistant,
            text: "done",
            runStartedAt: startedAt,
            runEndedAt: endedAt
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.runStartedAt, startedAt)
        XCTAssertEqual(decoded.runEndedAt, endedAt)
    }

    private func streamingConfig(id: String, outputMode: AgentConfig.OutputMode) -> AgentConfig {
        AgentConfig(
            id: id,
            name: id,
            command: "/usr/bin/agent",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: outputMode,
            supportsStop: true,
            stopSignal: .interrupt
        )
    }
}

private final class OpenCodeSessionRunner: AgentRunning, @unchecked Sendable {
    let sessionID: String
    private let lock = NSLock()
    private var storedCalls: [AgentRunCall] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func calls() async -> [AgentRunCall] {
        lock.withLock { storedCalls }
    }

    private func record(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) {
        lock.withLock {
            storedCalls.append(AgentRunCall(
                command: command,
                args: args,
                environment: environment,
                workingDirectory: workingDirectory,
                stdin: stdin
            ))
        }
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        let sessionID = self.sessionID
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(#"{"type":"step_start","sessionID":"\#(sessionID)","part":{}}"# + "\n"))
            continuation.yield(.stdout(#"{"type":"text","part":{"text":"ok"}}"# + "\n"))
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }
}

private final class ClaudeSessionIDRunner: AgentRunning, @unchecked Sendable {
    let sessionID: String
    private let lock = NSLock()
    private var storedCalls: [AgentRunCall] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func calls() async -> [AgentRunCall] {
        lock.withLock { storedCalls }
    }

    private func record(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) {
        lock.withLock {
            storedCalls.append(AgentRunCall(
                command: command,
                args: args,
                environment: environment,
                workingDirectory: workingDirectory,
                stdin: stdin
            ))
        }
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        let sessionID = self.sessionID
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(#"{"type":"system","subtype":"init","session_id":"\#(sessionID)","model":"claude-opus-4-8"}"# + "\n"))
            continuation.yield(.stdout(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"},"index":0}}"# + "\n"))
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }
}

private final class ClaudeResumeFailureThenReplayRunner: AgentRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [AgentRunCall] = []

    func calls() async -> [AgentRunCall] {
        lock.withLock { storedCalls }
    }

    private func record(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) -> Int {
        lock.withLock {
            storedCalls.append(AgentRunCall(
                command: command,
                args: args,
                environment: environment,
                workingDirectory: workingDirectory,
                stdin: stdin
            ))
            return storedCalls.count
        }
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        _ = record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        let callCount = record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        let isResume = args.contains("--resume")
        let sessionID = callCount == 1 ? "stale-claude-session" : "fresh-claude-session"
        return AsyncThrowingStream { continuation in
            if isResume {
                continuation.yield(.stderr("No conversation found for stale-claude-session"))
                continuation.yield(.exit(1))
            } else {
                continuation.yield(.stdout(#"{"type":"system","subtype":"init","session_id":"\#(sessionID)"}"# + "\n"))
                continuation.yield(.stdout(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"},"index":0}}"# + "\n"))
                continuation.yield(.exit(0))
            }
            continuation.finish()
        }
    }
}

private final class CodexThreadRunner: AgentRunning, @unchecked Sendable {
    let threadID: String
    private let lock = NSLock()
    private var storedCalls: [AgentRunCall] = []

    init(threadID: String) {
        self.threadID = threadID
    }

    func calls() async -> [AgentRunCall] {
        lock.withLock { storedCalls }
    }

    private func record(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) {
        lock.withLock {
            storedCalls.append(AgentRunCall(
                command: command,
                args: args,
                environment: environment,
                workingDirectory: workingDirectory,
                stdin: stdin
            ))
        }
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        record(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin)
        let threadID = self.threadID
        return AsyncThrowingStream { continuation in
            continuation.yield(.stdout(#"{"type":"thread.started","thread_id":"\#(threadID)"}"# + "\n"))
            continuation.yield(.stdout(#"{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}"# + "\n"))
            continuation.yield(.exit(0))
            continuation.finish()
        }
    }
}

private struct PromptOptimizationCall: Equatable, Sendable {
    var text: String
    var projectFiles: [String]
}

private actor MockPromptOptimizer: PromptOptimizing {
    let result: PromptOptimizationResult
    private var storedCalls: [PromptOptimizationCall] = []

    init(result: PromptOptimizationResult) {
        self.result = result
    }

    func optimizePrompt(_ text: String, projectFiles: [String]) async -> PromptOptimizationResult {
        storedCalls.append(PromptOptimizationCall(text: text, projectFiles: projectFiles))
        return result
    }

    func calls() -> [PromptOptimizationCall] {
        storedCalls
    }
}

private struct ChunkedRunner: AgentRunning {
    let events: [ProcessStreamEvent]

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        let events = self.events
        return AsyncThrowingStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private actor SlowSnapshotChangeTracker: WorkspaceChangeTracking {
    private var started = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func snapshot(in directory: URL) async -> WorkspaceChangeSnapshot {
        started = true
        startedContinuations.forEach { $0.resume() }
        startedContinuations.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return WorkspaceChangeSnapshot(paths: [])
    }

    func changedFiles(in directory: URL) async -> [String] {
        []
    }

    func waitUntilSnapshotStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func releaseSnapshot() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// 测试用 runner：stream 保持开启直到被取消（让会话停在"运行中"），
/// 并记录 runOneShot 调用（用于断言自定义停止命令）。
private final class OpenStreamRunner: AgentRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var oneShotInvocations: [[String]] = []
    private var streamStarted = false
    private var streamStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var streamContinuation: AsyncThrowingStream<ProcessStreamEvent, Error>.Continuation?

    func recordedOneShotInvocations() -> [[String]] {
        lock.withLock { oneShotInvocations }
    }

    func waitUntilStreamStarted() async {
        if lock.withLock({ streamStarted }) { return }

        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if streamStarted {
                    return true
                } else {
                    streamStartedContinuations.append(continuation)
                    return false
                }
            }
            if resumeNow { continuation.resume() }
        }
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        let continuation = lock.withLock {
            oneShotInvocations.append([command] + args)
            return streamContinuation
        }
        continuation?.finish()
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock {
                streamContinuation = continuation
                streamStarted = true
                streamStartedContinuations.forEach { $0.resume() }
                streamStartedContinuations.removeAll()
            }
            continuation.onTermination = { _ in continuation.finish() }
        }
    }
}

private struct AgentRunCall: Equatable, Sendable {
    var command: String
    var args: [String]
    var environment: [String: String]
    var workingDirectory: URL
    var stdin: String?
}

private enum TestRunnerError: LocalizedError {
    case failed

    var errorDescription: String? {
        "runner failed"
    }
}

private struct StaticChangeTracker: WorkspaceChangeTracking {
    var baseline: [String] = []
    var paths: [String]

    func snapshot(in directory: URL) async -> WorkspaceChangeSnapshot {
        WorkspaceChangeSnapshot(paths: Set(baseline))
    }

    func changedFiles(in directory: URL) async -> [String] {
        paths
    }
}

private struct WritingAgentRunner: AgentRunning {
    var relativePath: String
    var contents: String

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        let url = workingDirectory.appending(path: relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return ProcessResult(exitCode: 0, stdout: "done", stderr: "")
    }
}

private enum GitTestError: Error {
    case failed(args: [String], stderr: String)
}

private func runGit(_ args: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: GitService.resolveGit())
    process.arguments = args
    process.currentDirectoryURL = directory

    let stderr = Pipe()
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        throw GitTestError.failed(args: args, stderr: String(data: data, encoding: .utf8) ?? "")
    }
}

private actor RecordingAgentRunner: AgentRunning {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let error: (any Error)?
    let suspendsUntilReleased: Bool
    private var storedCalls: [AgentRunCall] = []
    private var waitUntilCalledContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func calls() -> [AgentRunCall] {
        storedCalls
    }

    init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        error: (any Error)? = nil,
        suspendsUntilReleased: Bool = false
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.error = error
        self.suspendsUntilReleased = suspendsUntilReleased
    }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult {
        storedCalls.append(AgentRunCall(
            command: command,
            args: args,
            environment: environment,
            workingDirectory: workingDirectory,
            stdin: stdin
        ))
        waitUntilCalledContinuations.forEach { $0.resume() }
        waitUntilCalledContinuations.removeAll()

        if suspendsUntilReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        if let error {
            throw error
        }

        return ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    func waitUntilCalled() async {
        guard storedCalls.isEmpty else { return }

        await withCheckedContinuation { continuation in
            waitUntilCalledContinuations.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
