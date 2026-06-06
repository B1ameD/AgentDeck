import SwiftUI
import AppKit

/// 外观相关的用户偏好（均经 @AppStorage 持久化，键名带 `appearance.` 前缀）。
/// 与 BundledCodeFont 同风格：枚举 + storageKey + resolve(_:)。

/// 转录（聊天消息）文字大小。映射到 DynamicTypeSize，对消息列表整体缩放语义字体。
enum TranscriptTextSize: String, CaseIterable, Identifiable {
    case small, medium, large

    static let storageKey = "appearance.transcriptTextSize"
    static let defaultID = TranscriptTextSize.medium.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: "小"
        case .medium: "中"
        case .large: "大"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .small
        case .medium: .large // SwiftUI 默认档
        case .large: .xLarge
        }
    }

    static func resolve(_ id: String) -> TranscriptTextSize {
        TranscriptTextSize(rawValue: id) ?? .medium
    }
}

/// 全局字号（px）：作为应用根视图的界面字号基准，同时被代码/等宽区域复用。
/// 10–24，步进 2（共 8 档）。用 Int 原值，便于 @AppStorage 直存。
enum AppFontSize: Int, CaseIterable, Identifiable {
    case s10 = 10, s12 = 12, s14 = 14, s16 = 16, s18 = 18, s20 = 20, s22 = 22, s24 = 24

    static let storageKey = "appearance.fontSize"
    static let defaultValue = AppFontSize.s14.rawValue // 贴近原硬编码 13px，取最接近的偶数档

    var id: Int { rawValue }

    /// 选项文案（如「14」）。
    var label: String { "\(rawValue)" }

    /// 实际点数。
    var points: CGFloat { CGFloat(rawValue) }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .s10: .xSmall
        case .s12: .small
        case .s14: .medium
        case .s16: .large
        case .s18: .xLarge
        case .s20: .xxLarge
        case .s22: .xxxLarge
        case .s24: .accessibility1
        }
    }

    static func resolve(_ value: Int) -> AppFontSize {
        AppFontSize(rawValue: value) ?? .s14
    }

    /// 直接拿点数，省去调用点反复 resolve。
    static func points(_ value: Int) -> CGFloat {
        resolve(value).points
    }
}

/// 代码块主题：浅色（沿用现有浅灰底）/ 深色（浅色 UI 里放深色代码框，常见做法；非语法高亮）。
enum CodeBlockTheme: String, CaseIterable, Identifiable {
    case light, dark

    static let storageKey = "appearance.codeBlockTheme"
    static let defaultID = CodeBlockTheme.light.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var background: Color {
        switch self {
        case .light: Color.black.opacity(0.06)
        case .dark: Color(red: 0.13, green: 0.145, blue: 0.17)
        }
    }

    var foreground: Color {
        switch self {
        case .light: .primary
        case .dark: Color(red: 0.92, green: 0.93, blue: 0.96)
        }
    }

    var secondaryForeground: Color {
        switch self {
        case .light: .secondary
        case .dark: Color.white.opacity(0.55)
        }
    }

    var nsBackground: NSColor {
        switch self {
        case .light: NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        case .dark: NSColor(red: 0.13, green: 0.145, blue: 0.17, alpha: 1)
        }
    }

    var nsForeground: NSColor {
        switch self {
        case .light: .labelColor
        case .dark: NSColor(red: 0.92, green: 0.93, blue: 0.96, alpha: 1)
        }
    }

    var nsSecondaryForeground: NSColor {
        switch self {
        case .light: .secondaryLabelColor
        case .dark: NSColor.white.withAlphaComponent(0.55)
        }
    }

    /// 代码卡片描边色（围栏块的圆角边框）。浅色用细分隔线，深色用低透明白线。
    var nsBorder: NSColor {
        switch self {
        case .light: NSColor.black.withAlphaComponent(0.10)
        case .dark: NSColor.white.withAlphaComponent(0.10)
        }
    }

    /// 语法高亮配色（VS Code Dark+/Light 风格、略调柔）。普通标识符不在此列，沿用前景色。
    var syntaxPalette: CodeSyntaxPalette {
        switch self {
        case .light:
            return CodeSyntaxPalette(
                keyword: NSColor(srgbRed: 0.61, green: 0.14, blue: 0.58, alpha: 1),   // 紫红
                type: NSColor(srgbRed: 0.15, green: 0.50, blue: 0.60, alpha: 1),       // 青
                string: NSColor(srgbRed: 0.64, green: 0.08, blue: 0.08, alpha: 1),     // 砖红
                number: NSColor(srgbRed: 0.04, green: 0.52, blue: 0.35, alpha: 1),     // 绿
                comment: NSColor(srgbRed: 0.42, green: 0.46, blue: 0.50, alpha: 1)     // 灰
            )
        case .dark:
            return CodeSyntaxPalette(
                keyword: NSColor(srgbRed: 0.34, green: 0.61, blue: 0.84, alpha: 1),    // 蓝
                type: NSColor(srgbRed: 0.31, green: 0.79, blue: 0.69, alpha: 1),       // 青绿
                string: NSColor(srgbRed: 0.81, green: 0.57, blue: 0.47, alpha: 1),     // 赭
                number: NSColor(srgbRed: 0.71, green: 0.81, blue: 0.66, alpha: 1),     // 浅绿
                comment: NSColor(srgbRed: 0.42, green: 0.60, blue: 0.40, alpha: 1)     // 灰绿
            )
        }
    }

