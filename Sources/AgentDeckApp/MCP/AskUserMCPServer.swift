import Foundation
import Network
import os

/// 用户对 MCP 提问的回答。
public enum AskUserMCPAnswer: Sendable {
    case answered(String) // 给 Claude 的工具结果文本（用户的选择）
    case rejected         // 用户跳过/拒绝
}

/// 把 MCP 服务器（后台 Network 线程）收到的 `ask_user` 工具调用，桥接到对应会话的卡片 UI，并等用户作答后回传。
/// MainActor：注册/投递/解析都在主线程，避免数据竞争。
@MainActor
public final class AskUserBroker {
    public static let shared = AskUserBroker()

    /// sessionID → 「展示提问卡片」的处理器（返回是否成功展示；会话已销毁则返回 false）。
    private var handlers: [String: (AskUserQuestion) -> Bool] = [:]
    /// mcpRequestID → 等待回答的 continuation。
    private var pending: [String: CheckedContinuation<AskUserMCPAnswer, Never>] = [:]

    public func register(sessionID: String, handler: @escaping (AskUserQuestion) -> Bool) {
        handlers[sessionID] = handler
    }

    public func unregister(sessionID: String) {
        handlers[sessionID] = nil
    }

    /// 服务器调用：把提问投递给会话并等待回答。无对应会话 / 展示失败 → 立即 .rejected（工具不至于永久挂起）。
    func ask(sessionID: String, question: AskUserQuestion) async -> AskUserMCPAnswer {
        guard let handler = handlers[sessionID] else { return .rejected }
        let mcpID = UUID().uuidString
        var tagged = question
        tagged.mcpRequestID = mcpID
        guard handler(tagged) else {
            handlers[sessionID] = nil // 会话已销毁 → 清理处理器
            return .rejected
        }
        return await withCheckedContinuation { continuation in
            pending[mcpID] = continuation
        }
    }

    /// 卡片提交/跳过时调用：唤醒挂起的工具调用，Claude 据此原地继续。
    public func resolve(_ mcpRequestID: String, _ answer: AskUserMCPAnswer) {
        guard let continuation = pending.removeValue(forKey: mcpRequestID) else { return }
        continuation.resume(returning: answer)
    }
}

/// 进程内 MCP（Streamable HTTP）服务器：给 Claude Code 暴露一个**阻塞**的 `ask_user` 工具，
/// 让 Claude（`-p` headless）也能「提问 → 等用户作答 → 原地继续」。
/// 路由：每个会话的 --mcp-config URL 形如 `http://127.0.0.1:<port>/mcp/<sessionID>`，据 path 段把提问投递到对应会话。
public final class AskUserMCPServer: @unchecked Sendable {
    public static let shared = AskUserMCPServer()

    /// 是否向 Claude 注入 MCP ask 标志（--mcp-config 等）。生产恒为真；单测里关掉以断言纯净的 CLI 参数。
    public nonisolated(unsafe) static var injectionEnabled = true

    private let queue = DispatchQueue(label: "AgentDeck.mcp.server")
    private let log = Logger(subsystem: "AgentDeck", category: "mcp")
    private let lock = NSLock()
    private var listener: NWListener?
    private var assignedPort: UInt16?
    private var initializeCount = 0
    private var toolsListCount = 0

    /// 诊断/测试用：MCP 客户端是否已握手（收到过 initialize）、是否拉过工具表。
    public var diagnostics: (initialized: Bool, listedTools: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (initializeCount > 0, toolsListCount > 0)
    }

