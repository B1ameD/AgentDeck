import Foundation
import os

// ACP 客户端传输:把 ACP 适配器(如 `npx -y @agentclientprotocol/claude-agent-acp`)当子进程拉起,
// 走换行分隔 JSON-RPC over stdio。这是第三个传输层(并列 ProcessRunner / OpenCodeStreamingClient)。
//
// 现状:spike。已用 docs 里的 Python 探针实测打通 initialize→session/new→session/prompt(见 ACP_INTEGRATION_PLAN.md)。
// 尚未接进 AgentSession / UI(phase 1)。进程 I/O 在此;纯逻辑(编解码/翻译)在 ACPProtocol/ACPEventTranslator。

public enum ACPClientError: Error, Equatable, LocalizedError {
    case spawnFailed(String)
    case notInitialized
    case requestFailed(code: Int, message: String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .spawnFailed(let detail): "ACP 适配器启动失败：\(detail)"
        case .notInitialized: "ACP 会话尚未初始化"
        case .requestFailed(let code, let message): "ACP 请求失败（\(code)）：\(message)"
        case .timeout: "ACP 请求超时或连接中断"
        }
    }
}

/// agent→client 请求(权限 / 文件读写)的应答决策,由上层(AgentSession)注入。
public struct ACPClientHandlers: Sendable {
    /// 收到 session/request_permission:给定选项,返回选中的 optionId(nil = 取消)。
    public var onPermission: @Sendable (_ toolCall: JSONValue, _ options: [ACPPermissionOption]) async -> String?
    /// 收到 fs/read_text_file:返回文件内容(nil = 让 agent 回退本地磁盘)。
    public var onReadTextFile: @Sendable (_ path: String) async -> String?
    /// 收到 fs/write_text_file:写入,返回是否成功。
    public var onWriteTextFile: @Sendable (_ path: String, _ content: String) async -> Bool

    public init(
        onPermission: @escaping @Sendable (JSONValue, [ACPPermissionOption]) async -> String? = { _, opts in
            opts.first(where: { $0.isAllow })?.optionId ?? opts.first?.optionId
        },
        onReadTextFile: @escaping @Sendable (String) async -> String? = { _ in nil },
        onWriteTextFile: @escaping @Sendable (String, String) async -> Bool = { _, _ in false }
    ) {
        self.onPermission = onPermission
        self.onReadTextFile = onReadTextFile
        self.onWriteTextFile = onWriteTextFile
    }
}

/// 一轮 prompt 的流式事件:逐条 session/update 的 update 体,终值为 stopReason。
public enum ACPPromptEvent: Sendable {
    case update(JSONValue)
    case completed(stopReason: String)
}

/// ACP 传输抽象:便于 AgentSession 注入假实现做单测;生产用 `ACPClient`。
public protocol ACPTransporting: Sendable {
    func start(command: String, args: [String], environment: [String: String], workingDirectory: URL) async throws
    func initialize() async throws -> ACPAgentCapabilities
    func newSession(cwd: URL, mcpServers: [JSONValue]) async throws -> ACPNewSession
    func resumeSession(sessionId: String, cwd: URL) async throws -> ACPNewSession
    func setMode(sessionId: String, modeId: String) async throws
    func setConfigOption(sessionId: String, configId: String, value: String) async throws
    func prompt(sessionId: String, content: [JSONValue]) -> AsyncThrowingStream<ACPPromptEvent, Error>
    func cancel(sessionId: String) async
    func shutdown() async
}

