import XCTest
@testable import AgentDeckApp

@MainActor
final class WorkspaceControllerTests: XCTestCase {
    func testInteractionModesExposeOnlyPlanAndBuildAndMigrateLegacyValues() {
        XCTAssertEqual(InteractionMode.allCases, [.plan, .build])
        XCTAssertEqual(InteractionMode.restore("plan"), .plan)
        XCTAssertEqual(InteractionMode.restore("build"), .build)
        XCTAssertEqual(InteractionMode.restore("chat"), .build)
        XCTAssertEqual(InteractionMode.restore("auto"), .build)
        XCTAssertEqual(InteractionMode.restore("unknown"), .build)
        XCTAssertEqual(InteractionMode.restore(nil), .build)
    }

    func testRestoredSessionsMigrateLegacyModesToBuild() {
        let snapshots = [
            ("plan", InteractionMode.plan),
            ("build", InteractionMode.build),
            ("chat", InteractionMode.build),
            ("auto", InteractionMode.build),
            ("unknown", InteractionMode.build)
        ].map { stored, _ in
            SessionSnapshot(
                id: UUID().uuidString,
                agentID: "a",
                workingDirectory: "/tmp/workspace",
                model: "default",
                focused: false,
                interactionMode: stored
            )
        }
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/workspace"),
            restoreSessions: snapshots
        )

