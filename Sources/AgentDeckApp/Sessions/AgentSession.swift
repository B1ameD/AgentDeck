import Foundation
import Observation
import os

public protocol AgentRunning: Sendable {
    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> ProcessResult

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error>
}

public extension AgentRunning {
    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL
    ) async throws -> ProcessResult {
        try await runOneShot(
            command: command,
            args: args,
            environment: environment,
            workingDirectory: workingDirectory,
            stdin: nil
        )
    }

    /// 默认「伪流式」：基于 runOneShot 一次性产出。让仅实现 runOneShot 的
    /// 测试 mock 自动获得 stream 能力；ProcessRunner 提供自己的真流式实现。
    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await runOneShot(
                        command: command,
                        args: args,
                        environment: environment,
                        workingDirectory: workingDirectory,
                        stdin: stdin
                    )
                    if !result.stdout.isEmpty { continuation.yield(.stdout(result.stdout)) }
                    if !result.stderr.isEmpty { continuation.yield(.stderr(result.stderr)) }
                    continuation.yield(.exit(result.exitCode))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension ProcessRunner: AgentRunning {}

@MainActor
@Observable
public final class AgentSession: Identifiable {
    public let id: UUID
    public let agent: AgentConfig
    public var workingDirectory: URL
    public var model: String
    public var reasoningEffort: ReasoningEffort
    public var interactionMode: InteractionMode
    public var command: AgentCommand
    /// 输入框草稿：随键入实时存到本会话，使切标签 / 调 effort / 视图重建等操作不丢失未发送内容。
    /// 仅内存态（不进快照、不落盘），App 重启后清空即可。
    public var draft: String = ""
    /// 用户自定义标签名（双击标签 / 右键「改名」设置）；为空时回落到首条消息摘要 / agent 名。
    public var customTitle: String?
    /// 标签是否置顶（左栏排序时置顶项在前）。
    public var pinned: Bool
    /// 该标签的工作目录是否被用户手动锁定（右键「设置工作目录…」）。
    /// 锁定后切换全局工作区不会再覆盖本标签目录，从而让单个标签拥有独立工作区。
    public var directoryPinned: Bool
    /// 选定的「恢复目标」会话 id（Claude 历史会话）；command == .resume 时透传给 --resume <id>。
    public var resumeSessionID: String?
    /// 工作目录是否已随对话锁死：一旦产生任何消息即永久锁定。
    /// claude 会话按 cwd 存储（实测换目录后 --resume 必报 No conversation found 而静默丢上下文），
    /// 故从源头禁止改目录（#4）；/clear 换新空会话后可重新选择目录。
    public var workingDirectoryLocked: Bool { !messages.isEmpty }
    public private(set) var messages: [ChatMessage]
    public private(set) var status: SessionStatus
    /// 最近一次运行「本轮改动的文件」相对路径（聊天里的改动卡片链接用）。
    public private(set) var lastChangedPaths: [String] = []
    /// 最近一次运行的结构化逐行 diff（运行后算一次、之后只读）。右侧栏「审核」与聊天内联卡片据此渲染，
    /// 不再从当前磁盘 / git HEAD 现算——保证展示的是该轮不可变的 before→after 改动。
    public private(set) var lastTurnDiffSummary: TurnDiffSummary?
    /// 单次运行的超时时长；nil 表示不超时。超时后自动终止并标记失败。
    public var timeout: Duration?
    /// 等待用户授权的待运行请求；非 nil 时 UI 应弹出确认。
    public private(set) var pendingPermission: PendingRun?
    /// ACP 工具权限请求（agent 通过 session/request_permission 发起，含 agent 自报的可选项）；
    /// 非 nil 时 UI 弹卡片，用户点选后经 resolveACPPermission 回传 optionId（#ACP 阶段 2）。
    public private(set) var pendingACPPermission: PendingACPPermission?
    private var acpPermissionContinuation: CheckedContinuation<String?, Never>?
    /// 对话变化后的持久化回调（WorkspaceController 注入，把本会话落盘）。
    public var onPersist: (@MainActor () -> Void)?
    /// /clear：请求「开新会话」——把当前标签换成同 agent/目录的新空会话，旧对话留在历史。
    /// 由 WorkspaceController 注入（它持有会话数组，会话自身无法把自己换出）。
    public var onRequestNewChat: (@MainActor () -> Void)?

    public typealias PermissionDecider = @Sendable (PermissionRequest) -> PermissionDecision