public actor ACPClient: ACPTransporting {
    private static let log = Logger(subsystem: "AgentDeck", category: "acp")

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()

    private var nextID = 0
    private var pendingResponses: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var sessionUpdateSink: ((JSONValue) -> Void)?
    private var handlers: ACPClientHandlers
    private var stdoutBuffer = Data()
    private var started = false

    public init(handlers: ACPClientHandlers = ACPClientHandlers()) {
        self.handlers = handlers
    }

    // MARK: - 生命周期

    /// 拉起适配器子进程并开始读 stdout。command/args 形如 ("npx", ["-y","@agentclientprotocol/claude-agent-acp"])。
    public func start(command: String, args: [String], environment: [String: String], workingDirectory: URL) async throws {
        guard !started else { return }
        process.executableURL = resolveExecutable(command)
        process.arguments = args
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        // GUI app 继承 launchd 最小 PATH（无 /opt/homebrew/bin / nvm），npx/node 会找不到（127）。
        // 调用方未显式给 PATH 时补登录 shell 级 PATH，与 ProcessRunner 一致。
        if environment["PATH"] == nil { env["PATH"] = ShellEnvironment.enrichedPATH }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.ingest(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8), !s.isEmpty {
                ACPClient.log.debug("acp stderr: \(s, privacy: .public)")
            }
        }
        do {
            try process.run()
            started = true
        } catch {
            throw ACPClientError.spawnFailed(error.localizedDescription)
        }
    }

    public func shutdown() {
        sessionUpdateSink = nil
        if process.isRunning { process.terminate() }
        for (_, cont) in pendingResponses { cont.resume(throwing: ACPClientError.timeout) }
        pendingResponses.removeAll()
    }

    // MARK: - 请求/响应

    public func initialize() async throws -> ACPAgentCapabilities {
        let result = try await request(method: "initialize", params: [
            "protocolVersion": .number(1),
            "clientCapabilities": .object([
                "fs": .object(["readTextFile": .bool(true), "writeTextFile": .bool(true)]),
                "terminal": .bool(false)
            ])
        ])
        return ACPAgentCapabilities(from: result)
    }

    public func newSession(cwd: URL, mcpServers: [JSONValue] = []) async throws -> ACPNewSession {
        let result = try await request(method: "session/new", params: [
            "cwd": .string(cwd.path),
            "mcpServers": .array(mcpServers)
        ])
        guard let session = ACPNewSession(from: result) else {
            throw ACPClientError.requestFailed(code: -1, message: "session/new 缺少 sessionId")
        }
        return session
    }

    /// 续接既有会话（不重放历史，本地转录已存）。需 agent 自报 resume 能力。
    public func resumeSession(sessionId: String, cwd: URL) async throws -> ACPNewSession {
        let result = try await request(method: "session/resume", params: [
            "sessionId": .string(sessionId),
            "cwd": .string(cwd.path)
        ])
        return ACPNewSession(sessionId: sessionId, from: result)
    }

    public func setMode(sessionId: String, modeId: String) async throws {
        _ = try await request(method: "session/set_mode", params: [
            "sessionId": .string(sessionId), "modeId": .string(modeId)
        ])
    }

    /// 设置会话配置项（如模型/推理强度——由 agent 自报的 configOptions 决定可选值）。
    /// 入参对齐 schema 的 SetSessionConfigOptionRequest：sessionId / configId / value。
    public func setConfigOption(sessionId: String, configId: String, value: String) async throws {
        _ = try await request(method: "session/set_config_option", params: [
            "sessionId": .string(sessionId), "configId": .string(configId), "value": .string(value)
        ])
    }

    /// 发送一轮 prompt,流式产出 session/update,终值 `.completed(stopReason)`。
    /// 流被取消(消费方 break/onTermination)时向 agent 发 session/cancel。
    public nonisolated func prompt(
        sessionId: String,
        content: [JSONValue]
    ) -> AsyncThrowingStream<ACPPromptEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.beginPrompt(sessionId: sessionId, content: content, continuation: continuation) }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason {
                    Task { await self.cancel(sessionId: sessionId) }
                }
            }
        }
    }

    private func beginPrompt(
        sessionId: String,
        content: [JSONValue],
        continuation: AsyncThrowingStream<ACPPromptEvent, Error>.Continuation
    ) async {
        sessionUpdateSink = { continuation.yield(.update($0)) }
        do {
            let result = try await request(method: "session/prompt", params: [
                "sessionId": .string(sessionId),
                "prompt": .array(content)
            ])
            sessionUpdateSink = nil
            continuation.yield(.completed(stopReason: result["stopReason"]?.stringValue ?? "end_turn"))
            continuation.finish()
        } catch {
            sessionUpdateSink = nil
            continuation.finish(throwing: error)
        }
    }

    public func cancel(sessionId: String) {
        let line = ACPCodec.encodeRequest(id: nil, method: "session/cancel",
                                          params: ["sessionId": .string(sessionId)])
        write(line)
    }

    // MARK: - 内部:发请求 + 读流

    private func request(method: String, params: [String: JSONValue]) async throws -> JSONValue {
        nextID += 1
        let id = nextID
        let line = ACPCodec.encodeRequest(id: id, method: method, params: params)
        return try await withCheckedThrowingContinuation { cont in
            pendingResponses[id] = cont
            write(line)
        }
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        stdinPipe.fileHandleForWriting.write(data)
    }

    /// 累积 stdout,按换行切帧,逐帧分派。
    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            dispatch(line)
        }
    }

    private func dispatch(_ line: String) {
        let frame: ACPIncomingFrame?
        do { frame = try ACPCodec.decodeFrame(line) } catch {
            ACPClient.log.debug("acp 帧解析失败: \(line, privacy: .public)")
            return
        }
        guard let frame else { return }

        if frame.isResponse, case let .number(id)? = frame.id {
            let cont = pendingResponses.removeValue(forKey: id)
            if let error = frame.error {
                cont?.resume(throwing: ACPClientError.requestFailed(code: error.code, message: error.message))
            } else {
                cont?.resume(returning: frame.result ?? .null)
            }
            return
        }
        if frame.isNotification, frame.method == "session/update", let params = frame.params {
            sessionUpdateSink?(params)
            return
        }
        if frame.isRequest, let method = frame.method, let id = frame.id {
            Task { await handleAgentRequest(id: id, method: method, params: frame.params) }
        }
    }

    /// 应答 agent→client 请求(权限 / 文件),否则 agent 会一直等而挂起。
    private func handleAgentRequest(id: ACPID, method: String, params: JSONValue?) async {
        switch method {
        case "session/request_permission":
            let options = (params?["options"]?.arrayValue ?? []).compactMap(ACPPermissionOption.init(from:))
            let chosen = await handlers.onPermission(params?["toolCall"] ?? .null, options)
            let outcome: [String: JSONValue] = chosen.map {
                ["outcome": .object(["outcome": .string("selected"), "optionId": .string($0)])]
            } ?? ["outcome": .object(["outcome": .string("cancelled")])]
            write(ACPCodec.encodeResponse(id: id, result: outcome))
        case "fs/read_text_file":
            let path = params?["path"]?.stringValue ?? ""
            let content = await handlers.onReadTextFile(path) ?? ""
            write(ACPCodec.encodeResponse(id: id, result: ["content": .string(content)]))
        case "fs/write_text_file":
            let path = params?["path"]?.stringValue ?? ""
            let content = params?["content"]?.stringValue ?? ""
            _ = await handlers.onWriteTextFile(path, content)
            write(ACPCodec.encodeResponse(id: id, result: [:]))
        default:
            write(ACPCodec.encodeResponse(id: id, result: [:])) // 未知请求:空应答,避免挂起
        }
    }

    private func resolveExecutable(_ command: String) -> URL {
        if command.contains("/") { return URL(fileURLWithPath: (command as NSString).expandingTildeInPath) }
        // 裸名:按常见 PATH 解析(npx/node 多在 /opt/homebrew/bin 或 /usr/local/bin)。phase 1 接登录 shell PATH。
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let candidate = "\(dir)/\(command)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return URL(fileURLWithPath: "/usr/bin/env") // 兜底:env 会按 PATH 找(配合 args 首项为命令名)
    }
}
