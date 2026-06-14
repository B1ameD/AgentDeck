import Foundation

/// 在输入框键入 “/” 时弹出的快捷指令。token 形如 "/plan"；选中后 action 落到当前会话。
public struct SlashCommand: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case setCommand(AgentCommand)
        case setMode(InteractionMode)
        case stop
        case clear
        case claudeLogin
        /// 进入「输入模型名」态（/model 带参数），由 UI 切到模型建议菜单。
        case startModelInput
        /// 透传给底层 CLI 的原生指令（自定义命令 / 技能）：不拦截，原样作为 prompt 发送。
        case passthrough
    }

    public let token: String   // 形如 "/plan"
    public let summary: String // 功能说明（菜单里展示）
    public let action: Action

    public var id: String { token }

    public init(token: String, summary: String, action: Action) {
        self.token = token
        self.summary = summary
        self.action = action
    }
}

/// 斜杠指令表与匹配逻辑（与 UI 解耦，便于测试）。
public enum SlashCommandMenu {
    /// 全量指令；数组顺序即菜单展示顺序。
    public static let all: [SlashCommand] = [
        SlashCommand(token: "/new", summary: "开始新会话（下次发送不续接历史）", action: .setCommand(.new)),
        SlashCommand(token: "/resume", summary: "恢复历史会话", action: .setCommand(.resume)),
        SlashCommand(token: "/continue", summary: "继续最近一次会话", action: .setCommand(.continueLast)),
        SlashCommand(token: "/compact", summary: "压缩当前上下文（透传给底层 CLI）", action: .passthrough),
        SlashCommand(token: "/login", summary: "登录 Claude 官方账号", action: .claudeLogin),
        SlashCommand(token: "/model", summary: "切换模型（/model <名称>）", action: .startModelInput),
        SlashCommand(token: "/plan", summary: "计划模式（先规划、不改动）", action: .setMode(.plan)),
        SlashCommand(token: "/build", summary: "构建模式（经 AgentDeck 授权后可改动）", action: .setMode(.build)),
        SlashCommand(token: "/stop", summary: "停止当前正在运行的 agent", action: .stop),
        SlashCommand(token: "/clear", summary: "开新会话（旧对话留存历史检索）", action: .clear)
    ]

    /// 当前 agent 实际生效的指令子集。与 CLIInvocationBuilder 的行为对齐，避免菜单
    /// 列出对该 agent 无效的指令（如 pi/custom 走透传，不注入 model/session/mode flag）。
    public static func availableCommands(for agent: AgentConfig) -> [SlashCommand] {
        all.filter { isApplicable($0, to: agent) }
    }

    private static func isApplicable(_ command: SlashCommand, to agent: AgentConfig) -> Bool {
        switch command.action {
        case .setCommand, .startModelInput:
            // new/resume/continue 与 model：仅内置编码 agent（claude/codex/opencode）会注入对应 flag。
            return injectsBuiltInFlags(agent.kind)
        case .setMode:
            // plan/build 在 claude（--permission-mode）、codex（--sandbox）、opencode（提示注入）
            // 三家都已落地；pi/custom 走透传无法注入 mode 语义，故按 supportsPlanMode 门控。
            return agent.supportsPlanMode
        case .claudeLogin:
            return agent.kind == .claudeCode
        case .stop:
            return agent.supportsStop
        case .clear:
            return true // 应用层动作，对任何 agent 有效。
        case .passthrough:
            return true // 原生指令透传，对任何 agent 有效（不在内置表里，仅防御性兜底）。
        }
    }

    private static func injectsBuiltInFlags(_ kind: AgentConfig.Kind) -> Bool {
        switch kind {
        case .claudeCode, .codex, .openCode: return true
        case .pi, .custom: return false
        }
    }

    /// 在 `all` 里按 token 前缀匹配（命令补全态）；非指令态返回 nil。供全量匹配 / 测试使用。
    public static func matches(for text: String) -> [SlashCommand]? {
        tokenMatches(text, in: all)
    }

