import SwiftUI

@main
struct AgentDeckApp: App {
    // 工作区上提到 App 级：主窗口与「设置」窗口共享同一 @Observable 实例，状态实时同步。
    @State private var workspace = WorkspaceController()
    // 界面字体与主题：作用于两个窗口根部（界面字体不影响显式的代码字体）。
    @AppStorage(InterfaceFont.storageKey) private var interfaceFontID = InterfaceFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue
    @AppStorage(AppTheme.storageKey) private var appThemeID = AppTheme.defaultID

    init() {
        // 忽略 SIGPIPE：向已关闭读端的管道写 stdin 时（子进程早退/崩溃）
        // 默认会用信号杀死整个进程。忽略后写入会返回 EPIPE 错误，由
        // ProcessRunner 捕获并降级为可处理的失败，而不是让 App 崩溃。
        signal(SIGPIPE, SIG_IGN)
        BundledFontRegistrar.register()
    }

    private var interfaceFont: InterfaceFont {
        InterfaceFont.resolve(interfaceFontID)
    }

    private var resolvedAppFontSize: AppFontSize {
        AppFontSize.resolve(appFontSize)
    }

    private var appTheme: AppTheme {
        AppTheme.resolve(appThemeID)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(workspace: workspace)
                .frame(minWidth: 1040, minHeight: 680)
                .interfaceFont(interfaceFont, size: resolvedAppFontSize.points)
                .dynamicTypeSize(resolvedAppFontSize.dynamicTypeSize)
                .preferredColorScheme(appTheme.colorScheme)
        }
        .windowStyle(.hiddenTitleBar)
        // 首次打开的默认尺寸（之前只设了最小尺寸，窗口就按最小值开，偏小）。
        .defaultSize(width: 1360, height: 900)

        // 独立「设置」窗口（自定义左分类栏 + 右面板的两栏布局）。
        Window("设置", id: AgentDeckApp.settingsWindowID) {
            SettingsWindowView(workspace: workspace)
                .interfaceFont(interfaceFont, size: resolvedAppFontSize.points)
                .dynamicTypeSize(resolvedAppFontSize.dynamicTypeSize)
                .preferredColorScheme(appTheme.colorScheme)
        }
        .defaultSize(width: 780, height: 540)
        .windowResizability(.contentSize)
    }

    static let settingsWindowID = "agentdeck-settings"
}
