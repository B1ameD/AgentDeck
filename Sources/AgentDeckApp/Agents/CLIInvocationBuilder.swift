import Foundation

/// 一次具体的进程调用：参数列表 + 可选 stdin。
public struct CLIInvocation: Equatable, Sendable {
    public var arguments: [String]
    public var stdin: String?

    public init(arguments: [String], stdin: String? = nil) {
        self.arguments = arguments
        self.stdin = stdin
    }
}

/// 把会话设置（模型 / 推理强度 / 模式 / 命令 / 附件）按目标 CLI 的**真实**参数
/// 约定翻译成调用。claude / opencode 的 flag 已对照本机 `--help` 核实；
/// codex / pi 本机未安装，按已知约定实现并在注释中标注「未验证」。
public enum CLIInvocationBuilder {
    public static func build(
        agent: AgentConfig,
        prompt: String,
        model: String,
        reasoningEffort: ReasoningEffort,
        interactionMode: InteractionMode,
        command: AgentCommand,
        attachments: [URL],
        sessionID: String? = nil,
        externalSessionID: String? = nil,
        conversationTitle: String? = nil,
        resumeSessionID: String? = nil,
        mcpAskEndpoint: String? = nil
    ) -> CLIInvocation {
        switch agent.kind {
        case .claudeCode:
            return claude(
                agent, prompt, model, reasoningEffort, interactionMode, command,
                attachments, sessionID, externalSessionID, resumeSessionID, mcpAskEndpoint
            )
        case .openCode:
            return opencode(agent, prompt, model, reasoningEffort, command, attachments, externalSessionID, conversationTitle)
        case .codex:
            return codex(agent, prompt, model, reasoningEffort, command, attachments, externalSessionID)
        case .pi, .custom:
            // pi 为未知 CLI、custom 由用户自定义：都不注入任何未知 flag，
            // 仅透传静态 args + prompt（附件并入文本），避免发出 CLI 不认识的参数。
            return passthrough(agent, prompt, attachments)
        }
    }

    // MARK: - Claude Code（已核实：-p / --model / --effort / -r --resume / -c --continue / --permission-mode）

    // swiftlint:disable:next function_parameter_count
    private static func claude(
        _ agent: AgentConfig,
        _ prompt: String,
        _ model: String,
        _ effort: ReasoningEffort,
        _ mode: InteractionMode,
        _ command: AgentCommand,
        _ attachments: [URL],
        _ sessionID: String?,
        _ externalSessionID: String?,
        _ resumeSessionID: String?,
        _ mcpAskEndpoint: String?
    ) -> CLIInvocation {
        var args = agent.args // 通常是 ["-p"]

        // 内置 MCP 提问工具：暴露一个**阻塞**的 ask_user，并禁用内置 AskUserQuestion，
        // 让 Claude 需要提问时调用它（在 AgentDeck 里弹卡片、等用户作答、原地继续），而非自行假设答案。
        if let endpoint = mcpAskEndpoint, let config = mcpConfigJSON(endpoint: endpoint) {
            args += ["--mcp-config", config]
            args += ["--disallowedTools", "AskUserQuestion"]
            args += ["--append-system-prompt",
                     "When you need the user to choose between options or to clarify intent, call the mcp__agentdeck__ask_user tool and wait for the answer — do not guess, and do not use AskUserQuestion."]
        }

        if let model = normalizedModel(model) {
            args += ["--model", model]
        }
        if effort != .medium {
            // claude --effort 取值 low/medium/high/xhigh/max，与本应用枚举 rawValue 一一对应。
            args += ["--effort", effort.rawValue]
        }
        switch mode {
        case .plan:
            args += ["--permission-mode", "plan"]
        case .build:
            // AgentDeck 以 `-p` 非交互方式运行 Claude Code，Claude 自己的审批提示
            // 无法回传到我们的 SwiftUI 弹窗；Build 仍经过 AgentDeck 自己的权限确认，
            // 通过后使用 Claude 的 bypassPermissions 模式执行。
            args += ["--permission-mode", "bypassPermissions"]
        }
        switch command {
        case .new:
            if let id = normalized(externalSessionID) {
                args += ["--resume", id]
            }
        case .resume:
            // -p（非交互）模式下 --resume 需要 session id；从历史会话选中后透传具体 id，
            // 未选则退回裸 --resume。
            if let id = resumeSessionID, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                args += ["--resume", id]
            } else {
                args += ["--resume"]
            }
        case .continueLast:
            args += ["--continue"]
        }