    /// 解析输入框文本为斜杠菜单状态：命令补全 / 模型参数 / 隐藏。
    /// 指令集 = agent 适用的内置应用指令 + 发现到的原生指令（extraCommands，透传）。
    /// “/model”（若该 agent 支持）或 “/model <query>” 进入模型态。
    /// 输入了未识别的 “/xxx” 时，给出一条「透传给 CLI」的命令，让任何原生指令都能发出去。
    public static func resolve(
        for text: String,
        agent: AgentConfig,
        extraCommands: [SlashCommand] = [],
        modelCatalog: [String] = []
    ) -> SlashInput {
        let available = availableCommands(for: agent) + extraCommands

        if available.contains(where: { $0.action == .startModelInput }),
           let query = modelQuery(in: text) {
            return .models(query: query, suggestions: modelSuggestions(for: agent.kind, query: query, catalog: modelCatalog))
        }
        if let commands = tokenMatches(text, in: available) {
            if commands.isEmpty, text.count >= 2 {
                // “/xxx” 无任何已知匹配 → 提供透传项（原样发给 CLI，由其解析为技能/命令）。
                return .commands([SlashCommand(
                    token: text,
                    summary: "发送给 \(agent.name)（CLI 指令，透传）",
                    action: .passthrough
                )])
            }
            return .commands(commands)
        }
        return .hidden
    }

