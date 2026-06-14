import XCTest
@testable import AgentDeckApp

final class CLIInvocationBuilderTests: XCTestCase {
    // MARK: - Claude Code

    func testClaudeMapsModelEffortModeAndContinue() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "do it",
            model: "sonnet",
            reasoningEffort: .high,
            interactionMode: .plan,
            command: .continueLast,
            attachments: []
        )

        XCTAssertEqual(invocation.arguments.prefix(7), ["-p", "--model", "sonnet", "--effort", "high", "--permission-mode", "plan"])
        XCTAssertEqual(invocation.arguments[7], "--append-system-prompt")
        XCTAssertTrue(invocation.arguments[8].contains("[Plan Mode]"))
        XCTAssertEqual(invocation.arguments.suffix(2), ["--continue", "do it"])
        XCTAssertNil(invocation.stdin)
    }

    func testClaudePlanModeUsesNativePlanPermissionMode() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "plan it",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .plan,
            command: .new,
            attachments: []
        )
        // plan 用原生只读权限模式（非 bypassPermissions），并保留提示词兜底。
        XCTAssertEqual(invocation.arguments.prefix(3), ["-p", "--permission-mode", "plan"])
        XCTAssertEqual(invocation.arguments[3], "--append-system-prompt")
        XCTAssertTrue(invocation.arguments[4].contains("[Plan Mode]"))
        XCTAssertFalse(invocation.arguments.contains("bypassPermissions"))
        XCTAssertEqual(invocation.arguments.last, "plan it")
    }

    func testClaudeBuildModeBypassesPermissionsForNonInteractiveRuns() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "edit test.md",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: []
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "edit test.md"],
            stdin: nil
        ))
    }

    func testClaudeNewDoesNotReuseAgentDeckSessionID() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "first",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            sessionID: "11111111-2222-3333-4444-555555555555"
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "first"],
            stdin: nil
        ))
    }

    func testClaudeNewWithExternalSessionIDUsesNativeResume() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "second",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            sessionID: "11111111-2222-3333-4444-555555555555",
            externalSessionID: "claude-session-123"
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "--resume", "claude-session-123", "second"],
            stdin: nil
        ))
    }

    func testClaudeAttachmentsAreMentionedInPrompt() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "review",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [URL(filePath: "/tmp/a.txt")]
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "review\n\n附件：\n@/tmp/a.txt"],
            stdin: nil
        ))
    }

    func testClaudeResumeWithSessionIDPassesTheId() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "go",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .resume,
            attachments: [],
            resumeSessionID: "abc-123"
        )
        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "--resume", "abc-123", "go"],
            stdin: nil
        ))
    }

    func testClaudeResumeWithoutSessionIDFallsBackToBareResume() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
            prompt: "go",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .resume,
            attachments: []
        )
        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["-p", "--permission-mode", "bypassPermissions", "--resume", "go"],
            stdin: nil
        ))
    }

    // MARK: - OpenCode

    func testOpenCodeMapsModelVariantContinueAndLocalFiles() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "go",
            model: "anthropic/claude",
            reasoningEffort: .low,
            interactionMode: .build,
            command: .resume,
            attachments: [URL(filePath: "/tmp/a.txt")]
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: [
                "run", "--format", "json", "--thinking", "-m", "anthropic/claude",
                "--variant", "minimal", "-c", "-f", "/tmp/a.txt", "--", "go"
            ],
            stdin: nil
        ))
    }

    func testOpenCodeJSONIncludesThinkingFlag() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "show your work",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: []
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: ["run", "--format", "json", "--thinking", "show your work"],
            stdin: nil
        ))
    }

    func testOpenCodeUsesWindowTitleForFirstRunAndCapturedSessionForNextRun() {
        let first = CLIInvocationBuilder.build(
            agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "first",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            conversationTitle: "AgentDeck window"
        )
        let second = CLIInvocationBuilder.build(
            agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "second",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            externalSessionID: "ses_123",
            conversationTitle: "AgentDeck window"
        )

        XCTAssertEqual(first.arguments, ["run", "--format", "json", "--thinking", "--title", "AgentDeck window", "first"])
        XCTAssertEqual(second.arguments, ["run", "--format", "json", "--thinking", "-s", "ses_123", "second"])
    }

    func testClaudeMapsExtendedEffortLevels() {
        for (effort, raw) in [(ReasoningEffort.xhigh, "xhigh"), (.max, "max")] {
            let invocation = CLIInvocationBuilder.build(
                agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
                prompt: "go",
                model: "default",
                reasoningEffort: effort,
                interactionMode: .build,
                command: .new,
                attachments: []
            )
            XCTAssertEqual(invocation, CLIInvocation(
                arguments: ["-p", "--effort", raw, "--permission-mode", "bypassPermissions", "go"],
                stdin: nil
            ))
        }
    }

    func testCodexJSONLinesUsesCapturedSessionIDInsteadOfLastSession() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "codex", args: ["exec"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "second",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            externalSessionID: "thread_123"
        )

        XCTAssertEqual(invocation, CLIInvocation(
            arguments: [
                "exec", "resume", "--json", "--skip-git-repo-check",
                "--dangerously-bypass-approvals-and-sandbox", "thread_123", "second"
            ],
            stdin: nil
        ))
    }

    func testCodexPlanModeUsesReadOnlySandbox() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "codex", args: ["exec"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "plan it",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .plan,
            command: .new,
            attachments: []
        )
        XCTAssertEqual(invocation.arguments.prefix(4), ["exec", "--json", "--skip-git-repo-check", "--sandbox"])
        XCTAssertEqual(invocation.arguments[4], "read-only")
        let prompt = invocation.arguments.last!
        XCTAssertTrue(prompt.contains("[Plan Mode]"))
        XCTAssertTrue(prompt.hasSuffix("plan it"))
        XCTAssertNil(invocation.stdin)
    }

    func testCodexInjectsAskUserMCPEndpoint() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "codex", args: ["exec"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "go",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .build,
            command: .new,
            attachments: [],
            mcpAskEndpoint: "http://127.0.0.1:9999/mcp/s1"
        )
        XCTAssertTrue(invocation.arguments.contains("-c"))
        XCTAssertTrue(invocation.arguments.contains("mcp_servers.agentdeck.url=http://127.0.0.1:9999/mcp/s1"))
        XCTAssertTrue(invocation.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testOpenCodeClampsExtendedEffortToHighVariant() {
        for effort in [ReasoningEffort.high, .xhigh, .max] {
            let invocation = CLIInvocationBuilder.build(
                agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument),
                prompt: "go",
                model: "default",
                reasoningEffort: effort,
                interactionMode: .build,
                command: .new,
                attachments: []
            )
            XCTAssertEqual(invocation, CLIInvocation(arguments: ["run", "--variant", "high", "go"], stdin: nil))
        }
    }

    func testOpenCodePlanModePrependsHintToPrompt() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "opencode", args: ["run"], inputMode: .oneShotArgument, outputMode: .jsonLines),
            prompt: "analyze this",
            model: "default",
            reasoningEffort: .medium,
            interactionMode: .plan,
            command: .new,
            attachments: []
        )
        XCTAssertEqual(invocation.arguments.prefix(3), ["run", "--format", "json"])
        let prompt = invocation.arguments.last!
        XCTAssertTrue(prompt.contains("[Plan Mode]"))
        XCTAssertTrue(prompt.hasSuffix("analyze this"))
        XCTAssertNil(invocation.stdin)
    }

    // MARK: - Pi / Custom（不注入任何未知 flag）

    func testPiPassesPromptViaStdinAndIgnoresModel() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "pi-local", args: ["chat", "--stdio"], inputMode: .stdin),
            prompt: "hello",
            model: "should-be-ignored",
            reasoningEffort: .high,
            interactionMode: .plan,
            command: .resume,
            attachments: []
        )

        XCTAssertEqual(invocation, CLIInvocation(arguments: ["chat", "--stdio"], stdin: "hello"))
    }

    func testCustomAgentInjectsNoFlags() {
        let invocation = CLIInvocationBuilder.build(
            agent: config(id: "my-agent", args: ["--foo"], inputMode: .oneShotArgument),
            prompt: "bar",
            model: "x",
            reasoningEffort: .high,
            interactionMode: .plan,
            command: .resume,
            attachments: []
        )

        XCTAssertEqual(invocation, CLIInvocation(arguments: ["--foo", "bar"], stdin: nil))
    }

    // MARK: - Helpers

    private func config(
        id: String,
        args: [String],
        inputMode: AgentConfig.InputMode,
        outputMode: AgentConfig.OutputMode = .stream
    ) -> AgentConfig {
        AgentConfig(
            id: id,
            name: id,
            command: "/usr/bin/\(id)",
            args: args,
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: inputMode,
            outputMode: outputMode,
            supportsStop: true,
            stopSignal: .interrupt
        )
    }
}
