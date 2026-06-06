import Foundation
import Observation

public enum ConversationReopenResult: Equatable, Sendable {
    case focusedExisting
    case restored
    case unavailable
}

@MainActor
@Observable
public final class WorkspaceController {
    public private(set) var registry: AgentRegistry
    public var sessions: [AgentSession]
    public var focusedSessionID: AgentSession.ID?
    public var multiAgentMode: Bool
    public var registryMessage: String?

    /// 当前工作区目录。前缀策略为 .workspace 的 agent 会在此目录运行。
    public private(set) var workspaceDirectory: URL

    private let store: SessionStore?
    private let conversationStore: ConversationStore
    /// opencode 流式通道，注入给每个会话；生产由无参 init 注入真实客户端，测试默认 nil（走非流式）。
    private let openCodeStreamer: OpenCodeStreaming?
    /// 被用户从「最近」移除的会话 id：仅隐藏出 Recent，转录仍在历史检索可找回。持久化于快照。
    private var dismissedRecentIDs: Set<String>

    /// 左栏展示用顺序：置顶项在前，组内保持插入顺序（不改动底层 sessions 顺序/快照）。
    public var orderedSessions: [AgentSession] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.pinned != rhs.element.pinned { return lhs.element.pinned }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public init(
        registry: AgentRegistry,
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        initialPaneCount: Int = 1,
        store: SessionStore? = nil,
        restoreAgentIDs: [String]? = nil,
        restoreSessions: [SessionSnapshot]? = nil,
        restoreDismissedRecents: [String]? = nil,
        conversationStore: ConversationStore = ConversationStore(),
        openCodeStreamer: OpenCodeStreaming? = nil
    ) {
        self.registry = registry
        self.workspaceDirectory = workingDirectory
        self.multiAgentMode = false
        self.store = store
        self.conversationStore = conversationStore
        self.openCodeStreamer = openCodeStreamer
        self.dismissedRecentIDs = Set(restoreDismissedRecents ?? [])
        // 在两段式初始化的第一阶段无法用 self.openCodeStreamer，用局部值注入到本次构造的会话里。
        let streamer = openCodeStreamer

        let workspace = workingDirectory
        let initialSessions: [AgentSession]
        var focusID: AgentSession.ID?

        if let restoreSessions, !restoreSessions.isEmpty {
            // 按会话快照重建：保留原 id（以便载回聊天记录）、目录、模型、推理强度、交互模式、命令模式、后端会话 ID。
            let restored = restoreSessions.compactMap { snap -> AgentSession? in
                guard let agent = registry.agents.first(where: { $0.id == snap.agentID }) else { return nil }
                let directory = snap.workingDirectory.map { URL(filePath: $0) }
                    ?? Self.resolveDirectory(for: agent, workspace: workspace)
                let reasoningEffort = snap.reasoningEffort.flatMap { ReasoningEffort(rawValue: $0) } ?? .medium
                let interactionMode = InteractionMode.restore(snap.interactionMode)
                let command = snap.command.flatMap { AgentCommand(rawValue: $0) } ?? .new
                return AgentSession(
                    id: UUID(uuidString: snap.id) ?? UUID(),
                    agent: agent,
                    workingDirectory: directory,
                    model: snap.model ?? "default",
                    reasoningEffort: reasoningEffort,
                    interactionMode: interactionMode,
                    command: command,
                    customTitle: snap.customTitle,
                    pinned: snap.pinned ?? false,
                    messages: conversationStore.load(id: snap.id)?.messages ?? [],
                    permissionDecider: Self.makePermissionDecider(),
                    openCodeStreamer: streamer,
                    restoredBackendSessionID: snap.backendSessionID,
                    restoredBackendSessionModel: snap.backendSessionModel
                )
            }
            initialSessions = restored
            if let focused = restoreSessions.first(where: { $0.focused == true }),
               let match = restored.first(where: { $0.id.uuidString == focused.id }) {
                focusID = match.id
            } else {
                focusID = restored.first?.id
            }
        } else {
            // 回落：按 agent id 恢复，或默认前缀。
            var agentsToOpen = (restoreAgentIDs ?? []).compactMap { id in
                registry.agents.first { $0.id == id }
            }
            if agentsToOpen.isEmpty {
                agentsToOpen = Array(registry.agents.prefix(max(0, min(initialPaneCount, 4))))
            }
            initialSessions = agentsToOpen.map { agent in
                AgentSession(
                    agent: agent,
                    workingDirectory: Self.resolveDirectory(for: agent, workspace: workspace),
                    permissionDecider: Self.makePermissionDecider(),
                    openCodeStreamer: streamer
                )
            }
            focusID = initialSessions.first?.id
        }

        self.sessions = initialSessions
        self.focusedSessionID = focusID
        self.registryMessage = Self.message(for: registry)
        for session in sessions { attach(to: session) }
        refreshRecents()
    }

