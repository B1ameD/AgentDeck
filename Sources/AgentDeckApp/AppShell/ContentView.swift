import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var workspace: WorkspaceController
    @Environment(\.openWindow) private var openWindow
    @State private var filePreviewController: FilePreviewController
    @State private var showingHistory = false
    @State private var terminalLaunch: TerminalLaunch?
    @State private var showFiles = false
    /// 右栏宽度以**归一化比例**持久化（跨启动/窗口尺寸保持相近比例）；0=未保存→用默认 600。
    @AppStorage("app-shell:right-panel-ratio:v2") private var sidebarRatio: Double = 0
    @State private var sidebarWidthOverride: CGFloat? // 拖拽中的实时宽度（不写盘，松手再落比例）
    @State private var sidebarDragBaseline: CGFloat? // 拖动起始宽度基准
    @State private var sidebarDragRawWidth: CGFloat? // 拖动中最近一次原始建议宽度（判断是否拖到要关闭）
    @State private var sidebarSlideX: CGFloat = 0 // 右栏滑入/滑出的水平偏移（0=就位，sidebarWidth=屏外右侧）
    @State private var sidebarRendered = false // 右栏覆盖层是否在视图树里（打开期间 + 关闭滑出期间为真）
    @State private var sidebarCloseGeneration = 0 // 守卫延迟关闭：期间又打开则作废
    @State private var mainAreaWidth: CGFloat = 0
    @State private var sidebarExpandedFolders: Set<URL> = [] // 侧栏已展开文件夹（会话内保留，关侧栏不丢失）
    @State private var sidebarMode: RightSidebarMode = .files
    @State private var sidebarBrowserURL: URL?
    @State private var selectedReviewSummary: TurnDiffSummary?
    @State private var selectedSubagent: SubagentTask? // 「委派任务」点击后在右侧栏展示的子任务明细

    init(workspace: WorkspaceController) {
        self.workspace = workspace
        _filePreviewController = State(
            initialValue: FilePreviewController(
                workspace: workspace.focusedSession?.workingDirectory ?? workspace.workspaceDirectory
            )
        )
    }

    /// 右栏滑入/滑出的弹性动画。约为原来的 2 倍速度（0.5s → 0.26s）。
    private var sidebarSpring: Animation { .spring(duration: 0.26, bounce: 0.1) }

    /// 当前右栏目标宽度：拖拽时用实时覆盖，否则按保存比例还原并夹紧到当前容器（中间栏至少留 352）。
    private var sidebarWidth: CGFloat {
        if let override = sidebarWidthOverride { return override }
        return SidebarSizing.width(forRatio: CGFloat(sidebarRatio), container: mainAreaWidth)
    }

    /// 聊天区为右栏预留的**布局**宽度：拖拽期间冻结为起始值（右栏覆盖层实时跟随鼠标），
    /// 松手才把最终宽度应用到布局——否则每帧改聊天列宽会触发所有可见气泡的全量 TextKit 重排（#2 拖拽卡顿）。
    private var sidebarLayoutWidth: CGFloat { sidebarDragBaseline ?? sidebarWidth }

    /// 开/合都**布局瞬变**（中间栏立刻定到最终宽度、保持贴底），右栏只作为覆盖层以 offset 滑入/滑出。
    /// 故关闭时中间栏不必等右栏滑回——`showFiles` 控制的预留空间立刻归零，右栏在其上方滑走。
    private func openSidebar() {
        guard !showFiles else { return }
        sidebarCloseGeneration += 1            // 取消可能在途的延迟移除
        sidebarRendered = true
        sidebarSlideX = sidebarWidth           // 右栏先停在屏外右侧（无动画）
        showFiles = true                       // 预留空间瞬变：中间栏立刻定到最终宽度（无动画）
        withAnimation(sidebarSpring) { sidebarSlideX = 0 } // 仅 offset 滑入
    }

    private func closeSidebar() {
        guard showFiles else { return }
        sidebarCloseGeneration += 1
        let generation = sidebarCloseGeneration
        showFiles = false                      // 预留空间瞬变：中间栏立刻变宽（不等右栏滑回）
        withAnimation(sidebarSpring) { sidebarSlideX = sidebarWidth } // 覆盖层滑出
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard generation == sidebarCloseGeneration else { return } // 期间又打开了 → 不移除
            sidebarRendered = false             // 滑出完成后再移除覆盖层
            sidebarSlideX = 0
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            leftRail
            mainPageSurface
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingHistory) {
            HistorySearchView(workspace: workspace)
        }
        .onChange(of: workspace.focusedSessionID) { _, _ in
            selectedReviewSummary = nil
            selectedSubagent = nil
            if let directory = workspace.focusedSession?.workingDirectory,
               directory.standardizedFileURL != filePreviewController.workspace.standardizedFileURL {
                filePreviewController.request(.changeWorkspace(directory)) { committed in
                    if case .changeWorkspace(let url) = committed {
                        filePreviewController.setWorkspace(url)
                    }
                }
            }
        }
        .background(GlassBackground())
        .background(AppWindowConfigurator())
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 16) {
            railBrand

            VStack(alignment: .leading, spacing: 8) {
                RailSectionLabel("Agents")
                ForEach(workspace.orderedSessions) { session in
                    AgentTabRow(
                        session: session,
                        isSelected: workspace.focusedSessionID == session.id,
                        showWorkspace: showWorkspaceOnTabs,
                        onFocus: { workspace.focusSession(id: session.id) },
                        onClose: { workspace.closeSession(id: session.id) },
                        onRename: { workspace.renameSession(id: session.id, to: $0) },
                        onTogglePin: { workspace.togglePinSession(id: session.id) },
                        onDelete: { workspace.deleteConversation(id: session.id.uuidString) },
                        onSetWorkingDirectory: { chooseSessionDirectory(for: session) },
                        onUnpinWorkingDirectory: { workspace.clearSessionDirectoryPin(id: session.id) },
                        onRevealWorkspace: { NSWorkspace.shared.activateFileViewerSelecting([session.workingDirectory]) },
                        onCopyWorkspacePath: { copyToPasteboard(session.workingDirectory.path) }
                    )
                }
                if workspace.sessions.isEmpty {
                    Text("No active panes")
                        .appFont(relative: -2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    RailSectionLabel("Recent")
                    Spacer()
                    if !workspace.recentConversations.isEmpty {
                        Button { workspace.clearRecents() } label: {
                            Image(systemName: "trash")
                                .appFont(relative: -3)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("清空最近（不删除历史记录）")
                    }
                }
                if workspace.recentConversations.isEmpty {
                    Text("暂无")
                        .appFont(relative: -3)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                }
                ForEach(workspace.recentConversations) { convo in
                    RecentConversationRow(
                        conversation: convo,
                        onOpen: { workspace.reopenConversation(id: convo.id) },
                        onRemoveFromRecent: { workspace.dismissRecent(id: convo.id) },
                        onDelete: { workspace.deleteConversation(id: convo.id) }
                    )
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                workspaceRow
                addAgentMenu
                RailActionButton(title: "历史检索", systemImage: "magnifyingglass") {
                    showingHistory = true
                }
                RailActionButton(title: "设置", systemImage: "gearshape") {
                    openWindow(id: AgentDeckApp.settingsWindowID)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(width: 238)
        .background(Theme.railSurface, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .stroke(Theme.border.opacity(0.58), lineWidth: 1)
        }
        .shadow(color: Theme.railShadowColor, radius: 22, x: 0, y: 12)
        .shadow(color: Theme.shadowColor.opacity(0.45), radius: 5, x: 0, y: 1)
    }

    private var railBrand: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AgentDeck")
                .appFont(relative: 7, weight: .semibold)
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .appFont(relative: -2)
                    .foregroundStyle(Theme.accent)
                Text(workspace.workspaceDirectory.lastPathComponent)
                    .appFont(relative: -2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 2)
    }

    private var workspaceRow: some View {
        Button(action: chooseWorkspace) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("工作目录")
                        .appFont(relative: -3)
                        .foregroundStyle(.secondary)
                    Text(workspace.workspaceDirectory.lastPathComponent)
                        .appFont(relative: -2, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(workspace.workspaceDirectory.path)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.workspaceDirectory
        if panel.runModal() == .OK, let url = panel.url {
            workspace.setWorkspaceDirectory(url)
        }
    }

    /// 为单个标签选择并锁定独立工作目录（右键「设置工作目录…」）。锁定后不随全局工作区切换而改变。
    private func chooseSessionDirectory(for session: AgentSession) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = session.workingDirectory
        panel.message = "为「\(session.displayTitle)」选择独立的工作目录"
        if panel.runModal() == .OK, let url = panel.url {
            workspace.setSessionDirectory(id: session.id, to: url)
        }
    }

    /// 当多个标签分处不同工作目录时，在标签上显示目录名以区分（工作区可视化关联）。
    private var showWorkspaceOnTabs: Bool {
        Set(workspace.sessions.map(\.workingDirectory.standardizedFileURL.path)).count > 1
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// perSessionPrompt 策略的 agent：新开标签前先让用户为本会话选目录；取消则不创建。
    /// 其余策略沿用各自的默认目录解析。
    private func addAgent(_ agent: AgentConfig) {
        guard agent.workingDirectoryPolicy == .perSessionPrompt else {
            workspace.addSession(agentID: agent.id)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.workspaceDirectory
        panel.message = "为 \(agent.name) 选择本会话的工作目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.addSession(agentID: agent.id, directoryOverride: url)
    }

    @ViewBuilder
    private var mainPageSurface: some View {
        GeometryReader { proxy in
            mainPage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { mainAreaWidth = proxy.size.width }
                // 右栏宽度按比例从 mainAreaWidth 派生：窗口变化时只需更新容器宽，宽度自动按比例还原（并夹紧）。
                .onChange(of: proxy.size.width) { _, newValue in mainAreaWidth = newValue }
        }
    }

    /// 右侧栏左缘的横向缩放手柄：拖动改变侧栏宽度（向左变宽），用 NSView 接管鼠标、不移动窗口。
    /// 热区整体放在分隔线**右侧**（侧栏一侧）：聊天区的纵向滚动条贴在分隔线左缘，
    /// 热区跨到左侧会盖住滚动条（用户反馈）。拖到小于最小宽直接关闭、双击复位默认宽度。
    private var sidebarResizeHandle: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.border.opacity(0.72)).frame(width: 1)
            ResizeDivider(
                axis: .horizontal,
                onBegan: { sidebarDragBaseline = sidebarWidth },
                onChanged: { dx in
                    let base = sidebarDragBaseline ?? sidebarWidth
                    let raw = base - dx // 向左拖（dx<0）→ 变宽
                    sidebarDragRawWidth = raw
                    sidebarWidthOverride = SidebarSizing.clampWidth(raw, container: mainAreaWidth)
                },
                onEnded: {
                    let raw = sidebarDragRawWidth
                    let width = sidebarWidthOverride ?? sidebarWidth
                    sidebarDragBaseline = nil
                    sidebarDragRawWidth = nil
                    sidebarWidthOverride = nil
                    if let raw, SidebarSizing.shouldCloseWhileDragging(rawWidth: raw) {
                        closeSidebar() // 拖到小于最小宽 → 直接关闭
                    } else {
                        // 落定为归一化比例（持久化）。
                        sidebarRatio = Double(SidebarSizing.ratio(forWidth: width, container: mainAreaWidth))
                    }
                },
                onDoubleClick: {
                    withAnimation(sidebarSpring) {
                        sidebarRatio = Double(SidebarSizing.ratio(
                            forWidth: SidebarSizing.defaultWidth, container: mainAreaWidth
                        ))
                    }
                }
            )
            .frame(width: 12)
            // 不再向左偏移:左侧 1px 都不占,避免压住聊天区滚动条;12px 落在侧栏内容的留白上。
            .frame(maxHeight: .infinity)
        }
        .frame(width: 1)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var mainPage: some View {
        if let registryMessage = workspace.registryMessage, workspace.sessions.isEmpty {
            EmptyRegistryView(message: registryMessage)
                .padding(18)
        } else if let session = workspace.focusedSession {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        AgentPageHeader(
                            session: session,
                            terminalLaunch: $terminalLaunch,
                            showFiles: showFiles,
                            onToggleFiles: toggleRightSidebar
                        )
                        ChatPaneView(
                            session: session,
                            workspace: workspace,
                            sidebarVisible: showFiles,
                            onClose: { workspace.closeSession(id: session.id) },
                            onOpenFile: openFileInPreview,
                            onOpenWebURL: { url in
                                sidebarBrowserURL = url
                                openSidebarMode(.browser)
                            },
                            onReviewChanges: { summary in
                                selectedReviewSummary = summary
                                openSidebarMode(.review)
                            },
                            onShowSubagent: { task in
                                selectedSubagent = task
                                openSidebarMode(.subagent)
                            },
                            onClaudeLogin: {
                                withAnimation(.easeInOut(duration: 0.28)) {
                                    terminalLaunch = .claudeAuthentication(executable: session.agent.command)
                                }
                            }
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if let terminalLaunch {
                        TerminalPanel(workingDirectory: session.workingDirectory, launch: terminalLaunch) {
                            withAnimation(.easeInOut(duration: 0.28)) { self.terminalLaunch = nil }
                        }
                        .frame(height: 240)
                        .overlay(alignment: .top) {
                            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 为右栏预留的空间**瞬变**（开=右栏宽、合=0），故中间栏开/合都立刻定到最终宽度、不等滑动。
                // 拖拽分隔条期间用冻结宽度（见 sidebarLayoutWidth），松手才重排一次。
                .padding(.trailing, showFiles ? sidebarLayoutWidth : 0)

                // 右栏作为覆盖层只用 offset 滑入/滑出，不参与中间栏的布局——这样关闭时中间栏不用等它滑回。
                if sidebarRendered {
                    RightSidebar(
                        workingDirectory: session.workingDirectory,
                        mode: Binding(
                            get: { sidebarMode },
                            set: { newMode in
                                if newMode == .review, sidebarMode != .review {
                                    selectedReviewSummary = nil
                                }
                                sidebarMode = newMode
                            }
                        ),
                        previewController: filePreviewController,
                        browserURL: $sidebarBrowserURL,
                        expandedFolders: $sidebarExpandedFolders,
                        reviewSummary: selectedReviewSummary ?? session.lastTurnDiffSummary,
                        selectedSubagent: selectedSubagent
                    ) {
                        closeSidebar()
                    }
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) { sidebarResizeHandle }
                    .offset(x: sidebarSlideX)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped() // 右栏滑出时不绘制到窗口外
        } else {
            EmptyRegistryView(message: "Add an agent to start chatting.")
                .padding(18)
        }
    }

    private func openFileInPreview(_ url: URL) {
        filePreviewController.request(.openFile(url)) { committed in
            guard case .openFile(let fileURL) = committed else { return }
            filePreviewController.open(fileURL)
            sidebarMode = RightSidebarNavigation.destinationForOpenedFile
            openSidebar()
        }
    }

    private func openSidebarMode(_ mode: RightSidebarMode) {
        filePreviewController.request(.switchMode(mode)) { committed in
            guard case .switchMode(let target) = committed else { return }
            sidebarMode = target
            openSidebar()
        }
    }

    private func toggleRightSidebar() {
        if !showFiles {
            if ReviewSelectionPolicy.shouldClearForGlobalSidebarToggle(
                sidebarIsVisible: false,
                mode: sidebarMode
            ) {
                selectedReviewSummary = nil
            }
            openSidebar()
            return
        }

        filePreviewController.request(.closeSidebar) { committed in
            guard case .closeSidebar = committed else { return }
            if ReviewSelectionPolicy.shouldClearForGlobalSidebarToggle(
                sidebarIsVisible: true,
                mode: sidebarMode
            ) {
                selectedReviewSummary = nil
            }
            closeSidebar()
        }
    }

    private var addAgentMenu: some View {
        Menu {
            if workspace.registry.agents.isEmpty {
                Text("No detected agents")
            } else {
                ForEach(workspace.registry.agents) { agent in
                    Button(agent.name) {
                        addAgent(agent)
                    }
                }
            }
        } label: {
            Label("Add Agent", systemImage: "plus")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(workspace.registry.agents.isEmpty)
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .foregroundStyle(workspace.registry.agents.isEmpty ? .secondary : Theme.accentStrong)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.accent.opacity(workspace.registry.agents.isEmpty ? 0.12 : 0.22), lineWidth: 1)
        }
    }
}

// 组件已拆分至独立文件(#24):
// SidebarRailViews.swift(RailSectionLabel/RailActionButton/RecentConversationRow)、
// AgentTabRow.swift、AgentPageHeader.swift(含 HeaderIconButton/SessionHistoryMenu)、
// ContentViewChrome.swift(EmptyRegistryView/GlassBackground)。

#Preview {
    ContentView(workspace: WorkspaceController())
        .frame(width: 1180, height: 720)
}