    static func resolve(_ id: String) -> CodeBlockTheme {
        CodeBlockTheme(rawValue: id) ?? .light
    }
}

/// 界面字体：作用于全局 UI（菜单/侧栏/聊天等界面文字），不影响显式指定的代码字体。
/// 提供两类非等宽选项——
///   1. 系统设计变体（系统/圆体/衬线）：经 `.fontDesign(_:)` 应用，保留语义字号层级；
///   2. 命名字体族（PingFang SC/Helvetica Neue/Avenir Next/Arial/Verdana/Georgia）：
///      只保留本机可解析字体，避免静默回落后看起来和系统默认一致。
/// 默认为「系统默认」，即维持现有外观。
enum InterfaceFont: String, CaseIterable, Identifiable {
    case system
    case rounded
    case serif
    case pingFangSC
    case helveticaNeue
    case avenirNext
    case arial
    case verdana
    case georgia

    static let storageKey = "appearance.interfaceFont"
    static let defaultID = InterfaceFont.system.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "系统默认"
        case .rounded: "圆体"
        case .serif: "衬线"
        case .pingFangSC: "PingFang SC"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .arial: "Arial"
        case .verdana: "Verdana"
        case .georgia: "Georgia"
        }
    }

    var fontDesign: Font.Design? {
        switch self {
        case .system: .default
        case .rounded: .rounded
        case .serif: .serif
        case .pingFangSC, .helveticaNeue, .avenirNext, .arial, .verdana, .georgia: nil
        }
    }

    /// 写入 SwiftUI fontDesign 环境的设计值。命名字体必须返回 nil，否则
    /// `.fontDesign(.default)` 会覆盖 `.custom(...)`，表现为所有命名字体都回落到系统默认。
    var environmentFontDesign: Font.Design? {
        familyName == nil ? fontDesign : nil
    }

    var familyName: String? {
        switch self {
        case .system, .rounded, .serif: nil
        case .pingFangSC: "PingFang SC"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        case .arial: "Arial"
        case .verdana: "Verdana"
        case .georgia: "Georgia"
        }
    }

    static func resolve(_ id: String) -> InterfaceFont {
        InterfaceFont(rawValue: id) ?? .system
    }

    func rootFont(size: CGFloat) -> Font {
        font(size: size)
    }

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let familyName {
            return .custom(familyName, size: size, relativeTo: .body).weight(weight)
        }
        return .system(size: size, weight: weight, design: fontDesign ?? .default)
    }

    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let familyName, let font = NSFont(name: familyName, size: size) {
            return font
        }

        let fallback = NSFont.systemFont(ofSize: size, weight: weight)
        guard let systemDesign else { return fallback }
        guard let descriptor = fallback.fontDescriptor.withDesign(systemDesign) else { return fallback }
        return NSFont(descriptor: descriptor, size: size) ?? fallback
    }

    private var systemDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .rounded: .rounded
        case .serif: .serif
        case .system, .pingFangSC, .helveticaNeue, .avenirNext, .arial, .verdana, .georgia: nil
        }
    }
}

/// 把所选界面字体与全局字号套到视图根部。modifier 的结构保持稳定，避免在
/// 系统设计字体和命名字体之间切换时重建子树、清空 SettingsWindowView 的 @State。
struct InterfaceFontModifier: ViewModifier {
    let font: InterfaceFont
    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .font(font.rootFont(size: size))
            .fontDesign(font.environmentFontDesign)
    }
}

private struct AppInterfaceFontModifier: ViewModifier {
    let size: CGFloat?
    let relative: CGFloat
    let weight: Font.Weight
    @AppStorage(InterfaceFont.storageKey) private var interfaceFontID = InterfaceFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue

    private var selectedFont: InterfaceFont {
        InterfaceFont.resolve(interfaceFontID)
    }

    private var points: CGFloat {
        max(8, size ?? (AppFontSize.points(appFontSize) + relative))
    }

    func body(content: Content) -> some View {
        content
            .font(selectedFont.font(size: points, weight: weight))
            .fontDesign(selectedFont.environmentFontDesign)
    }
}

extension View {
    /// 应用界面字体偏好（见 InterfaceFontModifier）。
    func interfaceFont(_ font: InterfaceFont, size: CGFloat) -> some View {
        modifier(InterfaceFontModifier(font: font, size: size))
    }

    /// 对显式文本样式使用界面字体偏好；用于替代 `.font(.caption/.body/.system(...))`
    /// 这类会覆盖根视图界面字体的调用。
    func appFont(size: CGFloat? = nil, relative: CGFloat = 0, weight: Font.Weight = .regular) -> some View {
        modifier(AppInterfaceFontModifier(size: size, relative: relative, weight: weight))
    }
}
