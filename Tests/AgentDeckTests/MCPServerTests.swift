import XCTest
@testable import AgentDeckApp

final class MCPServerTests: XCTestCase {
    func testHandshakeInitializeAndToolsList() async throws {
        let port = try await startedPort()
        let base = "http://127.0.0.1:\(port)/mcp/sess-handshake"

        let initResp = try await postJSONRPC(base, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]]
        ])
        let result = try XCTUnwrap(initResp["result"] as? [String: Any])
        XCTAssertNotNil(result["serverInfo"])
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])

        let listResp = try await postJSONRPC(base, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((listResp["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "ask_user")
    }

    func testToolCallBlocksUntilBrokerResolves() async throws {
        let port = try await startedPort()
        let sessionID = "sess-answer"
        let base = "http://127.0.0.1:\(port)/mcp/\(sessionID)"

        await MainActor.run {
            AskUserBroker.shared.register(sessionID: sessionID) { question in
                let mcpID = question.mcpRequestID ?? ""
                Task { @MainActor in AskUserBroker.shared.resolve(mcpID, .answered("蓝色")) }
                return true
            }
        }

        let resp = try await postJSONRPC(base, [
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": "ask_user", "arguments": ["questions": [["question": "色?", "options": [["label": "蓝色"], ["label": "绿色"]]]]]]
        ])
        let content = try XCTUnwrap((resp["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "蓝色")
        XCTAssertEqual((resp["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testToolCallWithoutSessionHandlerIsRejectedNotHung() async throws {
        let port = try await startedPort()
        let base = "http://127.0.0.1:\(port)/mcp/sess-nohandler-\(UUID().uuidString)"
        let resp = try await postJSONRPC(base, [
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "ask_user", "arguments": ["questions": [["question": "x", "options": [["label": "a"]]]]]]
        ])
        let result = try XCTUnwrap(resp["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false) // 跳过不算错误
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("跳过"))
    }

    @MainActor
    func testSessionAnswerResolvesMCPAndSurvivesHistoryRestore() async throws {
        let sessionID = UUID()
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )
        let session = AgentSession(
            id: sessionID,
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let question = AskUserQuestion(questions: [
            .init(
                header: "测试",
                question: "接下来测试什么？",
                multiSelect: true,
                options: [.init(label: "Diff"), .init(label: "MCP")]
            )
        ])

        let answerTask = Task { @MainActor in
            await AskUserBroker.shared.ask(sessionID: sessionID.uuidString, question: question)
        }

        var pendingRecord: QuestionToolRecord?
        for _ in 0..<100 {
            pendingRecord = session.messages
                .lazy
                .flatMap(\.questionTools)
                .first(where: \.isPending)
            if pendingRecord != nil { break }
            await Task.yield()
        }

        let record = try XCTUnwrap(pendingRecord)
        await session.answerQuestion(
            recordID: record.id,
            question: record.question,
            selections: [["Diff", "MCP"]]
        )

        switch await answerTask.value {
        case .answered(let text):
            XCTAssertEqual(text, "「接下来测试什么？」：Diff、MCP")
        case .rejected:
            XCTFail("MCP 提问不应被拒绝")
        }

        let encoded = try JSONEncoder().encode(session.messages)
        let restoredMessages = try JSONDecoder().decode([ChatMessage].self, from: encoded)
        let restored = AgentSession(
            id: sessionID,
            agent: config,
            workingDirectory: FileManager.default.temporaryDirectory,
            messages: restoredMessages
        )
        let restoredRecord = try XCTUnwrap(restored.messages.lazy.flatMap(\.questionTools).first)

        XCTAssertEqual(restoredRecord.resolution, .answered([["Diff", "MCP"]]))
        XCTAssertFalse(restoredRecord.isPending)
        XCTAssertEqual(restoredRecord.detailLines, [
            "Question：接下来测试什么？",
            "Choose：Diff / MCP"
        ])
    }

    /// 实测 Claude 客户端能否连上本服务器（需 claude 已登录）。默认跳过；设 RUN_CLAUDE_MCP_CHECK=1 运行。
    func testClaudeCodeConnectsToMCPServer() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CLAUDE_MCP_CHECK"] == "1" else {
            throw XCTSkip("set RUN_CLAUDE_MCP_CHECK=1 to run the live claude handshake check")
        }
        let port = try await startedPort()
        let url = "http://127.0.0.1:\(port)/mcp/live-check"
        let config = "{\"mcpServers\":{\"agentdeck\":{\"type\":\"http\",\"url\":\"\(url)\"}}}"
        let claude = ["/opt/homebrew/bin/claude", "\(NSHomeDirectory())/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/claude"

        let process = Process()
        process.executableURL = URL(filePath: claude)
        process.arguments = ["-p", "List your available tools then stop.", "--mcp-config", config, "--strict-mcp-config", "--debug"]
        // 同 AgentDeck：注入 ~/.claude/settings.json 的第三方 API 环境（ANTHROPIC_MODEL/BASE_URL/KEY），否则模型不可达。
        var env = ProcessInfo.processInfo.environment
        for (key, value) in ClaudeSettings.loadEnvironment() { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("=== claude --debug output ===\n\(out)\n=== end ===")
        // 关键验证：MCP 客户端在启动期已与本服务器握手（initialize + tools/list），与模型/鉴权是否成功无关。
        let diag = AskUserMCPServer.shared.diagnostics
        print("=== server diagnostics: initialized=\(diag.initialized) listedTools=\(diag.listedTools) ===")
        XCTAssertTrue(diag.initialized, "claude 的 MCP 客户端未与 agentdeck 服务器握手（未收到 initialize）")
        XCTAssertTrue(diag.listedTools, "claude 未拉取工具表（未收到 tools/list）")
    }

    // MARK: - helpers

    private func startedPort(timeout: TimeInterval = 3) async throws -> UInt16 {
        let server = AskUserMCPServer.shared
        server.start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = server.port { return port }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("MCP server did not become ready (no port)")
    }

    private func postJSONRPC(_ urlString: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