    /// 一个等待授权的运行请求。
    public struct PendingRun: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public var prompt: String
        public var attachments: [URL]
        public var request: PermissionRequest
    }

    /// 一条 ACP 工具权限请求：标题（工具调用摘要）+ agent 自报的可选项（allow_once/allow_always/…）。
    public struct PendingACPPermission: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public var title: String
        public var options: [ACPPermissionOption]
    }

    private typealias ClaudeContinuityStrategy = SessionContinuity.ClaudeStrategy

    private struct AgentRunOutcome: Equatable {
        var exitCode: Int32
        var stderr: String
        var producedMessage: Bool

        var isClaudeResumeFailure: Bool {
            let detail = stderr.lowercased()
            return detail.contains("no conversation found")
                || detail.contains("already in use")
                || detail.contains("invalid session")
                || detail.contains("--resume requires")
        }
    }

    private let runner: AgentRunning
    private let promptOptimizer: any PromptOptimizing
    private let changeTracker: any WorkspaceChangeTracking
    private let permissionDecider: PermissionDecider
    /// opencode 流式通道（注入；nil 表示退回非流式 `opencode run`）。仅 .openCode 会话使用。
    private let openCodeStreamer: OpenCodeStreaming?
    /// ACP 传输（agent.resolvedTransport == .acp 时使用）。注入用于测试；为 nil 时惰性创建 ACPClient。
    /// 跨轮复用同一会话（适配器子进程 + sessionId 常驻），获得多轮上下文。
    private var acpTransport: ACPTransporting?
    private var acpSessionID: String?
    private var acpAvailableModes: [ACPMode] = []
    /// ACP agent 自报的会话配置项（模型/推理强度等选择器）。Claude 适配器为空（模型走 env），
    /// codex-acp 等会自报；供未来配置项 UI 动态渲染。
    public private(set) var acpConfigOptions: [ACPConfigOption] = []
    /// ACP 会话当前模式 id（来自 session/new 初值与 current_mode_update）。供 UI 显示真实模式。
    public private(set) var acpCurrentModeID: String?
    /// initialize 协商到的 agent 能力（loadSession/resume 等）。
    private var acpCapabilities: ACPAgentCapabilities?
    /// 从持久化恢复的 ACP sessionId：首轮若 agent 支持 resume 则续接而非新建（跨重开恢复上下文）。
    private var acpRestoredSessionID: String?
    private static let streamingLog = Logger(subsystem: "AgentDeck", category: "opencode-stream")
    /// 「允许并记住」记下的授权目录。授权只对该目录有效——切到别的目录须重新征询，
    /// 避免把对 A 目录的许可静默套用到 B 目录（权限弹窗本就是按目录展示风险的）。
    private var approvedDirectory: URL?
    private var runTask: Task<AgentRunOutcome, Never>?
    private var timedOut = false
    private var activeRunStartedAt: Date?
    private var activeRunAssistantIDs: [UUID] = []
    /// Stop 可能发生在 status 已为 running、但 baseline snapshot 尚未结束、runTask 尚未创建的窗口。
    /// 记录该请求，baseline 完成后在启动外部进程前消费掉，避免空按 Stop 后进程仍被启动。
    private var stopRequested = false
    /// 后端会话连续性状态机（会话 id 捕获 / 模型切换失效 / Claude 回放策略），逻辑见 SessionContinuity.swift。
    private var sessionContinuity: SessionContinuity
    /// 后端会话 id，用于继续对话。ACP：当前/恢复的 sessionId（持久化后跨重开 resume）；CLI：续接状态机捕获的 id。
    public var backendSessionID: String? {
        agent.resolvedTransport == .acp ? (acpSessionID ?? acpRestoredSessionID) : sessionContinuity.backendSessionID
    }
    /// 捕获 backendSessionID 时使用的模型 key，模型切换时清空会话 id。
    public var backendSessionModel: String? { sessionContinuity.backendSessionModel }
    /// Claude 输出流里实际解析到的模型 id（system/init 的顶层 `model` 或 assistant 的 `message.model`）。
    /// 选 “opus”/“default” 等别名时运行时才解析为具体版本——据此把 UI 芯片显示成真实版本（如 Opus 4.8）。
    /// 改选模型时清空（见 setSelectedModel），下一轮重新捕获。
    public var resolvedModel: String? { sessionContinuity.resolvedModel }
    /// 会话累计 token/费用（真实计量，来自 claude result 行；其它 agent 暂无数据保持 isEmpty。#28）。
    public private(set) var usage: SessionUsage
    private var usageCapture = UsageCapture()

    private var isApprovedForCurrentDirectory: Bool {
        guard let approvedDirectory else { return false }
        return approvedDirectory.standardizedFileURL == workingDirectory.standardizedFileURL
    }

    public init(
        id: UUID = UUID(),
        agent: AgentConfig,
        workingDirectory: URL,
        model: String = "default",
        reasoningEffort: ReasoningEffort = .medium,
        interactionMode: InteractionMode = .build,
        command: AgentCommand = .new,
        customTitle: String? = nil,
        pinned: Bool = false,
        directoryPinned: Bool = false,
        resumeSessionID: String? = nil,
        messages: [ChatMessage] = [],
        status: SessionStatus = .idle,
        timeout: Duration? = nil,
        permissionDecider: @escaping PermissionDecider = { _ in .allow },
        runner: AgentRunning = ProcessRunner(),
        promptOptimizer: any PromptOptimizing = PromptOptimizationClient(),
        changeTracker: any WorkspaceChangeTracking = GitWorkspaceChangeTracker(),
        openCodeStreamer: OpenCodeStreaming? = nil,
        acpTransport: ACPTransporting? = nil,
        restoredBackendSessionID: String? = nil,
        restoredBackendSessionModel: String? = nil,
        restoredUsage: SessionUsage? = nil
    ) {
        self.id = id
        self.agent = agent
        self.workingDirectory = workingDirectory
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.interactionMode = interactionMode
        self.command = command
        self.customTitle = customTitle
        self.pinned = pinned
        self.directoryPinned = directoryPinned
        self.resumeSessionID = resumeSessionID
        self.messages = messages
        self.status = status
        self.timeout = timeout
        self.permissionDecider = permissionDecider
        self.runner = runner
        self.promptOptimizer = promptOptimizer
        self.changeTracker = changeTracker
        self.openCodeStreamer = openCodeStreamer
        self.acpTransport = acpTransport
        // ACP：恢复的后端 sessionId 暂存，首轮 ensureACPSession 据此 resume（而非新建）以跨重开续接上下文。
        if agent.resolvedTransport == .acp { self.acpRestoredSessionID = restoredBackendSessionID }
        self.sessionContinuity = SessionContinuity(
            agentKind: agent.kind,
            restoredSessionID: restoredBackendSessionID,
            restoredSessionModel: restoredBackendSessionModel
        )
        self.usage = restoredUsage ?? SessionUsage()
        self.lastChangedPaths = messages.last(where: { $0.kind == .changeReview })?.fileLinks ?? []
        self.lastTurnDiffSummary = messages
            .last(where: { $0.kind == .changeReview && $0.turnDiffSummary != nil })?
            .turnDiffSummary
        // Claude/Codex：启动内置 MCP 服务并注册「展示提问卡片」处理器，让 ask_user 工具能把提问投递到本会话。
        if agent.kind == .claudeCode || agent.kind == .codex {
            AskUserMCPServer.shared.start()
            let sessionKey = id.uuidString
            AskUserBroker.shared.register(sessionID: sessionKey) { [weak self] question in
                guard let self else { return false }
                self.appendMCPQuestion(question)
                return true
            }
        }
    }

    /// MCP `ask_user` 工具触发：把提问插入当前 assistant 时间线，而不是追加到整个对话末尾。
    /// 后续流式文本会继续写在标记之后，因此卡片始终停留在实际调用发生的位置。
    private func appendMCPQuestion(_ question: AskUserQuestion) {
        let activeID = activeRunAssistantIDs.last
        var assistantIndex = activeID.flatMap { id in
            messages.firstIndex { $0.id == id }
        }
        appendQuestionTool(question, assistantIndex: &assistantIndex)
        onPersist?()
    }

    /// 本会话 Claude 的 MCP ask_user 端点（服务器就绪才返回；否则 nil → 不注入，回退内置工具/追加消息）。
    private func claudeMCPEndpoint() -> String? {
        // codex 同样支持 streamable HTTP MCP(mcp_servers.<name>.url),提问卡片两家共用一套服务。
        guard agent.kind == .claudeCode || agent.kind == .codex,
              AskUserMCPServer.injectionEnabled else { return nil }
        return AskUserMCPServer.shared.endpointURL(forSession: id.uuidString)
    }

    /// 运行环境：Claude + MCP 就绪时放宽工具调用超时（用户作答可能较久），其余照旧。
    private func effectiveEnvironment() -> [String: String] {
        var environment = agent.runtimeEnvironment()
        if agent.kind == .claudeCode, AskUserMCPServer.shared.port != nil {
            environment["MCP_TOOL_TIMEOUT"] = "600000" // 10 分钟：阻塞等用户作答
            environment["MCP_TIMEOUT"] = "30000"
        }
        return environment
    }

    public var isRunning: Bool { status == .running }

    /// 标签展示名。回落顺序：自定义标题 → 首条用户消息摘要 → agent 名。
    public var displayTitle: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        if let summary = SessionTitle.summarize(messages.first(where: { $0.role == .user })?.text) {
            return summary
        }
        return agent.name
    }

    /// 改名：空字符串视为清除自定义名（回落到默认推导）。改完落盘。
    public func rename(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        customTitle = trimmed.isEmpty ? nil : trimmed
        onPersist?()
    }

    /// 切换置顶状态并落盘。
    public func togglePinned() {
        pinned.toggle()
        onPersist?()
    }

    public func send(_ prompt: String, attachments: [URL] = []) async {
        guard status != .running else { return }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 运行前权限闸门：normalAgentProcess 直接放行；其余在「当前目录尚未获记住授权」时需用户确认。
        if !isApprovedForCurrentDirectory {
            let request = permissionRequest()
            switch permissionDecider(request) {
            case .allow:
                break
            case .ask:
                pendingPermission = PendingRun(prompt: prompt, attachments: attachments, request: request)
                return
            case .deny:
                messages.append(ChatMessage(role: .system, text: "已拒绝运行 \(agent.name)。"))
                return
            }
        }

        await performSend(prompt: prompt, attachments: attachments)
    }

    /// 批准当前待运行请求并真正执行；remember 为 true 时本会话后续不再询问。
    public func approvePending(remember: Bool) async {
        guard let pending = pendingPermission else { return }
        await approve(pending, remember: remember)
    }

    /// 用显式捕获的待运行请求授权并执行。UI **必须**走这个入口：
    /// confirmationDialog 关闭时会通过 isPresented 绑定**同步**清空 pendingPermission，
    /// 早于按钮动作里异步 Task 的执行；若 Task 再去读 self.pendingPermission 就会读到 nil
    /// 而静默丢弃发送。因此按钮把 actions 闭包参数里的 pending 值直接传进来，不依赖共享可变状态。
    public func approve(_ pending: PendingRun, remember: Bool) async {
        pendingPermission = nil
        if remember { approvedDirectory = workingDirectory }
        await performSend(prompt: pending.prompt, attachments: pending.attachments)
    }

    /// 取消待运行请求。
    public func cancelPending() {
        pendingPermission = nil
    }

    /// 已获授权的发送：跳过逐会话权限闸门直接执行。广播授权弹窗已代表用户对**所有**目标会话的统一许可，
    /// 故对其中本无独立 pending 的会话也走这里——绝不再去设置各自的 `pendingPermission`，
    /// 从根上杜绝「后台标签弹出一个不可见的逐会话确认、导致那条广播一直发不出去」。
    public func sendApproved(
        prompt: String,
        attachments: [URL] = [],
        remember: Bool = false,
        broadcastID: String? = nil
    ) async {
        guard status != .running else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if remember { approvedDirectory = workingDirectory }
        await performSend(prompt: prompt, attachments: attachments, broadcastID: broadcastID)
    }

    /// 触发「开新会话」（/clear）：换上同 agent/目录的新空标签，旧对话留存历史。
    /// 实际换页由 WorkspaceController 注入的回调完成；未注入则不动作。
    public func requestNewChat() {
        onRequestNewChat?()
    }

    /// 用历史转录替换当前聊天记录（恢复某个历史会话时回填）。
    public func loadHistory(_ history: [ChatMessage]) {
        messages = history
        onPersist?()
    }

    /// 「AI 优化」：兼容旧调用点，只返回改写文本；失败详情见 optimizePromptResult(from:)。
    public func optimizedPrompt(from text: String) async -> String? {
        switch await optimizePromptResult(from: text) {
        case .success(let improved): improved
        case .failure: nil
        }
    }

    /// 「AI 优化」：走独立在线优化器，不进聊天、不改 status、不复用当前 agent session。
    public func optimizePromptResult(from text: String) async -> PromptOptimizationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("输入为空") }

        // 发现工作目录里的项目背景文件名放后台线程，避免阻塞主线程。
        // 在线优化只拿文件名作轻量背景，不拿当前聊天历史，也不复用当前 agent。
        let contextDirectory = workingDirectory
        let projectFiles = await Task.detached { ProjectContext.files(in: contextDirectory) }.value

        return await promptOptimizer.optimizePrompt(trimmed, projectFiles: projectFiles.map(\.lastPathComponent))
    }

    private func permissionRequest() -> PermissionRequest {
        PermissionRequest(
            agentName: agent.name,
            command: agent.command,
            workingDirectory: workingDirectory.path,
            risk: Self.risk(for: agent)
        )
    }

    /// 把 agent 家族映射到运行风险：编码类 agent 视为会改文件，pi 视为普通进程，
    /// 自定义 agent 保守地视为会执行 shell 命令。
    static func risk(for agent: AgentConfig) -> PermissionRequest.Risk {
        switch agent.kind {
        case .claudeCode, .codex, .openCode:
            .modifiesFiles
        case .pi:
            .normalAgentProcess
        case .custom:
            .runsShellCommand
        }
    }

    private func performSend(prompt: String, attachments: [URL], broadcastID: String? = nil) async {
        // ACP 传输走独立路径（不经 CLIInvocationBuilder / OutputParser），CLI 路径零改动。
        if agent.resolvedTransport == .acp {
            await performSendACP(prompt: prompt, attachments: attachments, broadcastID: broadcastID)
            return
        }
        let continuity = claudeContinuityStrategy(for: prompt)
        let externalSessionID = agent.kind == .claudeCode
            ? continuity.externalSessionID
            : externalSessionIDForInvocation()
        let title = conversationTitleForInvocation(externalSessionID: externalSessionID)
        let invocationPrompt = promptForInvocation(prompt, continuity: continuity)
        // 先显示用户消息 + 进入运行态（思考指示器即时出现），再捕获运行前基线快照——
        // 快照仍在 agent 真正执行之前完成，但不再让它阻塞「用户消息上屏」。
        messages.append(ChatMessage(role: .user, text: prompt, broadcastID: broadcastID))
        activeRunStartedAt = Date()
        activeRunAssistantIDs = []
        status = .running
        timedOut = false
        stopRequested = false
        let changeBaseline = await changeTracker.snapshot(in: workingDirectory)
        if stopRequested {
            lastChangedPaths = []
            lastTurnDiffSummary = nil
            recordTermination()
            finishActiveRunTiming()
            onPersist?()
            return
        }

        let invocation = CLIInvocationBuilder.build(
            agent: agent,
            prompt: invocationPrompt,
            model: model,
            reasoningEffort: reasoningEffort,
            interactionMode: interactionMode,
            command: command,
            attachments: attachments,
            sessionID: id.uuidString,
            externalSessionID: externalSessionID,
            conversationTitle: title,
            resumeSessionID: resumeSessionID,
            mcpAskEndpoint: claudeMCPEndpoint()
        )

        // opencode：构造流式事件源（注入了 streamer 时）。建立失败会在 consume 内回退非流式并告警。
        let streamingSource = makeOpenCodeStreamingSource(
            prompt: invocationPrompt,
            attachments: attachments,
            externalSessionID: externalSessionID,
            title: title
        )

        // 超时看门狗：到点若仍在运行，标记超时并取消（取消会触发停止信号）。
        let watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, self.isRunning else { return }
                self.timedOut = true
                self.runTask?.cancel()
            }
        } else {
            watchdog = nil
        }

        let firstOutcome = await run(
            invocation,
            suppressResumeFailureError: continuity.externalSessionID != nil,
            streamingSource: streamingSource
        )
        if agent.kind == .claudeCode,
           continuity.externalSessionID != nil,
           firstOutcome.exitCode != 0,
           firstOutcome.isClaudeResumeFailure {
            clearBackendSessionForLocalReplay()
            status = .running
            let fallbackPrompt = promptForInvocation(prompt, continuity: .localTranscriptReplay)
            let fallbackInvocation = CLIInvocationBuilder.build(
                agent: agent,
                prompt: fallbackPrompt,
                model: model,
                reasoningEffort: reasoningEffort,
                interactionMode: interactionMode,
                command: command,
                attachments: attachments,
                sessionID: id.uuidString,
                externalSessionID: nil,
                conversationTitle: title,
                resumeSessionID: resumeSessionID,
                mcpAskEndpoint: claudeMCPEndpoint()
            )
            _ = await run(fallbackInvocation, suppressResumeFailureError: false)
        }
        watchdog?.cancel()
        await appendChangedFileLinks(since: changeBaseline)
        finishActiveRunTiming()
        onPersist?()
    }

    // MARK: - ACP 路径（阶段 1：聊天 / 流式 / 取消）

    private func performSendACP(prompt: String, attachments: [URL], broadcastID: String?) async {
        messages.append(ChatMessage(role: .user, text: prompt, broadcastID: broadcastID))
        activeRunStartedAt = Date()
        activeRunAssistantIDs = []
        status = .running
        timedOut = false
        stopRequested = false

        let changeBaseline = await changeTracker.snapshot(in: workingDirectory)
        if stopRequested {
            lastChangedPaths = []
            lastTurnDiffSummary = nil
            recordTermination()
            finishActiveRunTiming()
            onPersist?()
            return
        }

        let watchdog: Task<Void, Never>?
        if let timeout {
            watchdog = Task {
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, self.isRunning else { return }
                self.timedOut = true
                self.runTask?.cancel()
            }
        } else {
            watchdog = nil
        }

        let task = Task { await self.consumeACP(prompt: prompt, attachments: attachments) }
        runTask = task
        _ = await task.value
        runTask = nil

        watchdog?.cancel()
        await appendChangedFileLinks(since: changeBaseline)
        finishActiveRunTiming()
        onPersist?()
    }

    /// 惰性建立 ACP 会话：首轮 start → initialize → session/new；后续轮复用同一适配器进程与 sessionId。
    private func ensureACPSession() async throws -> ACPTransporting {
        let transport = acpTransport ?? ACPClient(handlers: makeACPHandlers())
        acpTransport = transport
        if acpSessionID == nil {
            try await transport.start(
                command: agent.command,
                args: agent.args,
                environment: agent.runtimeEnvironment(),
                workingDirectory: workingDirectory
            )
            let capabilities = try await transport.initialize()
            acpCapabilities = capabilities
            // 恢复的 sessionId + agent 支持 resume → 续接（不重放历史，本地转录已存）；否则新建。
            // 续接失败（会话不在适配器/不可跨进程恢复，如 -32002 Resource not found——重启或经中转常见）
            // 自动回退新建：本地转录仍在 UI，仅后端不接旧上下文，避免整轮报错卡死。
            let session: ACPNewSession
            if let restored = acpRestoredSessionID, capabilities.supportsResume {
                do {
                    session = try await transport.resumeSession(sessionId: restored, cwd: workingDirectory)
                } catch {
                    Self.streamingLog.warning(
                        "ACP 续接失败（\(error.localizedDescription, privacy: .public)），回退新建会话。"
                    )
                    session = try await transport.newSession(cwd: workingDirectory, mcpServers: [])
                }
            } else {
                session = try await transport.newSession(cwd: workingDirectory, mcpServers: [])
            }
            acpSessionID = session.sessionId
            acpRestoredSessionID = nil
            acpAvailableModes = session.availableModes
            acpConfigOptions = session.configOptions
            acpCurrentModeID = session.currentModeId
        }
        return transport
    }

    /// 设置 ACP 会话配置项（模型/effort 等）。会话尚未建立则忽略。供未来配置项 UI 调用。
    public func setACPConfigOption(configId: String, value: String) async {
        guard let sessionID = acpSessionID, let transport = acpTransport else { return }
        try? await transport.setConfigOption(sessionId: sessionID, configId: configId, value: value)
    }

    /// plan/build → ACP 会话模式（仅当 agent 自报了该模式 id 时才设；否则用默认模式，危险操作经 request_permission 弹卡片）。
    /// build 用 acceptEdits（文件编辑直接放行、其余危险操作仍征询），契合 AgentDeck 的权限把关定位；
    /// 未自报 acceptEdits 时回落默认模式（多半每步征询，由权限卡片承接）。
    private func acpModeID(for mode: InteractionMode) -> String? {
        let candidate: String
        switch mode {
        case .plan: candidate = "plan"
        case .build: candidate = "acceptEdits"
        }
        return acpAvailableModes.contains { $0.id == candidate } ? candidate : nil
    }

    /// 构造 ACPClient 的 agent→client 回调：权限 → 弹卡片等用户作答；fs 读写 → 真实磁盘（我们 initialize 时
    /// advertise 了 fs 能力，agent 会把文件操作回调给我们，必须真正读写，否则 agent 读到空、写入失败）。
    /// internal（非 private）以便单测直接驱动 fs 回调。
    func makeACPHandlers() -> ACPClientHandlers {
        let cwd = workingDirectory
        return ACPClientHandlers(
            onPermission: { [weak self] toolCall, options in
                guard let self else { return options.first(where: { $0.isAllow })?.optionId }
                return await self.requestACPPermission(toolCall: toolCall, options: options)
            },
            onReadTextFile: { path in
                let url = Self.acpResolvePath(path, cwd: cwd)
                return try? String(contentsOf: url, encoding: .utf8)
            },
            onWriteTextFile: { path, content in
                let url = Self.acpResolvePath(path, cwd: cwd)
                do {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    return true
                } catch {
                    return false
                }
            }
        )
    }

    /// 绝对路径直用；相对路径按会话工作目录解析。nonisolated：供 @Sendable fs 回调在 actor 外调用。
    nonisolated private static func acpResolvePath(_ path: String, cwd: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : cwd.appendingPathComponent(path)
    }

    /// 弹出权限卡片并挂起，直到用户点选（返回 optionId）或取消/停止（返回 nil）。
    /// internal（非 private）以便单测直接驱动权限往返。
    func requestACPPermission(toolCall: JSONValue, options: [ACPPermissionOption]) async -> String? {
        // 无可选项（异常）→ 不挂起，按拒绝处理。
        guard !options.isEmpty else { return nil }
        // 已有挂起的权限请求（理论上 ACP 串行，不应发生）→ 先放掉旧的，避免续接丢失。
        acpPermissionContinuation?.resume(returning: nil)
        return await withCheckedContinuation { continuation in
            acpPermissionContinuation = continuation
            pendingACPPermission = PendingACPPermission(
                title: ACPEventTranslator.toolSummary(toolCall) ?? "工具调用",
                options: options
            )
        }
    }

    /// UI 回传用户对权限卡片的选择（optionId；nil = 取消/拒绝）。
    public func resolveACPPermission(optionId: String?) {
        pendingACPPermission = nil
        acpPermissionContinuation?.resume(returning: optionId)
        acpPermissionContinuation = nil
    }

    private func consumeACP(prompt: String, attachments: [URL]) async -> AgentRunOutcome {
        var assistantIndex: Int?
        var producedMessage = false
        do {
            let transport = try await ensureACPSession()
            guard let sessionID = acpSessionID else {
                throw ACPClientError.requestFailed(code: -1, message: "未能建立 ACP 会话")
            }
            if let modeID = acpModeID(for: interactionMode) {
                try? await transport.setMode(sessionId: sessionID, modeId: modeID)
            }

            let content = acpContentBlocks(prompt, attachments: attachments)

            for try await event in transport.prompt(sessionId: sessionID, content: content) {
                if Task.isCancelled { break }
                switch event {
                case .update(let params):
                    let translation = ACPEventTranslator.translate(updateParams: params)
                    if let turn = translation.usage { recordTurnUsage(turn) }
                    if let modeID = translation.currentModeId { acpCurrentModeID = modeID }
                    for parsed in translation.events {
                        apply(parsed, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
                    }
                case .completed:
                    break // stopReason 已由流结束表达；refusal/cancelled 的 UI 细化留待 phase 2
                }
            }

            if Task.isCancelled {
                resolveACPPermission(optionId: nil)
                recordTermination()
                return AgentRunOutcome(exitCode: -2, stderr: "", producedMessage: producedMessage)
            }
            if !producedMessage {
                appendAssistantText("（agent 没有任何输出）", assistantIndex: &assistantIndex)
            }
            status = .idle
            return AgentRunOutcome(exitCode: 0, stderr: "", producedMessage: producedMessage)
        } catch {
            if Task.isCancelled {
                resolveACPPermission(optionId: nil)
                recordTermination()
                return AgentRunOutcome(exitCode: -2, stderr: "", producedMessage: producedMessage)
            }
            messages.append(ChatMessage(role: .error, text: "ACP 运行出错：\(error.localizedDescription)"))
            status = .failed(error.localizedDescription)
            return AgentRunOutcome(exitCode: -1, stderr: error.localizedDescription, producedMessage: producedMessage)
        }
    }

    /// 构造 prompt 的 ContentBlock 数组：文本块 + 每个附件一个 resource_link 块（ACP baseline，所有 agent 必支持）。
    /// agent 经我们的 fs 回调读取链接文件；图片内联块（base64）留作后续增强。
    private func acpContentBlocks(_ prompt: String, attachments: [URL]) -> [JSONValue] {
        var blocks: [JSONValue] = [.object(["type": .string("text"), "text": .string(prompt)])]
        for url in attachments {
            blocks.append(.object([
                "type": .string("resource_link"),
                "uri": .string("file://" + url.path),
                "name": .string(url.lastPathComponent)
            ]))
        }
        return blocks
    }

    /// opencode 流式事件源：建立通道并返回与 `opencode run --format json` 同形态（但**增量**）的事件流。
    /// 建立失败抛错 → consume 回退非流式。
    typealias OpenCodeStreamSource = @Sendable () async throws -> AsyncThrowingStream<ProcessStreamEvent, Error>

    private func run(
        _ invocation: CLIInvocation,
        suppressResumeFailureError: Bool,
        streamingSource: OpenCodeStreamSource? = nil
    ) async -> AgentRunOutcome {
        let task = Task {
            await self.consume(
                invocation: invocation,
                suppressResumeFailureError: suppressResumeFailureError,
                streamingSource: streamingSource
            )
        }
        runTask = task
        let outcome = await task.value
        runTask = nil
        return outcome
    }

    /// 仅 .openCode 且注入了 streamer 时返回非 nil；否则走原有非流式路径。
    private func makeOpenCodeStreamingSource(
        prompt: String,
        attachments: [URL],
        externalSessionID: String?,
        title: String?
    ) -> OpenCodeStreamSource? {
        guard agent.kind == .openCode, let streamer = openCodeStreamer else { return nil }
        // plan 模式走 opencode 原生 plan agent（工具级禁用所有编辑工具，硬只读），而非注入提示词。
        // sessionCreateBody 仍 deny plan_enter/plan_exit：模型想切回 build 改文件会被自动拒绝、不挂起。
        let request = OpenCodeStreamRequest(
            executable: agent.command,
            environment: agent.runtimeEnvironment(),
            workingDirectory: workingDirectory,
            prompt: prompt,
            model: model,
            variant: Self.openCodeVariant(reasoningEffort),
            attachments: attachments,
            continueSessionID: externalSessionID,
            title: title,
            thinking: agent.outputMode == .jsonLines,
            stopSignal: agent.stopSignal,
            agent: interactionMode == .plan ? "plan" : nil
        )
        return { try await streamer.stream(request) }
    }

    /// 与 CLIInvocationBuilder.opencode 的 --variant 映射保持一致：low→minimal、high/xhigh/max→high、medium→默认。
    private static func openCodeVariant(_ effort: ReasoningEffort) -> String? {
        switch effort {
        case .low: return "minimal"
        case .medium: return nil
        case .high, .xhigh, .max: return "high"
        }
    }

    private func appendChangedFileLinks(since baseline: WorkspaceChangeSnapshot) async {
        let detected = await changeTracker.changedFiles(in: workingDirectory, since: baseline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let uniquePaths = Array(Set(detected)).sorted()

        // 用「运行前内容快照 → 运行后内容」算本轮精确的逐行 diff（关键修复：未跟踪/已 dirty 文件不再整文件标绿）。
        let summary = await TurnDiffBuilder.build(
            changedPaths: uniquePaths,
            in: workingDirectory,
            since: baseline
        )
        let reviewSummary = summary.isEmpty ? nil : summary
        lastTurnDiffSummary = reviewSummary
        // 有结构化 diff 时以其为准（已剔除「仅 mtime 变、内容没变」的文件）；否则回退检测到的路径清单。
        let paths = summary.isEmpty ? uniquePaths : summary.paths
        lastChangedPaths = paths // 即便为空也更新：清掉上一轮的审核内容。
        guard !paths.isEmpty else { return }

        // 本轮新建/删除了文件：失效工作目录索引，使新文件立即可链接化、审核标签拿到最新清单。
        WorkspaceFileIndex.shared.invalidate(workingDirectory)

        if let assistantIndex = messages.indices.reversed().first(where: { messages[$0].role == .assistant }) {
            messages[assistantIndex].fileLinks = paths
            // 把本轮逐行 diff 也挂到 assistant 消息上：聊天里每个「编辑 X」工具行据此就地展开该文件的 diff。
            messages[assistantIndex].turnDiffSummary = reviewSummary
        }
        let text = (["改动文件："] + paths.map { "- \($0)" }).joined(separator: "\n")
        messages.append(ChatMessage(
            role: .system,
            text: text,
            fileLinks: paths,
            kind: .changeReview,
            turnDiffSummary: reviewSummary
        ))
    }

    /// 停止当前运行：取消消费任务，进而向子进程发送停止信号。
    /// 声明 supportsStop == false 的 agent 不可中途停止，此处空操作（UI 也不显示停止按钮）。
    /// stopSignal == .customCommand 时先 best-effort 执行自定义停止命令（如发优雅关闭指令），
    /// 再取消任务——取消会触发 stream 的 SIGTERM 兜底，确保进程最终退出。
    public func stop() {
        guard isRunning, agent.supportsStop else { return }
        stopRequested = true

        // ACP：向 agent 发 session/cancel（prompt 响应随即以 cancelled 返回，干净收尾），并取消消费任务。
        if agent.resolvedTransport == .acp {
            resolveACPPermission(optionId: nil) // 放掉挂起的权限卡片，避免 agent 永久等待
            if let sessionID = acpSessionID, let transport = acpTransport {
                Task { await transport.cancel(sessionId: sessionID) }
            }
            runTask?.cancel()
            return
        }

        guard let runTask else { return }

        if agent.stopSignal == .customCommand,
           let stopCommand = agent.stopCommand,
           let executable = stopCommand.first {
            let arguments = Array(stopCommand.dropFirst())
            let directory = workingDirectory
            let environment = agent.runtimeEnvironment()
            let runner = self.runner
            Task {
                _ = try? await runner.runOneShot(
                    command: executable,
                    args: arguments,
                    environment: environment,
                    workingDirectory: directory,
                    stdin: nil
                )
            }
        }

        runTask.cancel()
    }

    private func consume(
        invocation: CLIInvocation,
        suppressResumeFailureError: Bool = false,
        streamingSource: OpenCodeStreamSource? = nil
    ) async -> AgentRunOutcome {
        let parser = OutputParser(mode: agent.outputMode)
        var assistantIndex: Int?
        var producedMessage = false
        var stderrBuffer = ""
        var exitCode: Int32 = 0

        // 流式合帧（#2）：stdout 先进缓冲，~80ms 排水一次再 parse+apply。
        // 否则管道每次可读都全量重渲染增长中的 assistant 气泡（markdown 重解析），长输出 CPU 爆高。
        // 全部状态只在 MainActor 上读写；流结束/取消前必须 drainPendingStdout() 同步排空。
        var pendingStdout = ""
        var pendingDrainTask: Task<Void, Never>?
        func drainPendingStdout() {
            guard !pendingStdout.isEmpty else { return }
            let chunk = pendingStdout
            pendingStdout = ""
            for parsed in parser.parse(chunk) {
                apply(parsed, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
            }
        }
        func cancelPendingDrain() {
            pendingDrainTask?.cancel()
            pendingDrainTask = nil
        }

        // 非流式事件源（opencode 流式不可用时的回退 / 其它 agent 的常规路径）。
        func cliEvents() -> AsyncThrowingStream<ProcessStreamEvent, Error> {
            runner.stream(
                command: agent.command,
                args: invocation.arguments,
                environment: effectiveEnvironment(),
                workingDirectory: workingDirectory,
                stdin: invocation.stdin,
                stopSignal: agent.stopSignal
            )
        }

        do {
            let events: AsyncThrowingStream<ProcessStreamEvent, Error>
            if let streamingSource {
                do {
                    events = try await streamingSource()
                } catch {
                    // 约定：流式建立失败 → 回退非流式 `opencode run`，并打明确警告日志。
                    Self.streamingLog.warning(
                        "opencode 流式不可用，已回退到非流式 opencode run：\(error.localizedDescription, privacy: .public)"
                    )
                    events = cliEvents()
                }
            } else {
                events = cliEvents()
            }

            for try await event in events {
                switch event {
                case .stdout(let chunk):
                    captureBackendSessionID(from: chunk)
                    if let turn = usageCapture.consume(chunk) { recordTurnUsage(turn) }
                    pendingStdout += chunk
                    if pendingDrainTask == nil {
                        pendingDrainTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(80))
                            guard !Task.isCancelled else { return }
                            pendingDrainTask = nil
                            drainPendingStdout()
                        }
                    }
                case .stderr(let chunk):
                    stderrBuffer += chunk
                case .exit(let code):
                    exitCode = code
                }
                if Task.isCancelled { break }
            }
            cancelPendingDrain()
            drainPendingStdout()

            if Task.isCancelled {
                recordTermination()
                return AgentRunOutcome(exitCode: -2, stderr: "", producedMessage: producedMessage)
            }

            flushBackendSessionCapture()
            if let turn = usageCapture.flush() { recordTurnUsage(turn) }
            for parsed in parser.flush() {
                apply(parsed, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
            }

            if exitCode == 0 {
                if !producedMessage {
                    // 退出码 0 但无消息输出：回落到 stderr，再不行给占位提示，避免空气泡。
                    let fallback = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "（agent 没有任何输出）"
                        : stderrBuffer
                    appendAssistantText(fallback, assistantIndex: &assistantIndex)
                }
                status = .idle
                return AgentRunOutcome(exitCode: exitCode, stderr: stderrBuffer, producedMessage: producedMessage)
            } else {
                let assistantText = assistantIndex.map { messages[$0].text } ?? ""
                let detail = stderrBuffer.isEmpty ? assistantText : stderrBuffer
                let stderrDetail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                let outcome = AgentRunOutcome(exitCode: exitCode, stderr: stderrBuffer, producedMessage: producedMessage)
                if !(suppressResumeFailureError && outcome.isClaudeResumeFailure) {
                    messages.append(ChatMessage(
                        role: .error,
                        text: stderrDetail.isEmpty
                            ? "运行失败（退出码 \(exitCode)）"
                            : "运行失败（退出码 \(exitCode)）：\n\(stderrDetail)"
                    ))
                }
                status = .failed("Exited with code \(exitCode): \(detail)")
                return outcome
            }
        } catch {
            // 异常路径同样先排空合帧缓冲——否则挂着的 80ms 定时器会在 run 结束后迟到落消息。
            cancelPendingDrain()
            drainPendingStdout()
            if Task.isCancelled {
                recordTermination()
                return AgentRunOutcome(exitCode: -2, stderr: "", producedMessage: producedMessage)
            } else {
                messages.append(ChatMessage(role: .error, text: "运行出错：\(error.localizedDescription)"))
                status = .failed(error.localizedDescription)
                return AgentRunOutcome(exitCode: -1, stderr: error.localizedDescription, producedMessage: producedMessage)
            }
        }
    }

    /// 运行被取消时记录：超时作为红色错误消息，用户主动停止作为中性提示。
    private func recordTermination() {
        if timedOut {
            messages.append(ChatMessage(role: .error, text: "运行超时，已终止。"))
            status = .failed("运行超时，已终止。")
        } else {
            messages.append(ChatMessage(role: .system, text: "已停止。"))
            status = .failed("已停止。")
        }
    }

    /// 把解析出的事件落到消息列表：message 累加到同一个 assistant 气泡（实现实时追加），
    /// status/error 作为独立 system 气泡。
    private func apply(_ event: OutputEvent, assistantIndex: inout Int?, producedMessage: inout Bool) {
        switch event.kind {
        case .message:
            producedMessage = true
            appendAssistantText(event.text, assistantIndex: &assistantIndex)
        case .tool:
            producedMessage = true
            appendAssistantToolCall(event.text, assistantIndex: &assistantIndex)
        case .status:
            messages.append(ChatMessage(role: .system, text: event.text))
        case .error:
            messages.append(ChatMessage(role: .error, text: event.text))
        case .question:
            appendQuestion(event.text, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
        case .subagent:
            applySubagentEvent(event.text, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
        }
    }

    /// 委派任务事件：派发态 → 在当前 assistant 气泡插入「委派任务」行并记录任务；结果态 → 回填到含该 id 的消息。
    private func applySubagentEvent(_ json: String, assistantIndex: inout Int?, producedMessage: inout Bool) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else { return }

        if object["done"] as? Bool == true {
            let result = object["result"] as? String
            let isError = (object["isError"] as? Bool) == true
            // 已存在该任务（Claude 先发派发态、或 opencode 重复完成快照）：仅回填结果，避免重复行。
            for index in messages.indices {
                if let taskIndex = messages[index].subagentTasks.firstIndex(where: { $0.id == id }) {
                    messages[index].subagentTasks[taskIndex].result = result
                    messages[index].subagentTasks[taskIndex].isError = isError
                    return
                }
            }
            // 找不到既有任务（opencode 只在完成时一次性给出整条 part）：创建完整任务 + 标记，使该行可点击。
            producedMessage = true
            appendSubagentTask(
                SubagentTask(
                    id: id,
                    agentType: (object["agentType"] as? String) ?? "",
                    taskDescription: (object["description"] as? String) ?? "",
                    prompt: (object["prompt"] as? String) ?? "",
                    result: result,
                    isError: isError
                ),
                assistantIndex: &assistantIndex
            )
            return
        }

        producedMessage = true
        appendSubagentTask(
            SubagentTask(
                id: id,
                agentType: (object["agentType"] as? String) ?? "",
                taskDescription: (object["description"] as? String) ?? "",
                prompt: (object["prompt"] as? String) ?? ""
            ),
            assistantIndex: &assistantIndex
        )
    }

    /// 插入「委派任务」内联标记并把任务挂到当前 assistant 消息（派发态与完成态 upsert 共用）。
    private func appendSubagentTask(_ task: SubagentTask, assistantIndex: inout Int?) {
        appendAssistantToolCall(SubagentMarker.encode(id: task.id, label: task.rowLabel), assistantIndex: &assistantIndex)
        if let index = assistantIndex {
            messages[index].subagentTasks.append(task)
        }
    }

    /// AskUserQuestion：把结构化问题插入当前 assistant 的有序内容流。
    /// 有结构化选项 → 原位渲染卡片；无选项（部分 opencode 提问）→ 退化为普通提示。
    private func appendQuestion(_ inputJSON: String, assistantIndex: inout Int?, producedMessage: inout Bool) {
        producedMessage = true
        if let question = AskUserQuestionParser.parse(inputJSON: inputJSON) {
            appendQuestionTool(question, assistantIndex: &assistantIndex)
            return
        }
        let detail = AskUserQuestionParser.fallbackPrompt(inputJSON: inputJSON)
        let lead = detail.map { "Agent 想了解：\($0)" } ?? "Agent 提出了一个交互式问题。"
        messages.append(ChatMessage(
            role: .system,
            text: "\(lead)\n（无法解析为可点选卡片；请直接在下方回复，或点停止。）"
        ))
    }

    /// 回答时间线中的提问工具记录：先原位更新并落盘，再把答案回传给对应 agent。
    public func answerQuestion(
        recordID: UUID,
        question: AskUserQuestion,
        selections: [[String]]
    ) async {
        markQuestion(recordID: recordID, resolution: .answered(selections))
        await deliverQuestionAnswer(question, selections: selections)
    }

    /// 兼容旧版独立 question 消息；新界面调用带 recordID 的重载。
    public func answerQuestion(_ question: AskUserQuestion, selections: [[String]]) async {
        if let recordID = pendingQuestionRecordID(matching: question) {
            await answerQuestion(recordID: recordID, question: question, selections: selections)
            return
        }
        await deliverQuestionAnswer(question, selections: selections)
    }

    private func deliverQuestionAnswer(_ question: AskUserQuestion, selections: [[String]]) async {
        // Claude MCP 阻塞提问：唤醒挂起的 ask_user 工具调用，Claude 在同一进程原地继续。
        if let mcpID = question.mcpRequestID {
            AskUserBroker.shared.resolve(mcpID, .answered(Self.composedAnswerText(question, selections: selections)))
            return
        }
        if let requestID = question.requestID, agent.kind == .openCode, let streamer = openCodeStreamer {
            await streamer.replyToQuestion(
                executable: agent.command, environment: agent.runtimeEnvironment(),
                workingDirectory: workingDirectory, requestID: requestID, answers: selections
            )
            return
        }
        await send(Self.composedAnswerText(question, selections: selections))
    }

    /// 跳过时间线中的提问工具记录：先记为已跳过并落盘，再解除 agent 的等待。
    public func rejectQuestion(recordID: UUID, question: AskUserQuestion) async {
        markQuestion(recordID: recordID, resolution: .skipped)
        await deliverQuestionRejection(question)
    }

    /// 兼容旧版独立 question 消息；新界面调用带 recordID 的重载。
    public func rejectQuestion(_ question: AskUserQuestion) async {
        if let recordID = pendingQuestionRecordID(matching: question) {
            await rejectQuestion(recordID: recordID, question: question)
            return
        }
        await deliverQuestionRejection(question)
    }

    private func deliverQuestionRejection(_ question: AskUserQuestion) async {
        if let mcpID = question.mcpRequestID {
            AskUserBroker.shared.resolve(mcpID, .rejected)
            return
        }
        guard let requestID = question.requestID, agent.kind == .openCode, let streamer = openCodeStreamer else { return }
        await streamer.rejectQuestion(
            executable: agent.command, environment: agent.runtimeEnvironment(),
            workingDirectory: workingDirectory, requestID: requestID
        )
    }

    private func appendQuestionTool(_ question: AskUserQuestion, assistantIndex: inout Int?) {
        let record = QuestionToolRecord(question: question)
        appendAssistantToolCall(QuestionMarker.encode(id: record.id), assistantIndex: &assistantIndex)
        guard let index = assistantIndex else { return }
        messages[index].questionTools.append(record)
    }

    private func markQuestion(recordID: UUID, resolution: QuestionToolRecord.Resolution) {
        for messageIndex in messages.indices {
            guard let recordIndex = messages[messageIndex].questionTools.firstIndex(where: { $0.id == recordID }) else {
                continue
            }
            switch resolution {
            case .pending:
                break
            case .answered(let selections):
                messages[messageIndex].questionTools[recordIndex].answer(selections)
            case .skipped:
                messages[messageIndex].questionTools[recordIndex].skip()
            }
            onPersist?()
            return
        }
    }

    private func pendingQuestionRecordID(matching question: AskUserQuestion) -> UUID? {
        for message in messages.reversed() {
            if let record = message.questionTools.last(where: {
                $0.isPending && questionsReferToSameRequest($0.question, question)
            }) {
                return record.id
            }
        }
        return nil
    }

    private func questionsReferToSameRequest(_ lhs: AskUserQuestion, _ rhs: AskUserQuestion) -> Bool {
        if let left = lhs.mcpRequestID, let right = rhs.mcpRequestID {
            return left == right
        }
        if let left = lhs.requestID, let right = rhs.requestID {
            return left == right
        }
        return lhs == rhs
    }

    /// 把各题选择拼成发给 Claude 的回答文本（保留题序）。
    static func composedAnswerText(_ question: AskUserQuestion, selections: [[String]]) -> String {
        let lines = zip(question.questions, selections).map { item, labels in
            "「\(item.title)」：\(labels.joined(separator: "、"))"
        }
        if lines.count == 1 { return lines.first ?? "" }
        return (["我的选择："] + lines.map { "- \($0)" }).joined(separator: "\n")
    }

    private func appendAssistantText(_ text: String, assistantIndex: inout Int?) {
        guard !text.isEmpty else { return }
        if let index = assistantIndex {
            registerAssistantRunTiming(at: index)
            messages[index].text += text
        } else {
            messages.append(ChatMessage(role: .assistant, text: text))
            assistantIndex = messages.count - 1
            registerAssistantRunTiming(at: messages.count - 1)
        }
    }

    /// 工具调用以内联标记追加进当前 assistant 气泡的**文本流**，保持与正文的时间顺序
    /// （展示层据标记把「读取 / 编辑 / 运行 …」状态行穿插渲染在输出中间，见 ToolActivity / MessagePresentation）。
    private func appendAssistantToolCall(_ text: String, assistantIndex: inout Int?) {
        guard !text.isEmpty else { return }
        let marker = ToolActivity.marker(text)
        if let index = assistantIndex {
            registerAssistantRunTiming(at: index)
            messages[index].text += marker
        } else {
            messages.append(ChatMessage(role: .assistant, text: marker))
            assistantIndex = messages.count - 1
            registerAssistantRunTiming(at: messages.count - 1)
        }
    }

    private func registerAssistantRunTiming(at index: Int) {
        guard let startedAt = activeRunStartedAt, messages.indices.contains(index) else { return }
        if messages[index].runStartedAt == nil {
            messages[index].runStartedAt = startedAt
        }
        let id = messages[index].id
        if !activeRunAssistantIDs.contains(id) {
            activeRunAssistantIDs.append(id)
        }
    }

    private func finishActiveRunTiming() {
        guard let startedAt = activeRunStartedAt else { return }
        let endedAt = Date()
        let ids = Set(activeRunAssistantIDs)
        for index in messages.indices where ids.contains(messages[index].id) {
            if messages[index].runStartedAt == nil {
                messages[index].runStartedAt = startedAt
            }
            messages[index].runEndedAt = endedAt
        }
        activeRunStartedAt = nil
        activeRunAssistantIDs = []
    }

    // 连续性逻辑（策略/回放转录/会话 id 失效）已抽到 SessionContinuity.swift（#25 第一步），
    // 此处仅保留绑定会话上下文（model/command/messages）的薄转发。

    private func externalSessionIDForInvocation() -> String? {
        sessionContinuity.externalSessionIDForInvocation(modelKey: currentBackendModelKey)
    }

    private func conversationTitleForInvocation(externalSessionID: String?) -> String? {
        sessionContinuity.conversationTitle(externalSessionID: externalSessionID, command: command, sessionUUID: id)
    }

    private func claudeContinuityStrategy(for prompt: String) -> ClaudeContinuityStrategy {
        sessionContinuity.claudeStrategy(
            for: prompt,
            command: command,
            modelKey: currentBackendModelKey,
            messages: messages
        )
    }

    private func promptForInvocation(_ prompt: String, continuity: ClaudeContinuityStrategy) -> String {
        SessionContinuity.promptForInvocation(
            prompt,
            strategy: continuity,
            agentKind: agent.kind,
            command: command,
            messages: messages
        )
    }

    private func clearBackendSessionForLocalReplay() {
        sessionContinuity.clearBackendSessionForLocalReplay(modelKey: currentBackendModelKey)
    }

    /// 用户在 /model 选择器改选模型：更新选择并清掉上一次解析到的具体版本，
    /// 避免芯片仍显示上一个模型的版本——下一轮运行会重新捕获。
    public func setSelectedModel(_ newModel: String) {
        model = newModel
        sessionContinuity.clearResolvedModel()
    }

    private var currentBackendModelKey: String { SessionContinuity.modelKey(model) }

    private func captureBackendSessionID(from chunk: String) {
        sessionContinuity.captureBackendSessionID(from: chunk, modelKey: currentBackendModelKey)
    }

    /// 记一轮用量：CLI 报不出费用（第三方/国产模型 total_cost_usd=0）时，
    /// 按用户计价表（model-pricing.json）用真实 token 数本地补算（#28）。
    private func recordTurnUsage(_ raw: TurnUsage) {
        var turn = raw
        if turn.costUSD == 0,
           let rule = ModelPricing.rule(for: resolvedModel ?? model, in: ModelPricing.loadRules()) {
            turn.costUSD = ModelPricing.cost(of: turn, rule: rule)
            turn.costCurrency = rule.currency
        }
        usage.add(turn)
    }

    private func flushBackendSessionCapture() {
        sessionContinuity.flushBackendSessionCapture(modelKey: currentBackendModelKey)
    }
}
