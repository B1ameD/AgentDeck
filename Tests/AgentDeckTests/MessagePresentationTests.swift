import XCTest
@testable import AgentDeckApp

final class MessagePresentationTests: XCTestCase {
    func testChangeReviewRequestUsesOnlyTheMessagesPersistedSummary() {
        let oldSummary = TurnDiffSummary(workingDirectory: "/tmp/old", files: [])
        let latestSummary = TurnDiffSummary(workingDirectory: "/tmp/latest", files: [])
        let old = ChatMessage(
            role: .system,
            text: "old",
            kind: .changeReview,
            turnDiffSummary: oldSummary
        )
        let latest = ChatMessage(
            role: .system,
            text: "latest",
            kind: .changeReview,
            turnDiffSummary: latestSummary
        )

        XCTAssertEqual(ChangeReviewRequest.forMessage(old)?.summary, oldSummary)
        XCTAssertEqual(ChangeReviewRequest.forMessage(latest)?.summary, latestSummary)
    }

    func testLegacyChangeReviewWithoutSummaryHasNoReviewRequest() {
        let legacy = ChatMessage(
            role: .system,
            text: "改动文件：\n- old.swift",
            fileLinks: ["old.swift"],
            kind: .changeReview
        )

        XCTAssertNil(ChangeReviewRequest.forMessage(legacy))
    }

    func testGlobalSidebarOpenClearsHistoricalReviewSelectionOnlyInReviewMode() {
        XCTAssertTrue(
            ReviewSelectionPolicy.shouldClearForGlobalSidebarToggle(
                sidebarIsVisible: false,
                mode: .review
            )
        )
        XCTAssertFalse(
            ReviewSelectionPolicy.shouldClearForGlobalSidebarToggle(
                sidebarIsVisible: true,
                mode: .review
            )
        )
        XCTAssertFalse(
            ReviewSelectionPolicy.shouldClearForGlobalSidebarToggle(
                sidebarIsVisible: false,
                mode: .files
            )
        )
    }

    func testDetectsInlineLoginAndAPIError() {
        let text = #"Please run /login · API Error: 403 {"error":{"type":"new_api_error","message":"预扣费额度失败"},"type":"error"}"#

        XCTAssertTrue(MessagePresentation.isInlineError(text))
    }

    func testDetectsJSONErrorType() {
        XCTAssertTrue(MessagePresentation.isInlineError(#"{"type":"error","message":"failed"}"#))
    }

    func testDoesNotTreatOrdinaryAssistantTextAsError() {
        XCTAssertFalse(MessagePresentation.isInlineError("I have enough context. Let me check the current state."))
    }

    func testAssistantBlocksExtractThinkTags() {
        let text = """
        <think>
        先检查上下文。
        </think>
        最终回答。
        """

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .thinking("先检查上下文。"),
            .text("最终回答。")
        ])
    }

