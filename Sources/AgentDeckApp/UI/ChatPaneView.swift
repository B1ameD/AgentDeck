import SwiftUI
import AppKit

/// 底部锚点是否落在视口内（≈用户贴底）。侧栏开合时据此决定是否保持贴底。
private struct ChatBottomVisibleKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// 窗口顶部哨兵在视口坐标系里的 maxY（负值=在视口上方多远）。
/// 用连续数值而非布尔：滚动中每帧变化都触发 onPreferenceChange，自动释放才能连续推进。
private struct ChatTopDistanceKey: PreferenceKey {
    static let defaultValue: CGFloat = -.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 聊天框（底部 safeAreaInset）的实时高度。多行输入会把它撑高，
/// 而 inset 增高只缩小视口、不调整滚动偏移——不重锚的话最新消息会被盖住（#3）。
private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ChatPaneView: View {
    @Bindable var session: AgentSession
    var workspace: WorkspaceController?
    /// 右侧栏是否可见。开合会改变聊天列宽、触发重排——据此把滚动重新锚回底部（最新消息），见 issue 6。
    var sidebarVisible: Bool = false
    let onClose: () -> Void
    var onOpenFile: (URL) -> Void = { _ in }
    var onOpenWebURL: (URL) -> Void = { _ in }
    var onReviewChanges: (TurnDiffSummary) -> Void = { _ in } // 「审核改动」：打开右侧栏「审核」标签
    var onShowSubagent: (SubagentTask) -> Void = { _ in } // 「委派任务」：在右侧栏展开子任务明细
    var onClaudeLogin: () -> Void = {}
    @State private var composerMenuOpen = false // 菜单打开时聊天区显示透明遮罩，点击即关闭
    /// 用户当前是否处于（接近）聊天底部。只有「本就在底部」时，侧栏开合才把视图保持贴底；
    /// 若在上翻看历史，则不打扰其位置。避免之前「一开侧栏就强行滚到底」的突兀观感。
    @State private var atBottom = true
    /// 长转录尾部窗口：只渲染最近 N 条（#2 首帧性能——否则要测量全部气泡高度，
    /// 每条都是一次完整 TextKit 布局）。上滑接近顶部时自动渐进释放更早消息。
    @State private var transcriptLimit = TranscriptWindow.defaultLimit
    /// 自动释放冷却：让上一批的 TextKit 布局先落定，避免连续触发把滚动卡死。
    @State private var lastAutoRelease = Date.distantPast
    /// 聊天框当前高度（随输入行数变化）。用于在它长高/收缩时把贴底的视图重新钉底（#3）。
    @State private var composerHeight: CGFloat = 0
    /// 设置项：历史会话默认全部展开（不做尾部窗口截断）。
    @AppStorage(TranscriptWindow.expandAllStorageKey) private var expandAllHistory = TranscriptWindow.expandAllDefault

    /// 聊天列表底部锚点 id（滚动到最新消息用）。
    private static let bottomAnchorID = "agentdeck.chat.bottomAnchor"
    private static let scrollSpace = "agentdeck.chat.scrollSpace"

    var body: some View {
        ScrollViewReader { proxy in
        GeometryReader { outer in
        ScrollView {
            // 注意是**急切** VStack:可见消息已被 TranscriptWindow 截到尾部窗口(默认 40 条),
            // 全部气泡高度一次定型——LazyVStack 在上滑时才物化上方气泡,NSTextView 真实高度
            // 迟到会顶得内容跳动(「浮现移动」),而窗口化后急切渲染的成本是有界的。
            VStack(alignment: .leading, spacing: 10) {
                if transcriptSlice.hiddenCount > 0 {
                    // 顶部哨兵：上报与视口的距离，接近时自动释放下一批更早消息（无按钮，渐进展开）。
                    Color.clear.frame(height: 1)
                        .background(GeometryReader { top in
                            Color.clear.preference(
                                key: ChatTopDistanceKey.self,
                                value: top.frame(in: .named(Self.scrollSpace)).maxY
                            )
                        })
                }
                ForEach(visibleMessages) { message in
                    MessageBubble(
                        message: message,
                        workingDirectory: session.workingDirectory,
                        // 流式输出中的那条 assistant 气泡先不检测散文文件名（避免逐分片重扫）；跑完转 true 重渲染一次。
                        detectFileReferences: message.id != streamingAssistantID,
                        isStreaming: message.id == streamingAssistantID,
                        onOpenFile: onOpenFile,
                        onOpenWebURL: onOpenWebURL,
                        onReviewChanges: onReviewChanges,
                        onAnswerQuestion: { record, question, selections in
                            Task {
                                if let record {
                                    await session.answerQuestion(
                                        recordID: record.id,
                                        question: question,
                                        selections: selections
                                    )
                                } else {
                                    await session.answerQuestion(question, selections: selections)
                                }
                            }
                        },
                        onRejectQuestion: { record, question in
                            Task {
                                if let record {
                                    await session.rejectQuestion(recordID: record.id, question: question)
                                } else {
                                    await session.rejectQuestion(question)
                                }
                            }
                        },
                        onShowSubagent: onShowSubagent
                    )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                }
                if shouldShowThinkingIndicator {
                    ThinkingIndicatorBubble()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
                }
                // 底部锚点：既给 scrollTo 用，也用它在视口里的位置判断「是否贴底」。
                Color.clear.frame(height: 1)
                    .id(Self.bottomAnchorID)
                    .background(GeometryReader { anchor in
                        Color.clear.preference(
                            key: ChatBottomVisibleKey.self,
                            value: anchor.frame(in: .named(Self.scrollSpace)).minY <= outer.size.height + 140
                        )
                    })
            }
            .padding(18)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.messages.count)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: shouldShowThinkingIndicator)
        }
        .coordinateSpace(name: Self.scrollSpace)
        // 默认锚定到底部：打开会话即显示最新对话；在底部时新内容自动跟随，已手动上翻则保留当前位置。
        .defaultScrollAnchor(.bottom)
        // 进入/切换不同会话时重建滚动视图，确保每次点进都从最新（底部）开始，而非上次的位置。
        .id(session.id)
        // 切换会话时收回尾部窗口（@State 不随上面的 .id 重建）。
        .onChange(of: session.id) { _, _ in transcriptLimit = TranscriptWindow.defaultLimit }
        .onPreferenceChange(ChatBottomVisibleKey.self) { atBottom = $0 }
        // 上滑几乎到顶 → 自动放出下一批更早消息。注意 defaultScrollAnchor(.bottom)
        // 只在贴底时保持距底偏移；翻历史时保持的是「距顶偏移」，释放后必须把原首条
        // 钉回视口顶（见 releaseOlderMessages），否则视口压进新内容会连锁触发直至全量展开。
        .onPreferenceChange(ChatTopDistanceKey.self) { distance in
            guard distance > -TranscriptWindow.releaseDistance else { return }
            releaseOlderMessages(proxy)
        }
        // 侧栏开/合会改列宽并重排聊天：仅当本就贴底时，逐帧把视图保持贴底（无动画，故不会上下乱滚）。
        .onChange(of: sidebarVisible) { _, _ in keepPinnedToBottomIfNeeded(proxy) }
        // 窗口缩放（尤其改高度）同理：视口变小时若不重锚，底部最新消息会被推出可视区（内容“不可见”）。
        .onChange(of: outer.size) { _, _ in keepPinnedToBottomIfNeeded(proxy) }
        // 菜单打开时，聊天区覆盖一层透明遮罩：点击列表外即关闭菜单。
        .overlay {
            if composerMenuOpen {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { composerMenuOpen = false }
            }
        }
        // 聊天框悬浮于内容之上：消息从其下方穿过，营造「前置」层次。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // 用布局把聊天框约束为列宽的 0.8 并居中：宽度在布局阶段计算，
            // 故侧栏开/关导致列宽变化时，聊天框与侧栏在同一动画事务里平滑跟随（不再瞬移）。
            ProportionalWidthLayout(fraction: 0.8) {
                ComposerView(
                    session: session,
                    workspace: workspace,
                    onClaudeLogin: onClaudeLogin,
                    menuOpen: $composerMenuOpen
                )
            }
            .background(GeometryReader { composer in
                Color.clear.preference(key: ComposerHeightKey.self, value: composer.size.height)
            })
        }
        // 聊天框长高/收缩（多行输入、附件 chips、发送后清空）只改 inset 不改滚动偏移：
        // 贴底时最新消息会被盖住/露出空隙，与侧栏开合同样处理——无动画重新钉底（#3）。
        .onPreferenceChange(ComposerHeightKey.self) { height in
            guard abs(height - composerHeight) > 0.5 else { return }
            composerHeight = height
            keepPinnedToBottomIfNeeded(proxy)
        }
        .confirmationDialog(
            "允许运行 \(session.agent.name)？",
            isPresented: Binding(
                get: { session.pendingPermission != nil },
                set: { presented in if !presented { session.cancelPending() } }
            ),
            presenting: session.pendingPermission
        ) { pending in
            // 传入捕获的 pending 值，而非让动作去读 session.pendingPermission：
            // 弹窗关闭会先经 isPresented 绑定同步清空它，异步动作会读到 nil 而丢发送。
            Button("允许一次") { Task { await session.approve(pending, remember: false) } }
            Button("允许并记住") { Task { await session.approve(pending, remember: true) } }
            Button("取消", role: .cancel) { session.cancelPending() }
        } message: { pending in
            Text("命令：\(pending.request.command)\n目录：\(pending.request.workingDirectory)\n风险：\(riskLabel(pending.request.risk))")
        }
        // 广播为用户显式批量动作，默认放行（见 WorkspaceController.broadcast），不再弹聚合授权框。
        }
        }
    }

    private var transcriptSlice: (hiddenCount: Int, visibleStart: Int) {
        TranscriptWindow.slice(
            totalCount: session.messages.count,
            // 「默认全部展开」打开时跳过尾部窗口:hiddenCount 恒 0,哨兵与自动释放自然失效。
            // 代价是首帧需测量全部气泡高度(#2 的根因),长会话打开会明显变慢。
            limit: expandAllHistory ? Int.max : transcriptLimit
        )
    }

    private var visibleMessages: ArraySlice<ChatMessage> {
        session.messages[transcriptSlice.visibleStart...]
    }

    /// 放出下一批更早消息，并把释放前的首条消息**无动画钉回视口顶**——
    /// 新批次留在视口上方等用户继续上滑，而不是让视口滑进新内容（那会连锁触发到全量展开）。
    /// 250ms 冷却让上一批 TextKit 布局落定。
    private func releaseOlderMessages(_ proxy: ScrollViewProxy) {
        guard transcriptSlice.hiddenCount > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoRelease) > 0.25 else { return }
        lastAutoRelease = now
        let anchorID = visibleMessages.first?.id
        transcriptLimit = TranscriptWindow.scrollExpandedLimit(
            current: transcriptLimit,
            totalCount: session.messages.count
        )
        guard let anchorID else { return }
        Task { @MainActor in
            // 双帧锚定（同 keepPinnedToBottomIfNeeded）：等新批次布局落定后再钉一次兜底。
            for _ in 0..<2 {
                await Task.yield()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(anchorID, anchor: .top) }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// 仅当用户本就贴底时，在侧栏宽度动画(≈0.28s)期间逐帧把视图保持在底部。
    /// 关键：用**无动画**的 scrollTo——内容随列宽重排时底部始终被钉住，看起来是「内容贴着底不动」，
    /// 而非之前那种带动画的来回滚动。若用户在上翻看历史（非贴底），则完全不打扰。
    private func keepPinnedToBottomIfNeeded(_ proxy: ScrollViewProxy) {
        guard atBottom else { return }
        // 中间栏现在是「瞬变」重排（一次性、无动画），故只需在重排稳定后**无动画**地锚一次（再补一帧兜底），
        // 不再用逐帧 scrollTo 追逐动画中的底部——那正是之前跳动/抖动的来源。
        Task { @MainActor in
            for _ in 0..<2 {
                await Task.yield()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    /// 正在流式输出的那条 assistant 气泡 id（运行中且为最后一条 assistant 消息）；非运行态为 nil。
    private var streamingAssistantID: ChatMessage.ID? {
        guard session.isRunning else { return nil }
        return session.messages.last(where: { $0.role == .assistant })?.id
    }

    private var shouldShowThinkingIndicator: Bool {
        guard session.isRunning else { return false }
        guard let lastUserIndex = session.messages.lastIndex(where: { $0.role == .user }) else { return true }
        let afterUserIndex = session.messages.index(after: lastUserIndex)
        guard afterUserIndex < session.messages.endIndex else { return true }
        return !session.messages[afterUserIndex...].contains { message in
            message.role == .assistant
                && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func riskLabel(_ risk: PermissionRequest.Risk) -> String {
        switch risk {
        case .normalAgentProcess: "普通 agent 进程"
        case .runsShellCommand: "会执行 shell 命令"
        case .readsFiles: "会读取文件"
        case .modifiesFiles: "会修改文件"
        }
    }

}

/// 把唯一子视图按可用宽度的 fraction 比例缩放并水平居中；高度跟随子视图。
/// 因为宽度在布局阶段计算（非响应式测量 state），父级宽度做动画时会逐帧平滑跟随。
struct ProportionalWidthLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let fullWidth = proposal.width ?? 0
        let childWidth = fullWidth * fraction
        let childHeight = subviews.first?
            .sizeThatFits(ProposedViewSize(width: childWidth, height: proposal.height)).height ?? 0
        return CGSize(width: fullWidth, height: childHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let childWidth = bounds.width * fraction
        child.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(width: childWidth, height: proposal.height)
        )
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let workingDirectory: URL
    var detectFileReferences: Bool = true
    var isStreaming = false
    let onOpenFile: (URL) -> Void
    let onOpenWebURL: (URL) -> Void
    var onReviewChanges: (TurnDiffSummary) -> Void = { _ in }
    var onAnswerQuestion: (QuestionToolRecord?, AskUserQuestion, [[String]]) -> Void = { _, _, _ in }
    var onRejectQuestion: (QuestionToolRecord?, AskUserQuestion) -> Void = { _, _ in }
    var onShowSubagent: (SubagentTask) -> Void = { _ in }
    @State private var copied = false
    @State private var hovering = false
    @State private var hoverOffTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 0) {
            if message.role == .user { Spacer(minLength: 40) }
            bubble
                .frame(
                    maxWidth: message.role == .assistant ? .infinity : 560,
                    alignment: message.role == .user ? .trailing : .leading
                )
            if message.role != .user { Spacer(minLength: 0) }
        }
    }

    private func handleHover(_ inside: Bool) {
        hoverOffTask?.cancel()
        if inside {
            hovering = true
        } else {
            hoverOffTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) { hovering = false }
            }
        }
    }

    private var bubble: some View {
        ZStack(alignment: .bottomTrailing) {
            content
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                )
                .shadow(color: shadowColor, radius: 4, y: 1)

            if message.role == .user {
                MessageCopyButton(text: message.text, copied: $copied)
                    .fixedSize()
                    .alignmentGuide(.bottom) { $0.height - 24 }
                    .alignmentGuide(.trailing) { $0.width + 4 }
                    .opacity(hovering || copied ? 1 : 0)
            }
        }
        .padding(.bottom, message.role == .user ? 40 : 0)
        .padding(.trailing, message.role == .user ? 20 : 0)
        .contentShape(Rectangle())
        .onHover { handleHover($0) }
    }

    private var horizontalPadding: CGFloat {
        message.role == .assistant ? Theme.Spacing.sm : Theme.Spacing.md
    }

    private var verticalPadding: CGFloat {
        message.role == .assistant ? Theme.Spacing.xs : 9
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .assistant {
            AssistantMessageContent(
                text: message.text,
                toolCalls: message.toolCalls,
                isStreaming: isStreaming,
                runStartedAt: message.runStartedAt,
                runEndedAt: message.runEndedAt,
                turnDiffSummary: message.turnDiffSummary,
                questionTools: message.questionTools,
                subagentTasks: message.subagentTasks,
                linkContext: linkContext,
                onReviewChanges: onReviewChanges,
                onAnswerQuestion: onAnswerQuestion,
                onRejectQuestion: onRejectQuestion,
                onShowSubagent: onShowSubagent
            )
        } else if message.role == .error {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .appFont(relative: -1)
                Text(message.text)
                    .appFont()
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        } else if message.role == .system {
            if message.kind == .changeReview {
                changeReviewSummary
            } else if message.kind == .question, let question = message.question {
                AskUserQuestionCard(
                    question: question,
                    onAnswer: { onAnswerQuestion(nil, question, $0) },
                    onReject: { onRejectQuestion(nil, question) }
                )
            } else {
                MarkdownText(content: message.text, linkContext: linkContext)
            }
        } else {
            Text(message.text)
                .appFont()
                .textSelection(.enabled)
        }
    }

    /// 「改动审核」消息：顶部摘要 + 「审核改动」按钮（开右侧栏审核标签），下方是可点开的改动文件清单。
    private var changeReviewSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(Theme.accent)
                Text("本轮改动 \(message.fileLinks.count) 个文件")
                    .appFont(relative: -1, weight: .semibold)
                Spacer(minLength: 8)
                if let request = ChangeReviewRequest.forMessage(message) {
                    Button {
                        onReviewChanges(request.summary)
                    } label: {
                        reviewButtonLabel
                    }
                    .buttonStyle(.plain)
                    .help("在右侧栏「审核」标签查看逐行 diff")
                } else {
                    Button(action: {}) {
                        reviewButtonLabel
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                    .help("此历史记录没有可用的逐行 Diff")
                }
            }
            // 有本轮结构化 diff → 渲染有界内联卡片（Claude 风格）；否则回落到路径清单。
            if let request = ChangeReviewRequest.forMessage(message), !request.summary.isEmpty {
                InlineDiffCardView(summary: request.summary) {
                    onReviewChanges(request.summary)
                }
            } else if !changeListText.isEmpty {
                MarkdownText(content: changeListText, linkContext: linkContext)
            }
        }
    }

    private var reviewButtonLabel: some View {
        Label("审核改动", systemImage: "arrow.left.arrow.right")
            .appFont(relative: -2, weight: .medium)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
            .foregroundStyle(Theme.accentStrong)
    }

    /// 改动清单正文：去掉首行「改动文件：」标题（标题已由摘要头呈现），仅保留文件项。
    private var changeListText: String {
        let lines = message.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "改动文件：" {
            return lines.dropFirst().joined(separator: "\n")
        }
        return message.text
    }

    private var linkContext: MessageLinkContext {
        MessageLinkContext(
            workingDirectory: workingDirectory,
            fileLinks: message.fileLinks,
            openFile: onOpenFile,
            openWebURL: onOpenWebURL,
            detectFileReferences: detectFileReferences
        )
    }

    private var background: Color {
        if message.kind == .question { return Color.clear } // 卡片自带描边/底色，外层气泡保持透明
        switch message.role {
        case .user:
            return Theme.accent.opacity(0.14)
        case .assistant:
            return Color.clear
        case .system:
            return Color.indigo.opacity(0.08)
        case .error:
            return Color.red.opacity(0.10)
        }
    }

    private var borderColor: Color {
        if message.kind == .question { return Color.clear }
        switch message.role {
        case .user:
            return Theme.accent.opacity(0.24)
        case .error:
            return Color.red.opacity(0.24)
        case .assistant:
            return Color.clear
        default:
            return Theme.hairline
        }
    }

    private var shadowColor: Color {
        .clear
    }
}

