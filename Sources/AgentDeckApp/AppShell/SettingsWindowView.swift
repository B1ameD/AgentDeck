import SwiftUI
import AppKit

/// 独立设置窗口：左侧分类栏 + 右侧内容面板（参考 Claude 设置界面）。
/// 分五大类：常规 / 外观 / 个性化 / 工作区 / 关于。
struct SettingsWindowView: View {
    @Bindable var workspace: WorkspaceController

    @State private var selection: SettingsCategory = .general

    // 外观
    @AppStorage(BundledCodeFont.storageKey) private var selectedCodeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue
    @AppStorage(InterfaceFont.storageKey) private var interfaceFontID = InterfaceFont.defaultID
    @AppStorage(CodeBlockTheme.storageKey) private var codeBlockThemeID = CodeBlockTheme.defaultID

    // 常规
    @AppStorage(AgentActivationMode.storageKey) private var agentActivationID = AgentActivationMode.defaultID
    @AppStorage(PromptOptimizationMode.storageKey) private var promptOptModeID = PromptOptimizationMode.defaultID
    @AppStorage(AppTheme.storageKey) private var appThemeID = AppTheme.defaultID
    @AppStorage(AppLanguage.storageKey) private var appLanguageID = AppLanguage.defaultID

    // 提示词优化（自定义服务，复用既有键）
    @AppStorage(PromptOptimizationSettings.providerKey) private var promptOptProviderID = PromptOptimizationProvider.defaultProvider.id
    @AppStorage(PromptOptimizationSettings.baseURLKey) private var promptOptBaseURL = PromptOptimizationProvider.defaultProvider.baseURL
    @AppStorage(PromptOptimizationSettings.modelKey) private var promptOptModel = PromptOptimizationProvider.defaultProvider.defaultModel
    @AppStorage(PromptOptimizationSettings.apiKeyKey) private var promptOptAPIKey = ""

    // 个性化
    @AppStorage(AgentBehaviorRule.storageKey) private var behaviorRuleID = AgentBehaviorRule.defaultID
    @AppStorage(SystemPromptPreset.storageKey) private var systemPromptPresetID = SystemPromptPreset.defaultID
    @AppStorage(SystemPromptPreset.customTextKey) private var systemPromptCustom = ""
    @AppStorage(InstructionPreset.storageKey) private var instructionsID = InstructionPreset.defaultID

    // 工作区
    @AppStorage(WorkspaceMode.storageKey) private var workspaceModeID = WorkspaceMode.defaultID
    @AppStorage(KnownProjectsStore.storageKey) private var knownProjectsRaw = ""
    @AppStorage(KnownProjectsStore.currentIDKey) private var currentProjectID = ""

