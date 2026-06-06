import SwiftUI

/// 「个性化」分类的用户偏好。键名带 `personalization.` 前缀。
/// 这些项作为偏好持久化，描述用户期望的 agent 风格 / 系统提示 / 指令集；
/// 是否进一步注入到具体 CLI 调用由后续接线决定（当前以持久化偏好为主）。

/// Agent 行为规则：在「严格遵循」与「自由发挥」之间取舍。
enum AgentBehaviorRule: String, CaseIterable, Identifiable {
    case strict     // 严格遵循指令
    case balanced   // 平衡灵活与安全
    case freeform   // 最大自由度

    static let storageKey = "personalization.behaviorRule"
    static let defaultID = AgentBehaviorRule.balanced.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .strict: "严格遵循指令"
        case .balanced: "平衡灵活与安全"
        case .freeform: "最大自由度"
        }
    }

    static func resolve(_ id: String) -> AgentBehaviorRule {
        AgentBehaviorRule(rawValue: id) ?? .balanced
    }
}

/// System Prompt 预设：提供若干模板并支持自定义。
/// 选中非 custom 预设时把模板文本写入编辑框；用户改动则切到 custom 并存入 customTextKey。
enum SystemPromptPreset: String, CaseIterable, Identifiable {
    case assistant       // 默认助手
    case codeExpert      // 代码专家
    case creativeWriter  // 创意写作
    case custom          // 自定义

    static let storageKey = "personalization.systemPromptPreset"
    static let customTextKey = "personalization.systemPromptCustom"
    static let defaultID = SystemPromptPreset.assistant.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .assistant: "默认助手"
        case .codeExpert: "代码专家"
        case .creativeWriter: "创意写作"
        case .custom: "自定义"
        }
    }

    /// 预设模板文本；custom 无固定模板（返回空串，改用 customTextKey 中的内容）。
    var template: String {
        switch self {
        case .assistant:
            "你是一个乐于助人、回答简洁准确的通用助手。优先给出可执行的结论，再按需补充说明。"
        case .codeExpert:
            "你是一名资深软件工程师。给出地道、可维护的代码，解释关键取舍，主动指出潜在 bug 与边界情况。"
        case .creativeWriter:
            "你是一位富有想象力的中文创意写作者。注重画面感与节奏，避免空洞辞藻与套路化表达。"
        case .custom:
            ""
        }
    }

    static func resolve(_ id: String) -> SystemPromptPreset {
        SystemPromptPreset(rawValue: id) ?? .assistant
    }
}

/// Instructions：预设指令集。
enum InstructionPreset: String, CaseIterable, Identifiable {
    case general         // 通用
    case taskManagement  // 任务管理
    case dataAnalysis    // 数据分析

    static let storageKey = "personalization.instructions"
    static let defaultID = InstructionPreset.general.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "通用"
        case .taskManagement: "任务管理"
        case .dataAnalysis: "数据分析"
        }
    }

    /// 指令集摘要，用于界面说明与（后续）注入。
    var summary: String {
        switch self {
        case .general: "按常识完成请求，缺信息时先澄清。"
        case .taskManagement: "把目标拆成可跟踪的步骤，逐项推进并汇报进度。"
        case .dataAnalysis: "以数据为依据，列出假设、方法与结论，必要时给出图表建议。"
        }
    }

    static func resolve(_ id: String) -> InstructionPreset {
        InstructionPreset(rawValue: id) ?? .general
    }
}
