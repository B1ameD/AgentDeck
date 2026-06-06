import AppKit
import CoreText
import SwiftUI

enum BundledCodeFont: String, CaseIterable, Identifiable {
    // 前四种为随包内置的 TTF（见 Resources/Fonts），后两种为 macOS 系统自带等宽字体
    // （不随包发布，运行时按 PostScript 名解析；缺失时 nsFont(size:) 回落系统等宽）。
    case jetBrainsMono
    case firaCode
    case cascadiaCode
    case ubuntuMono
    case menlo
    case monaco

    static let storageKey = "codeFontID"
    static let defaultID = BundledCodeFont.jetBrainsMono.rawValue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .jetBrainsMono: "JetBrains Mono"
        case .firaCode: "Fira Code"
        case .cascadiaCode: "Cascadia Code"
        case .ubuntuMono: "Ubuntu Mono"
        case .menlo: "Menlo"
        case .monaco: "Monaco"
        }
    }

    var postScriptName: String {
        switch self {
        case .jetBrainsMono: "JetBrainsMono-Regular"
        case .firaCode: "FiraCode-Regular"
        case .cascadiaCode: "CascadiaCode-Regular"
        case .ubuntuMono: "UbuntuMono-Regular"
        case .menlo: "Menlo-Regular"
        case .monaco: "Monaco"
        }
    }

    static func resolve(_ id: String) -> BundledCodeFont {
        BundledCodeFont(rawValue: id) ?? .jetBrainsMono
    }

    func swiftUIFont(size: CGFloat) -> Font {
        Font.custom(postScriptName, size: size)
    }

    func nsFont(size: CGFloat) -> NSFont {
        NSFont(name: postScriptName, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

enum BundledFontRegistrar {
    static func register() {
        for url in fontURLs() {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func fontURLs() -> [URL] {
        var urls: [URL] = []
        if let resourcesURL = Bundle.main.resourceURL {
            for directoryURL in [
                resourcesURL,
                resourcesURL.appending(path: "Fonts", directoryHint: .isDirectory)
            ] {
                if let bundleURLs = try? FileManager.default.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                ) {
                    urls.append(contentsOf: bundleURLs.filter { $0.pathExtension.lowercased() == "ttf" })
                }
            }
        }
        if Bundle.main.bundleIdentifier != "com.agentdeck.app" {
            if let packageURLs = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: nil) {
                urls.append(contentsOf: packageURLs)
            }
            if let packageURLs = Bundle.module.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts") {
                urls.append(contentsOf: packageURLs)
            }
        }
        return Array(Set(urls)).sorted { $0.path < $1.path }
    }
}
