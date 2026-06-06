import SwiftUI
import AppKit

/// 每个 agent 家族的可视标识，让左栏标签一眼看出用的是哪个 agent。
/// 优先用随包内置的官方品牌图标（Resources/AgentIcons/*.png）；没有图标的（pi/自定义）回落 SF Symbol。
enum AgentVisuals {
    /// 真实品牌图标（claude / codex / opencode）。无则返回 nil，由调用方回落到 SF Symbol。
    @MainActor
    static func iconImage(for kind: AgentConfig.Kind) -> NSImage? {
        guard let name = assetName(for: kind) else { return nil }
        return AgentIconCache.shared.image(named: name)
    }

    private static func assetName(for kind: AgentConfig.Kind) -> String? {
        switch kind {
        case .claudeCode: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        case .pi, .custom: nil
        }
    }

    /// SF Symbol 回落（pi/自定义，或图标资源缺失时）。
    static func icon(for kind: AgentConfig.Kind) -> String {
        switch kind {
        case .claudeCode: "sparkles"
        case .openCode: "chevron.left.forwardslash.chevron.right"
        case .codex: "cpu"
        case .pi: "function"
        case .custom: "terminal"
        }
    }

    static func tint(for kind: AgentConfig.Kind) -> Color {
        switch kind {
        case .claudeCode: Color(red: 0.85, green: 0.46, blue: 0.24)
        case .openCode: Color(red: 0.20, green: 0.62, blue: 0.55)
        case .codex: Color(red: 0.36, green: 0.42, blue: 0.85)
        case .pi: Color(red: 0.80, green: 0.36, blue: 0.62)
        case .custom: Color.secondary
        }
    }
}

/// 进程内图标缓存：按名加载一次 NSImage（标签反复重绘时不重复读盘）。
@MainActor
private final class AgentIconCache {
    static let shared = AgentIconCache()
    private var cache: [String: NSImage?] = [:]

    func image(named name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = AgentIconCache.url(named: name).flatMap { NSImage(contentsOf: $0) }
        cache[name] = image
        return image
    }

    /// 解析图标 URL：打包版走 `Bundle.main.resourceURL/AgentIcons/<name>.png`（package_app.sh 复制而来）；
    /// SwiftPM（swift run/test）走 `Bundle.module`（Package.swift 的 .process("Resources")）。与字体加载同源。
    private static func url(named name: String) -> URL? {
        if let base = Bundle.main.resourceURL {
            for candidate in [
                base.appending(path: "AgentIcons", directoryHint: .isDirectory).appending(path: "\(name).png"),
                base.appending(path: "\(name).png")
            ] where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if Bundle.main.bundleIdentifier != "com.agentdeck.app" {
            if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "AgentIcons") {
                return url
            }
            if let url = Bundle.module.url(forResource: name, withExtension: "png") {
                return url
            }
        }
        return nil
    }
}
