import Foundation
import os

/// opencode 流式调用的抽象接口。便于在测试中注入假实现，生产用 `OpenCodeStreamingClient`。
///
/// `stream(_:)` 负责建立通道（拉起服务、建/续会话、订阅事件）；建立阶段失败应抛
/// `OpenCodeStreamingError.unavailable`，由调用方（AgentSession）回退到非流式 `opencode run`。
/// 成功后返回的事件流以 opencode `run --format json` 的 JSON 行形态承载**增量**文本，
/// 从而可以原样复用既有 `OutputParser`（增量追加到同一个气泡）。
public protocol OpenCodeStreaming: Sendable {
    func stream(_ request: OpenCodeStreamRequest) async throws -> AsyncThrowingStream<ProcessStreamEvent, Error>
    /// 回答 opencode 提问（POST /question/{requestID}/reply）。answers 按问题顺序，每项是该问题选中的 label 数组。
    func replyToQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String, answers: [[String]]
    ) async
    /// 拒绝/跳过 opencode 提问（POST /question/{requestID}/reject）。
    func rejectQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String
    ) async
}

public extension OpenCodeStreaming {
    // 默认空实现：非 opencode 的测试替身无需关心提问回传。
    func replyToQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String, answers: [[String]]
    ) async {}
    func rejectQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String
    ) async {}
}

/// 一次 opencode 流式调用所需的结构化参数（取代 CLI 参数编码）。
public struct OpenCodeStreamRequest: Sendable {
    public var executable: String
    public var environment: [String: String]
    public var workingDirectory: URL
    public var prompt: String
    /// "default" 或 "provider/model"。
    public var model: String
    /// provider 专属推理强度（minimal/high…），nil 表示默认。
    public var variant: String?
    public var attachments: [URL]
    /// 续接的后端会话 id；nil/空表示新建会话。
    public var continueSessionID: String?
    /// 新建会话标题（仅新建时使用）。
    public var title: String?
    /// 是否展开 reasoning（思考块），与 `opencode run --thinking` 对齐。
    public var thinking: Bool
    public var stopSignal: AgentConfig.StopSignal

    public init(
        executable: String,
        environment: [String: String],
        workingDirectory: URL,
        prompt: String,
        model: String,
        variant: String?,
        attachments: [URL],
        continueSessionID: String?,
        title: String?,
        thinking: Bool,
        stopSignal: AgentConfig.StopSignal
    ) {
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.model = model
        self.variant = variant
        self.attachments = attachments
        self.continueSessionID = continueSessionID
        self.title = title
        self.thinking = thinking
        self.stopSignal = stopSignal
    }
}

/// 生产实现：通过 opencode 的 headless server + SSE `/event` 拿到逐 token 增量文本。
public final class OpenCodeStreamingClient: OpenCodeStreaming, @unchecked Sendable {
    public static let shared = OpenCodeStreamingClient()

    private let server: OpenCodeServer
    private let session: URLSession
    private let log = Logger(subsystem: "AgentDeck", category: "opencode-stream")

    init(server: OpenCodeServer = .shared, session: URLSession = .shared) {
        self.server = server
        self.session = session
    }

    public func stream(_ request: OpenCodeStreamRequest) async throws -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        // 建立阶段：服务 + 会话。任一失败抛 unavailable → 调用方回退非流式。
        let base = try await server.baseURL(executable: request.executable, environment: request.environment)