/// assistant 消息的完整呈现(计时头+思考折叠+工具行+正文)。
/// 非 private:广播对比视图(#27)复用同一渲染器,保证与单聊气泡显示一致。
struct AssistantMessageContent: View {
    let text: String
    let toolCalls: [String]
    let isStreaming: Bool
    let runStartedAt: Date?
    let runEndedAt: Date?
    var turnDiffSummary: TurnDiffSummary?
    var questionTools: [QuestionToolRecord] = []
    var subagentTasks: [SubagentTask] = []
    let linkContext: MessageLinkContext
    var onReviewChanges: (TurnDiffSummary) -> Void = { _ in }
    var onAnswerQuestion: (QuestionToolRecord?, AskUserQuestion, [[String]]) -> Void = { _, _, _ in }
    var onRejectQuestion: (QuestionToolRecord?, AskUserQuestion) -> Void = { _, _ in }
    var onShowSubagent: (SubagentTask) -> Void = { _ in }
    @State private var processDetailsHidden = false

    var body: some View {
        let renderBlocks = MessagePresentation.assistantTimelineBlocks(in: text)
        // 折叠「运行细节」：思考过程 + 工具活动一并折叠。折叠箭头与结束后自动折叠在「有思考或工具」时生效。
        let hasProcessDetails = RunProcessDetailPresentation.containsCollapsibleProcessDetails(renderBlocks)

        VStack(alignment: .leading, spacing: 7) {
            if let runStartedAt {
                RunTimerHeader(
                    startedAt: runStartedAt,
                    endedAt: runEndedAt,
                    hasProcessDetails: hasProcessDetails,
                    processDetailsHidden: processDetailsHidden
                ) {
                    withAnimation(.easeOut(duration: 0.18)) { processDetailsHidden.toggle() }
                }
            }

            // 「工具调用」汇总块随运行细节一并折叠。
            if !toolCalls.isEmpty && !processDetailsHidden {
                CollapsibleToolCallsBlock(toolCalls: toolCalls)
            }

            ForEach(Array(renderBlocks.enumerated()), id: \.offset) { _, collapsed in
                if RunProcessDetailPresentation.shouldRender(collapsed.block, detailsHidden: processDetailsHidden) {
                    switch collapsed.block {
                    case .text(let text):
                        AssistantBodyTextBlock(text: text, linkContext: linkContext, runEndedAt: runEndedAt)
                    case .thinking(let text):
                        ThinkingProcessBlock(text: text)
                    case .toolCall(let text):
                        InlineToolActivityRow(
                            text: text,
                            count: collapsed.count,
                            linkContext: linkContext,
                            turnDiffSummary: turnDiffSummary,
                            onReviewChanges: onReviewChanges
                        )
                    case .questionRef(let id):
                        if let record = questionTools.first(where: { $0.id == id }) {
                            QuestionToolTimelineBlock(
                                record: record,
                                onAnswer: { selections in
                                    onAnswerQuestion(record, record.question, selections)
                                },
                                onReject: {
                                    onRejectQuestion(record, record.question)
                                }
                            )
                        }
                    case .inlineError(let text):
                        InlineErrorLine(text: text)
                    case .subagentRef(let id, let label):
                        SubagentActivityRow(
                            task: subagentTasks.first { $0.id == id },
                            label: label
                        ) { task in onShowSubagent(task) }
                    }
                }
            }
        }
        // 运行结束即自动折叠运行细节（思考 + 工具，等效点击「运行总时间」行）。仅在有可折叠细节时生效。
        .onAppear { if runEndedAt != nil && hasProcessDetails { processDetailsHidden = true } }
        .onChange(of: runEndedAt) { _, newValue in
            guard newValue != nil, hasProcessDetails else { return }
            withAnimation(.easeOut(duration: 0.2)) { processDetailsHidden = true }
        }
    }
}

