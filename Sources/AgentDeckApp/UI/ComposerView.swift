import SwiftUI
import AppKit

struct ComposerModePresentation: Equatable {
    let isBroadcast: Bool
    let targetCount: Int
    let agentName: String

    var placeholder: String {
        isBroadcast ? "输入要广播给所有agent的请求" : "Message \(agentName)"
    }

    var resolvesSlashCommands: Bool {
        !isBroadcast
    }

    var submitHelp: String {
        isBroadcast ? "广播给 \(targetCount) 个 agent" : "发送"
    }
}

enum ModelMenuRefreshTrigger {
    static func shouldRefresh(
        agentKind: AgentConfig.Kind,
        wasOpen: Bool,
        isOpen: Bool
    ) -> Bool {
        agentKind == .claudeCode && !wasOpen && isOpen
    }
}

struct ComposerView: View {
    @Bindable var session: AgentSession
    var workspace: WorkspaceController?
    var onClaudeLogin: () -> Void = {}
    /// 与父级（ChatPaneView 聊天区遮罩）同步「斜杠/模型菜单是否打开」：
    /// ComposerView 置真打开，父级遮罩点击会置假以请求关闭。
    @Binding var menuOpen: Bool
    @State private var prompt = ""
    @State private var inputHeight: CGFloat = 84 // 输入框内容高度：初始 84，随内容增高，封顶 168 后内部滚动
    @State private var attachments: [URL] = []
    @State private var focusToken = 0
    /// 发现到的原生指令（自定义命令），并入斜杠菜单、透传给 CLI。
    @State private var nativeCommands: [SlashCommand] = []
    /// 动态获取的模型列表（如 opencode models）；空则回落到内置预设。
    @State private var modelCatalog: [String] = []
    @State private var modelLoading = false
    @State private var modelRefreshGeneration = 0
    /// claude settings.json 的「角色 → 模型」映射（Haiku/Sonnet/Opus/默认），给模型选择器打标签，
    /// 并提示「default 实际用 ANTHROPIC_MODEL（可能较重）」——对应慢的根因。
    @State private var claudeModelRoles = ClaudeSettings.ModelRoles(labels: [:], defaultModel: nil)
    /// AI 优化进行中（点「优化」后到 agent 返回前）。
    @State private var optimizing = false
    /// 上次优化失败原因（无输出 / 出错），用于提示用户重试。
    @State private var optimizeError: String?
    @State private var hoveringOptimize = false
    @State private var hoveringContext = false
    @State private var showingCompare = false // 广播对比 sheet(#27)
    @State private var showingEffortSlider = false // 点 effort 芯片弹出火苗滑块 popover
    @State private var forceModelMenu = false // 点模型芯片打开模型菜单（不写入输入框，保留草稿）
    @AppStorage(InterfaceFont.storageKey) private var interfaceFontID = InterfaceFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue
    @AppStorage(PromptOptimizationMode.storageKey) private var promptOptimizationModeID = PromptOptimizationMode.defaultID

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedPrompt.isEmpty
            && session.status != .running
            && (!modePresentation.isBroadcast || modePresentation.targetCount > 0)
    }

    private var slashInput: SlashInput {
        guard modePresentation.resolvesSlashCommands else { return .hidden }
        // 模型芯片点开：直接展示模型菜单（query 为空＝全量），不依赖输入框文本 → 草稿不受影响。
        if forceModelMenu {
            return .models(
                query: "",
                suggestions: SlashCommandMenu.modelSuggestions(for: session.agent.kind, query: "", catalog: modelCatalog)
            )
        }
        return SlashCommandMenu.resolve(for: prompt, agent: session.agent, extraCommands: nativeCommands, modelCatalog: modelCatalog)
    }

    private var modePresentation: ComposerModePresentation {
        ComposerModePresentation(
            isBroadcast: workspace?.multiAgentMode == true,
            targetCount: workspace?.sessions.count ?? 0,
            agentName: session.agent.name
        )
    }

    /// 斜杠 / 模型菜单是否正在显示。
    private var menuIsOpen: Bool {
        switch slashInput {
        case .commands(let commands): return !commands.isEmpty
        case .models: return true
        case .hidden: return false
        }
    }

    private var modelMenuIsOpen: Bool {
        if case .models = slashInput {
            return true
        }
        return false
    }

    /// Esc：菜单打开时清空斜杠输入以关闭（返回 true 表示已消费）。
    private func handleEscape() -> Bool {
        guard menuIsOpen else { return false }
        if forceModelMenu { forceModelMenu = false } else { prompt = "" } // 芯片开的模型菜单：关菜单留草稿
        return true
    }

    @ViewBuilder
    private var slashMenu: some View {
        switch slashInput {
        case .commands(let commands) where !commands.isEmpty:
            slashCommandMenu(commands)
        case .models(let query, let suggestions):
            modelMenu(query: query, suggestions: suggestions)
        default:
            EmptyView()
        }
    }

    var body: some View {
        composerDock
            .overlay(alignment: .topLeading) {
                // 指令/模型菜单浮在输入区上方 8pt，盖住对话区文本——而非把对话顶走。
                // overlay 不计入 ComposerView 高度 → 底部 safeAreaInset 不变 → 对话区不被压缩上移。
                slashMenu
                    .alignmentGuide(.top) { $0[.bottom] + 8 }
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity) // 填满父布局给定的宽度（由 ProportionalWidthLayout 约束为 0.8 列宽并居中）
        .onChange(of: prompt) { _, newValue in
            optimizeError = nil
            session.draft = newValue // 随键入存草稿到会话，切标签/重建视图不丢失
            if forceModelMenu { forceModelMenu = false } // 一旦键入，让位给基于输入的菜单解析
        }
        .onAppear {
            // 视图(重)建时从会话恢复草稿——ChatPaneView .id(session.id) 切标签会重建本视图，
            // 默认 @State 会被重置为空；这里把未发送内容找回。
            if prompt.isEmpty, !session.draft.isEmpty { prompt = session.draft }
        }
        .onChange(of: modelMenuIsOpen) { wasOpen, isOpen in
            if ModelMenuRefreshTrigger.shouldRefresh(
                agentKind: session.agent.kind,
                wasOpen: wasOpen,
                isOpen: isOpen
            ) {
                startClaudeModelRefresh()
            }
        }
        .onChange(of: menuIsOpen) { _, open in
            if menuOpen != open { menuOpen = open }
        }
        .onChange(of: menuOpen) { _, open in
            if !open && menuIsOpen { // 父级遮罩点击 → 关闭菜单
                if forceModelMenu { forceModelMenu = false } else { prompt = "" }
            }
        }
        .task(id: session.workingDirectory) {
            await discoverNativeCommands()
            if session.agent.kind != .claudeCode {
                await fetchModelCatalog()
            }
        }
    }

    private var composerDock: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !attachments.isEmpty {
                AttachmentChipsView(attachments: attachments) { url in
                    attachments.removeAll { $0 == url }
                }
                .padding(.bottom, 1)
            }
            promptInput
            composerControls
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .stroke(Theme.border.opacity(0.45), lineWidth: 1)
        }
        // 悬浮在聊天内容之上：向上偏的柔和投影把卡片「抬」到前景，再叠一层贴身环境光。
        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: -3)
        .shadow(color: Color.black.opacity(0.06), radius: 5, x: 0, y: 2)
    }

    private var promptInput: some View {
        PromptTextView(
            text: $prompt,
            placeholder: modePresentation.placeholder,
            onSubmit: send,
            onTab: handleTab,
            onCtrlT: cycleReasoning,
            focusToken: focusToken,
            font: promptFont,
            onEscape: handleEscape,
            onAttachFiles: appendAttachments,
            onHeightChange: { inputHeight = $0 }
        )
        // 初始 84，随内容自适应增高显示完整；到 168 封顶后才出现上下滚动条（之后滚轮查看）。
        .frame(height: min(max(inputHeight, 84), 168))
        .padding(.horizontal, 2)
        .padding(.top, 1)
        .frame(maxWidth: .infinity)
    }

    private func discoverNativeCommands() async {
        let agent = session.agent
        let directory = session.workingDirectory
        nativeCommands = await Task.detached {
            NativeSlashCommands.discover(for: agent, workingDirectory: directory)
        }.value
    }

    private func fetchModelCatalog() async {
        modelLoading = true
        modelCatalog = await ModelCatalog.fetch(for: session.agent, workingDirectory: session.workingDirectory)
        modelLoading = false
    }

    private func startClaudeModelRefresh() {
        modelRefreshGeneration += 1
        let generation = modelRefreshGeneration
        modelCatalog = []
        claudeModelRoles = ClaudeSettings.ModelRoles(labels: [:], defaultModel: nil)
        modelLoading = true
        Task {
            let snapshot = await ModelCatalog.fetchClaudeSnapshot()
            guard generation == modelRefreshGeneration else { return }
            modelCatalog = snapshot.candidates
            claudeModelRoles = snapshot.roles
            modelLoading = false
        }
    }

    /// 控制行（参考 opencode）：模式 / 模型 / 推理 依次排列，分别用 Tab、/model、⌃T 切换；
    /// 最右侧是上下文用量（界面右下角）。
    private var composerControls: some View {
        HStack(spacing: 10) {
            Menu {
                Button {
                    appendAttachments(AttachmentPicker.chooseFiles())
                } label: {
                    Label("附加照片/文件", systemImage: "photo.on.rectangle")
                }
                Button {
                    AttachmentPicker.captureScreenshot { appendAttachments([$0]) }
                } label: {
                    Label("屏幕截图", systemImage: "camera.viewfinder")
                }
                if !attachments.isEmpty {
                    Divider()
                    Button(role: .destructive) { attachments.removeAll() } label: {
                        Label("清除全部附件", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: attachments.isEmpty ? "paperclip" : "paperclip.badge.ellipsis")
                    .frame(width: 19, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(attachments.isEmpty ? Color.secondary : Theme.accentStrong)
            .help("附加照片/文件 · 屏幕截图")

            ControlChip(
                text: modeLabel,
                hint: modeHint,
                isDisabled: !session.agent.supportsPlanMode,
                action: cycleMode
            )
            ControlChip(text: modelLabel, hint: modelHint) {
                forceModelMenu = true // 打开模型菜单，不动输入框
                focusToken += 1
            }
            ControlChip(
                text: session.reasoningEffort.label,
                hint: "点击调推理强度 · ⌃T 循环切换",
                isActive: session.reasoningEffort == .max,
                widthAnchors: ReasoningEffort.allCases.map(\.label)
            ) {
                showingEffortSlider = true
            }
            .popover(isPresented: $showingEffortSlider, arrowEdge: .top) {
                EffortSliderWebView(effort: $session.reasoningEffort)
                    .frame(width: 292, height: 104)
            }
            if let workspace {
                ControlChip(
                    text: workspace.multiAgentMode ? "广播" : "单聊",
                    hint: workspace.multiAgentMode ? "切回当前 agent" : "广播给所有 agent",
                    isActive: workspace.multiAgentMode
                ) {
                    workspace.multiAgentMode.toggle()
                    focusToken += 1
                }
                if hasBroadcastRound {
                    // 广播过至少一轮才显示:并排对比各 agent 对同一 prompt 的回答(#27)。
                    ControlChip(text: "对比", hint: "并排对比最近一轮广播的各家回答", isActive: showingCompare) {
                        showingCompare = true
                    }
                    .sheet(isPresented: $showingCompare) {
                        BroadcastCompareView(workspace: workspace)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                if let optimizeError {
                    Text(optimizeError)
                        .appFont(relative: -3)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(optimizeError)
                }
                if promptOptimizationMode.showsComposerButton {
                    optimizeButton
                }
                contextIndicator
                runButton
            }
            // 上下文 hover 文字出现/消失时，整行重排（含「优化」按钮位移）一起平滑滑动。
            .animation(.easeOut(duration: 0.18), value: hoveringContext)
        }
        .appFont(relative: -1)
        .frame(minHeight: 21)
    }

    @ViewBuilder
    private var runButton: some View {
        if session.isRunning {
            if session.agent.supportsStop {
                Button(action: { session.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(Color.red, in: Circle())
                .help("停止运行")
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .help("此 agent 不支持中途停止")
            }
        } else {
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(canSend ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
            .disabled(!canSend)
            .help(modePresentation.submitHelp)
        }
    }

    /// 「提示词优化」按钮：用当前 agent 把输入框里的 prompt 改写得更清晰。
    private var optimizeButton: some View {
        Button { Task { await optimizePrompt() } } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(trimmedPrompt.isEmpty ? Theme.controlHover.opacity(0.45) : Theme.selected)
                    if optimizing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        GeminiSparkleShape()
                            .fill(trimmedPrompt.isEmpty ? Color.secondary.opacity(0.65) : Theme.accentStrong)
                            .frame(width: 12, height: 14)
                    }
                }
                .frame(width: 21, height: 21)
                .offset(x: hoveringOptimize ? -2 : 0)

                Text("优化")
                    .appFont(relative: -2, weight: .medium)
                    .foregroundStyle(trimmedPrompt.isEmpty ? Color.secondary.opacity(0.65) : Theme.accentStrong)
                    .opacity(hoveringOptimize ? 1 : 0)
                    .offset(x: hoveringOptimize ? -2 : -10)
            }
            .frame(width: hoveringOptimize ? 56 : 22, height: 22, alignment: .leading)
            .clipped()
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hoveringOptimize = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: hoveringOptimize)
        .opacity(trimmedPrompt.isEmpty ? 0.55 : 1)
        .help(promptOptimizationMode.helpText)
    }

    /// 用当前 agent 异步改写输入框里的提示词；成功则替换并回焦，失败则提示重试。
    private func optimizePrompt() async {
        guard promptOptimizationMode.showsComposerButton else { return }
        let source = prompt
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !optimizing else { return }
        optimizing = true
        optimizeError = nil
        defer { optimizing = false }
        switch await session.optimizePromptResult(from: source) {
        case .success(let improved):
            if improved != source {
                prompt = improved
                focusToken += 1
            }
        case .failure(let message):
            optimizeError = "优化失败：\(message)"
        }
    }

    /// 上下文用量（估算）+ 累计费用（真实计量，#28）：控制行最右 = 界面右下角。
    private var contextIndicator: some View {
        let tokens = ContextEstimate.estimatedTokens(forTexts: session.messages.map(\.text))
        let window = ContextEstimate.contextWindow(forModel: session.model)
        return HStack(spacing: 6) {
            ProgressView(value: ContextEstimate.usageFraction(tokens: tokens, window: window))
                .progressViewStyle(.linear)
                .frame(width: 74)
            if !session.usage.isEmpty {
                // 有费用显费用；无费用（第三方模型未配计价表）退显真实 token 计数。明细在悬停里。
                Text(session.usage.costUSD > 0 ? session.usage.costLabel : session.usage.tokensLabel)
                    .appFont(relative: -2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            if hoveringContext {
                Text(hoverDetail(tokens: tokens, window: window))
                    .appFont(relative: -2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { hoveringContext = $0 }
        .help(session.usage.isEmpty
            ? "上下文用量（按字符估算，非真实 token 计数）"
            : "上下文用量（估算）· 累计 \(session.usage.compactSummary)（真实计量，共 \(session.usage.turns) 轮）")
    }

    private func hoverDetail(tokens: Int, window: Int) -> String {
        let estimate = "≈ \(ContextEstimate.compact(tokens)) / \(ContextEstimate.compact(window))"
        guard !session.usage.isEmpty else { return estimate }
        return "\(estimate) · \(session.usage.compactSummary)"
    }

    /// 是否存在过广播轮次(打标用户消息)。消息数组为 CoW 引用,逐条只查 role+broadcastID,开销可忽略。
    private var hasBroadcastRound: Bool {
        guard let workspace else { return false }
        return BroadcastCompare.latestBroadcastID(in: workspace.sessions.map(\.messages)) != nil
    }

    private var modeLabel: String {
        switch session.interactionMode {
        case .plan: "Plan"
        case .build: "Build"
        }
    }

    /// 模式芯片 tooltip：不支持的后端点明「透传无效果」；支持的后端附上 plan 的约束强度，
    /// 让用户清楚同一个开关在不同 agent 下的实际语义（硬沙箱 / 原生只读 / 提示约束）。
    private var modeHint: String {
        guard session.agent.supportsPlanMode else {
            return "该 agent 不支持 plan/build 模式（透传，无效果）"
        }
        let strength: String
        switch session.agent.kind {
        case .codex: strength = "Plan=只读沙箱"
        case .claudeCode: strength = "Plan=只读规划"
        case .openCode: strength = "Plan=提示约束"
        case .pi, .custom: strength = ""
        }
        return strength.isEmpty ? "Tab 切换模式" : "Tab 切换模式｜\(strength)"
    }

    /// 芯片显示实际解析到的模型（如别名 opus → Opus 4.8）；没捕获到就显示所选模型。
    private var modelLabel: String {
        modelDisplayName(session.resolvedModel ?? session.model)
    }

    /// 选别名/默认而运行时解析为具体版本时，tooltip 点明「选择 → 实际」映射；否则只提示如何切换。
    private var modelHint: String {
        let base = "/model 切换模型"
        guard let resolved = session.resolvedModel else { return base }
        let selected = modelDisplayName(session.model)
        let actual = modelDisplayName(resolved)
        guard selected != actual else { return base }
        return "选择 \(selected) → 实际 \(actual)｜\(base)"
    }

    private var promptFont: NSFont {
        InterfaceFont.resolve(interfaceFontID).nsFont(size: AppFontSize.points(appFontSize))
    }

    private var promptOptimizationMode: PromptOptimizationMode {
        PromptOptimizationMode.resolve(promptOptimizationModeID)
    }

    private func cycleMode() {
        // pi/custom 无法注入 mode 语义；芯片已灰显，此处再兜住 Tab 键路径（:669 调用 cycleMode）。
        guard session.agent.supportsPlanMode else { return }
        let modes = InteractionMode.allCases
        if let i = modes.firstIndex(of: session.interactionMode) {
            session.interactionMode = modes[(i + 1) % modes.count]
        }
    }

    private func cycleReasoning() {
        let efforts = ReasoningEffort.allCases
        if let i = efforts.firstIndex(of: session.reasoningEffort) {
            session.reasoningEffort = efforts[(i + 1) % efforts.count]
        }
    }

    private func appendAttachments(_ urls: [URL]) {
        for url in PromptAttachmentDrop.normalizedFileURLs(urls) where !attachments.contains(url) {
            attachments.append(url)
        }
    }

    private func slashCommandMenu(_ matches: [SlashCommand]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(matches) { command in
                MenuRow(action: { complete(command) }) {
                    HStack(spacing: 10) {
                        Text(command.token)
                            .font(.callout.monospaced().weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 96, alignment: .leading)
                        Text(command.summary)
                            .appFont(relative: -2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(6)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
        .shadow(color: Theme.shadowColor, radius: 10, y: 3)
    }

    private func modelMenu(query: String, suggestions: [String]) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let showsFreeText = !trimmed.isEmpty
            && !suggestions.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        let recent = recentModels(matching: trimmed, within: suggestions)
        // 去重：Recent 段已展示的别名不在下方分组里重复；分组内渲染同名的项（如别名解析版本与带日期全名都显示
        // “Opus 4.8”）也只保留一项——修掉 /model 菜单「大堆模型、存在重复」。
        let recentDisplayNames = Set(recent.map(modelDisplayName))
        let dedupedSuggestions = SlashCommandMenu.dedupedByDisplayName(suggestions, excludingDisplayNames: recentDisplayNames)
        let groups = SlashCommandMenu.groupModels(dedupedSuggestions)

        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if modelLoading && modelCatalog.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("加载模型列表…").appFont(relative: -2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                if showsFreeText {
                    modelRow(value: trimmed, label: "设为 “\(trimmed)”")
                }
                if !recent.isEmpty {
                    sectionHeader("Recent")
                    ForEach(recent, id: \.self) { modelRow(value: $0, label: modelDisplayName($0)) }
                }
                ForEach(groups, id: \.provider) { group in
                    if !group.provider.isEmpty {
                        sectionHeader(group.provider)
                    }
                    ForEach(group.models, id: \.self) { modelRow(value: $0, label: modelDisplayName($0)) }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 260)
        .background(Theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
        .shadow(color: Theme.shadowColor, radius: 10, y: 3)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .appFont(relative: -2, weight: .semibold)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 统一的人类可读模型名（去供应商 / 去连字符 / 首字母大写），见 SlashCommandMenu.modelDisplayName。
    private func modelDisplayName(_ model: String) -> String {
        SlashCommandMenu.modelDisplayName(model)
    }

    /// 最近用过、且仍在当前候选里、匹配 query 的模型。
    private func recentModels(matching query: String, within suggestions: [String]) -> [String] {
        let valid = Set(suggestions)
        let q = query.lowercased()
        return RecentModels.get(forAgent: session.agent.id)
            .filter { valid.contains($0) && (q.isEmpty || $0.lowercased().contains(q)) }
    }

    private func modelRow(value: String, label: String) -> some View {
        MenuRow(action: { applyModel(value) }) {
            HStack(spacing: 8) {
                Text(label).appFont(relative: -1)
                if let tag = roleTag(for: value) {
                    Text(tag.text)
                        .appFont(relative: -3, weight: .medium)
                        .foregroundStyle(tag.warns ? Color.orange : Theme.accentStrong)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((tag.warns ? Color.orange : Theme.accent).opacity(0.12)))
                }
                Spacer(minLength: 8)
                if value == session.model {
                    Image(systemName: "checkmark")
                        .appFont(relative: -2, weight: .bold)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.leading, 12) // 在供应商标题下缩进，体现层级
        }
    }

    /// 模型行的角色标签（仅 claude）：settings.json 里映射的 Haiku/Sonnet/Opus/默认；
    /// 「default」项额外提示其实际用 ANTHROPIC_MODEL（可能较重），点这条便于改选更快的模型。
    private func roleTag(for value: String) -> (text: String, warns: Bool)? {
        guard session.agent.kind == .claudeCode else { return nil }
        if value == "default", let model = claudeModelRoles.defaultModel {
            return ("默认→\(modelDisplayName(model)) · 可能较重", true)
        }
        if let role = claudeModelRoles.labels[value] {
            return (role, role.contains("默认"))
        }
        return nil
    }

    private func send() {
        // 指令态优先：回车在斜杠菜单里选中首项，而不是把 “/xxx” 当消息发出。
        switch slashInput {
        case .commands(let commands):
            // 透传命令不拦截：落到普通发送，把 /xxx 原样发给 CLI。
            if let first = commands.first, first.action != .passthrough {
                apply(first)
                return
            }
        case .models(let query, let suggestions):
            let value = suggestions.first ?? query.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { applyModel(value); return }
        case .hidden:
            break
        }
        guard canSend else { return }
        let text = prompt
        let files = attachments
        prompt = ""
        attachments = []
        if modePresentation.isBroadcast {
            workspace?.broadcast(text, attachments: files)
        } else {
            Task { await session.send(text, attachments: files) }
        }
    }

    /// 点击/Tab 补写：把指令 token 填入输入框（而非直接执行），回车再执行。
    /// /model 填入后即进入模型建议态。补写后把焦点交回输入框。
    private func complete(_ command: SlashCommand) {
        // 透传命令：补全后留个空格接参数，回车把 /xxx 原样发给 CLI；应用指令照旧。
        prompt = command.action == .passthrough ? command.token + " " : command.token
        focusToken += 1
    }

    /// Tab 补全：命令态补全首个匹配；模型态把首个建议补成 “/model <名称>”。返回是否已消费。
    private func handleTab() -> Bool {
        switch slashInput {
        case .commands(let commands):
            guard let first = commands.first else { return false }
            complete(first)
            return true
        case .models(_, let suggestions):
            guard let first = suggestions.first else { return false }
            prompt = "/model \(first)"
            focusToken += 1
            return true
        case .hidden:
            // 非斜杠态：Tab 切换交互模式（参考 opencode 的 tab 切 agents）。
            cycleMode()
            return true
        }
    }

    /// 把选中的指令落到当前会话，并清掉已消费的指令 token（保留附件）。
    private func apply(_ command: SlashCommand) {
        switch command.action {
        case .setCommand(let value):
            session.command = value
        case .setMode(let value):
            session.interactionMode = value
        case .stop:
            session.stop()
        case .clear:
            // 开新会话：旧对话留在历史，换上同 agent/目录的新空标签，并清空输入与附件。
            session.requestNewChat()
            prompt = ""
            attachments = []
            return
        case .claudeLogin:
            onClaudeLogin()
        case .startModelInput:
            prompt = "/model" // 进入模型输入态：菜单切到模型建议；不清空
            return
        case .passthrough:
            return // 透传命令不在此拦截（send 已放行到普通发送）
        }
        prompt = ""
    }

    /// 把选中/输入的模型名落到会话，记入 Recent，并清空输入。
    private func applyModel(_ model: String) {
        session.setSelectedModel(model)
        RecentModels.record(model, forAgent: session.agent.id)
        forceModelMenu = false
        // 仅清掉「/model」斜杠触发的文本；模型芯片打开时输入框是用户草稿，保留不动。
        if prompt.hasPrefix("/model") { prompt = "" }
    }

}

/// 控制行的一项（模式/模型/推理）：静止为纯文字（无底框），鼠标悬停才显示淡淡背景。
private struct ControlChip: View {
    let text: String
    let hint: String
    var isActive: Bool = false
    var isDisabled: Bool = false
    /// 预留宽度的候选文字：芯片按其中最宽者定宽，使文字切换（如 effort 的 Low/Medium/X-High）
    /// 不改变芯片宽度——避免挤压相邻控件、并让锚在芯片中心的 popover 不左右漂移。随字号自适应。
    var widthAnchors: [String] = []
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                ForEach(widthAnchors, id: \.self) { anchor in
                    Text(anchor).appFont(relative: -1).lineLimit(1).hidden()
                }
                Text(text)
                    .appFont(relative: -1)
                    .foregroundStyle(isActive ? Theme.accentStrong : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Theme.accentSoft : (hovering ? Theme.controlHover : Color.clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .help(hint)
        .onHover { hovering = isDisabled ? false : $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

private struct GeminiSparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cx = rect.midX
        let cy = rect.midY
        let rx = rect.width / 2
        let ry = rect.height / 2
        let innerX = rect.width * 0.14
        let innerY = rect.height * 0.13

        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - ry))
        path.addQuadCurve(
            to: CGPoint(x: cx + innerX, y: cy - innerY),
            control: CGPoint(x: cx + rect.width * 0.08, y: cy - rect.height * 0.28)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + rx, y: cy),
            control: CGPoint(x: cx + rect.width * 0.28, y: cy - rect.height * 0.07)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx + innerX, y: cy + innerY),
            control: CGPoint(x: cx + rect.width * 0.28, y: cy + rect.height * 0.07)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy + ry),
            control: CGPoint(x: cx + rect.width * 0.08, y: cy + rect.height * 0.28)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - innerX, y: cy + innerY),
            control: CGPoint(x: cx - rect.width * 0.08, y: cy + rect.height * 0.28)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - rx, y: cy),
            control: CGPoint(x: cx - rect.width * 0.28, y: cy + rect.height * 0.07)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx - innerX, y: cy - innerY),
            control: CGPoint(x: cx - rect.width * 0.28, y: cy - rect.height * 0.07)
        )
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - ry),
            control: CGPoint(x: cx - rect.width * 0.08, y: cy - rect.height * 0.28)
        )
        path.closeSubpath()
        return path
    }
}

/// 斜杠 / 模型菜单的一行：鼠标悬停时显示海蓝淡底高亮，点击执行。
private struct MenuRow<Content: View>: View {
    let action: () -> Void
    let content: Content
    @State private var hovering = false

    init(action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(hovering ? Theme.selected : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
    }
}