    /// 懒启动：绑定回环、OS 选端口。已在启动则无操作。失败静默（调用方回退到内置工具/追加消息）。
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: params) else {
            log.warning("MCP 服务器无法创建监听器")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setPort(listener.port?.rawValue)
            case .failed, .cancelled:
                self?.setPort(nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func setPort(_ port: UInt16?) {
        lock.lock(); defer { lock.unlock() }
        assignedPort = port
    }

    public var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return assignedPort
    }

    /// 某会话的 MCP 端点 URL；服务器未就绪则 nil（调用方据此不注入 --mcp-config）。
    public func endpointURL(forSession sessionID: String) -> String? {
        guard let port = port else { return nil }
        return "http://127.0.0.1:\(port)/mcp/\(sessionID)"
    }

    // MARK: - 连接处理

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { connection.cancel(); return }
            defer { connection.cancel() }
            guard let request = await Self.readRequest(connection) else { return }
            let response = await self.respond(to: request)
            await Self.send(response, on: connection)
        }
    }

    /// 处理一个 MCP JSON-RPC 请求，返回完整 HTTP 响应字节。
    private func respond(to request: HTTPRequest) async -> Data {
        guard request.method == "POST" else {
            return Self.httpResponse(status: "405 Method Not Allowed", body: Data())
        }
        let sessionID = Self.sessionID(fromPath: request.path)
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Self.jsonRPCError(id: nil, code: -32_700, message: "Parse error")
        }

        let method = object["method"] as? String
        let id = object["id"] // 可能是 number/string/null（通知无 id）

        switch method {
        case "initialize":
            lock.withLock { initializeCount += 1 }
            let clientVersion = (object["params"] as? [String: Any])?["protocolVersion"] as? String
            let result: [String: Any] = [
                "protocolVersion": clientVersion ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agentdeck", "version": "1.0.0"]
            ]
            return Self.jsonRPCResult(id: id, result: result, extraHeaders: ["Mcp-Session-Id": UUID().uuidString])

        case "notifications/initialized", "notifications/cancelled":
            return Self.httpResponse(status: "202 Accepted", body: Data())

        case "tools/list":
            lock.withLock { toolsListCount += 1 }
            return Self.jsonRPCResult(id: id, result: ["tools": [Self.askUserToolSchema()]])

        case "tools/call":
            return await handleToolCall(id: id, params: object["params"] as? [String: Any], sessionID: sessionID)

        case "ping":
            return Self.jsonRPCResult(id: id, result: [:])

        default:
            // 其它请求（resources/prompts 等）不支持。通知无 id → 202；请求 → method not found。
            if id == nil { return Self.httpResponse(status: "202 Accepted", body: Data()) }
            return Self.jsonRPCError(id: id, code: -32_601, message: "Method not found")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]?, sessionID: String?) async -> Data {
        let name = params?["name"] as? String
        let arguments = (params?["arguments"] as? [String: Any]) ?? [:]
        guard name == "ask_user" else {
            return Self.jsonRPCError(id: id, code: -32_602, message: "Unknown tool")
        }
        guard let sessionID, let question = AskUserQuestionParser.parse(object: arguments) else {
            return Self.toolResult(id: id, text: "无法解析提问参数。", isError: true)
        }
        let answer = await AskUserBroker.shared.ask(sessionID: sessionID, question: question)
        switch answer {
        case .answered(let text):
            return Self.toolResult(id: id, text: text, isError: false)
        case .rejected:
            // 不当作错误：让 Claude 知道用户没选，自行决定后续。
            return Self.toolResult(id: id, text: "用户跳过了该提问（未作答）。请据此自行决定或继续。", isError: false)
        }
    }

    private static func askUserToolSchema() -> [String: Any] {
        [
        "name": "ask_user",
        "description": "向用户提出一个或多个多选题并**等待**其回答。当你需要用户在若干选项中选择、或澄清意图时使用本工具（不要自行假设答案）。",
        "inputSchema": [
            "type": "object",
            "properties": [
                "questions": [
                    "type": "array",
                    "description": "要问的问题（可多条）。",
                    "items": [
                        "type": "object",
                        "properties": [
                            "question": ["type": "string", "description": "完整的问题文本"],
                            "header": ["type": "string", "description": "很短的标签（≤12 字）"],
                            "multiSelect": ["type": "boolean", "description": "是否允许多选"],
                            "options": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string"],
                                        "description": ["type": "string"]
                                    ],
                                    "required": ["label"]
                                ]
                            ]
                        ],
                        "required": ["question", "options"]
                    ]
                ]
            ],
            "required": ["questions"]
        ]
    ]
    }

    /// 工具调用是否为本服务器的 ask_user（供输出解析层抑制其活动行——卡片已替它呈现）。
    public static func isAskUserToolName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "ask_user" || lower.hasSuffix("__ask_user") || lower.contains("agentdeck__ask_user")
    }

    // MARK: - HTTP 帮助

    private static func sessionID(fromPath path: String) -> String? {
        // /mcp/<sessionID>（忽略查询串）
        let trimmed = path.split(separator: "?").first.map(String.init) ?? path
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0] == "mcp" else { return nil }
        return parts[1]
    }

    private static func jsonRPCResult(id: Any?, result: [String: Any], extraHeaders: [String: String] = [:]) -> Data {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id ?? NSNull()
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return httpResponse(status: "200 OK", body: body, contentType: "application/json", extraHeaders: extraHeaders)
    }

    private static func jsonRPCError(id: Any?, code: Int, message: String) -> Data {
        var payload: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        payload["id"] = id ?? NSNull()
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return httpResponse(status: "200 OK", body: body, contentType: "application/json")
    }

    /// MCP tools/call 的结果包装：{ content:[{type:text,text}], isError }。
    private static func toolResult(id: Any?, text: String, isError: Bool) -> Data {
        let result: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "isError": isError
        ]
        return jsonRPCResult(id: id, result: result)
    }

    private static func httpResponse(
        status: String,
        body: Data,
        contentType: String? = nil,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var header = "HTTP/1.1 \(status)\r\n"
        if let contentType { header += "Content-Type: \(contentType)\r\n" }
        for (key, value) in extraHeaders { header += "\(key): \(value)\r\n" }
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private static func send(_ data: Data, on connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    private static func readRequest(_ connection: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        while true {
            guard let chunk = await receiveChunk(connection), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            if let request = HTTPRequest.parse(buffer) { return request }
            if buffer.count > 8_000_000 { return nil } // 防御：异常大请求直接放弃
        }
    }

    private static func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data()) // 无数据但连接仍开：上层会再 receive
                }
            }
        }
    }
}

/// 极简 HTTP/1.1 请求解析（仅取方法/路径/体；够 MCP JSON-RPC 用）。
struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// 当缓冲区里已含完整请求（头 + Content-Length 指定的体）时返回；否则 nil（需更多字节）。
    static func parse(_ buffer: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.firstRange(of: separator) else { return nil }
        let headerData = buffer[..<range.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1]) ?? 0
            }
        }

        let bodyStart = range.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil } // 体还没收全
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])
        return HTTPRequest(method: method, path: path, body: body)
    }
}