    func testAssistantBlocksMergeAdjacentThinkingTagsFromStreamDeltas() {
        let text = """
        <think>The user is</think><think> asking for a short answer.</think>
        ok
        """

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .thinking("The user is asking for a short answer."),
            .text("ok")
        ])
    }

    func testAssistantBlocksDoNotInsertSpacesBetweenCJKThinkingDeltas() {
        let text = "<think>我</think><think>会</think><think>继续处理</think>"

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .thinking("我会继续处理")
        ])
    }

    func testAssistantBlocksExtractLabeledThinkingSection() {
        let text = """
        思考过程：
        先定位问题。
        再验证修复。

        最终回答：
        已完成。
        """

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .thinking("先定位问题。\n再验证修复。"),
            .text("已完成。")
        ])
    }

    func testAssistantBlocksKeepOrdinaryTextAsText() {
        XCTAssertEqual(
            MessagePresentation.assistantBlocks(in: "我会先检查项目结构，然后给出方案。"),
            [.text("我会先检查项目结构，然后给出方案。")]
        )
    }

    func testAssistantBlocksSplitInlineErrors() {
        let error = #"Please run /login · API Error: 403 {"type":"error"}"#
        XCTAssertEqual(
            MessagePresentation.assistantBlocks(in: "before\n\(error)\nafter"),
            [.text("before"), .inlineError(error), .text("after")]
        )
    }

    func testAssistantBlocksInterleaveInlineToolActivityInOrder() {
        let text = "先看看代码。"
            + ToolActivity.marker("读取 a.swift")
            + "再改一处。"
            + ToolActivity.marker("编辑 a.swift")
            + "完成。"

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .text("先看看代码。"),
            .toolCall("读取 a.swift"),
            .text("再改一处。"),
            .toolCall("编辑 a.swift"),
            .text("完成。")
        ])
    }

    func testAssistantBlocksToolActivityCoexistsWithThinking() {
        let text = "<think>规划一下</think>"
            + ToolActivity.marker("运行 ls")
            + "好了。"

        XCTAssertEqual(MessagePresentation.assistantBlocks(in: text), [
            .thinking("规划一下"),
            .toolCall("运行 ls"),
            .text("好了。")
        ])
    }

    func testAssistantTimelineBlocksKeepToolActivityBeforeLaterThinking() {
        let text = ToolActivity.marker("读取 a.swift")
            + "<think>继续分析</think>"
            + "完成。"

        XCTAssertEqual(MessagePresentation.assistantTimelineBlocks(in: text), [
            .init(block: .toolCall("读取 a.swift"), count: 1),
            .init(block: .thinking("继续分析"), count: 1),
            .init(block: .text("完成。"), count: 1)
        ])
    }

    func testThinkingBlocksDoNotExposeIndividualCollapse() {
        XCTAssertFalse(ThinkingBlockPresentation.allowsIndividualCollapse)
        XCTAssertTrue(ThinkingBlockPresentation.alwaysShowsContent)
    }

    func testToolActivitySegmentsAndStripRoundTrip() {
        let text = "a" + ToolActivity.marker("读取 x") + "b"
        XCTAssertEqual(ToolActivity.segments(in: text), [
            .text("a"), .tool("读取 x"), .text("b")
        ])
        // 历史回放/纯文本时整体剥掉工具标记与摘要。
        XCTAssertEqual(ToolActivity.strip(from: text), "ab")
        XCTAssertEqual(ToolActivity.segments(in: "无标记文本"), [.text("无标记文本")])
    }

    func testCollapsingToolRunsMergesAdjacentIdenticalActivity() {
        let blocks: [AssistantContentBlock] = [
            .text("先看看"),
            .toolCall("编辑 /a/test.md"),
            .toolCall("编辑 /a/test.md"),
            .toolCall("编辑 /a/test.md"),
            .text("再看看"),
            .toolCall("编辑 /a/test.md") // 与上面不相邻 → 不并入前面那组
        ]
        XCTAssertEqual(MessagePresentation.collapsingToolRuns(blocks), [
            .init(block: .text("先看看"), count: 1),
            .init(block: .toolCall("编辑 /a/test.md"), count: 3),
            .init(block: .text("再看看"), count: 1),
            .init(block: .toolCall("编辑 /a/test.md"), count: 1)
        ])
    }

    func testCollapsingToolRunsKeepsDifferentTargetsSeparate() {
        let blocks: [AssistantContentBlock] = [.toolCall("编辑 a"), .toolCall("编辑 b")]
        XCTAssertEqual(MessagePresentation.collapsingToolRuns(blocks), [
            .init(block: .toolCall("编辑 a"), count: 1),
            .init(block: .toolCall("编辑 b"), count: 1)
        ])
    }

    func testToolActivityFileTargetResolvesFileVerbsOnly() {
        let workingDirectory = URL(filePath: "/work")

        let absolute = ToolActivity.fileTarget(in: "编辑 /Users/x/test.md", workingDirectory: workingDirectory)
        XCTAssertEqual(absolute?.prefix, "编辑 ")
        XCTAssertEqual(absolute?.path, "test.md")
        XCTAssertEqual(absolute?.relativePath, "/Users/x/test.md")
        XCTAssertEqual(absolute?.url.path, "/Users/x/test.md")

        // 相对路径相对工作目录解析。
        let relative = ToolActivity.fileTarget(in: "读取 src/a.swift", workingDirectory: workingDirectory)
        XCTAssertEqual(relative?.path, "a.swift")
        XCTAssertEqual(relative?.relativePath, "src/a.swift")
        XCTAssertEqual(
            relative?.url.path,
            "/work/src/a.swift"
        )

        // 非文件动词 / 命令 / 截断路径 / 无参 → nil（不可点）。
        XCTAssertNil(ToolActivity.fileTarget(in: "运行 ls -la", workingDirectory: workingDirectory))
        XCTAssertNil(ToolActivity.fileTarget(in: "搜索 TODO", workingDirectory: workingDirectory))
        XCTAssertNil(ToolActivity.fileTarget(in: "编辑 /very/long/path…", workingDirectory: workingDirectory))
        XCTAssertNil(ToolActivity.fileTarget(in: "更新计划", workingDirectory: workingDirectory))
    }

    func testToolActivityFileTargetDisplaysWorkspaceAbsolutePathAsFilenameLinkLabel() {
        let workingDirectory = URL(filePath: "/Users/jean/Desktop/Codex/AgentDeck")

        let target = ToolActivity.fileTarget(
            in: "读取 /Users/jean/Desktop/Codex/AgentDeck/test.md",
            workingDirectory: workingDirectory
        )

        XCTAssertEqual(target?.prefix, "读取 ")
        XCTAssertEqual(target?.path, "test.md")
        XCTAssertEqual(target?.relativePath, "test.md")
        XCTAssertEqual(target?.url.path, "/Users/jean/Desktop/Codex/AgentDeck/test.md")
    }

    func testToolActivityRunCommandCompactsExecutedWorkspaceScriptWithoutLink() {
        let workingDirectory = URL(filePath: "/Users/jean/Desktop/Codex/AgentDeck")
        let python = "运行 python3 /Users/jean/Desktop/Codex/AgentDeck/test_script.py --check"

        XCTAssertEqual(
            ToolActivity.displayText(in: python, workingDirectory: workingDirectory),
            "运行 python3 test_script.py --check"
        )
        XCTAssertEqual(
            ToolActivity.displayParts(in: python, workingDirectory: workingDirectory),
            [.text("运行 python3 test_script.py --check")]
        )

        let shell = "运行 zsh /Users/jean/Desktop/Codex/AgentDeck/Scripts/package_app.sh 2>&1"
        XCTAssertEqual(
            ToolActivity.displayText(in: shell, workingDirectory: workingDirectory),
            "运行 zsh package_app.sh 2>&1"
        )
        XCTAssertEqual(
            ToolActivity.displayParts(in: shell, workingDirectory: workingDirectory),
            [.text("运行 zsh package_app.sh 2>&1")]
        )

        let spacedWorkingDirectory = URL(filePath: "/Users/jean/Desktop/Claude Code")
        let quoted = #"运行 zsh "/Users/jean/Desktop/Claude Code/Scripts/package app.sh" --release"#
        XCTAssertEqual(
            ToolActivity.displayText(in: quoted, workingDirectory: spacedWorkingDirectory),
            #"运行 zsh "package app.sh" --release"#
        )
        XCTAssertEqual(
            ToolActivity.displayParts(in: quoted, workingDirectory: spacedWorkingDirectory),
            [.text(#"运行 zsh "package app.sh" --release"#)]
        )
    }

    func testToolActivityRunCommandCompactsDirectWorkspaceExecutableWithoutLink() {
        let workingDirectory = URL(filePath: "/work")
        let summary = "运行 /work/bin/tool --flag"

        XCTAssertEqual(
            ToolActivity.displayText(in: summary, workingDirectory: workingDirectory),
            "运行 tool --flag"
        )
        XCTAssertEqual(
            ToolActivity.displayParts(in: summary, workingDirectory: workingDirectory),
            [.text("运行 tool --flag")]
        )
    }

    func testToolActivityRunCommandPreservesInspectionPaths() {
        let workingDirectory = URL(filePath: "/work")
        let summaries = [
            "运行 ls -la /work/dist",
            "运行 find /work -name '*.swift'",
            "运行 grep -n TODO /work/Sources",
            "运行 pwd"
        ]

        for summary in summaries {
            XCTAssertEqual(
                ToolActivity.displayText(in: summary, workingDirectory: workingDirectory),
                summary
            )
            XCTAssertEqual(
                ToolActivity.displayParts(in: summary, workingDirectory: workingDirectory),
                [.text(summary)]
            )
        }
    }

    func testToolActivityDisplayTextCompactsFileToolWorkspacePath() {
        let workingDirectory = URL(filePath: "/Users/jean/Desktop/Codex/AgentDeck")

        XCTAssertEqual(
            ToolActivity.displayText(
                in: "读取 /Users/jean/Desktop/Codex/AgentDeck/test.md",
                workingDirectory: workingDirectory
            ),
            "读取 test.md"
        )
    }

    func testToolActivityFileLinkMenuMatchesBodyLinkMenu() {
        let workingDirectory = URL(filePath: "/Users/jean/Desktop/Codex/AgentDeck")
        let fileURL = workingDirectory.appending(path: "Sources/AgentDeckApp/UI/ChatPaneView.swift")

        XCTAssertEqual(ToolActivityRowPresentation.fileMenuTitles, FileLinkContextMenuPresentation.titles)
        XCTAssertEqual(
            FileLinkContextMenuPresentation.absoluteFolderPath(for: fileURL),
            "/Users/jean/Desktop/Codex/AgentDeck/Sources/AgentDeckApp/UI"
        )
        XCTAssertEqual(
            FileLinkContextMenuPresentation.relativeFolderPath(for: fileURL, workingDirectory: workingDirectory),
            "Sources/AgentDeckApp/UI"
        )
    }

    func testToolActivityRowsRenderWithoutContainerFrame() {
        XCTAssertFalse(ToolActivityRowPresentation.drawsContainerFrame)
    }

    func testRunDurationPresentationFormatsElapsedTime() {
        let startedAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            RunDurationPresentation.label(startedAt: startedAt, endedAt: nil, now: Date(timeIntervalSince1970: 105)),
            "运行 00:05"
        )
        XCTAssertEqual(
            RunDurationPresentation.label(startedAt: startedAt, endedAt: Date(timeIntervalSince1970: 165), now: Date(timeIntervalSince1970: 999)),
            "运行 01:05"
        )
        XCTAssertEqual(
            RunDurationPresentation.label(startedAt: startedAt, endedAt: Date(timeIntervalSince1970: 3_705), now: Date(timeIntervalSince1970: 999)),
            "运行 1:00:05"
        )
    }

    func testRunTimerIsPlacedAtTopOfAssistantOutput() {
        let blocks = MessagePresentation.assistantTimelineBlocks(in: "开头。<think>分析</think>回答。")

        XCTAssertEqual(RunDurationPresentation.timerInsertionIndex(in: blocks), 0)
    }

    func testRunTimerFallsBackToFirstAssistantBlockWithoutThinking() {
        let blocks = MessagePresentation.assistantTimelineBlocks(in: "直接回答。")

        XCTAssertEqual(RunDurationPresentation.timerInsertionIndex(in: blocks), 0)
    }

    func testProcessDetailVisibilityHidesThinkingAndToolBlocksOnly() {
        XCTAssertTrue(RunProcessDetailPresentation.shouldRender(.text("正文"), detailsHidden: true))
        XCTAssertTrue(RunProcessDetailPresentation.shouldRender(.inlineError("错误"), detailsHidden: true))
        XCTAssertFalse(RunProcessDetailPresentation.shouldRender(.thinking("分析"), detailsHidden: true))
        XCTAssertFalse(RunProcessDetailPresentation.shouldRender(.toolCall("读取 a.swift"), detailsHidden: true))

        XCTAssertTrue(RunProcessDetailPresentation.shouldRender(.thinking("分析"), detailsHidden: false))
        XCTAssertTrue(RunProcessDetailPresentation.shouldRender(.toolCall("读取 a.swift"), detailsHidden: false))
    }

    func testProcessDetailToggleAvoidsMovingLayoutTransitions() {
        XCTAssertFalse(RunProcessDetailPresentation.animatesLayoutOnToggle)
        XCTAssertFalse(RunProcessDetailPresentation.usesMovingTransition)
    }

    func testRunCompletionTimePresentationFormatsFinishedClockTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let endedAt = Date(timeIntervalSince1970: 3_661)

        XCTAssertEqual(
            RunCompletionTimePresentation.label(endedAt: endedAt, calendar: calendar),
            "完成于 01:01:01"
        )
    }

    func testCompletionTimeHoverKeepsBodyLayoutStable() {
        XCTAssertTrue(RunCompletionTimePresentation.reservesHoverSlot)
        XCTAssertFalse(RunCompletionTimePresentation.movesBodyOnHover)
    }

    func testAssistantCopyTextIncludesThinkingWithoutInternalTags() {
        let text = """
        <think>
        先检查上下文。
        </think>
        最终回答。
        """

        XCTAssertEqual(
            MessagePresentation.assistantPlainTextForCopy(text),
            "思考过程：\n先检查上下文。\n\n最终回答。"
        )
    }
}