        let sessionID: String
        if let existing = request.continueSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            sessionID = existing
        } else {
            sessionID = try await createSession(base: base, directory: request.workingDirectory, title: request.title)
        }
        return makeStream(base: base, sessionID: sessionID, request: request)
    }

    // MARK: - 事件流

    private func makeStream(
        base: URL,
        sessionID: String,
        request: OpenCodeStreamRequest
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        let connectionBox = OpenCodeSSEConnectionBox()
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                // 先发一行带 sessionID 的占位事件：上层 captureBackendSessionID 据此记住后端会话以便续接。
                continuation.yield(.stdout(OpenCodeStreamWire.line([
                    "type": "step_start", "sessionID": sessionID, "part": [String: Any]()
                ]) + "\n"))

                do {
                    // SSE 必须在发 prompt 前连上（避免漏掉早期事件）。
                    let eventConnection = try await connectEventStream(base: base, directory: request.workingDirectory)
                    connectionBox.set(eventConnection)
                    defer { eventConnection.cancel() }

                    let promptTask = Task { [self] () -> String? in
                        do {
                            try await postMessage(base: base, sessionID: sessionID, request: request)
                            return nil
                        } catch {
                            return Self.describe(error)
                        }
                    }

                    var translator = OpenCodeEventTranslator(sessionID: sessionID, thinking: request.thinking)
                    var reachedIdle = false
                    for try await sseEvent in eventConnection.events {
                        if Task.isCancelled { break }
                        let event = sseEvent.object
                        let translation = translator.translate(event)
                        for line in translation.lines {
                            continuation.yield(.stdout(line + "\n"))
                        }
                        if let permissionID = translation.rejectPermissionID {
                            // 与 `opencode run` 一致：非交互模式自动拒绝权限请求，避免挂起。
                            await rejectPermission(
                                base: base, sessionID: sessionID,
                                permissionID: permissionID, directory: request.workingDirectory
                            )
                        }
                        if translation.finished { reachedIdle = true; break }
                    }

                    // 没到 idle 却是因为发消息本身失败（如模型不存在）：把错误显式暴露给用户（运行内错误，不回退）。
                    if !reachedIdle, !Task.isCancelled, let promptError = await promptTask.value {
                        continuation.yield(.stdout(OpenCodeStreamWire.line([
                            "type": "error", "sessionID": sessionID, "error": promptError
                        ]) + "\n"))
                    }
                    promptTask.cancel()

                    if !Task.isCancelled { continuation.yield(.exit(0)) }
                    continuation.finish()
                } catch {
                    // 连接/读取事件流异常：作为错误事件暴露，再正常收尾（已开始流式，不回退）。
                    if !Task.isCancelled {
                        continuation.yield(.stdout(OpenCodeStreamWire.line([
                            "type": "error", "sessionID": sessionID, "error": Self.describe(error)
                        ]) + "\n"))
                        continuation.yield(.exit(0))
                    }
                    continuation.finish()
                }
            }

            continuation.onTermination = { [self, connectionBox] reason in
                task.cancel()
                connectionBox.cancel()
                // 消费方取消（Stop / 超时）→ 通知服务端中止本会话生成。
                if case .cancelled = reason {
                    Task { [self] in
                        await abort(base: base, sessionID: sessionID, directory: request.workingDirectory)
                    }
                }
            }
        }
    }

    // MARK: - HTTP

    private func createSession(base: URL, directory: URL, title: String?) async throws -> String {
        let request = makeRequest(
            base.appendingPathComponent("session"),
            method: "POST", directory: directory,
            body: OpenCodeStreamWire.sessionCreateBody(title: title)
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenCodeStreamingError.unavailable("创建会话失败（HTTP \(Self.statusCode(response))）")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            throw OpenCodeStreamingError.unavailable("会话响应缺少 id")
        }
        return id
    }

    private func connectEventStream(base: URL, directory: URL) async throws -> OpenCodeSSEConnection {
        var request = makeRequest(base.appendingPathComponent("event"), method: "GET", directory: directory, timeout: 600)
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let events = AsyncThrowingStream<OpenCodeSSEEvent, Error>.makeStream()
        let opened = AsyncThrowingStream<Void, Error>.makeStream()
        let delegate = OpenCodeSSEStreamDelegate(
            events: events.continuation,
            opened: opened.continuation
        )
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 600
        let eventSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = eventSession.dataTask(with: request)
        let connection = OpenCodeSSEConnection(
            events: events.stream,
            task: task,
            session: eventSession,
            delegate: delegate
        )
        task.resume()

        var iterator = opened.stream.makeAsyncIterator()
        guard (try await iterator.next()) != nil else {
            connection.cancel()
            throw OpenCodeStreamingError.unavailable("订阅事件失败（未收到 HTTP 响应）")
        }
        return connection
    }

    private func postMessage(base: URL, sessionID: String, request: OpenCodeStreamRequest) async throws {
        let body = OpenCodeStreamWire.messageBody(
            model: request.model, variant: request.variant,
            prompt: request.prompt, attachments: request.attachments
        )
        let httpRequest = makeRequest(
            base.appendingPathComponent("session/\(sessionID)/message"),
            method: "POST", directory: request.workingDirectory, body: body, timeout: 600
        )
        let (data, response) = try await session.data(for: httpRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw OpenCodeStreamingError.unavailable("发送消息失败（HTTP \(Self.statusCode(response))）\(detail)")
        }
    }

    private func rejectPermission(base: URL, sessionID: String, permissionID: String, directory: URL) async {
        let request = makeRequest(
            base.appendingPathComponent("session/\(sessionID)/permissions/\(permissionID)"),
            method: "POST", directory: directory, body: ["response": "reject"], timeout: 10
        )
        _ = try? await session.data(for: request)
    }

    private func abort(base: URL, sessionID: String, directory: URL) async {
        let request = makeRequest(
            base.appendingPathComponent("session/\(sessionID)/abort"),
            method: "POST", directory: directory, timeout: 10
        )
        _ = try? await session.data(for: request)
    }

    // MARK: - 提问回传（question.asked → reply / reject）

    public func replyToQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String, answers: [[String]]
    ) async {
        await postQuestion(
            executable: executable, environment: environment, directory: workingDirectory,
            path: "question/\(requestID)/reply", body: ["answers": answers]
        )
    }

    public func rejectQuestion(
        executable: String, environment: [String: String], workingDirectory: URL,
        requestID: String
    ) async {
        await postQuestion(
            executable: executable, environment: environment, directory: workingDirectory,
            path: "question/\(requestID)/reject", body: nil
        )
    }

    /// 解析 base（拉起/复用 headless server）后向 question 端点 POST。失败静默（用户可重试 / Stop）。
    private func postQuestion(
        executable: String, environment: [String: String], directory: URL,
        path: String, body: [String: Any]?
    ) async {
        guard let base = try? await server.baseURL(executable: executable, environment: environment) else { return }
        let request = makeRequest(base.appendingPathComponent(path), method: "POST", directory: directory, body: body, timeout: 15)
        _ = try? await session.data(for: request)
    }

    private func makeRequest(
        _ url: URL,
        method: String,
        directory: URL,
        body: [String: Any]? = nil,
        timeout: TimeInterval = 60
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        // 工作目录随每个请求下发，所以一个共享服务即可服务所有会话目录。
        request.setValue(directory.path, forHTTPHeaderField: "x-opencode-directory")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func statusCode(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    private static func describe(_ error: Error) -> String {
        if let streaming = error as? OpenCodeStreamingError { return streaming.errorDescription ?? "\(streaming)" }
        return error.localizedDescription
    }
}

// MARK: - SSE 连接

private final class OpenCodeSSEConnection: @unchecked Sendable {
    let events: AsyncThrowingStream<OpenCodeSSEEvent, Error>
    private let task: URLSessionDataTask
    private let session: URLSession
    private let delegate: OpenCodeSSEStreamDelegate

    init(
        events: AsyncThrowingStream<OpenCodeSSEEvent, Error>,
        task: URLSessionDataTask,
        session: URLSession,
        delegate: OpenCodeSSEStreamDelegate
    ) {
        self.events = events
        self.task = task
        self.session = session
        self.delegate = delegate
    }

    func cancel() {
        task.cancel()
        session.invalidateAndCancel()
        delegate.finish(error: nil)
    }
}

private final class OpenCodeSSEConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: OpenCodeSSEConnection?

    func set(_ connection: OpenCodeSSEConnection) {
        lock.withLock { self.connection = connection }
    }

    func cancel() {
        let current = lock.withLock { connection }
        current?.cancel()
    }
}