        XCTAssertEqual(
            controller.sessions.map(\.interactionMode),
            [.plan, .build, .build, .build, .build]
        )
    }

    func testInitialSessionsUseRegistryAgents() {
        let agents = [
            makeAgent(id: "claude-code", name: "Claude Code", command: "/usr/local/bin/claude"),
            makeAgent(id: "codex", name: "Codex", command: "/opt/homebrew/bin/codex")
        ]

        let controller = WorkspaceController(
            registry: AgentRegistry(agents: agents),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(controller.sessions.map(\.agent.id), ["claude-code"])
        XCTAssertEqual(controller.sessions.map(\.agent.command), ["/usr/local/bin/claude"])
        XCTAssertEqual(controller.focusedSession?.agent.id, "claude-code")
        XCTAssertEqual(controller.sessions.map(\.workingDirectory), [URL(filePath: "/tmp/workspace")])
        XCTAssertEqual(controller.focusedSession?.interactionMode, .build)
    }

    func testInitialSessionFallsBackToNoAgentsMessageWhenRegistryIsEmpty() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: []),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(controller.sessions.count, 0)
        XCTAssertEqual(controller.registryMessage, "No CLI agents found. Add JSON configs in ~/Library/Application Support/AgentDeck/Agents.")
    }

    func testAddSessionFocusesSelectedAgentAsCurrentTab() {
        let agents = [
            makeAgent(id: "a", name: "A", command: "/bin/a"),
            makeAgent(id: "b", name: "B", command: "/bin/b"),
            makeAgent(id: "c", name: "C", command: "/bin/c")
        ]
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: agents),
            workingDirectory: URL(filePath: "/tmp/workspace"),
            initialPaneCount: 1
        )

        controller.addSession(agentID: "b")
        controller.addSession(agentID: "c")

        XCTAssertEqual(controller.sessions.map(\.agent.id), ["a", "b", "c"])
        XCTAssertEqual(controller.focusedSession?.agent.id, "c")
    }

    func testFocusSessionChangesCurrentTab() {
        let agents = [
            makeAgent(id: "a", name: "A", command: "/bin/a"),
            makeAgent(id: "b", name: "B", command: "/bin/b"),
            makeAgent(id: "c", name: "C", command: "/bin/c")
        ]
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: agents),
            workingDirectory: URL(filePath: "/tmp/workspace"),
            initialPaneCount: 1
        )

        controller.addSession(agentID: "b")
        controller.addSession(agentID: "c")
        let firstSessionID = controller.sessions[0].id

        controller.focusSession(id: firstSessionID)

        XCTAssertEqual(controller.focusedSession?.agent.id, "a")
    }

    func testCloseSessionRemovesTabAndKeepsAValidFocus() {
        let agents = [
            makeAgent(id: "a", name: "A", command: "/bin/a"),
            makeAgent(id: "b", name: "B", command: "/bin/b"),
            makeAgent(id: "c", name: "C", command: "/bin/c")
        ]
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: agents),
            workingDirectory: URL(filePath: "/tmp/workspace"),
            initialPaneCount: 3
        )
        let middleSessionID = controller.sessions[1].id

        controller.closeSession(id: middleSessionID)

        XCTAssertEqual(controller.sessions.map(\.agent.id), ["a", "c"])
        XCTAssertEqual(controller.focusedSession?.agent.id, "a")
    }

    func testHomePolicyResolvesToHomeDirectory() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "h", name: "Home", command: "/bin/h", policy: .home)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(
            controller.sessions.first?.workingDirectory,
            FileManager.default.homeDirectoryForCurrentUser
        )
    }

    func testFixedPathPolicyResolvesToConfiguredDirectory() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "f", name: "Fixed", command: "/bin/f", policy: .fixedPath, fixedWorkingDirectory: "/tmp/fixed-dir")
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(controller.sessions.first?.workingDirectory.path, "/tmp/fixed-dir")
    }

    func testFixedPathPolicyExpandsTilde() {
        let url = WorkspaceController.resolveDirectory(
            for: makeAgent(id: "f", name: "Fixed", command: "/bin/f", policy: .fixedPath, fixedWorkingDirectory: "~/Projects/demo"),
            workspace: URL(filePath: "/tmp/workspace")
        )

        XCTAssertEqual(url.path, ("~/Projects/demo" as NSString).expandingTildeInPath)
    }

    func testAddSessionUsesDirectoryOverrideForPerSessionPromptAgent() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "p", name: "PerSession", command: "/bin/p", policy: .perSessionPrompt)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )
        // perSessionPrompt 在启动时无从询问，初始会话回落到工作区目录。
        XCTAssertEqual(controller.sessions.first?.workingDirectory, URL(filePath: "/tmp/workspace"))

        // 交互添加时由 UI 传入用户选定目录。
        let chosen = URL(filePath: "/tmp/chosen-session-dir")
        controller.addSession(agentID: "p", directoryOverride: chosen)
        XCTAssertEqual(controller.sessions.last?.workingDirectory, chosen)
    }

    func testSetWorkspaceDirectoryUpdatesWorkspaceSessions() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "w", name: "Workspace", command: "/bin/w", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )

        controller.setWorkspaceDirectory(URL(filePath: "/tmp/other"))

        XCTAssertEqual(controller.workspaceDirectory, URL(filePath: "/tmp/other"))
        XCTAssertEqual(controller.sessions.first?.workingDirectory, URL(filePath: "/tmp/other"))
    }

    func testSetSessionDirectoryPinsTabAndGlobalSwitchSkipsIt() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace),
                makeAgent(id: "b", name: "B", command: "/bin/b", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace"),
            initialPaneCount: 2
        )
        let pinned = controller.sessions[0]
        let follower = controller.sessions[1]

        controller.setSessionDirectory(id: pinned.id, to: URL(filePath: "/tmp/project-x"))
        XCTAssertTrue(pinned.directoryPinned)
        XCTAssertEqual(pinned.workingDirectory, URL(filePath: "/tmp/project-x"))

        // 切换全局工作区：未锁定标签跟随，锁定标签保持独立目录。
        controller.setWorkspaceDirectory(URL(filePath: "/tmp/other"))
        XCTAssertEqual(pinned.workingDirectory, URL(filePath: "/tmp/project-x"))
        XCTAssertEqual(follower.workingDirectory, URL(filePath: "/tmp/other"))
    }

    func testClearSessionDirectoryPinResumesFollowingWorkspace() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )
        let session = controller.sessions[0]
        controller.setSessionDirectory(id: session.id, to: URL(filePath: "/tmp/project-x"))

        controller.clearSessionDirectoryPin(id: session.id)
        XCTAssertFalse(session.directoryPinned)
        // 解锁后切回当前工作区，并重新跟随后续切换。
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/workspace"))
        controller.setWorkspaceDirectory(URL(filePath: "/tmp/other"))
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/other"))
    }

    // claude 会话按 cwd 存储,换目录 resume 必失败丢上下文(#4 实测)——产生对话后目录锁死。
    func testConversationLocksSessionDirectoryAgainstAllChanges() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )
        let session = controller.sessions[0]
        session.loadHistory([ChatMessage(role: .user, text: "hello")])
        XCTAssertTrue(session.workingDirectoryLocked)

        // ① 右键「设置工作目录…」被拒
        controller.setSessionDirectory(id: session.id, to: URL(filePath: "/tmp/project-x"))
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/workspace"))
        XCTAssertFalse(session.directoryPinned)

        // ② 全局切换不再带走有对话的会话;全局目录本身仍可换(供新标签使用)
        controller.setWorkspaceDirectory(URL(filePath: "/tmp/other"))
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/workspace"))
        XCTAssertEqual(controller.workspaceDirectory, URL(filePath: "/tmp/other"))
    }

    func testConversationLocksPinnedSessionAgainstUnpin() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )
        let session = controller.sessions[0]
        controller.setSessionDirectory(id: session.id, to: URL(filePath: "/tmp/project-x"))
        session.loadHistory([ChatMessage(role: .user, text: "hello")])

        // ③「跟随全局工作区」被拒:保持锁定目录不动
        controller.clearSessionDirectoryPin(id: session.id)
        XCTAssertTrue(session.directoryPinned)
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/project-x"))
        controller.setWorkspaceDirectory(URL(filePath: "/tmp/other"))
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/project-x"))
    }

    func testEmptySessionDirectoryStaysChangeable() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace)
            ]),
            workingDirectory: URL(filePath: "/tmp/workspace")
        )
        let session = controller.sessions[0]
        XCTAssertFalse(session.workingDirectoryLocked)
        controller.setSessionDirectory(id: session.id, to: URL(filePath: "/tmp/project-x"))
        XCTAssertEqual(session.workingDirectory, URL(filePath: "/tmp/project-x"))
    }

    func testPinnedSessionDirectorySurvivesGlobalSwitchAfterRestore() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(baseDirectory: base)
        let registry = AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a", policy: .workspace)])

        let first = WorkspaceController(registry: registry, store: store)
        first.setSessionDirectory(id: first.sessions[0].id, to: URL(filePath: "/tmp/project-x"))

        // 从同一 store 恢复：锁定状态与独立目录都应保留。
        let restored = WorkspaceController(registry: registry, store: store)
        XCTAssertTrue(restored.sessions[0].directoryPinned)
        XCTAssertEqual(restored.sessions[0].workingDirectory, URL(filePath: "/tmp/project-x"))

        // 恢复后切换全局工作区仍不影响锁定标签。
        restored.setWorkspaceDirectory(URL(filePath: "/tmp/other"))
        XCTAssertEqual(restored.sessions[0].workingDirectory, URL(filePath: "/tmp/project-x"))
    }

    func testBroadcastSendsOriginalPromptToAllOpenSessions() async {
        let registry = AgentRegistry(agents: [
            makeAgent(id: "pi-local", name: "Pi", command: "/usr/bin/true")
        ])
        let controller = WorkspaceController(
            registry: registry,
            workingDirectory: URL(filePath: "/tmp/ws"),
            initialPaneCount: 1
        )
        controller.addSession(agentID: "pi-local")

        controller.broadcast("修复广播输入", attachments: [URL(filePath: "/tmp/spec.md")])

        for _ in 0..<50 {
            if controller.sessions.allSatisfy({ $0.messages.first?.text == "修复广播输入" }) {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(controller.sessions.map { $0.messages.first?.role }, [.user, .user])
        XCTAssertEqual(controller.sessions.map { $0.messages.first?.text }, ["修复广播输入", "修复广播输入"])
    }

    func testBroadcastBypassesPermissionAndSendsToAllOpenSessions() async {
        // 广播是显式批量动作，默认放行：即便是会改文件的 claude/codex，也不弹聚合授权框、
        // 不在任何会话留下 pendingPermission，直接发到所有打开会话。
        let registry = AgentRegistry(agents: [
            makeAgent(id: "claude-code", name: "Claude Code", command: "/usr/bin/true"),
            makeAgent(id: "codex", name: "Codex", command: "/usr/bin/true")
        ])
        let controller = WorkspaceController(
            registry: registry,
            workingDirectory: URL(filePath: "/tmp/ws"),
            initialPaneCount: 2
        )

        controller.broadcast("广播默认通过", attachments: [URL(filePath: "/tmp/spec.md")])

        for _ in 0..<100 {
            if controller.sessions.allSatisfy({ $0.messages.first?.text == "广播默认通过" }) { break }
            await Task.yield()
        }

        XCTAssertEqual(controller.sessions.map { $0.messages.first?.role }, [.user, .user])
        XCTAssertEqual(controller.sessions.map { $0.messages.first?.text }, ["广播默认通过", "广播默认通过"])
        XCTAssertTrue(controller.sessions.allSatisfy { $0.pendingPermission == nil })
    }

    func testWorkspacePersistsAndRestoresSessionsAndDirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(baseDirectory: base)
        let registry = AgentRegistry(agents: [
            makeAgent(id: "a", name: "A", command: "/bin/a"),
            makeAgent(id: "b", name: "B", command: "/bin/b")
        ])

        // 首个控制器：无快照→默认打开 a，再加 b，并切换工作目录（每步都会持久化）。
        let first = WorkspaceController(registry: registry, store: store)
        first.addSession(agentID: "b")
        first.setWorkspaceDirectory(URL(filePath: "/tmp/restored"))

        // 第二个控制器：从同一 store 恢复。
        let restored = WorkspaceController(registry: registry, store: store)

        XCTAssertEqual(restored.sessions.map(\.agent.id), ["a", "b"])
        XCTAssertEqual(restored.workspaceDirectory, URL(filePath: "/tmp/restored"))
        XCTAssertEqual(restored.sessions.first?.workingDirectory, URL(filePath: "/tmp/restored"))
    }

    func testRestoresSessionsWithMessagesModelAndDirectoryAndFocus() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: convoDir)
        }
        let store = SessionStore(baseDirectory: base)
        let conversations = ConversationStore(directory: convoDir)
        let registry = AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")])

        // 第一个控制器：默认打开 'a'；设模型、存一段聊天、切目录（触发持久化）。
        let first = WorkspaceController(registry: registry, store: store, conversationStore: conversations)
        let sessionID = first.sessions.first!.id.uuidString
        first.sessions.first!.model = "sonnet"
        try conversations.save(StoredConversation(
            id: sessionID, agentID: "a", agentName: "A", workingDirectory: "/x",
            messages: [ChatMessage(role: .user, text: "hi"), ChatMessage(role: .assistant, text: "yo")],
            updatedAt: Date()
        ))
        first.setWorkspaceDirectory(URL(filePath: "/tmp/proj"))

        // 第二个控制器：从同一 store + conversations 恢复。
        let snapshot = try store.loadSnapshot()
        let restored = WorkspaceController(
            registry: registry,
            workingDirectory: URL(filePath: "/tmp/proj"),
            store: store,
            restoreSessions: snapshot.activeSessions,
            conversationStore: conversations
        )

        XCTAssertEqual(restored.sessions.map(\.id.uuidString), [sessionID]) // 同一 session id
        XCTAssertEqual(restored.sessions.first?.model, "sonnet")
        XCTAssertEqual(restored.sessions.first?.messages.map(\.text), ["hi", "yo"]) // 聊天记录载回
        XCTAssertEqual(restored.sessions.first?.workingDirectory.path, "/tmp/proj")
        XCTAssertEqual(restored.focusedSessionID?.uuidString, sessionID) // 焦点恢复
    }

    func testStartNewChatReplacesTabWithFreshSessionAndKeepsOldInHistory() throws {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: convoDir) }
        let conversations = ConversationStore(directory: convoDir)
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )

        let old = controller.sessions.first!
        let oldID = old.id
        old.model = "sonnet"
        old.interactionMode = .plan
        // loadHistory 触发 onPersist → 旧对话落盘到历史。
        old.loadHistory([ChatMessage(role: .user, text: "remember me"), ChatMessage(role: .assistant, text: "ok")])

        controller.startNewChat(replacing: oldID)

        // 标签被替换为新空会话：新 id、同 agent / 模型 / 模式、无消息、获得焦点。
        XCTAssertEqual(controller.sessions.count, 1)
        let fresh = controller.sessions.first!
        XCTAssertNotEqual(fresh.id, oldID)
        XCTAssertEqual(fresh.agent.id, "a")
        XCTAssertEqual(fresh.model, "sonnet")
        XCTAssertEqual(fresh.interactionMode, .plan)
        XCTAssertTrue(fresh.messages.isEmpty)
        XCTAssertEqual(controller.focusedSessionID, fresh.id)

        // 旧对话进入 Recent（不再只在历史检索里），可按 id 取回。
        XCTAssertEqual(controller.recentConversations.map(\.id), [oldID.uuidString])
        XCTAssertEqual(controller.conversation(id: oldID.uuidString)?.messages.map(\.text), ["remember me", "ok"])
    }

    func testReopenConversationFromRecentRestoresItAsActiveTab() throws {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: convoDir) }
        let conversations = ConversationStore(directory: convoDir)
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )

        let oldID = controller.sessions.first!.id
        controller.sessions.first!.loadHistory([ChatMessage(role: .user, text: "keep going")])
        controller.startNewChat(replacing: oldID)
        XCTAssertEqual(controller.recentConversations.map(\.id), [oldID.uuidString]) // 已在 Recent

        let result = controller.reopenConversation(id: oldID.uuidString)

        // 重新成为活动标签：同 id、载回聊天记录、接焦点，并移出 Recent。
        XCTAssertEqual(result, .restored)
        XCTAssertTrue(controller.canReopenConversation(id: oldID.uuidString))
        XCTAssertTrue(controller.sessions.contains { $0.id == oldID })
        XCTAssertEqual(controller.focusedSessionID, oldID)
        XCTAssertEqual(controller.sessions.first { $0.id == oldID }?.messages.map(\.text), ["keep going"])
        XCTAssertFalse(controller.recentConversations.contains { $0.id == oldID.uuidString })
    }

    func testReopenConversationAlreadyOpenOnlyFocusesExistingSession() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a"),
                makeAgent(id: "b", name: "B", command: "/bin/b")
            ]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            initialPaneCount: 2
        )
        let first = controller.sessions[0]
        controller.focusSession(id: controller.sessions[1].id)

        let result = controller.reopenConversation(id: first.id.uuidString)

        XCTAssertEqual(result, .focusedExisting)
        XCTAssertEqual(controller.focusedSessionID, first.id)
        XCTAssertEqual(controller.sessions.count, 2)
        XCTAssertTrue(controller.canReopenConversation(id: first.id.uuidString))
    }

    func testReopenConversationReportsUnavailableWhenStoredAgentIsMissing() throws {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: convoDir) }
        let conversations = ConversationStore(directory: convoDir)
        let conversationID = UUID().uuidString
        try conversations.save(StoredConversation(
            id: conversationID,
            agentID: "removed-agent",
            agentName: "Removed Agent",
            workingDirectory: "/tmp/ws",
            messages: [ChatMessage(role: .user, text: "restore me")],
            updatedAt: Date()
        ))
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )

        XCTAssertFalse(controller.canReopenConversation(id: conversationID))
        XCTAssertEqual(controller.reopenConversation(id: conversationID), .unavailable)
        XCTAssertFalse(controller.sessions.contains { $0.id.uuidString == conversationID })
    }

    func testReopenConversationRestoresBackendSessionAndContinuityState() throws {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: convoDir) }
        let conversations = ConversationStore(directory: convoDir)
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )

        // 模拟「之前用过、已关闭」的会话：带后端会话 id / 命令模式 / 模型等续接状态落盘。
        let convoID = UUID().uuidString
        try conversations.save(StoredConversation(
            id: convoID,
            agentID: "a",
            agentName: "A",
            workingDirectory: "/tmp/ws",
            messages: [ChatMessage(role: .user, text: "hi")],
            updatedAt: Date(),
            model: "prov/m1",
            reasoningEffort: "high",
            interactionMode: "plan",
            command: "continueLast",
            backendSessionID: "backend-123",
            backendSessionModel: "prov/m1"
        ))

        controller.reopenConversation(id: convoID)

        // 重开后续接状态完整恢复（与 app 重启恢复一致），故再发消息能续接原会话。
        let session = controller.sessions.first { $0.id.uuidString == convoID }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.backendSessionID, "backend-123")
        XCTAssertEqual(session?.backendSessionModel, "prov/m1")
        XCTAssertEqual(session?.command, .continueLast)
        XCTAssertEqual(session?.model, "prov/m1")
        XCTAssertEqual(session?.reasoningEffort, .high)
        XCTAssertEqual(session?.interactionMode, .plan)
        XCTAssertEqual(session?.messages.map(\.text), ["hi"])
    }

    func testStartNewChatOnEmptySessionIsNoOp() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws")
        )
        let original = controller.sessions.first!

        controller.startNewChat(replacing: original.id)

        // 空会话已是干净状态，不换 id。
        XCTAssertEqual(controller.sessions.map(\.id), [original.id])
    }

    // MARK: - 最近：可移除（不删历史） / 清空 / 重开后取消移除

    func testDismissRecentHidesFromRecentButHistoryStillFindsIt() throws {
        let (controller, oldID) = makeArchivedConversationController(userText: "alpha topic")

        controller.dismissRecent(id: oldID)

        XCTAssertTrue(controller.recentConversations.isEmpty) // 移出 Recent
        XCTAssertEqual(controller.searchConversations("alpha").map(\.id), [oldID]) // 历史检索仍找得到
        XCTAssertTrue(controller.allConversationHits().contains { $0.id == oldID }) // 全量列表仍含
    }

    func testClearRecentsHidesAllButKeepsHistory() throws {
        let (controller, oldID) = makeArchivedConversationController(userText: "beta topic")

        controller.clearRecents()

        XCTAssertTrue(controller.recentConversations.isEmpty)
        XCTAssertEqual(controller.searchConversations("beta").map(\.id), [oldID])
    }

    func testReopenAfterDismissReentersRecentWhenClosedAgain() throws {
        let (controller, oldID) = makeArchivedConversationController(userText: "gamma topic")
        controller.dismissRecent(id: oldID)
        XCTAssertTrue(controller.recentConversations.isEmpty)

        controller.reopenConversation(id: oldID)            // 重开 → 取消「已移除」标记
        let sessionID = controller.sessions.first { $0.id.uuidString == oldID }!.id
        controller.closeSession(id: sessionID)              // 再关 → 应重新进入 Recent

        XCTAssertTrue(controller.recentConversations.contains { $0.id == oldID })
    }

    func testDismissedRecentsPersistAcrossRestart() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: convoDir)
        }
        let store = SessionStore(baseDirectory: base)
        let conversations = ConversationStore(directory: convoDir)
        let registry = AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")])

        let first = WorkspaceController(registry: registry, store: store, conversationStore: conversations)
        let oldID = first.sessions.first!.id.uuidString
        first.sessions.first!.loadHistory([ChatMessage(role: .user, text: "delta topic")])
        first.startNewChat(replacing: first.sessions.first!.id)
        first.dismissRecent(id: oldID)

        // 重启恢复：从快照载回会话 + 被移除集合（custom conversationStore 需手动传 restore 参数）。
        let snapshot = try store.loadSnapshot()
        let restored = WorkspaceController(
            registry: registry,
            store: store,
            restoreSessions: snapshot.activeSessions,
            restoreDismissedRecents: snapshot.dismissedRecents,
            conversationStore: conversations
        )
        XCTAssertFalse(restored.recentConversations.contains { $0.id == oldID }) // 仍不在 Recent
        XCTAssertEqual(restored.searchConversations("delta").map(\.id), [oldID]) // 历史仍找得到
    }

    func testDeleteConversationRemovesRecordAndTab() throws {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: convoDir) }
        let conversations = ConversationStore(directory: convoDir)
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )
        let id = controller.sessions.first!.id
        controller.sessions.first!.loadHistory([ChatMessage(role: .user, text: "to delete")])

        controller.deleteConversation(id: id.uuidString)

        XCTAssertFalse(controller.sessions.contains { $0.id == id })          // 标签关闭
        XCTAssertNil(controller.conversation(id: id.uuidString))               // 记录删除
        XCTAssertTrue(controller.searchConversations("to delete").isEmpty)     // 历史也不再有
    }

    // MARK: - 标签：置顶排序 / 改名 / 置顶持久化

    func testOrderedSessionsPutsPinnedFirstPreservingInsertionOrder() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [
                makeAgent(id: "a", name: "A", command: "/bin/a"),
                makeAgent(id: "b", name: "B", command: "/bin/b"),
                makeAgent(id: "c", name: "C", command: "/bin/c")
            ]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            initialPaneCount: 3
        )
        let cID = controller.sessions[2].id

        controller.togglePinSession(id: cID)

        XCTAssertEqual(controller.orderedSessions.map(\.agent.id), ["c", "a", "b"]) // 置顶在前
        XCTAssertEqual(controller.sessions.map(\.agent.id), ["a", "b", "c"])         // 底层顺序不变
    }

    func testRenameAndPinPersistAcrossRestart() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = SessionStore(baseDirectory: base)
        let registry = AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")])

        let first = WorkspaceController(registry: registry, store: store)
        let id = first.sessions.first!.id
        first.renameSession(id: id, to: "My Task")
        first.togglePinSession(id: id)

        let restored = WorkspaceController(registry: registry, store: store)
        XCTAssertEqual(restored.sessions.first?.customTitle, "My Task")
        XCTAssertEqual(restored.sessions.first?.displayTitle, "My Task")
        XCTAssertEqual(restored.sessions.first?.pinned, true)
    }

    func testRenameToBlankClearsCustomTitleAndFallsBackToAgentName() {
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "Claude", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws")
        )
        let id = controller.sessions.first!.id
        controller.renameSession(id: id, to: "Renamed")
        XCTAssertEqual(controller.sessions.first?.displayTitle, "Renamed")

        controller.renameSession(id: id, to: "   ")
        XCTAssertNil(controller.sessions.first?.customTitle)
        XCTAssertEqual(controller.sessions.first?.displayTitle, "Claude") // 回落 agent 名
    }

    /// 造一个「已归档进 Recent」的会话：默认会话存一段聊天 → /clear 换页 → 旧对话进 Recent。返回 (控制器, 旧会话 id 字符串)。
    private func makeArchivedConversationController(userText: String) -> (WorkspaceController, String) {
        let convoDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let conversations = ConversationStore(directory: convoDir)
        let controller = WorkspaceController(
            registry: AgentRegistry(agents: [makeAgent(id: "a", name: "A", command: "/bin/a")]),
            workingDirectory: URL(filePath: "/tmp/ws"),
            conversationStore: conversations
        )
        let oldID = controller.sessions.first!.id
        controller.sessions.first!.loadHistory([ChatMessage(role: .user, text: userText)])
        controller.startNewChat(replacing: oldID)
        return (controller, oldID.uuidString)
    }

    private func makeAgent(
        id: String,
        name: String,
        command: String,
        policy: AgentConfig.WorkingDirectoryPolicy = .workspace,
        fixedWorkingDirectory: String? = nil
    ) -> AgentConfig {
        AgentConfig(
            id: id,
            name: name,
            command: command,
            args: [],
            env: [:],
            workingDirectoryPolicy: policy,
            inputMode: .stdin,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt,
            fixedWorkingDirectory: fixedWorkingDirectory
        )
    }
}
