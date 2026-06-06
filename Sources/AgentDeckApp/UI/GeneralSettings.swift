import SwiftUI

/// 「常规」分类的用户偏好。均经 @AppStorage 持久化，键名带 `general.` 前缀，
/// 风格与 AppearanceSettings 一致：枚举 + storageKey + defaultID + resolve(_:)。

/// Agent 启用状态：是否随 App 自动激活 agent。
enum AgentActivationMode: String, CaseIterable, Identifiable {
    case always       // 始终启用
    case onDemand     // 按需启用（打开标签时再起）
    case disabled     // 禁用

    static let storageKey = "general.agentActivation"
    static let defaultID = AgentActivationMode.always.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: "始终启用"
        case .onDemand: "按需启用"
        case .disabled: "禁用"
        }
    }

    static func resolve(_ id: String) -> AgentActivationMode {
        AgentActivationMode(rawValue: id) ?? .always
    }
}

/// 提示词优化 AI 配置：决定输入框「优化」按钮的行为。
/// - useDefault：用当前 agent 一次性改写（开箱即用，无需 API Key）。
/// - custom：走自定义在线服务（需填 Base URL / 模型 / API Key，见 PromptOptimizationSettings）。
/// - disabled：隐藏并停用「优化」按钮。
enum PromptOptimizationMode: String, CaseIterable, Identifiable {
    case useDefault
    case custom
    case disabled

    static let storageKey = "general.promptOptimizationMode"
    static let defaultID = PromptOptimizationMode.useDefault.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .useDefault: "使用默认模型"
        case .custom: "自定义模型（需填写 API）"
        case .disabled: "禁用优化"
        }
    }

    var showsComposerButton: Bool {
        self != .disabled
    }

    var helpText: String {
        switch self {
        case .useDefault:
            "AI 优化：使用默认模型把输入改写得更清晰、具体"
        case .custom:
            "AI 优化：使用自定义模型把输入改写得更清晰、具体"
        case .disabled:
            "提示词优化已禁用"
        }
    }

    static func resolve(_ id: String) -> PromptOptimizationMode {
        PromptOptimizationMode(rawValue: id) ?? .useDefault
    }
}

/// 界面主题：浅色 / 深色 / 跟随系统。经根视图 `.preferredColorScheme(_:)` 应用。
enum AppTheme: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    static let storageKey = "general.appTheme"
    static let defaultID = AppTheme.system.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "亮色"
        case .dark: "暗色"
        case .system: "跟随系统"
        }
    }

    /// 跟随系统返回 nil（不覆盖），由 OS 决定明暗。
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    static func resolve(_ id: String) -> AppTheme {
        AppTheme(rawValue: id) ?? .system
    }
}

/// 界面语言。当前界面文案为中文；此项作为偏好持久化，自动检测＝跟随系统区域。
/// （完整英文本地化尚未提供，故修改后界面文案暂不切换。）
enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans   // 简体中文
    case english  // English
    case auto     // 自动检测

    static let storageKey = "general.appLanguage"
    static let defaultID = AppLanguage.auto.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .zhHans: "简体中文"
        case .english: "English"
        case .auto: "自动检测"
        }
    }

    static func resolve(_ id: String) -> AppLanguage {
        AppLanguage(rawValue: id) ?? .auto
    }
}