    private static let currentDirID = "__current_dir__"
    private let controlWidth: CGFloat = 240

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.border.opacity(0.72)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    panel
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            ensurePromptOptimizationDefaults()
            ensureWorkspaceDefaults()
        }
        .onChange(of: promptOptModeID) { _, modeID in
            if PromptOptimizationMode.resolve(modeID) == .useDefault {
                applyPromptOptimizationProvider(PromptOptimizationProvider.defaultProvider.id)
            }
        }
    }

    // MARK: - 左侧分类栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("设置")
                .font(uiFont(size: appFontPoints + 5, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ForEach(SettingsCategory.allCases) { category in
                Button { selection = category } label: {
                    HStack(spacing: 9) {
                        Image(systemName: category.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(category.title).font(uiFont(size: appFontPoints))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(selection == category ? Theme.accentStrong : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(selection == category ? Theme.selected : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 196)
        .background(Theme.panelRaised)
    }

    // MARK: - 右侧面板分发

    @ViewBuilder
    private var panel: some View {
        switch selection {
        case .general: generalPanel
        case .appearance: appearancePanel
        case .personalization: personalizationPanel
        case .workspace: workspacePanel
        case .about: aboutPanel
        }
    }

    // MARK: - 常规

    private var generalPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeader("常规")

            settingRow("Agent 启用状态", "控制 agent 是否随 App 自动激活。") {
                menuPicker(selection: $agentActivationID, options: AgentActivationMode.allCases)
            }

            settingRow("提示词优化 AI 配置", "输入框「优化」按钮使用的服务。") {
                menuPicker(selection: $promptOptModeID, options: PromptOptimizationMode.allCases)
            }
            switch PromptOptimizationMode.resolve(promptOptModeID) {
            case .useDefault:
                defaultOptimizationFields
            case .custom:
                customOptimizationFields
            case .disabled:
                EmptyView()
            }

            settingRow("模型计价表", "第三方/国产模型（kimi、mimo、deepseek、qwen…）按此表用真实 token 数补算费用；CLI 报得出费用时优先用真实值。") {
                Button("打开配置文件") {
                    NSWorkspace.shared.open(ModelPricing.writeTemplateIfMissing())
                }
            }

            settingRow("界面主题", "整体明暗外观。") {
                menuPicker(selection: $appThemeID, options: AppTheme.allCases)
            }

            settingRow("语言", "界面语言（自动检测＝跟随系统）。") {
                menuPicker(selection: $appLanguageID, options: AppLanguage.allCases)
            }
            if AppLanguage.resolve(appLanguageID) != .zhHans && AppLanguage.resolve(appLanguageID) != .auto {
                Text("英文本地化尚在进行中，界面文案暂以中文显示。")
                    .font(captionFont).foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 2)

            detectedAgentsSection
        }
    }

    private var defaultOptimizationFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(PromptOptimizationProvider.defaultProvider.displayName) · \(PromptOptimizationProvider.defaultProvider.defaultModel)")
                .font(captionFont)
                .foregroundStyle(.secondary)
            labeledField("API Key") {
                SecureField("", text: $promptOptAPIKey)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(12)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
        )
    }

    /// 自定义提示词优化服务的字段（仅「自定义模型」模式可见）。
    private var customOptimizationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingRow("服务商", "自定义优化服务的提供方。") {
                Picker("", selection: $promptOptProviderID) {
                    ForEach(PromptOptimizationProvider.all) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: controlWidth, alignment: .trailing)
                .onChange(of: promptOptProviderID) { _, providerID in
                    applyPromptOptimizationProvider(providerID)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                labeledField("Base URL") {
                    TextField("", text: $promptOptBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: appFontPoints, design: .monospaced))
                }
                labeledField("模型") {
                    TextField("", text: $promptOptModel)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: appFontPoints, design: .monospaced))
                }
                labeledField("API Key") {
                    SecureField("", text: $promptOptAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(12)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
            )
        }
    }

    private var detectedAgentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("已检测到的 Agents").font(headlineFont)
                Spacer()
                // 目录改动会自动热加载(#30);按钮兜底手动触发。
                Button("打开配置目录") {
                    let directory = WorkspaceController.defaultCustomAgentsDirectory()
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(directory)
                }
                Button("重新加载") { workspace.reloadAgentRegistry() }
            }
            if workspace.registry.agents.isEmpty {
                Text("未检测到任何 agent。").font(bodyFont).foregroundStyle(.secondary)
            } else {
                ForEach(workspace.registry.agents) { agent in
                    HStack {
                        Text(agent.name)
                        Spacer()
                        Text(agent.command)
                            .font(.system(size: max(10, appFontPoints - 2), design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            // 配置问题逐条展示:致命(已跳过)与非致命(已加载但提醒)都在这里(#30)。
            ForEach(workspace.registry.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(captionFont)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 外观

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeader("外观")

            settingRow("代码字体", "代码块与终端使用的等宽字体。") {
                menuPicker(selection: $selectedCodeFontID, options: BundledCodeFont.allCases)
            }
            Text("The quick brown fox 0123 => { }")
                .font(BundledCodeFont.resolve(selectedCodeFontID).swiftUIFont(size: AppFontSize.points(appFontSize)))
                .foregroundStyle(.secondary)

            settingRow("字体大小", "全局界面字号基准（px）。") {
                Picker("", selection: $appFontSize) {
                    ForEach(AppFontSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: controlWidth, alignment: .trailing)
            }

            settingRow("界面字体", "菜单 / 侧栏 / 聊天等界面文字的字体。") {
                menuPicker(selection: $interfaceFontID, options: InterfaceFont.allCases)
            }

            settingRow("代码块主题", "代码块的明暗配色（非语法高亮）。") {
                Picker("", selection: $codeBlockThemeID) {
                    ForEach(CodeBlockTheme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: controlWidth, alignment: .trailing)
            }
        }
    }

    // MARK: - 个性化

    private var personalizationPanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeader("个性化")

            settingRow("Agent 行为规则", "在严格遵循与自由发挥之间取舍。") {
                menuPicker(selection: $behaviorRuleID, options: AgentBehaviorRule.allCases)
            }

            VStack(alignment: .leading, spacing: 10) {
                settingRow("System Prompt", "选择预设模板，或在下方直接编辑为自定义。") {
                    menuPicker(selection: $systemPromptPresetID, options: SystemPromptPreset.allCases)
                }
                TextEditor(text: systemPromptText)
                    .font(bodyFont)
                    .frame(height: 120)
                    .padding(6)
                    .scrollContentBackground(.hidden)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).stroke(Theme.hairline, lineWidth: 1)
                    )
                Text("编辑文本会自动切换为「自定义」并保存。")
                    .font(captionFont).foregroundStyle(.secondary)
            }

            settingRow("Instructions", "预设指令集。") {
                menuPicker(selection: $instructionsID, options: InstructionPreset.allCases)
            }
            Text(InstructionPreset.resolve(instructionsID).summary)
                .font(captionFont).foregroundStyle(.secondary)
        }
    }

    /// System Prompt 文本：非自定义预设显示模板；一旦编辑即切到自定义并保存。
    private var systemPromptText: Binding<String> {
        Binding(
            get: {
                let preset = SystemPromptPreset.resolve(systemPromptPresetID)
                return preset == .custom ? systemPromptCustom : preset.template
            },
            set: { newValue in
                systemPromptCustom = newValue
                systemPromptPresetID = SystemPromptPreset.custom.rawValue
            }
        )
    }

    // MARK: - 工作区

    private var workspacePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionHeader("工作区")

            VStack(alignment: .leading, spacing: 10) {
                settingRow("当前项目", "切换 agent 运行所在的工作目录。") {
                    Picker("", selection: $currentProjectID) {
                        ForEach(displayedProjects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: controlWidth, alignment: .trailing)
                    .onChange(of: currentProjectID) { _, id in selectProject(id) }
                }
                HStack(spacing: 10) {
                    Text(workspace.workspaceDirectory.path)
                        .font(.system(size: max(10, appFontPoints - 2), design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("添加新的工作区…") { addWorkspace() }
                }
            }

            settingRow("工作区设置", "工作区的协作 / 权限基调（预设）。") {
                menuPicker(selection: $workspaceModeID, options: WorkspaceMode.allCases)
            }

            Divider().padding(.vertical, 2)

            currentSessionDefaults
        }
    }

    @ViewBuilder
    private var currentSessionDefaults: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前会话默认").font(headlineFont)
            if let session = workspace.focusedSession {
                Text("作用于当前标签：\(session.agent.name)").font(captionFont).foregroundStyle(.secondary)
                labeledField("模型") {
                    TextField("", text: Binding(get: { session.model }, set: { session.setSelectedModel($0) }))
                        .textFieldStyle(.roundedBorder)
                }
                settingRow("运行超时", "单次运行的最长时间。") {
                    Picker("", selection: Binding(get: { session.timeout }, set: { session.timeout = $0 })) {
                        Text("关闭").tag(Duration?.none)
                        Text("30 秒").tag(Duration?.some(.seconds(30)))
                        Text("2 分钟").tag(Duration?.some(.seconds(120)))
                        Text("5 分钟").tag(Duration?.some(.seconds(300)))
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: controlWidth, alignment: .trailing)
                }
            } else {
                Text("当前没有打开的会话。").font(bodyFont).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 关于

    private var aboutPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("关于")

            HStack { Text("AgentDeck"); Spacer(); Text(Self.appVersion).foregroundStyle(.secondary) }

            HStack {
                Text("更新日志").font(headlineFont)
                Spacer()
                Button("查看更新日志") { showChangelog() }
            }

            HStack { Text("许可证").font(headlineFont); Spacer(); Text("私有项目 · 保留所有权利").foregroundStyle(.secondary) }

            HStack {
                Spacer()
                Button("检查更新") { checkForUpdates() }
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("配置目录").font(captionFont.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(Self.configDirectoryDisplayPath)
                        .font(.system(size: appFontPoints, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("在 Finder 中显示") { revealConfigDirectory() }
                }
            }
        }
    }

    // MARK: - 复用小组件

    private var selectedInterfaceFont: InterfaceFont {
        InterfaceFont.resolve(interfaceFontID)
    }

    private var resolvedAppFontSize: AppFontSize {
        AppFontSize.resolve(appFontSize)
    }

    private var appFontPoints: CGFloat {
        resolvedAppFontSize.points
    }

    private var bodyFont: Font {
        uiFont(size: appFontPoints)
    }

    private var headlineFont: Font {
        uiFont(size: appFontPoints + 1, weight: .semibold)
    }

    private var captionFont: Font {
        uiFont(size: max(10, appFontPoints - 2))
    }

    private func uiFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        selectedInterfaceFont.font(size: size, weight: weight)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(uiFont(size: appFontPoints + 6, weight: .semibold))
    }

    private func settingRow<Control: View>(_ title: String, _ subtitle: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(headlineFont)
                Text(subtitle).font(captionFont).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            control()
        }
    }

    private func labeledField<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(captionFont.weight(.semibold)).foregroundStyle(.secondary)
            field()
        }
    }

    /// 统一的下拉选择器：适用于实现了 LabeledSettingOption 的枚举（≥3 项一律用下拉）。
    private func menuPicker<Option: LabeledSettingOption>(
        selection: Binding<String>,
        options: [Option],
        width: CGFloat? = nil
    ) -> some View {
        Picker("", selection: selection) {
            ForEach(options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        // 固定宽度槽内右对齐:下拉自身按内容收缩,不指定对齐会被居中,
        // 各行标签长短不一时右缘参差(用户要求 Word 式「靠右对齐」)。
        .frame(width: width ?? controlWidth, alignment: .trailing)
    }

    // MARK: - 工作区逻辑

    private func loadedProjects() -> [KnownProject] {
        let stored = KnownProjectsStore.decode(knownProjectsRaw)
        return stored.isEmpty ? KnownProjectsStore.seedProjects() : stored
    }

    /// 下拉展示的项目：已存项目 + 当前工作目录（若不在列表中，置顶补一条）。
    private var displayedProjects: [KnownProject] {
        var list = loadedProjects()
        let currentPath = workspace.workspaceDirectory.path
        if !list.contains(where: { $0.path == currentPath }) {
            let name = workspace.workspaceDirectory.lastPathComponent
            list.insert(
                KnownProject(id: Self.currentDirID, name: (name.isEmpty ? "当前目录" : name) + "（当前）", path: currentPath),
                at: 0
            )
        }
        return list
    }

    private func ensureWorkspaceDefaults() {
        if KnownProjectsStore.decode(knownProjectsRaw).isEmpty {
            knownProjectsRaw = KnownProjectsStore.encode(KnownProjectsStore.seedProjects())
        }
        // 把下拉选中项对齐到当前真实工作目录
        let currentPath = workspace.workspaceDirectory.path
        if let match = displayedProjects.first(where: { $0.path == currentPath }) {
            currentProjectID = match.id
        } else if currentProjectID.isEmpty {
            currentProjectID = displayedProjects.first?.id ?? ""
        }
    }

    private func selectProject(_ id: String) {
        guard let project = displayedProjects.first(where: { $0.id == id }) else { return }
        let url = URL(filePath: project.path)
        guard url.path != workspace.workspaceDirectory.path else { return }
        workspace.setWorkspaceDirectory(url)
    }

    private func addWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择一个目录作为新的工作区"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var list = loadedProjects()
        if let existing = list.first(where: { $0.path == url.path }) {
            currentProjectID = existing.id
        } else {
            let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            let project = KnownProject(name: name, path: url.path)
            list.append(project)
            knownProjectsRaw = KnownProjectsStore.encode(list)
            currentProjectID = project.id
        }
        workspace.setWorkspaceDirectory(url)
    }

    // MARK: - 关于逻辑

    private func showChangelog() {
        let alert = NSAlert()
        alert.messageText = "更新日志（\(Self.appVersion)）— MCP Server & 交互式提问"
        alert.informativeText = """
        新增
        · MCP ask_user 服务器：Agent 可在对话中弹出多选 / 单选卡片向你提问，作答后原地继续
        · 文件预览侧边栏（独立 FilePreview 模块）
        · Subagent（委派任务）详情展示与交互优化

        改进
        · CLIInvocationBuilder 增强 subagent 处理
        · OutputParser 消息解析、AgentSession 问题流程
        · ChatPaneView 多项 UX 优化
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }
        Task {
            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("AgentDeck", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    await MainActor.run { presentUpdateUnavailable(status: status) }
                    return
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                await MainActor.run { presentUpdateResult(release) }
            } catch {
                await MainActor.run { presentUpdateError(error) }
            }
        }
    }

    /// 比对 GitHub 最新 release 与当前版本，提示是否有更新。
    private func presentUpdateResult(_ release: GitHubRelease) {
        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let alert = NSAlert()
        if latest.compare(current, options: .numeric) == .orderedDescending {
            alert.messageText = "发现新版本：v\(latest)"
            let title = release.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            alert.informativeText = (title.isEmpty ? "" : title + "\n\n") + "当前版本 v\(current)，是否前往 GitHub 下载？"
            alert.addButton(withTitle: "前往下载")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn, let link = URL(string: release.htmlURL) {
                NSWorkspace.shared.open(link)
            }
        } else {
            alert.messageText = "已是最新版本"
            alert.informativeText = "当前版本 v\(current)，已是最新。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    private func presentUpdateError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = "无法连接 GitHub：\(error.localizedDescription)"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func presentUpdateUnavailable(status: Int) {
        let alert = NSAlert()
        alert.messageText = "暂时无法检查更新"
        alert.informativeText = status == 404
            ? "未在 GitHub 找到发布信息（仓库可能尚未公开，或还没有 Release）。"
            : "GitHub 返回状态码 \(status)，请稍后再试。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - 提示词优化逻辑

    private func ensurePromptOptimizationDefaults() {
        if promptOptBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
           promptOptModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyPromptOptimizationProvider(promptOptProviderID)
        }
    }

    private func applyPromptOptimizationProvider(_ providerID: String) {
        let provider = PromptOptimizationProvider.resolve(providerID)
        guard provider.id != "custom" else { return }
        promptOptBaseURL = provider.baseURL
        promptOptModel = provider.defaultModel
    }

    // MARK: - 配置目录

    private func revealConfigDirectory() {
        let url = Self.configDirectoryURL
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static var configDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        return support
            .appending(path: "AgentDeck", directoryHint: .isDirectory)
            .appending(path: "Agents", directoryHint: .isDirectory)
    }

    private static var configDirectoryDisplayPath: String {
        "~/Library/Application Support/AgentDeck/Agents"
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        return "版本 \(version)"
    }

    private static let githubRepo = "B1ameD/AgentDeck"

    /// GitHub releases/latest 响应（仅取所需字段）。
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let name: String?
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case name
        }
    }
}

/// 让设置枚举可被统一的 menuPicker 消费：提供 id 与展示文案。
protocol LabeledSettingOption: Identifiable {
    var id: String { get }
    var label: String { get }
}

extension AgentActivationMode: LabeledSettingOption {}
extension PromptOptimizationMode: LabeledSettingOption {}
extension AppTheme: LabeledSettingOption {}
extension AppLanguage: LabeledSettingOption {}
extension BundledCodeFont: LabeledSettingOption { var label: String { displayName } }
extension InterfaceFont: LabeledSettingOption {}
extension TranscriptTextSize: LabeledSettingOption {}
extension AgentBehaviorRule: LabeledSettingOption {}
extension SystemPromptPreset: LabeledSettingOption {}
extension InstructionPreset: LabeledSettingOption {}
extension WorkspaceMode: LabeledSettingOption {}

/// 设置分类（左侧栏）。
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case appearance
    case personalization
    case workspace
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "常规"
        case .appearance: "外观"
        case .personalization: "个性化"
        case .workspace: "工作区"
        case .about: "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .personalization: "person.crop.circle"
        case .workspace: "folder"
        case .about: "info.circle"
        }
    }
}