        // 附件：claude 的 --file 指远端 file 资源而非本地路径，故以 @路径 形式并入 prompt。
        return place(prompt: promptWithAttachments(prompt, attachments), into: agent, args: args)
    }

    // MARK: - OpenCode（已核实：run -m provider/model / --variant / -c / -s / -f 本地附件）

    private static func opencode(
        _ agent: AgentConfig,
        _ prompt: String,
        _ model: String,
        _ effort: ReasoningEffort,
        _ command: AgentCommand,
        _ attachments: [URL],
        _ externalSessionID: String?,
        _ conversationTitle: String?
    ) -> CLIInvocation {
        var args = agent.args // 通常是 ["run"]

        if agent.outputMode == .jsonLines {
            args += ["--format", "json"]
            // OpenCode 的 raw JSON 只有显式开启 --thinking 才会 emit reasoning part；
            // parser 已把 reasoning part 折叠成「思考过程」。
            args += ["--thinking"]
        }
        if let model = normalizedModel(model) {
            args += ["-m", model] // 形如 provider/model
        }
        switch effort {
        case .low:
            args += ["--variant", "minimal"]
        case .medium:
            break
        case .high, .xhigh, .max:
            // opencode 仅有 minimal/high 档；xhigh/max 一并夹到 high。
            args += ["--variant", "high"]
        }
        // opencode run 无 permission-mode，plan/build 暂不映射。
        switch command {
        case .new:
            if let id = normalized(externalSessionID) {
                args += ["-s", id]
            } else if let title = normalized(conversationTitle) {
                args += ["--title", title]
            }
        case .resume, .continueLast:
            if let id = normalized(externalSessionID) {
                args += ["-s", id]
            } else {
                args += ["-c"]
            }
        }
        // opencode 原生支持本地附件 -f <path>，无需并入 prompt。
        for url in attachments {
            args += ["-f", url.path]
        }
        if !attachments.isEmpty {
            // OpenCode 的 -f 是 array flag，会吞后续 positional prompt；-- 显式终止解析。
            args += ["--"]
        }

        return place(prompt: prompt, into: agent, args: args)
    }

    // MARK: - Codex（本机未安装，未验证；按 `codex exec` 已知约定实现）

    private static func codex(
        _ agent: AgentConfig,
        _ prompt: String,
        _ model: String,
        _ effort: ReasoningEffort,
        _ command: AgentCommand,
        _ attachments: [URL],
        _ externalSessionID: String?
    ) -> CLIInvocation {
        var args = agent.args // 通常是 ["exec"]

        switch command {
        case .new:
            if normalized(externalSessionID) != nil {
                args += ["resume"]
            }
        case .resume:
            args += ["resume"]
        case .continueLast:
            args += ["resume", "--last"]
        }
        if agent.outputMode == .jsonLines {
            args += ["--json"]
        }
        if let model = normalizedModel(model) {
            args += ["-m", model]
        }
        if effort != .medium {
            // codex 通过配置覆盖设置推理强度（未在本机验证）。
            args += ["-c", "model_reasoning_effort=\(effort.rawValue)"]
        }
        if case .new = command, let id = normalized(externalSessionID) {
            args += [id]
        }

        return place(prompt: promptWithAttachments(prompt, attachments), into: agent, args: args)
    }

    // MARK: - 通用透传（pi / custom）

    private static func passthrough(
        _ agent: AgentConfig,
        _ prompt: String,
        _ attachments: [URL]
    ) -> CLIInvocation {
        place(prompt: promptWithAttachments(prompt, attachments), into: agent, args: agent.args)
    }

    // MARK: - 公共助手

    /// 按 inputMode 决定 prompt 是作为最后一个位置参数，还是写入 stdin。
    private static func place(prompt: String, into agent: AgentConfig, args: [String]) -> CLIInvocation {
        switch agent.inputMode {
        case .stdin:
            return CLIInvocation(arguments: args, stdin: prompt)
        case .oneShotArgument:
            return CLIInvocation(arguments: args + [prompt], stdin: nil)
        }
    }

    private static func promptWithAttachments(_ prompt: String, _ attachments: [URL]) -> String {
        guard !attachments.isEmpty else { return prompt }
        let list = attachments.map { "@\($0.path)" }.joined(separator: "\n")
        return prompt + "\n\n附件：\n" + list
    }

    /// `--mcp-config` 的内联 JSON：注册名为 agentdeck 的 http MCP 服务（指向进程内 AskUserMCPServer）。
    private static func mcpConfigJSON(endpoint: String) -> String? {
        let config: [String: Any] = ["mcpServers": ["agentdeck": ["type": "http", "url": endpoint]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedModel(_ model: String) -> String? {
        guard let trimmed = normalized(model), trimmed != "default" else { return nil }
        return trimmed
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