    private static func tokenMatches(_ text: String, in commands: [SlashCommand]) -> [SlashCommand]? {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else { return nil }
        let query = text.dropFirst().lowercased()
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.token.dropFirst().lowercased().hasPrefix(query) }
    }

    /// 模型预设建议（按 query 子串过滤；query 为空给全量）。模型是自由文本，预设只是快捷入口。
    public static func modelSuggestions(for kind: AgentConfig.Kind, query: String, catalog: [String] = []) -> [String] {
        let base = suggestionBase(for: kind, catalog: catalog)
        let normalized = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty else { return base }
        return base.filter { $0.lowercased().contains(normalized) }
    }

    /// 候选基集。claude：始终把内置预设（含具体版本全名，如 claude-opus-4-8）并入动态目录，
    /// 避免官方登录时 settings.json 只暴露一个别名（如 “opus”）导致选择器只有一项、看不到/选不到具体版本。
    /// 其它 agent：有目录用目录（前置 default），否则回落内置预设。
    private static func suggestionBase(for kind: AgentConfig.Kind, catalog: [String]) -> [String] {
        switch kind {
        case .claudeCode:
            return dedupePreservingOrder(["default"] + catalog + modelPresets(for: kind))
        default:
            return catalog.isEmpty ? modelPresets(for: kind) : (["default"] + catalog)
        }
    }

    private static func dedupePreservingOrder(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    /// claude 给已知别名；其余 agent 模型名各异且无法可靠枚举，仅给 default，靠自由文本输入。
    static func modelPresets(for kind: AgentConfig.Kind) -> [String] {
        switch kind {
        case .claudeCode:
            // claude --model 收别名（解析为最新）或全名。别名在前，再附已知全名。
            ["default", "sonnet", "opus", "haiku",
             "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        default:
            ["default"]
        }
    }

    /// 按**人类可读显示名**去重（保留首个出现项），并排除显示名已在 `shown` 中的项。
    /// 供 /model 菜单去掉重复行：Recent 段已展示的别名不再在分组里重复出现，
    /// 且「别名解析到的具体版本」与「带日期全名」等渲染同名（如都显示 “Opus 4.8”）只保留一项。
    public static func dedupedByDisplayName(_ models: [String], excludingDisplayNames shown: Set<String> = []) -> [String] {
        var seen = shown
        var result: [String] = []
        for model in models where seen.insert(modelDisplayName(model)).inserted {
            result.append(model)
        }
        return result
    }

    /// 按 “provider/” 前缀把模型分组（参考 opencode 选择器）。无 “/” 的（别名/全名）归入 provider=""，
    /// 保持首次出现的分组顺序与组内顺序。
    public static func groupModels(_ models: [String]) -> [ModelGroup] {
        var order: [String] = []
        var grouped: [String: [String]] = [:]
        for model in models {
            let provider = model.firstIndex(of: "/").map { String(model[..<$0]) } ?? ""
            if grouped[provider] == nil { order.append(provider) }
            grouped[provider, default: []].append(model)
        }
        return order.map { ModelGroup(provider: $0, models: grouped[$0] ?? []) }
    }

    /// 已知缩写词表：命中（不区分大小写）则用规范大小写，否则按首字母大写处理。
    public static let modelAcronyms: [String: String] = [
        "gpt": "GPT", "api": "API", "ai": "AI", "llm": "LLM", "vlm": "VLM",
        "tts": "TTS", "stt": "STT", "asr": "ASR", "ocr": "OCR",
        "vl": "VL", "oss": "OSS", "moe": "MoE", "xl": "XL", "hd": "HD", "rl": "RL"
    ]

    /// 人类可读的模型名：去供应商（取最后一个 “/” 之后）、去开头厂商名（claude/anthropic）、
    /// 去结尾 8 位日期段；连续数字段用 “.” 连成版本号，其余段按 “-” 切分、首字母大写，命中缩写词表用规范大小写。
    /// 例：“claude-opus-4-8” → “Opus 4.8”；“anthropic/claude-sonnet-4-6” → “Sonnet 4.6”；
    /// “claude-opus-4-8-20260514” → “Opus 4.8”；“openai/gpt-4o” → “GPT 4o”；“default” → “默认模型”。
    public static func modelDisplayName(_ model: String) -> String {
        if model == "default" { return "默认模型" }
        let name = model.split(separator: "/").last.map(String.init) ?? model
        var segments = name.split(separator: "-").map(String.init)
        // 结尾 8 位日期段（如 …-20260514）只是发布日期，不展示。
        if segments.count > 1, let last = segments.last, isDateSegment(last) {
            segments.removeLast()
        }
        // 开头的厂商名（claude/anthropic）冗余，去掉让芯片更短、版本号更醒目。
        if segments.count > 1, let first = segments.first?.lowercased(),
           first == "claude" || first == "anthropic" {
            segments.removeFirst()
        }
        var result = ""
        for (index, raw) in segments.enumerated() {
            let token = displayToken(raw)
            if index == 0 {
                result = token
            } else if isNumeric(raw) && isNumeric(segments[index - 1]) {
                result += "." + token // 连续数字段 → 版本号：4-8 → 4.8
            } else {
                result += " " + token
            }
        }
        return result.isEmpty ? model : result
    }

    private static func displayToken(_ raw: String) -> String {
        if let acronym = modelAcronyms[raw.lowercased()] { return acronym }
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    private static func isNumeric(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy(\.isNumber)
    }

    private static func isDateSegment(_ value: String) -> Bool {
        value.count == 8 && isNumeric(value)
    }

    /// “/model” → 空 query；“/model <x>” → x；否则 nil（非模型态）。
    private static func modelQuery(in text: String) -> String? {
        if text == "/model" { return "" }
        if text.hasPrefix("/model ") { return String(text.dropFirst("/model ".count)) }
        return nil
    }
}

/// 一组同 provider 的模型（用于分组展示）。provider 为空表示别名/全名等无前缀项。
public struct ModelGroup: Equatable, Sendable {
    public let provider: String
    public let models: [String]
    public init(provider: String, models: [String]) {
        self.provider = provider
        self.models = models
    }
}

/// 斜杠输入的三种状态。
public enum SlashInput: Equatable, Sendable {
    case hidden
    case commands([SlashCommand])
    case models(query: String, suggestions: [String])
}
