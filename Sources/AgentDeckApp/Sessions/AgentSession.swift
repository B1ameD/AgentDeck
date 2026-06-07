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
    /// 用户自定义标签名（双击标签 / 右键「改名」设置）；为空时回落到首条消息摘要 / agent 名。
    public var customTitle: String?
    /// 标签是否置顶（左栏排序时置顶项在前）。
    public var pinned: Bool
    /// 选定的「恢复目标」会话 id（Claude 历史会话）；command == .resume 时透传给 --resume <id>。
    public var resumeSessionID: String?
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

    private enum ClaudeContinuityStrategy: Equatable {
        case none
        case nativeResume(String)
        case localTranscriptReplay

        var externalSessionID: String? {
            if case .nativeResume(let id) = self { return id }
            return nil
        }
    }

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
    /// CLI 返回的会话 id，用于继续对话（-s 或 --session-id）。
    public private(set) var backendSessionID: String?
    /// 捕获 backendSessionID 时使用的模型 key，模型切换时清空会话 id。
    public private(set) var backendSessionModel: String?
    /// Claude 输出流里实际解析到的模型 id（system/init 的顶层 `model` 或 assistant 的 `message.model`）。
    /// 选 “opus”/“default” 等别名时运行时才解析为具体版本——据此把 UI 芯片显示成真实版本（如 Opus 4.8）。
    /// 改选模型时清空（见 setSelectedModel），下一轮重新捕获。
    public private(set) var resolvedModel: String?
    private var backendSessionJSONBuffer = ""

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
        resumeSessionID: String? = nil,
        messages: [ChatMessage] = [],
        status: SessionStatus = .idle,
        timeout: Duration? = nil,
        permissionDecider: @escaping PermissionDecider = { _ in .allow },
        runner: AgentRunning = ProcessRunner(),
        promptOptimizer: any PromptOptimizing = PromptOptimizationClient(),
        changeTracker: any WorkspaceChangeTracking = GitWorkspaceChangeTracker(),
        openCodeStreamer: OpenCodeStreaming? = nil,
        restoredBackendSessionID: String? = nil,
        restoredBackendSessionModel: String? = nil
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
        self.resumeSessionID = resumeSessionID
        self.messages = messages
        self.status = status
        self.timeout = timeout
        self.permissionDecider = permissionDecider
        self.runner = runner
        self.promptOptimizer = promptOptimizer
        self.changeTracker = changeTracker
        self.openCodeStreamer = openCodeStreamer
        self.backendSessionID = restoredBackendSessionID
        self.backendSessionModel = restoredBackendSessionModel
        self.lastChangedPaths = messages.last(where: { $0.kind == .changeReview })?.fileLinks ?? []
        self.lastTurnDiffSummary = messages
            .last(where: { $0.kind == .changeReview && $0.turnDiffSummary != nil })?
            .turnDiffSummary
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
    public func sendApproved(prompt: String, attachments: [URL] = [], remember: Bool = false) async {
        guard status != .running else { return }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if remember { approvedDirectory = workingDirectory }
        await performSend(prompt: prompt, attachments: attachments)
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

    private func performSend(prompt: String, attachments: [URL]) async {
        let continuity = claudeContinuityStrategy(for: prompt)
        let externalSessionID = agent.kind == .claudeCode
            ? continuity.externalSessionID
            : externalSessionIDForInvocation()
        let title = conversationTitleForInvocation(externalSessionID: externalSessionID)
        let invocationPrompt = promptForInvocation(prompt, continuity: continuity)
        // 先显示用户消息 + 进入运行态（思考指示器即时出现），再捕获运行前基线快照——
        // 快照仍在 agent 真正执行之前完成，但不再让它阻塞「用户消息上屏」。
        messages.append(ChatMessage(role: .user, text: prompt))
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
            resumeSessionID: resumeSessionID
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
                resumeSessionID: resumeSessionID
            )
            _ = await run(fallbackInvocation, suppressResumeFailureError: false)
        }
        watchdog?.cancel()
        await appendChangedFileLinks(since: changeBaseline)
        finishActiveRunTiming()
        onPersist?()
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
            stopSignal: agent.stopSignal
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

        // 非流式事件源（opencode 流式不可用时的回退 / 其它 agent 的常规路径）。
        func cliEvents() -> AsyncThrowingStream<ProcessStreamEvent, Error> {
            runner.stream(
                command: agent.command,
                args: invocation.arguments,
                environment: agent.runtimeEnvironment(),
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
                    for parsed in parser.parse(chunk) {
                        apply(parsed, assistantIndex: &assistantIndex, producedMessage: &producedMessage)
                    }
                case .stderr(let chunk):
                    stderrBuffer += chunk
                case .exit(let code):
                    exitCode = code
                }
                if Task.isCancelled { break }
            }

            if Task.isCancelled {
                recordTermination()
                return AgentRunOutcome(exitCode: -2, stderr: "", producedMessage: producedMessage)
            }

            flushBackendSessionCapture()
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
            for index in messages.indices {
                if let taskIndex = messages[index].subagentTasks.firstIndex(where: { $0.id == id }) {
                    messages[index].subagentTasks[taskIndex].result = result
                    messages[index].subagentTasks[taskIndex].isError = isError
                    break
                }
            }
            return
        }

        producedMessage = true
        let task = SubagentTask(
            id: id,
            agentType: (object["agentType"] as? String) ?? "",
            taskDescription: (object["description"] as? String) ?? "",
            prompt: (object["prompt"] as? String) ?? ""
        )
        appendAssistantToolCall(SubagentMarker.encode(id: id, label: task.rowLabel), assistantIndex: &assistantIndex)
        if let index = assistantIndex {
            messages[index].subagentTasks.append(task)
        }
    }

    /// AskUserQuestion：把解析出的问题作为独立卡片消息追加，并结束当前 assistant 气泡（问题之后的输出另起一条）。
    /// 有结构化选项 → 渲染可点选卡片；无选项（部分 opencode 提问）→ 退化为一条提示，请用户直接在下方回复。
    private func appendQuestion(_ inputJSON: String, assistantIndex: inout Int?, producedMessage: inout Bool) {
        producedMessage = true
        assistantIndex = nil
        if let question = AskUserQuestionParser.parse(inputJSON: inputJSON) {
            messages.append(ChatMessage(
                role: .system,
                text: question.plainSummary,
                kind: .question,
                question: question
            ))
            return
        }
        let detail = AskUserQuestionParser.fallbackPrompt(inputJSON: inputJSON)
        let lead = detail.map { "Agent 想了解：\($0)" } ?? "Agent 提出了一个交互式问题。"
        messages.append(ChatMessage(
            role: .system,
            text: "\(lead)\n（无法解析为可点选卡片；请直接在下方回复，或点停止。）"
        ))
    }

    /// 回答提问卡片。opencode（有 requestID）→ 经 reply API 回传给运行中的 agent，原地继续；
    /// Claude（无 requestID）→ 把选择拼成下一条消息发出（续接会话）。
    public func answerQuestion(_ question: AskUserQuestion, selections: [[String]]) async {
        if let requestID = question.requestID, agent.kind == .openCode, let streamer = openCodeStreamer {
            await streamer.replyToQuestion(
                executable: agent.command, environment: agent.runtimeEnvironment(),
                workingDirectory: workingDirectory, requestID: requestID, answers: selections
            )
            return
        }
        await send(Self.composedAnswerText(question, selections: selections))
    }

    /// 跳过提问。opencode → reject API（解除阻塞、agent 继续）；Claude → 不发送（用户可自行输入）。
    public func rejectQuestion(_ question: AskUserQuestion) async {
        guard let requestID = question.requestID, agent.kind == .openCode, let streamer = openCodeStreamer else { return }
        await streamer.rejectQuestion(
            executable: agent.command, environment: agent.runtimeEnvironment(),
            workingDirectory: workingDirectory, requestID: requestID
        )
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

    private func externalSessionIDForInvocation() -> String? {
        guard agent.kind == .claudeCode || agent.kind == .openCode || agent.kind == .codex else { return nil }

        let modelKey = currentBackendModelKey
        if backendSessionModel != modelKey {
            backendSessionID = nil
            backendSessionModel = modelKey
            backendSessionJSONBuffer = ""
        }
        return backendSessionID
    }

    private func conversationTitleForInvocation(externalSessionID: String?) -> String? {
        guard agent.kind == .openCode, externalSessionID == nil, command == .new else { return nil }
        return "AgentDeck \(id.uuidString)"
    }

    private func claudeContinuityStrategy(for prompt: String) -> ClaudeContinuityStrategy {
        guard agent.kind == .claudeCode, command == .new else { return .none }

        if let id = externalSessionIDForInvocation()?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return .nativeResume(id)
        }

        if let transcript = localHistoryTranscript(excludingUserPrompt: prompt),
           !transcript.isEmpty {
            return .localTranscriptReplay
        }

        return .none
    }

    private func promptForInvocation(_ prompt: String, continuity: ClaudeContinuityStrategy) -> String {
        guard agent.kind == .claudeCode,
              command == .new,
              continuity == .localTranscriptReplay,
              let transcript = localHistoryTranscript(excludingUserPrompt: prompt),
              !transcript.isEmpty else {
            return prompt
        }

        return """
        <agentdeck_history>
        The following is the local AgentDeck transcript for this chat. Treat it as prior conversation context.

        \(transcript)
        </agentdeck_history>

        Current user request:
        \(prompt)
        """
    }

    private func clearBackendSessionForLocalReplay() {
        backendSessionID = nil
        backendSessionModel = currentBackendModelKey
        backendSessionJSONBuffer = ""
    }

    private func localHistoryTranscript(
        excludingUserPrompt currentPrompt: String,
        maxMessages: Int = 8,
        maxCharacters: Int = 4_000
    ) -> String? {
        let currentUserText = Self.normalizedHistoryText(currentPrompt)
        var seen = Set<String>()
        var chunks: [String] = []

        for message in messages.reversed() {
            guard chunks.count < maxMessages,
                  message.role == .user || message.role == .assistant else { continue }
            let text = Self.sanitizedHistoryText(message.text)
            guard !text.isEmpty else { continue }
            if message.role == .user, Self.normalizedHistoryText(text) == currentUserText {
                continue
            }
            let key = "\(message.role.rawValue):\(Self.normalizedHistoryText(text))"
            guard seen.insert(key).inserted else { continue }
            chunks.append("\(Self.historyRoleLabel(message.role)):\n\(text)")
        }
        chunks.reverse()
        guard !chunks.isEmpty else { return nil }

        let transcript = chunks.joined(separator: "\n\n")
        guard transcript.count > maxCharacters else { return transcript }

        let start = transcript.index(
            transcript.endIndex,
            offsetBy: -maxCharacters,
            limitedBy: transcript.startIndex
        ) ?? transcript.startIndex
        return "[Earlier local transcript truncated]\n" + String(transcript[start...])
    }

    private static func sanitizedHistoryText(_ text: String) -> String {
        // 历史回放给模型时，剥掉思考块与内联工具活动标记（两者都是给人看的 UI 噪声）。
        normalizedHistoryText(ToolActivity.strip(from: strippingThinkingBlocks(from: text)))
    }

    private static func normalizedHistoryText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingThinkingBlocks(from text: String) -> String {
        var remaining = text
        while let start = remaining.range(of: "<think>") {
            guard let end = remaining.range(of: "</think>", range: start.upperBound..<remaining.endIndex) else {
                remaining.removeSubrange(start.lowerBound..<remaining.endIndex)
                break
            }
            remaining.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return remaining
    }

    private static func historyRoleLabel(_ role: ChatMessage.Role) -> String {
        switch role {
        case .user: "user"
        case .assistant: "assistant"
        case .system: "system"
        case .error: "error"
        }
    }

    /// 用户在 /model 选择器改选模型：更新选择并清掉上一次解析到的具体版本，
    /// 避免芯片仍显示上一个模型的版本——下一轮运行会重新捕获。
    public func setSelectedModel(_ newModel: String) {
        model = newModel
        resolvedModel = nil
    }

    private var currentBackendModelKey: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private func captureBackendSessionID(from chunk: String) {
        guard agent.kind == .claudeCode || agent.kind == .openCode || agent.kind == .codex else { return }
        backendSessionJSONBuffer += chunk

        while let newline = backendSessionJSONBuffer.firstIndex(of: "\n") {
            let line = String(backendSessionJSONBuffer[..<newline])
            backendSessionJSONBuffer.removeSubrange(...newline)
            captureBackendSessionID(fromJSONLine: line)
        }
    }

    private func flushBackendSessionCapture() {
        guard !backendSessionJSONBuffer.isEmpty else { return }
        let line = backendSessionJSONBuffer
        backendSessionJSONBuffer = ""
        captureBackendSessionID(fromJSONLine: line)
    }

    private func captureBackendSessionID(fromJSONLine line: String) {
        // 已拿到会话 id、且本轮模型也已解析时，无需再逐行解析 JSON（模型在 init 行即出现、单轮内不变）。
        let needsSession = backendSessionID == nil
        let needsModel = agent.kind == .claudeCode && resolvedModel == nil
        guard needsSession || needsModel,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if needsModel { captureResolvedModel(from: object) }
        guard needsSession else { return }

        switch agent.kind {
        case .claudeCode:
            if let sessionID = (object["session_id"] as? String) ?? (object["sessionID"] as? String),
               !sessionID.isEmpty {
                backendSessionID = sessionID
                backendSessionModel = currentBackendModelKey
            }
        case .openCode:
            if let sessionID = object["sessionID"] as? String, !sessionID.isEmpty {
                backendSessionID = sessionID
                backendSessionModel = currentBackendModelKey
            }
        case .codex:
            if object["type"] as? String == "thread.started",
               let threadID = object["thread_id"] as? String,
               !threadID.isEmpty {
                backendSessionID = threadID
                backendSessionModel = currentBackendModelKey
            }
        case .pi, .custom:
            break
        }
    }

    /// 从 Claude 输出流捕获实际解析到的模型：优先 system/init 的顶层 `model`，回退 assistant 的 `message.model`。
    private func captureResolvedModel(from object: [String: Any]) {
        let candidate = (object["model"] as? String)
            ?? ((object["message"] as? [String: Any])?["model"] as? String)
        guard let candidate, !candidate.isEmpty, candidate != resolvedModel else { return }
        resolvedModel = candidate
    }
}