private struct RunTimerHeader: View {
    let startedAt: Date
    let endedAt: Date?
    let hasProcessDetails: Bool
    let processDetailsHidden: Bool
    let toggleProcessDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Group {
                if let endedAt {
                    interactiveLine(now: endedAt)
                } else {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        interactiveLine(now: context.date)
                    }
                }
            }

            Rectangle()
                .fill(Theme.border.opacity(0.45))
                .frame(height: 1)
        }
        .padding(.leading, 2)
        .padding(.bottom, 7)
        .help("总运行时间")
        .accessibilityLabel(RunDurationPresentation.label(startedAt: startedAt, endedAt: endedAt, now: Date()))
    }

    @ViewBuilder
    private func interactiveLine(now: Date) -> some View {
        if hasProcessDetails {
            Button(action: toggleProcessDetails) {
                timerLabel(now: now)
            }
            .buttonStyle(.plain)
            .help(processDetailsHidden ? "展开运行细节" : "折叠运行细节")
        } else {
            timerLabel(now: now)
        }
    }

    private func timerLabel(now: Date) -> some View {
        HStack(spacing: 5) {
            Text(RunDurationPresentation.label(startedAt: startedAt, endedAt: endedAt, now: now))
                .appFont(weight: .medium)
                .monospacedDigit()
            if hasProcessDetails {
                Text(processDetailsHidden ? "›" : "⌄")
                    .appFont(weight: .medium)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.secondary.opacity(0.72))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct AssistantBodyTextBlock: View {
    let text: String
    let linkContext: MessageLinkContext
    let runEndedAt: Date?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            MarkdownText(content: text, linkContext: linkContext)
            if let runEndedAt {
                Text(RunCompletionTimePresentation.label(endedAt: runEndedAt))
                    .appFont(relative: -3)
                    .foregroundStyle(Color.secondary.opacity(0.46))
                    .opacity(hovering ? 1 : 0)
                    .offset(y: hovering ? 0 : -4)
                    .frame(height: 14, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}

private struct ThinkingProcessBlock: View {
    let text: String

    var body: some View {
        MarkdownText(content: text)
            .foregroundStyle(.secondary)
    }
}

private struct CollapsibleToolCallsBlock: View {
    let toolCalls: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .appFont(relative: -2, weight: .semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Theme.accent.opacity(0.78))
                    Image(systemName: "wrench.and.screwdriver")
                        .appFont(relative: -2, weight: .semibold)
                        .foregroundStyle(Theme.accent.opacity(0.78))
                    Text("工具调用")
                        .appFont(relative: -1, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .appFont(relative: -2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起工具调用" : "展开工具调用")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(toolCalls.enumerated()), id: \.offset) { _, call in
                        ToolCallRow(text: call)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlHover.opacity(0.36), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.border.opacity(0.68), lineWidth: 1)
        }
    }

    private var summary: String {
        let count = toolCalls.count
        return expanded ? "已展开 · \(count) 个" : "已折叠 · \(count) 个"
    }
}

private struct ToolCallRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "wrench")
                .appFont(relative: -3, weight: .semibold)
                .foregroundStyle(Theme.accent.opacity(0.78))
                .frame(width: 12)
            Text(compactText)
                .appFont(relative: -2, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.controlHover.opacity(0.42), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.border.opacity(0.45), lineWidth: 1)
        }
    }

    private var compactText: String {
        text
    }
}