private final class OpenCodeSSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let events: AsyncThrowingStream<OpenCodeSSEEvent, Error>.Continuation
    private let opened: AsyncThrowingStream<Void, Error>.Continuation
    private let lock = NSLock()
    private var decoder = OpenCodeSSEChunkDecoder()

    init(
        events: AsyncThrowingStream<OpenCodeSSEEvent, Error>.Continuation,
        opened: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        self.events = events
        self.opened = opened
    }

    func finish(error: Error?) {
        if let error {
            opened.finish(throwing: error)
            events.finish(throwing: error)
        } else {
            opened.finish()
            events.finish()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let error = OpenCodeStreamingError.unavailable(
                "订阅事件失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）"
            )
            finish(error: error)
            completionHandler(.cancel)
            return
        }

        opened.yield(())
        opened.finish()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let parsed = lock.withLock { decoder.append(data) }
        for event in parsed {
            events.yield(event)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error: error)
    }
}

// MARK: - 纯逻辑（可单测，无 IO）

/// 把 opencode 服务端 SSE 事件翻译成 `opencode run --format json` 形态的 JSON 行（**增量**文本）。
/// 这样上层无需改 OutputParser 即可逐 token 追加。翻译是纯函数式的，便于单测。
struct OpenCodeEventTranslator {
    let sessionID: String
    let thinking: Bool
    private var accumulator = DeltaAccumulator()
    /// partID → 已知累计文本（来自 part.delta 增量累加，或 part.updated 全量快照）。
    private var cumulativeByPart: [String: String] = [:]
    /// partID → 部件类型（text/reasoning/tool）。来自 message.part.updated（part 创建先于其 delta），
    /// 用来区分逐 token 的 delta 属于「答案」还是「思考」——因为 part.delta 的 field 恒为 "text"。
    private var typeByPart: [String: String] = [:]
    /// messageID → role（来自 message.updated）。仅在 part.updated 全量兜底路径用于过滤用户消息回显。
    private var rolesByMessageID: [String: String] = [:]
    /// 最近一次发出答案文本的 text part id：换到新的文本 part（如工具调用后的续写）时补换行，不黏连。
    private var lastEmittedTextPartID: String?
    /// assistant message 的最新用量（cost USD + tokens，随 message.updated 滚动更新取终值；
    /// 字段形状已在安装版 source map 核实）。结束时合成 claude result 同形行复用 UsageCapture（#28）。
    private var usageByMessageID: [String: (cost: Double, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]

    init(sessionID: String, thinking: Bool) {
        self.sessionID = sessionID
        self.thinking = thinking
    }

    mutating func translate(_ event: [String: Any]) -> OpenCodeEventTranslation {
        guard let type = event["type"] as? String else { return OpenCodeEventTranslation() }
        let properties = event["properties"] as? [String: Any] ?? [:]

        switch type {
        case "message.updated":
            if let info = properties["info"] as? [String: Any],
               info["sessionID"] as? String == sessionID,
               let id = info["id"] as? String,
               let role = info["role"] as? String {
                rolesByMessageID[id] = role
                if role == "assistant", let tokens = info["tokens"] as? [String: Any] {
                    let cache = tokens["cache"] as? [String: Any] ?? [:]
                    usageByMessageID[id] = (
                        cost: (info["cost"] as? Double) ?? 0,
                        input: Self.intValue(tokens["input"]),
                        // reasoning 按输出计（计费口径一致）
                        output: Self.intValue(tokens["output"]) + Self.intValue(tokens["reasoning"]),
                        cacheRead: Self.intValue(cache["read"]),
                        cacheWrite: Self.intValue(cache["write"])
                    )
                }
            }
            return OpenCodeEventTranslation()

        case "message.part.delta":
            // 真·逐 token 流式：每个事件携带一段增量文本。field 恒为 "text"（被修改的字段名），
            // 故按 partID 的**部件类型**区分答案/思考（类型来自先到的 part.updated）。
            guard properties["sessionID"] as? String == sessionID,
                  let partID = properties["partID"] as? String,
                  let delta = properties["delta"] as? String, !delta.isEmpty else {
                return OpenCodeEventTranslation()
            }
            cumulativeByPart[partID, default: ""] += delta
            let fresh = accumulator.delta(partID: partID, fullText: cumulativeByPart[partID] ?? "")
            return emit(partID: partID, newContent: fresh)

        case "message.part.updated":
            guard let part = properties["part"] as? [String: Any],
                  part["sessionID"] as? String == sessionID,
                  let partID = part["id"] as? String else { return OpenCodeEventTranslation() }
            if let partType = part["type"] as? String { typeByPart[partID] = partType }
            return translateUpdatedPart(part, partID: partID)

        case "session.error":
            guard properties["sessionID"] as? String == sessionID else { return OpenCodeEventTranslation() }
            var translation = OpenCodeEventTranslation()
            translation.lines = [OpenCodeStreamWire.line([
                "type": "error", "sessionID": sessionID, "error": OpenCodeStreamWire.errorMessage(properties["error"])
            ])]
            return translation

        case "session.idle":
            // 服务端给本会话的明确「生成结束」事件。
            var translation = OpenCodeEventTranslation()
            translation.finished = properties["sessionID"] as? String == sessionID
            if translation.finished { translation.lines += usageResultLines() }
            return translation

        case "session.status":
            guard properties["sessionID"] as? String == sessionID else { return OpenCodeEventTranslation() }
            let status = properties["status"] as? [String: Any]
            var translation = OpenCodeEventTranslation()
            translation.finished = (status?["type"] as? String) == "idle"
            if translation.finished { translation.lines += usageResultLines() }
            return translation

        case "permission.asked", "permission.updated":
            guard properties["sessionID"] as? String == sessionID else { return OpenCodeEventTranslation() }
            var translation = OpenCodeEventTranslation()
            translation.rejectPermissionID = properties["id"] as? String
            return translation

        case "question.asked":
            // opencode 的提问工具（Question.ask）发布本事件并**阻塞**等回答。转成 question 事件交上层渲染可点选卡片；
            // 不拒绝、不结束、不中止——run 保持运行等用户作答，answers 经 POST /question/{requestID}/reply 回传，agent 原地继续。
            guard properties["sessionID"] as? String == sessionID,
                  let requestID = properties["id"] as? String else { return OpenCodeEventTranslation() }
            let line = OpenCodeStreamWire.line([
                "type": "question",
                "sessionID": sessionID,
                "requestID": requestID,
                "input": ["questions": properties["questions"] ?? []]
            ])
            return OpenCodeEventTranslation(lines: [line])

        default:
            return OpenCodeEventTranslation()
        }
    }

    /// 处理全量快照事件：工具部件出摘要；文本/思考部件仅作**非流式 provider 的兜底**——
    /// 若该 part 已被 delta 覆盖，accumulator 返回空（不重复）；只在缺 delta 时补出完整文本。
    private mutating func translateUpdatedPart(_ part: [String: Any], partID: String) -> OpenCodeEventTranslation {
        switch part["type"] as? String {
        case "tool":
            guard let state = part["state"] as? [String: Any],
                  let status = state["status"] as? String,
                  status == "completed" || status == "error" else { return OpenCodeEventTranslation() }
            // 透传成既有 OutputParser 认识的 opencode tool_use 形态（只摘要、不灌结果）。
            return OpenCodeEventTranslation(lines: [
                OpenCodeStreamWire.line(["type": "tool_use", "sessionID": sessionID, "part": part])
            ])

        case "text", "reasoning":
            guard isAssistant(part) else { return OpenCodeEventTranslation() } // 跳过用户消息回显
            let full = part["text"] as? String ?? ""
            guard full.count > (cumulativeByPart[partID]?.count ?? 0) else { return OpenCodeEventTranslation() }
            cumulativeByPart[partID] = full
            let fresh = accumulator.delta(partID: partID, fullText: full)
            return emit(partID: partID, newContent: fresh)

        default:
            return OpenCodeEventTranslation()
        }
    }

    /// 把某 part 的「新增内容」按其类型转成输出行：text→答案（跨 part 补换行），reasoning→<think>。
    private mutating func emit(partID: String, newContent: String) -> OpenCodeEventTranslation {
        guard !newContent.isEmpty else { return OpenCodeEventTranslation() }
        if typeByPart[partID] == "reasoning" {
            guard thinking else { return OpenCodeEventTranslation() }
            return OpenCodeEventTranslation(lines: [OpenCodeStreamWire.line([
                "type": "reasoning", "sessionID": sessionID, "part": ["type": "reasoning", "text": newContent]
            ])])
        }
        // 默认按答案文本处理（含类型未知的极少数情况）。
        var payload = newContent
        if let last = lastEmittedTextPartID, last != partID { payload = "\n" + payload }
        lastEmittedTextPartID = partID
        return OpenCodeEventTranslation(lines: [OpenCodeStreamWire.line([
            "type": "text", "sessionID": sessionID, "part": ["type": "text", "text": payload]
        ])])
    }

    /// 生成结束时把本轮全部 assistant 用量合成**一条**与 claude result 同形的 JSON 行，
    /// 直接复用 AgentSession 的 UsageCapture 管线（#28）。发出即清空，避免重复计量。
    private mutating func usageResultLines() -> [String] {
        guard !usageByMessageID.isEmpty else { return [] }
        var cost = 0.0
        var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
        for usage in usageByMessageID.values {
            cost += usage.cost
            input += usage.input
            output += usage.output
            cacheRead += usage.cacheRead
            cacheWrite += usage.cacheWrite
        }
        usageByMessageID = [:]
        guard cost > 0 || input > 0 || output > 0 else { return [] }
        return [OpenCodeStreamWire.line([
            "type": "result",
            "total_cost_usd": cost,
            "usage": [
                "input_tokens": input,
                "output_tokens": output,
                "cache_read_input_tokens": cacheRead,
                "cache_creation_input_tokens": cacheWrite
            ]
        ])]
    }

    private static func intValue(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? 0
    }

    /// 该 part 是否属于助手消息：优先按 message.updated 记录的 role；角色未知时用「助手 part 必有 time、
    /// 用户 part 无 time」兜底（见服务端事件实测）。
    private func isAssistant(_ part: [String: Any]) -> Bool {
        if let messageID = part["messageID"] as? String, let role = rolesByMessageID[messageID] {
            return role == "assistant"
        }
        return part["time"] != nil
    }
}

/// 翻译结果：要发给上层的 JSON 行、是否本会话已 idle（结束）、需 best-effort 拒绝的权限 id。
struct OpenCodeEventTranslation {
    var lines: [String] = []
    var finished = false
    var rejectPermissionID: String?
}

/// 按 part 维度记录「已发出的文本」，把服务端的**累计**文本转成**增量**（delta）。
/// opencode 的 `message.part.updated` 携带的是到目前为止的完整文本快照，每次取差量发出，
/// 这样即便漏掉中间快照，最终累计仍等于完整文本（只要拿到了最后一帧）。
struct DeltaAccumulator {
    private var emitted: [String: String] = [:]

