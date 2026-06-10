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

    public static func builtInPresets(executableResolver: (String) -> String?) -> [AgentConfig] {
        let candidates: [
            (
                id: String,
                name: String,
                executable: String,
                args: [String],
                inputMode: AgentConfig.InputMode,
                outputMode: AgentConfig.OutputMode
            )
        ] = [
            (
                "claude-code",
                "Claude Code",
                "claude",
                ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"],
                .oneShotArgument,
                .jsonLines
            ),
            ("codex", "Codex", "codex", ["exec"], .oneShotArgument, .jsonLines),
            ("opencode", "OpenCode", "opencode", ["run"], .oneShotArgument, .jsonLines),
            ("pi-local", "Pi", "pi", ["chat", "--stdio"], .stdin, .stream)
        ]

        return candidates.compactMap { candidate in
            guard let command = executableResolver(candidate.executable) else {
                return nil
            }

            return AgentConfig(
                id: candidate.id,
                name: candidate.name,
                command: command,
                args: candidate.args,
                env: [:],
                workingDirectoryPolicy: .workspace,
                inputMode: candidate.inputMode,
                outputMode: candidate.outputMode,
                supportsStop: true,
                stopSignal: .interrupt
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