enum ToolActivityRowPresentation {
    static let fileMenuTitles = FileLinkContextMenuPresentation.titles
    static let drawsContainerFrame = false
}

/// 内联工具活动行：把「读取 / 编辑 / 创建 / 运行 …」状态按时间顺序穿插在 assistant 输出里
/// （参考 Codex / Claude Code 的运行状态提示）。图标按动词推断，工具出错时转红；
/// 相邻重复（如连续编辑同一文件）合并成一行并显示 ×次数；文件类动词的路径渲染为可点击链接，点开在右侧栏显示。
/// 行尾「›」可点开展开：显示完整摘要（全路径/命令），编辑类还就地展开该文件本轮逐行 diff。
private struct InlineToolActivityRow: View {
    let text: String
    var count: Int = 1
    let linkContext: MessageLinkContext
    var turnDiffSummary: TurnDiffSummary?
    var onReviewChanges: (TurnDiffSummary) -> Void = { _ in }

    @State private var expanded = false
    @State private var hovering = false

    /// 拦截路径链接点击用的私有 scheme（绝对路径放在 url.path 里）。
    private static let fileScheme = "agentdeck-toolfile"
    /// 工具行里文件链接的中性灰：比同行普通次级文字更深，仍提示可点击，但不抢蓝色强调。
    private static let linkColor = Color.primary.opacity(0.72)