    mutating func delta(partID: String, fullText: String) -> String {
        let previous = emitted[partID] ?? ""
        emitted[partID] = fullText
        if fullText.hasPrefix(previous) {
            return String(fullText.dropFirst(previous.count))
        }
        // 非前缀（极罕见的重写）：退而取公共前缀后的后缀，尽量不丢新增内容。
        let common = OpenCodeStreamWire.commonPrefixCount(previous, fullText)
        return String(fullText.dropFirst(common))
    }
}

struct OpenCodeSSEEvent: @unchecked Sendable {
    let object: [String: Any]
}

/// 按 URLSession delegate 的 data chunk 增量解码 SSE。用 Data 缓冲到换行后再转 String，
/// 避免中文等多字节 UTF-8 字符被网络分片切开时出现损坏或替换字符。
struct OpenCodeSSEChunkDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [OpenCodeSSEEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var events: [OpenCodeSSEEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineBytes = Data(buffer[..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if lineBytes.last == 0x0D { lineBytes.removeLast() }
            guard let line = String(data: lineBytes, encoding: .utf8),
                  let event = OpenCodeStreamWire.parseSSELine(line) else { continue }
            events.append(OpenCodeSSEEvent(object: event))
        }
        return events
    }
}

/// opencode 流式的纯函数助手：SSE 解析、模型拆分、请求体构造、JSON 行序列化等。
enum OpenCodeStreamWire {
    /// 解析一行 SSE：去掉 `data:` 前缀后按 JSON 解析；空行/心跳/非 JSON 返回 nil。
    static func parseSSELine(_ raw: String) -> [String: Any]? {
        var line = raw
        if line.hasPrefix("data:") { line.removeFirst("data:".count) }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    /// "default"/空 → nil（用 agent 默认模型）；"provider/model" → 按第一个 "/" 拆分。
    static func splitModel(_ model: String) -> (providerID: String, modelID: String)? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default", let slash = trimmed.firstIndex(of: "/") else { return nil }
        let provider = String(trimmed[..<slash])
        let model = String(trimmed[trimmed.index(after: slash)...])
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return (provider, model)
    }

    /// 新建会话请求体：沿用 `opencode run` 的拒绝规则（question/plan），避免非交互下挂起。
    static func sessionCreateBody(title: String?) -> [String: Any] {
        var body: [String: Any] = [
            "permission": [
                ["permission": "question", "action": "deny", "pattern": "*"],
                ["permission": "plan_enter", "action": "deny", "pattern": "*"],
                ["permission": "plan_exit", "action": "deny", "pattern": "*"]
            ]
        ]
        if let title, !title.isEmpty { body["title"] = title }
        return body
    }

    /// 发消息请求体：附件作为 file part 在前、文本 part 在后；模型/变体可选。
    static func messageBody(model: String, variant: String?, prompt: String, attachments: [URL]) -> [String: Any] {
        var parts: [[String: Any]] = attachments.map { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return [
                "type": "file",
                "url": url.absoluteString,
                "filename": url.lastPathComponent,
                "mime": isDirectory == true ? "application/x-directory" : "text/plain"
            ]
        }
        parts.append(["type": "text", "text": prompt])

        var body: [String: Any] = ["parts": parts]
        if let split = splitModel(model) {
            body["model"] = ["providerID": split.providerID, "modelID": split.modelID]
        }
        if let variant, !variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["variant"] = variant
        }
        return body
    }

    /// 把字典序列化成单行 JSON（OutputParser 按行解析）。
    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    static func errorMessage(_ error: Any?) -> String {
        if let string = error as? String, !string.isEmpty { return string }
        if let dictionary = error as? [String: Any] {
            if let data = dictionary["data"] as? [String: Any],
               let message = data["message"] as? String, !message.isEmpty { return message }
            if let message = dictionary["message"] as? String, !message.isEmpty { return message }
            if let name = dictionary["name"] as? String, !name.isEmpty { return name }
        }
        return "opencode 会话出错"
    }

    /// 两个字符串的公共前缀长度（按 Character）。
    static func commonPrefixCount(_ a: String, _ b: String) -> Int {
        var count = 0
        var i = a.startIndex
        var j = b.startIndex
        while i < a.endIndex, j < b.endIndex, a[i] == b[j] {
            count += 1
            i = a.index(after: i)
            j = b.index(after: j)
        }
        return count
    }
}