    /// 从持久化快照恢复工作区（活动标签 + 聊天记录 + 最近工作目录）。
    public convenience init(
        registry: AgentRegistry,
        store: SessionStore,
        openCodeStreamer: OpenCodeStreaming? = nil
    ) {
        let snapshot = (try? store.loadSnapshot()) ?? .default
        let workspace = snapshot.recentWorkspace.map { URL(filePath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.init(
            registry: registry,
            workingDirectory: workspace,
            store: store,
            restoreAgentIDs: snapshot.activeAgentIDs,
            restoreSessions: snapshot.activeSessions,
            restoreDismissedRecents: snapshot.dismissedRecents,
            openCodeStreamer: openCodeStreamer
        )
    }

    /// 切换工作区目录，并同步更新所有沿用 .workspace 策略的现有会话。
    public func setWorkspaceDirectory(_ url: URL) {
        workspaceDirectory = url
        for session in sessions where session.agent.workingDirectoryPolicy == .workspace {
            session.workingDirectory = url
        }
        persist()
    }

    /// 把当前工作区状态写入持久化存储（无 store 时为空操作）。
    private func persist() {
        guard let store else { return }
        let snapshot = WorkspaceSnapshot(
            layout: WorkspaceLayout(rawValue: max(1, min(sessions.count, 4))) ?? .one,
            activeAgentIDs: sessions.map(\.agent.id),
            activeSessions: sessions.map { session in
                SessionSnapshot(
                    id: session.id.uuidString,
                    agentID: session.agent.id,
                    workingDirectory: session.workingDirectory.path,
                    model: session.model,
                    focused: session.id == focusedSessionID,
                    reasoningEffort: session.reasoningEffort.rawValue,
                    interactionMode: session.interactionMode.rawValue,
                    command: session.command.rawValue,
                    backendSessionID: session.backendSessionID,
                    backendSessionModel: session.backendSessionModel,
                    customTitle: session.customTitle,
                    pinned: session.pinned ? true : nil
                )
            },
            recentWorkspace: workspaceDirectory.path,
            dismissedRecents: dismissedRecentIDs.isEmpty ? nil : Array(dismissedRecentIDs)
        )
        try? store.save(snapshot)
    }

    /// 按 agent 的工作目录策略解析实际目录。
    /// fixedPath 用配置里的 fixedWorkingDirectory（validate 已保证非空）；
    /// perSessionPrompt 在启动/恢复时无从询问，回落工作区——交互添加时由 UI 经
    /// addSession(directoryOverride:) 传入用户选定的目录。
    static func resolveDirectory(for agent: AgentConfig, workspace: URL) -> URL {
        switch agent.workingDirectoryPolicy {
        case .workspace:
            return workspace
        case .home:
            return FileManager.default.homeDirectoryForCurrentUser
        case .fixedPath:
            guard let path = agent.fixedWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return workspace
            }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        case .perSessionPrompt:
            return workspace
        }
    }

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.homeDirectoryForCurrentUser
        let customDirectory = support
            .appending(path: "AgentDeck", directoryHint: .isDirectory)
            .appending(path: "Agents", directoryHint: .isDirectory)

        // load 永不抛错：坏配置已被跳过并记录在 registry.warnings 中。
        // 生产入口：注入真实 opencode 流式客户端（测试走带 registry 的 init，默认 nil → 非流式）。
        self.init(
            registry: AgentRegistry.load(customDirectory: customDirectory),
            store: SessionStore(),
            openCodeStreamer: OpenCodeStreamingClient.shared
        )
    }

    private static func message(for registry: AgentRegistry) -> String? {
        if registry.agents.isEmpty {
            var lines = ["No CLI agents found. Add JSON configs in ~/Library/Application Support/AgentDeck/Agents."]
            lines.append(contentsOf: registry.warnings)
            return lines.joined(separator: "\n")
        }
        return registry.warnings.isEmpty ? nil : registry.warnings.joined(separator: "\n")
    }

    public func addSession(agentID: AgentConfig.ID, directoryOverride: URL? = nil) {
        guard let agent = registry.agents.first(where: { $0.id == agentID }) else { return }

        let directory = directoryOverride ?? Self.resolveDirectory(for: agent, workspace: workspaceDirectory)
        let session = AgentSession(
            agent: agent,
            workingDirectory: directory,
            permissionDecider: Self.makePermissionDecider(),
            openCodeStreamer: openCodeStreamer
        )
        attach(to: session)
        sessions.append(session)
        focusedSessionID = session.id
        persist()
    }

