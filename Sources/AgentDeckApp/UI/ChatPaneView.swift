import SwiftUI
import AppKit

struct ChatPaneView: View {
    @Bindable var session: AgentSession
    var workspace: WorkspaceController? = nil
    let onClose: () -> Void
    var onOpenFile: (URL) -> Void = { _ in }
    var onOpenWebURL: (URL) -> Void = { _ in }
    var onReviewChanges: (TurnDiffSummary) -> Void = { _ in } // 「审核改动」：打开右侧栏「审核」标签
    var onClaudeLogin: () -> Void = {}
    @State private var composerMenuOpen = false // 菜单打开时聊天区显示透明遮罩，点击即关闭

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(session.messages) { message in
                    MessageBubble(
                        message: message,
                        workingDirectory: session.workingDirectory,
                        // 流式输出中的那条 assistant 气泡先不检测散文文件名（避免逐分片重扫）；跑完转 true 重渲染一次。
                        detectFileReferences: message.id != streamingAssistantID,
                        isStreaming: message.id == streamingAssistantID,
                        onOpenFile: onOpenFile,
                        onOpenWebURL: onOpenWebURL,
                        onReviewChanges: onReviewChanges
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
            }
            .padding(18)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.messages.count)
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: shouldShowThinkingIndicator)
        }
        // 默认锚定到底部：打开会话即显示最新对话；在底部时新内容自动跟随，已手动上翻则保留当前位置。
        .defaultScrollAnchor(.bottom)
        // 进入/切换不同会话时重建滚动视图，确保每次点进都从最新（底部）开始，而非上次的位置。
        .id(session.id)
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
                linkContext: linkContext
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
        switch message.role {
        case .user:
            Theme.accent.opacity(0.14)
        case .assistant:
            Color.clear
        case .system:
            Color.indigo.opacity(0.08)
        case .error:
            Color.red.opacity(0.10)
        }
    }

    private var borderColor: Color {
        switch message.role {
        case .user:
            Theme.accent.opacity(0.24)
        case .error:
            Color.red.opacity(0.24)
        case .assistant:
            Color.clear
        default:
            Theme.hairline
        }
    }

    private var shadowColor: Color {
        .clear
    }
}

private struct AssistantMessageContent: View {
    let text: String
    let toolCalls: [String]
    let isStreaming: Bool
    let runStartedAt: Date?
    let runEndedAt: Date?
    let linkContext: MessageLinkContext
    @State private var processDetailsHidden = false

    var body: some View {
        let renderBlocks = MessagePresentation.assistantTimelineBlocks(in: text)
        let hasProcessDetails = RunProcessDetailPresentation.containsProcessDetails(
            toolCalls: toolCalls,
            blocks: renderBlocks
        )

        VStack(alignment: .leading, spacing: 7) {
            if let runStartedAt {
                RunTimerHeader(
                    startedAt: runStartedAt,
                    endedAt: runEndedAt,
                    hasProcessDetails: hasProcessDetails,
                    processDetailsHidden: processDetailsHidden
                ) {
                    processDetailsHidden.toggle()
                }
            }

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
                        InlineToolActivityRow(text: text, count: collapsed.count, linkContext: linkContext)
                    case .inlineError(let text):
                        InlineErrorLine(text: text)
                    }
                }
            }
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
            .help(processDetailsHidden ? "显示全部思考/工具内容" : "隐藏全部思考/工具内容")
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
private struct InlineToolActivityRow: View {
    let text: String
    var count: Int = 1
    let linkContext: MessageLinkContext

    /// 拦截路径链接点击用的私有 scheme（绝对路径放在 url.path 里）。
    private static let fileScheme = "agentdeck-toolfile"

    var body: some View {
        let error = ToolActivityStyle.isError(text)
        let tint = error ? Color.red.opacity(0.85) : Theme.accent.opacity(0.85)
        let parts = ToolActivity.displayParts(in: text, workingDirectory: linkContext.workingDirectory)
        let firstTarget = firstFileTarget(in: parts)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ToolActivityStyle.icon(for: text))
                .appFont(relative: -2, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 15)
            Group {
                if let firstTarget {
                    // 路径片段渲染成链接：点击交给下方 openURL → 在右侧栏打开。链接行不开文本选择，避免和点击冲突。
                    Text(linkedString(parts: parts, error: error)).tint(Theme.accent)
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
            .lineLimit(2)
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
        }
        .padding(.leading, 9)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.fileScheme else { return .systemAction }
            linkContext.openFile(URL(filePath: url.path))
            return .handled
        })
        .accessibilityLabel(count > 1 ? "\(accessibleText)（\(count) 次）" : accessibleText)
    }

    private func plainString(error: Bool) -> AttributedString {
        var plain = AttributedString(ToolActivity.displayText(in: text, workingDirectory: linkContext.workingDirectory))
        plain.foregroundColor = error ? Color.red.opacity(0.92) : .secondary
        return plain
    }

    private var accessibleText: String {
        ToolActivity.displayText(in: text, workingDirectory: linkContext.workingDirectory)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// 普通命令文本保持次级色；路径段压缩成文件名并加链接（自定义 scheme，真实路径放 url.path）。
    private func linkedString(parts: [ToolActivity.DisplayPart], error: Bool) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            switch part {
            case .text(let text):
                var value = AttributedString(text)
                value.foregroundColor = error ? Color.red.opacity(0.92) : .secondary
                result += value
            case .file(let target):
                var link = AttributedString(target.path)
                link.foregroundColor = Color(nsColor: .linkColor)
                link.underlineStyle = .single
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

/// 据工具活动文案的中文动词推断 SF Symbol 图标（与 OutputParser.toolSummary 的动词集对应）。
private enum ToolActivityStyle {
    static func isError(_ text: String) -> Bool {
        text.hasPrefix("工具出错")
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