    var body: some View {
        let error = ToolActivityStyle.isError(text)
        let tint = error ? Color.red.opacity(0.85) : Theme.accent.opacity(0.85)
        let parts = ToolActivity.displayParts(in: text, workingDirectory: linkContext.workingDirectory)
        let firstTarget = firstFileTarget(in: parts)
        let display = ToolActivity.displayText(in: text, workingDirectory: linkContext.workingDirectory)
        let matchedDiff = matchedFileDiff(for: firstTarget)
        let canExpand = matchedDiff != nil || text != display

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ToolActivityStyle.icon(for: text))
                    .appFont(relative: -2, weight: .semibold)
                    .foregroundStyle(tint)
                    .frame(width: 15)
                Group {
                    if let firstTarget {
                        // 路径片段渲染成链接：点击交给下方 openURL → 在右侧栏打开。
                        Text(linkedString(parts: parts, error: error)).tint(Self.linkColor)
                            .contextMenu {
                                Button(FileLinkContextMenuPresentation.copyAbsoluteFolderTitle) {
                                    copy(FileLinkContextMenuPresentation.absoluteFolderPath(for: firstTarget.url))
                                }
                                Button(FileLinkContextMenuPresentation.copyRelativeFolderTitle) {
                                    copy(FileLinkContextMenuPresentation.relativeFolderPath(
                                        for: firstTarget.url,
                                        workingDirectory: linkContext.workingDirectory
                                    ))
                                }
                                Button(FileLinkContextMenuPresentation.openInFinderTitle) {
                                    NSWorkspace.shared.activateFileViewerSelecting([firstTarget.url])
                                }
                            }
                    } else {
                        Text(plainString(error: error)).textSelection(.enabled)
                    }
                }
                .appFont(relative: -1)
                .lineLimit(expanded ? nil : 2)
                .truncationMode(.middle)
                Spacer(minLength: 6)
                if count > 1 {
                    Text("×\(count)")
                        .appFont(relative: -2, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.16), in: Capsule())
                }
                // 编辑行内联 +N −M（图2 风格）：让「编辑 X」一眼看出改了多少、点开看 diff。
                if let matchedDiff {
                    if matchedDiff.addedCount > 0 {
                        Text("+\(matchedDiff.addedCount)")
                            .appFont(relative: -2, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.green)
                    }
                    if matchedDiff.removedCount > 0 {
                        Text("−\(matchedDiff.removedCount)")
                            .appFont(relative: -2, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }
                if canExpand { disclosureButton }
            }
            if expanded && canExpand {
                detailPanel(diff: matchedDiff)
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(hovering && canExpand ? Theme.controlHover.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.fileScheme else { return .systemAction }
            linkContext.openFile(URL(filePath: url.path))
            return .handled
        })
        .accessibilityLabel(count > 1 ? "\(display)（\(count) 次）" : display)
    }

    /// 行尾展开钮：点开显示完整摘要 + 编辑 diff。
    private var disclosureButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .appFont(relative: -3, weight: .semibold)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(hovering || expanded ? Theme.accent.opacity(0.85) : .secondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "收起" : "显示详情")
    }

    /// 展开区：完整摘要（全路径/命令，可选中）+ 编辑类的逐行 diff + 跳右侧栏看全部。
    @ViewBuilder
    private func detailPanel(diff: TurnFileDiff?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .appFont(relative: -2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let diff {
                InlineDiffFileCardView(file: diff, initiallyExpanded: true)
                if let summary = turnDiffSummary {
                    Button { onReviewChanges(summary) } label: {
                        Label("在审核栏查看全部 diff", systemImage: "arrow.up.forward.app")
                            .appFont(relative: -3, weight: .medium)
                            .foregroundStyle(Theme.accentStrong)
                    }
                    .buttonStyle(.plain)
                    .help("在右侧栏「审核」标签查看本轮完整逐行 diff")
                }
            }
        }
        .padding(.leading, 23)
        .padding(.top, 1)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    /// 仅对「改了文件」的动词（编辑/创建/编辑笔记本）匹配本轮 diff；读取等不产生改动的行不挂 diff。
    private func matchedFileDiff(for target: ToolActivity.FileTarget?) -> TurnFileDiff? {
        guard let target, let summary = turnDiffSummary, ToolActivityStyle.isMutatingVerb(text) else { return nil }
        return summary.fileDiff(forRelativePath: target.relativePath)
    }

    private func plainString(error: Bool) -> AttributedString {
        var plain = AttributedString(ToolActivity.displayText(in: text, workingDirectory: linkContext.workingDirectory))
        plain.foregroundColor = error ? Color.red.opacity(0.92) : .secondary
        return plain
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// 普通命令文本保持次级色；路径段压缩成文件名并加链接（自定义 scheme，真实路径放 url.path）。
    /// 链接为中性灰（非蓝），默认无下划线，仅整行 hover 时显示同色下划线——既可辨识可点击，又不喧宾夺主。
    private func linkedString(parts: [ToolActivity.DisplayPart], error: Bool) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            switch part {
            case .text(let text):
                var value = AttributedString(text)
                value.foregroundColor = error ? Color.red.opacity(0.92) : .secondary
                result += value
            case .file(let target):
                var link = AttributedString(target.path)
                link.foregroundColor = Self.linkColor
                // 下划线仅 hover 时出现，且与链接文字同色（通过 LineStyle 的 color 设定）。
                if hovering {
                    link.underlineStyle = Text.LineStyle(pattern: .solid, color: Self.linkColor)
                }
                if var components = URLComponents(string: "\(Self.fileScheme)://open") {
                    components.path = target.url.path
                    link.link = components.url
                }
                result += link
            }
        }
    }

    private func firstFileTarget(in parts: [ToolActivity.DisplayPart]) -> ToolActivity.FileTarget? {
        for part in parts {
            if case .file(let target) = part { return target }
        }
        return nil
    }
}

