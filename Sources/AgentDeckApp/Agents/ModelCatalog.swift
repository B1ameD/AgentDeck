import Foundation

/// 动态获取某 agent 的可用模型列表。
/// OpenCode 提供 `opencode models`（输出 `provider/model` 每行一个），可实时拉取；
/// Claude 的 `--model` 只收别名/全名、无列模型命令；其它 agent 暂无 → 返回空，由调用方回落到内置预设。
public enum ModelCatalog {
    public static func fetch(
        for agent: AgentConfig,
        workingDirectory: URL,
        runner: ProcessRunner = ProcessRunner()
    ) async -> [String] {
        // 用户在配置里声明的模型列表优先（ACP/第三方中转等无法自动列模型时的来源）。
        if let declared = agent.models, !declared.isEmpty { return declared }
        // ACP 适配器没有「列模型」CLI 命令——不要去跑 `<command> models`（会是 `npx models` 之类的无效调用）。
        if agent.resolvedTransport == .acp { return [] }
        if agent.kind == .claudeCode {
            return await fetchClaudeSnapshot().candidates
        }
        // 缓存命中直接返回——opencode models 约 1.5s，避免每次切标签/开菜单都重跑。
        if let cached = await ModelCatalogCache.shared.get(agent.command) { return cached }
        let models = await run(for: agent, workingDirectory: workingDirectory, runner: runner)
        if !models.isEmpty { await ModelCatalogCache.shared.set(agent.command, models) }
        return models
    }

    public static func fetchClaudeSnapshot(
        settingsURL: URL = ClaudeSettings.defaultSettingsURL
    ) async -> ClaudeSettings.ModelSnapshot {
        await Task.detached {
            ClaudeSettings.modelSnapshot(settingsURL: settingsURL)
        }.value
    }

    private static func run(
        for agent: AgentConfig,
        workingDirectory: URL,
        runner: ProcessRunner
    ) async -> [String] {
        switch agent.kind {
        case .claudeCode:
            return await fetchClaudeSnapshot().candidates
        case .openCode:
            guard let result = try? await runner.runOneShot(
                command: agent.command,
                args: ["models"],
                environment: agent.runtimeEnvironment(),
                workingDirectory: workingDirectory
            ), result.exitCode == 0 else { return [] }
            return parse(result.stdout)
        case .codex, .pi, .custom:
            return [] // 无可靠的列模型命令；回落到 SlashCommandMenu 的内置预设。
        }
    }

    /// 解析每行一个模型名的输出（如 opencode models 的 `provider/model`）。
    static func parse(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// 进程内模型列表缓存（按可执行路径）。仅缓存非空结果，失败下次会重试。
private actor ModelCatalogCache {
    static let shared = ModelCatalogCache()
    private var cache: [String: [String]] = [:]
    func get(_ key: String) -> [String]? { cache[key] }
    func set(_ key: String, _ value: [String]) { cache[key] = value }
}