    // MARK: - 会话持久化与搜索

    /// 给会话注入回调：对话变化时把转录落盘（仅非空时）；/clear 时换上新会话。
    private func attach(to session: AgentSession) {
        session.onPersist = { [weak self, weak session] in
            guard let self, let session else { return }
            self.persistConversation(session)
        }
        session.onRequestNewChat = { [weak self, weak session] in
            guard let self, let session else { return }
            self.startNewChat(replacing: session.id)
        }
    }

    /// /clear：把指定标签替换为同 agent / 目录 / 模型设置的新空会话。
    /// 旧对话已按轮落盘（这里再兜底存一次），仍可在「历史检索」找回。
    /// 会话本就为空时不替换——已是干净状态，避免无谓地换 id。
    public func startNewChat(replacing sessionID: AgentSession.ID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let old = sessions[index]
        guard !old.messages.isEmpty else { return }

        persistConversation(old) // 兜底：确保旧对话进了历史。
        let fresh = AgentSession(
            agent: old.agent,
            workingDirectory: old.workingDirectory,
            model: old.model,
            reasoningEffort: old.reasoningEffort,
            interactionMode: old.interactionMode,
            timeout: old.timeout,
            permissionDecider: Self.makePermissionDecider(),
            openCodeStreamer: openCodeStreamer
        )
        attach(to: fresh)
        sessions[index] = fresh
        if focusedSessionID == sessionID { focusedSessionID = fresh.id }
        persist()
        refreshRecents() // 旧会话已离开标签 → 进入 Recent。
    }

    private func persistConversation(_ session: AgentSession) {
        guard !session.messages.isEmpty else { return }
        let conversation = StoredConversation(
            id: session.id.uuidString,
            agentID: session.agent.id,
            agentName: session.agent.name,
            workingDirectory: session.workingDirectory.path,
            messages: session.messages,
            updatedAt: Date(),
            model: session.model,
            reasoningEffort: session.reasoningEffort.rawValue,
            interactionMode: session.interactionMode.rawValue,
            command: session.command.rawValue,
            backendSessionID: session.backendSessionID,
            backendSessionModel: session.backendSessionModel,
            customTitle: session.customTitle,
            pinned: session.pinned ? true : nil
        )
        try? conversationStore.save(conversation)
        persist() // 顺带刷新工作区快照（捕获当前模型/目录），保证重开后状态一致。
    }

    /// 在全部落盘会话里全文搜索。
    public func searchConversations(_ query: String) -> [ConversationHit] {
        ConversationSearch.search(conversationStore.all(), query: query)
    }

    /// 取一段落盘会话（供查看转录）。
    public func conversation(id: String) -> StoredConversation? {
        conversationStore.load(id: id)
    }

    public func canReopenConversation(id: String) -> Bool {
        if sessions.contains(where: { $0.id.uuidString == id }) {
            return true
        }
        guard let stored = conversationStore.load(id: id) else {
            return false
        }
        return registry.agents.contains { $0.id == stored.agentID }
    }

    /// 基于 PermissionBroker 的默认决策闭包：普通进程放行，其余首次需确认。
    private static func makePermissionDecider() -> AgentSession.PermissionDecider {
        let broker = PermissionBroker()
        return { request in broker.defaultDecision(for: request) }
    }

    public func closeSession(id: AgentSession.ID) {
        sessions.removeAll { $0.id == id }
        if focusedSessionID == id {
            focusedSessionID = sessions.first?.id
        }
        persist()
        refreshRecents() // 关掉的标签若有对话 → 进入 Recent。
    }

    public func focusSession(id: AgentSession.ID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        focusedSessionID = id
        persist() // 记住当前焦点标签，重开后恢复到同一个。
    }

    public var focusedSession: AgentSession? {
        guard let focusedSessionID else { return sessions.first }
        return sessions.first { $0.id == focusedSessionID } ?? sessions.first
    }

    /// 「Recent」：已落盘但当前未作为标签打开的会话（含 /clear 归档、关闭的标签），最近在前。
    /// 存于内存、仅在会话归档/恢复时刷新（见 refreshRecents），避免每次渲染读盘。
    public private(set) var recentConversations: [StoredConversation] = []

    /// 重新计算 Recent：取所有落盘会话，排除当前已作为标签打开的、以及用户从最近移除的，最近更新在前。
    private func refreshRecents() {
        let activeIDs = Set(sessions.map(\.id.uuidString))
        recentConversations = conversationStore.all()
            .filter { !activeIDs.contains($0.id) && !dismissedRecentIDs.contains($0.id) }
    }

