import SwiftUI
import AppKit

/// 设计令牌：统一调色板、间距、圆角、材质与阴影。风格＝浅色 IDE 工作台 + 海蓝主色。
/// 视图层应优先使用这里的令牌，避免散落的硬编码颜色/间距。
enum Theme {
    /// 强调色：海蓝。
    static let accent = dynamicColor(
        light: rgb(0.13, 0.45, 0.92),
        dark: rgb(0.38, 0.62, 1.00)
    )
    static let accentSoft = accent.opacity(0.12)
    static let accentStrong = dynamicColor(
        light: rgb(0.08, 0.32, 0.72),
        dark: rgb(0.62, 0.78, 1.00)
    )

    static let appBackground = dynamicColor(
        light: rgb(0.945, 0.965, 0.988),
        dark: rgb(0.070, 0.084, 0.102)
    )
    static let panel = dynamicColor(
        light: rgb(0.970, 0.980, 0.995),
        dark: rgb(0.095, 0.110, 0.132)
    )
    static let panelRaised = dynamicColor(
        light: .white,
        dark: rgb(0.125, 0.142, 0.168)
    )
    static let railSurface = dynamicColor(
        light: rgb(0.975, 0.985, 0.998),
        dark: rgb(0.105, 0.120, 0.145)
    )
    static let canvas = dynamicColor(
        light: rgb(0.945, 0.965, 0.988),
        dark: rgb(0.070, 0.084, 0.102)
    )
    static let composerSurface = dynamicColor(
        light: rgb(1.000, 1.000, 1.000, alpha: 0.58),
        dark: rgb(0.125, 0.142, 0.168, alpha: 0.92)
    )
    static let control = dynamicColor(
        light: rgb(1.000, 1.000, 1.000, alpha: 0.88),
        dark: rgb(0.158, 0.178, 0.210, alpha: 0.95)
    )
    static let controlHover = dynamicColor(
        light: rgb(0.910, 0.940, 0.980),
        dark: rgb(0.190, 0.220, 0.265)
    )
    static let selected = accent.opacity(0.12)
    static let border = dynamicColor(
        light: rgb(0.780, 0.830, 0.890),
        dark: rgb(0.280, 0.325, 0.390)
    )

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 22
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 10
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    static let hairline = border.opacity(0.72)
    static let shadowColor = dynamicColor(
        light: rgb(0.000, 0.000, 0.000, alpha: 0.07),
        dark: rgb(0.000, 0.000, 0.000, alpha: 0.34)
    )
    static let railShadowColor = dynamicColor(
        light: rgb(0.080, 0.140, 0.240, alpha: 0.11),
        dark: rgb(0.000, 0.000, 0.000, alpha: 0.28)
    )

    /// 冷静的工作台背景，保留轻微层次但不抢界面内容。
    static let backgroundGradient = LinearGradient(
        colors: [
            dynamicColor(light: rgb(0.938, 0.958, 0.984), dark: rgb(0.058, 0.070, 0.088)),
            dynamicColor(light: rgb(0.955, 0.972, 0.992), dark: rgb(0.080, 0.096, 0.118))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func surface(_ opacity: Double) -> Color { panel.opacity(opacity) }

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        })
    }
}

extension View {
    /// 工作台面板：浅色表面 + 细描边 + 克制阴影。
    func workbenchCard(radius: CGFloat = Theme.Radius.md) -> some View {
        background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.shadowColor, radius: 8, y: 2)
    }

    /// 兼容旧调用点；视觉上已切换为工作台卡片。
    func glassCard(radius: CGFloat = Theme.Radius.md) -> some View {
        workbenchCard(radius: radius)
    }
}
