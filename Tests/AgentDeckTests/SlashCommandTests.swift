import XCTest
@testable import AgentDeckApp

final class SlashCommandTests: XCTestCase {
    func testNonSlashTextShowsNoMenu() {
        XCTAssertNil(SlashCommandMenu.matches(for: ""))
        XCTAssertNil(SlashCommandMenu.matches(for: "hello"))
        XCTAssertNil(SlashCommandMenu.matches(for: "fix /plan please"))
    }

    func testBareSlashListsAllCommands() {
        XCTAssertEqual(
            SlashCommandMenu.matches(for: "/")?.map(\.token),
            SlashCommandMenu.all.map(\.token)
        )
    }

    func testFiltersByTokenPrefix() {
        XCTAssertEqual(SlashCommandMenu.matches(for: "/pl")?.map(\.token), ["/plan"])
        XCTAssertEqual(SlashCommandMenu.matches(for: "/b")?.map(\.token), ["/build"])
        XCTAssertEqual(SlashCommandMenu.matches(for: "/c")?.map(\.token), ["/continue", "/compact", "/clear"])
    }

    func testSpaceEndsSlashMode() {
        // 出现空格即视为普通消息，不再是指令态。
        XCTAssertNil(SlashCommandMenu.matches(for: "/plan now"))
    }

    func testUnknownCommandYieldsEmptyMenu() {
        XCTAssertEqual(SlashCommandMenu.matches(for: "/zzz"), [])
    }

    func testEveryCommandHasASummary() {
        for command in SlashCommandMenu.all {
            XCTAssertFalse(command.summary.isEmpty, "\(command.token) 缺少功能说明")
        }
    }

    func testModelCommandIsListedAndStartsModelInput() {
        let model = SlashCommandMenu.all.first { $0.token == "/model" }
        XCTAssertEqual(model?.action, .startModelInput)
        // 仍在拼 token（"/mod"）时按命令补全展示 /model。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/mod", agent: agent(id: "claude-code")),
            .commands([model].compactMap { $0 })
        )
    }

    func testCompactCommandIsListedAsPassthroughContextAction() {
        let compact = SlashCommandMenu.all.first { $0.token == "/compact" }
        XCTAssertEqual(compact?.action, .passthrough)
        XCTAssertEqual(compact?.summary, "压缩当前上下文（透传给底层 CLI）")
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/comp", agent: agent(id: "claude-code")),
            .commands([compact].compactMap { $0 })
        )
    }

    func testResolveEntersModelModeAtFullTokenAndWithArgument() {
        // "/model"（无空格）即进入模型态，给出该 agent 的预设建议。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/model", agent: agent(id: "claude-code")),
            .models(query: "", suggestions: ["default", "sonnet", "opus", "haiku", "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"])
        )
        // 带 query 过滤预设（别名 + 全名都含 "son"）。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/model son", agent: agent(id: "claude-code")),
            .models(query: "son", suggestions: ["sonnet", "claude-sonnet-4-6"])
        )
    }

    func testResolveModelModeKeepsFreeTextWhenNoPresetMatches() {
        // 自由文本模型名：无预设命中，suggestions 为空，但 query 保留（UI 据此提供“设为 …”）。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/model my/custom-model", agent: agent(id: "codex")),
            .models(query: "my/custom-model", suggestions: [])
        )
    }

    func testNonClaudeAgentsOnlyPresetDefault() {
        XCTAssertEqual(SlashCommandMenu.modelPresets(for: .codex), ["default"])
        XCTAssertEqual(SlashCommandMenu.modelPresets(for: .openCode), ["default"])
        XCTAssertEqual(SlashCommandMenu.modelPresets(for: .custom), ["default"])
    }

    // MARK: - 指令集随 agent 变化

    func testAvailableCommandsAreAgentSpecific() {
        XCTAssertEqual(
            SlashCommandMenu.availableCommands(for: agent(id: "claude-code")).map(\.token),
            ["/new", "/resume", "/continue", "/compact", "/model", "/plan", "/build", "/stop", "/clear"]
        )
        // codex / opencode 没有 --permission-mode，去掉 plan/build。
        XCTAssertEqual(
            SlashCommandMenu.availableCommands(for: agent(id: "codex")).map(\.token),
            ["/new", "/resume", "/continue", "/compact", "/model", "/stop", "/clear"]
        )
        XCTAssertEqual(
            SlashCommandMenu.availableCommands(for: agent(id: "opencode")).map(\.token),
            ["/new", "/resume", "/continue", "/compact", "/model", "/stop", "/clear"]
        )
        // pi / custom 走透传，不注入任何 flag，只剩应用层动作。
        XCTAssertEqual(SlashCommandMenu.availableCommands(for: agent(id: "pi-local")).map(\.token), ["/compact", "/stop", "/clear"])
        XCTAssertEqual(SlashCommandMenu.availableCommands(for: agent(id: "my-agent")).map(\.token), ["/compact", "/stop", "/clear"])
    }

    func testStopHiddenWhenAgentDoesNotSupportStop() {
        XCTAssertEqual(
            SlashCommandMenu.availableCommands(for: agent(id: "pi-local", supportsStop: false)).map(\.token),
            ["/compact", "/clear"]
        )
    }

    func testModelModeUnavailableForPassthroughAgent() {
        // pi 不支持 /model：不进入模型态，而是作为透传命令发给 agent。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/model", agent: agent(id: "pi-local")),
            .commands([SlashCommand(token: "/model", summary: "发送给 pi-local（CLI 指令，透传）", action: .passthrough)])
        )
    }

    func testResolveFiltersCommandTokensByAgent() {
        let plan = SlashCommandMenu.all.first { $0.token == "/plan" }!
        // "/p" 对 claude 给 /plan；对 codex（无 plan）无匹配 → 透传项。
        XCTAssertEqual(SlashCommandMenu.resolve(for: "/p", agent: agent(id: "claude-code")), .commands([plan]))
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/p", agent: agent(id: "codex")),
            .commands([SlashCommand(token: "/p", summary: "发送给 codex（CLI 指令，透传）", action: .passthrough)])
        )
    }

    func testUnknownSlashOffersPassthrough() {
        // 任何未识别的 /命令 → 透传项（原样发给 CLI）。
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/cost", agent: agent(id: "claude-code")),
            .commands([SlashCommand(token: "/cost", summary: "发送给 claude-code（CLI 指令，透传）", action: .passthrough)])
        )
    }

    func testDiscoveredCommandsMatchInMenu() {
        let review = SlashCommand(token: "/review", summary: "x", action: .passthrough)
        XCTAssertEqual(
            SlashCommandMenu.resolve(for: "/rev", agent: agent(id: "claude-code"), extraCommands: [review]),
            .commands([review])
        )
    }

    func testModelDisplayNameStripsProviderDashesAndCapitalizes() {
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("opencode-go/deepseek-v4-flash"), "Deepseek V4 Flash")
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("anthropic/claude-sonnet-4-6"), "Claude Sonnet 4 6")
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("sonnet"), "Sonnet")
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("default"), "默认模型")
    }

    func testModelDisplayNameUppercasesKnownAcronyms() {
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("openai/gpt-4o"), "GPT 4o")
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("qwen/qwen2-vl"), "Qwen2 VL")
        XCTAssertEqual(SlashCommandMenu.modelDisplayName("gpt-oss"), "GPT OSS")
    }

    private func agent(id: String, supportsStop: Bool = true) -> AgentConfig {
        AgentConfig(
            id: id,
            name: id,
            command: "/usr/bin/agent",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: supportsStop,
            stopSignal: .interrupt
        )
    }
}