    /// 从「最近」移除一条（不删转录，仍可经历史检索找回）。
    public func dismissRecent(id: String) {
        dismissedRecentIDs.insert(id)
        persist()
        refreshRecents()
    }

    /// 清空「最近」列表（把当前所有 Recent 标记为已移除；转录均保留）。
    public func clearRecents() {
        dismissedRecentIDs.formUnion(recentConversations.map(\.id))
        persist()
        refreshRecents()
    }

    /// 彻底删除一条会话记录（删转录文件 + 从最近隐藏；若它当前是打开的标签则一并关闭）。
    public func deleteConversation(id: String) {
        sessions.removeAll { $0.id.uuidString == id }
        if focusedSessionID?.uuidString == id { focusedSessionID = sessions.first?.id }
        conversationStore.delete(id: id)
        dismissedRecentIDs.remove(id) // 记录已不存在，无需再记为「已移除」
        persist()
        refreshRecents()
    }

    /// 全部落盘会话（按更新时间倒序），映射成命中项——供历史检索在「无查询」时默认全部展示。
    public func allConversationHits() -> [ConversationHit] {
        conversationStore.all().map { convo in
            ConversationHit(
                id: convo.id,
                agentName: convo.agentName,
                title: convo.title,
                snippet: ConversationSearch.snippet(
                    of: convo.messages.first?.text ?? "",
                    around: ""
                ),
                updatedAt: convo.updatedAt
            )
        }
    }

    // MARK: - 标签管理（改名 / 置顶 / 删除）

    /// 改名当前标签（空字符串视为清除自定义名）。
    public func renameSession(id: AgentSession.ID, to newTitle: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.rename(to: newTitle)
        persist()
    }

    /// 切换标签置顶状态。
    public func togglePinSession(id: AgentSession.ID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.togglePinned()
        persist()
    }

    /// 点击 Recent：把一段历史会话重新打开为标签（沿用其 agent / 目录 / 聊天记录）并接焦点；
    /// 若它已在打开中则直接聚焦；对应 agent 已不存在则忽略。
    @discardableResult
    public func reopenConversation(id: String) -> ConversationReopenResult {
        if let existing = sessions.first(where: { $0.id.uuidString == id }) {
            focusedSessionID = existing.id
            persist()
            return .focusedExisting
        }
        guard let stored = conversationStore.load(id: id),
              let agent = registry.agents.first(where: { $0.id == stored.agentID }) else {
            return .unavailable
        }
        // 与 app 重启恢复（SessionSnapshot）一致地恢复续接状态：模型 / 推理强度 / 交互模式 /
        // 命令模式 / 后端会话 ID——这样重开后发消息仍续接原会话、保留模型上下文。
        let reasoningEffort = stored.reasoningEffort.flatMap { ReasoningEffort(rawValue: $0) } ?? .medium
        let interactionMode = InteractionMode.restore(stored.interactionMode)
        let command = stored.command.flatMap { AgentCommand(rawValue: $0) } ?? .new
        let session = AgentSession(
            id: UUID(uuidString: stored.id) ?? UUID(),
            agent: agent,
            workingDirectory: URL(filePath: stored.workingDirectory),
            model: stored.model ?? "default",
            reasoningEffort: reasoningEffort,
            interactionMode: interactionMode,
            command: command,
            customTitle: stored.customTitle,
            pinned: stored.pinned ?? false,
            messages: stored.messages,
            permissionDecider: Self.makePermissionDecider(),
            openCodeStreamer: openCodeStreamer,
            restoredBackendSessionID: stored.backendSessionID,
            restoredBackendSessionModel: stored.backendSessionModel
        )
        attach(to: session)
        sessions.append(session)
        focusedSessionID = session.id
        dismissedRecentIDs.remove(id) // 重新打开过 → 取消「已从最近移除」标记，关掉后可再次进入最近
        persist()
        refreshRecents()
        return .restored
    }

    // MARK: - 广播（multiAgentMode）

    /// 把同一条原始请求广播到所有打开的会话。广播是用户的显式批量动作，**默认放行**：
    /// 每个会话各起一个 Task 经 `sendApproved` 直接下发（跳过逐会话权限弹窗）——既并行不互相干等，
    /// 也不会在非当前标签上留下不可见的确认弹窗（那正是之前「广播发不出去」的根因）。
    /// 普通单会话发送仍走各自的权限闸门，不受影响。
    public func broadcast(_ prompt: String, attachments: [URL] = []) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sessions.isEmpty else { return }

        for session in sessions {
            Task { await session.sendApproved(prompt: prompt, attachments: attachments) }
        }
    }
}