/// 「委派任务」行：显示子代理类型/描述 + 状态（进行中/完成/出错），点击在右侧栏展开明细（派发的 prompt + 子代理结果）。
private struct SubagentActivityRow: View {
    let task: SubagentTask?
    let label: String
    let onOpen: (SubagentTask) -> Void
    @State private var hovering = false

    var body: some View {
        let isError = task?.isError == true
        let done = task?.result != nil
        Button {
            if let task { onOpen(task) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2.fill")
                    .appFont(relative: -2, weight: .semibold)
                    .foregroundStyle(isError ? Color.red.opacity(0.85) : Theme.accent.opacity(0.85))
                    .frame(width: 15)
                Text("委派任务")
                    .appFont(relative: -1, weight: .medium)
                    .foregroundStyle(.secondary)
                Text(label)
                    .appFont(relative: -1)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                statusView(done: done, isError: isError)
                Image(systemName: "sidebar.right")
                    .appFont(relative: -3, weight: .semibold)
                    .foregroundStyle(hovering ? Theme.accent.opacity(0.85) : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if hovering && InlineRecordRowPresentation.highlightsOnHover {
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .fill(Theme.controlHover.opacity(InlineRecordRowPresentation.hoverBackgroundOpacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(task == nil)
        .onHover { hovering = $0 }
        .help(task == nil ? "" : "在右侧栏查看子任务明细（派发内容 + 子代理结果）")
    }

    @ViewBuilder
    private func statusView(done: Bool, isError: Bool) -> some View {
        if isError {
            Text("出错").appFont(relative: -2, weight: .medium).foregroundStyle(.red)
        } else if done {
            Image(systemName: "checkmark.circle.fill").appFont(relative: -2).foregroundStyle(.green)
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

/// 据工具活动文案的中文动词推断 SF Symbol 图标（与 OutputParser.toolSummary 的动词集对应）。
private enum ToolActivityStyle {
    static func isError(_ text: String) -> Bool {
        text.hasPrefix("工具出错")
    }

    /// 「改了文件」的动词（编辑/创建/编辑笔记本）：这些行才挂本轮逐行 diff。
    static func isMutatingVerb(_ text: String) -> Bool {
        switch leadingVerb(text) {
        case "编辑", "创建", "编辑笔记本": return true
        default: return false
        }
    }

    static func icon(for text: String) -> String {
        if isError(text) { return "exclamationmark.triangle" }
        switch leadingVerb(text) {
        case "读取": return "doc.text"
        case "编辑", "编辑笔记本": return "pencil"
        case "创建": return "doc.badge.plus"
        case "运行": return "terminal"
        case "搜索": return "magnifyingglass"
        case "联网搜索", "抓取": return "globe"
        case "查找": return "doc.text.magnifyingglass"
        case "列出": return "list.bullet"
        case "更新计划": return "checklist"
        case "委派任务": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }

    /// 取首个空格前的词（中文动词）；无空格则取整串（如独立的「更新计划」）。
    private static func leadingVerb(_ text: String) -> String {
        if let space = text.firstIndex(of: " ") {
            return String(text[..<space])
        }
        return text
    }
}

private struct ThinkingIndicatorBubble: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("思考中")
                    .appFont(relative: -1, weight: .medium)
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .fill(Theme.accent.opacity(index == phase ? 0.85 : 0.25))
                            .frame(width: 4.5, height: 4.5)
                            .scaleEffect(index == phase ? 1.18 : 1)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(420))
                withAnimation(.easeInOut(duration: 0.2)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityLabel("思考中")
    }
}

/// AskUserQuestion 卡片：渲染问题与可点选项。
/// opencode（question.requestID 非空）：agent **原地等待**，提交直接经 reply API 回传、它据此继续。
/// Claude（requestID 为空）：`-p` 非交互无法回灌进程，提交作为**下一条消息**发出（会话续接）。
private struct AskUserQuestionCard: View {
    let question: AskUserQuestion
    let onAnswer: ([[String]]) -> Void
    var onReject: () -> Void = {}
    @State private var selections: [String: Set<String>] = [:] // 问题 id → 已选 label 集合
    @State private var submitting = false

    /// 会阻塞等待回答：opencode（requestID）或 Claude 经 MCP ask_user（mcpRequestID）。其余（Claude 追加消息）为 false。
    private var waitsForReply: Bool { question.requestID != nil || question.mcpRequestID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(waitsForReply
                ? "Agent 正在等待你的选择；选好点「提交」即据此继续。"
                : "Claude 不会停下来等待；选好点「提交」会作为新消息发给它继续。")
                .appFont(relative: -3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.questions) { item in
                questionBlock(item)
            }
            submitRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(Theme.accent)
            Text("需要你的选择")
                .appFont(relative: -1, weight: .semibold)
            Spacer(minLength: 8)
        }
    }

    private func questionBlock(_ item: AskUserQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(item.title)
                    .appFont(relative: -1, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                if item.multiSelect {
                    Text("可多选")
                        .appFont(relative: -3, weight: .medium)
                        .foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }
            ForEach(item.options) { option in
                optionRow(item: item, option: option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(item: AskUserQuestion.Item, option: AskUserQuestion.Option) -> some View {
        let isSelected = selections[item.id]?.contains(option.label) == true
        return Button {
            toggle(item: item, option: option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selectionSymbol(multiSelect: item.multiSelect, selected: isSelected))
                    .appFont(relative: -1)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .appFont(relative: -1, weight: .medium)
                        .foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .appFont(relative: -3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Theme.selected : Theme.panelRaised.opacity(0.6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    private var submitRow: some View {
        HStack(spacing: 10) {
            Button(action: skip) {
                Text("跳过")
                    .appFont(relative: -2, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.controlHover.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(submitting)
            .help(waitsForReply ? "拒绝该提问（agent 继续）" : "跳过，不回复")
            Spacer(minLength: 0)
            Button(action: submit) {
                Text(submitting ? "提交中" : "提交")
                    .appFont(relative: -1, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(canSubmit ? Theme.accent : Color.secondary.opacity(0.32), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help(waitsForReply ? "把选择回传给运行中的 agent" : "把选择作为新消息发给 Claude")
        }
    }

    private func selectionSymbol(multiSelect: Bool, selected: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private var canSubmit: Bool {
        !submitting && question.questions.allSatisfy { !(selections[$0.id]?.isEmpty ?? true) }
    }

    private func toggle(item: AskUserQuestion.Item, option: AskUserQuestion.Option) {
        var set = selections[item.id] ?? []
        if item.multiSelect {
            if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
        } else {
            set = [option.label] // 单选：替换
        }
        selections[item.id] = set
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        onAnswer(orderedSelections())
    }

    private func skip() {
        guard !submitting else { return }
        submitting = true
        onReject()
    }

    /// 每题按选项原始顺序导出选中的 label 数组（opencode reply / Claude 文案共用）。
    private func orderedSelections() -> [[String]] {
        question.questions.map { item in
            item.options.map(\.label).filter { selections[item.id]?.contains($0) == true }
        }
    }
}

/// 提问工具在 assistant 时间线中的两种形态：待回答显示卡片，完成后原位折叠成「询问」工具记录。
private struct QuestionToolTimelineBlock: View {
    let record: QuestionToolRecord
    let onAnswer: ([[String]]) -> Void
    let onReject: () -> Void

    @ViewBuilder
    var body: some View {
        if record.isPending {
            AskUserQuestionCard(
                question: record.question,
                onAnswer: onAnswer,
                onReject: onReject
            )
        } else {
            ResolvedQuestionToolRow(record: record)
        }
    }
}

private struct ResolvedQuestionToolRow: View {
    let record: QuestionToolRecord
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.bubble")
                        .appFont(relative: -2, weight: .semibold)
                        .foregroundStyle(Theme.accent.opacity(0.82))
                    Text(QuestionToolPresentation.title)
                        .appFont(relative: -1, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .appFont(relative: -2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .appFont(relative: -3, weight: .semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起询问详情" : "展开询问详情")

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(record.detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .appFont(relative: -2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 21)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if hovering && InlineRecordRowPresentation.highlightsOnHover {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.controlHover.opacity(InlineRecordRowPresentation.hoverBackgroundOpacity))
            }
        }
        .onHover { hovering = $0 }
    }

    private var summary: String {
        switch record.resolution {
        case .pending:
            return ""
        case .answered:
            return QuestionToolPresentation.answeredSummary
        case .skipped:
            return QuestionToolPresentation.skippedSummary
        }
    }
}

private struct MessageCopyButton: View {
    let text: String
    @Binding var copied: Bool

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .appFont(relative: -3, weight: .semibold)
                if copied {
                    Text("已复制")
                        .appFont(relative: -3, weight: .medium)
                }
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .padding(.horizontal, copied ? 7 : 6)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .help(copied ? "已复制整条消息" : "复制整条消息")
        .accessibilityLabel(copied ? "已复制" : "复制整条消息")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        }
    }
}

private struct InlineErrorLine: View {
    let text: String
    @AppStorage(BundledCodeFont.storageKey) private var selectedCodeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Rectangle()
                .fill(Color.red.opacity(0.70))
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .appFont(relative: -2, weight: .semibold)
                    Text("错误")
                        .appFont(relative: -2, weight: .semibold)
                }
                .foregroundStyle(Color.red.opacity(0.88))
                Text(text)
                    .font(BundledCodeFont.resolve(selectedCodeFontID).swiftUIFont(size: AppFontSize.points(appFontSize)))
                    .foregroundStyle(Color.red.opacity(0.92))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.075), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        }
    }
}
