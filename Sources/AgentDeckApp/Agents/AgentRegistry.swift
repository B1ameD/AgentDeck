import Foundation

public struct AgentRegistry: Equatable {
    public var agents: [AgentConfig]
    /// 加载过程中跳过的项（坏 JSON、校验失败、ID 冲突）的可读警告，供 UI 展示。
    public var warnings: [String]

    public init(agents: [AgentConfig], warnings: [String] = []) {
        self.agents = agents
        self.warnings = warnings
    }

    /// 加载注册表。设计为「永不抛错」：单个坏配置只会被跳过并记录警告，
    /// 不会让内置 agent 或其它正常配置一起消失。
    public static func load(
        customDirectory: URL,
        executableResolver: (String) -> String? = AgentDetection.resolveExecutable(named:)
    ) -> AgentRegistry {
        let builtIns = builtInPresets(executableResolver: executableResolver)
        let custom = loadCustomAgents(
            from: customDirectory,
            reservedIDs: Set(builtIns.map(\.id)),
            executableResolver: executableResolver
        )
        return AgentRegistry(agents: builtIns + custom.agents, warnings: custom.warnings)
    }

    /// ACP-first：内置 agent 统一走 ACP 适配器（替代原 CLI 接入）。检测到「基础 agent」安装即生成其 ACP 预设。
    /// - codex/opencode/gemini/cursor 的 ACP 适配器用各自原生登录，开箱即用、无需配 token。
    /// - claude 不在此列：claude-agent-acp 借不到 Claude Code 宿主 OAuth、需显式鉴权（base_url/token），
    ///   由用户自定义 `claude-acp.json` 提供（见 docs/ACP_INTEGRATION_PLAN.md §11）。
    /// codex/opencode 沿用原 id（延续 kind 推导与品牌图标），仅把 transport 切到 ACP、命令换成适配器。
    public static func builtInPresets(executableResolver: (String) -> String?) -> [AgentConfig] {
        let npx = executableResolver("npx") ?? "npx"
        let candidates: [(base: String, id: String, name: String, command: String, args: [String])] = [
            ("codex", "codex", "Codex", npx, ["-y", "@agentclientprotocol/codex-acp"]),
            ("opencode", "opencode", "OpenCode", npx, ["-y", "opencode-ai", "acp"]),
            ("gemini", "gemini-acp", "Gemini", executableResolver("gemini") ?? "gemini", ["--acp"]),
            ("cursor-agent", "cursor-acp", "Cursor", executableResolver("cursor-agent") ?? "cursor-agent", ["acp"])
        ]

        return candidates.compactMap { candidate in
            guard executableResolver(candidate.base) != nil else { return nil }
            return AgentConfig(
                id: candidate.id,
                name: candidate.name,
                command: candidate.command,
                args: candidate.args,
                env: [:],
                workingDirectoryPolicy: .workspace,
                inputMode: .oneShotArgument,
                outputMode: .stream,
                supportsStop: true,
                stopSignal: .interrupt,
                transport: .acp
            )
        }
    }

    /// 逐文件加载自定义 agent：坏文件/校验失败/ID 冲突都只跳过并记录警告。
    /// `reservedIDs` 用于让自定义 agent 不能覆盖内置 agent 的 id。
    public static func loadCustomAgents(
        from directory: URL,
        reservedIDs: Set<String> = [],
        executableResolver: (String) -> String? = AgentDetection.resolveExecutable(named:)
    ) -> (agents: [AgentConfig], warnings: [String]) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return ([], [])
        }

        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return ([], ["无法读取 agent 目录：\(error.localizedDescription)"])
        }

        var agents: [AgentConfig] = []
        var warnings: [String] = []
        var seenIDs = reservedIDs

        for file in files {
            do {
                let data = try Data(contentsOf: file)
                let config = try JSONDecoder().decode(AgentConfig.self, from: data)
                try config.validate()

                guard seenIDs.insert(config.id).inserted else {
                    warnings.append("已跳过 \(file.lastPathComponent)：agent id「\(config.id)」与已有配置重复。")
                    continue
                }
                // 非致命问题照常加载,但逐条提醒(可执行缺失/env 键非法/固定目录不存在,#30)。
                warnings.append(contentsOf: config.validationWarnings(executableResolver: executableResolver)
                    .map { "\(file.lastPathComponent)（\(config.name)）：\($0)" })
                agents.append(config)
            } catch {
                warnings.append("已跳过 \(file.lastPathComponent)：\(String(describing: error))")
            }
        }

        return (agents, warnings)
    }
}
