import Foundation

/// 后端会话连续性状态机：从 CLI 输出流捕获会话 id（claude / opencode / codex）、
/// 模型切换时使会话失效、为 Claude 提供「原生 resume → 本地转录回放」的降级策略。
/// 纯值类型、不持有 AgentSession——会话上下文（model / command / messages）按参数传入，可独立单测。
/// （#25 拆分第一步；#4 同会话丢上下文的核心逻辑集中于此。）
struct SessionContinuity {
    /// Claude 跨进程续聊策略：优先原生 `--resume <id>`；无 id 时回放本地转录；都没有则全新开场。
    enum ClaudeStrategy: Equatable {
        case none
        case nativeResume(String)
        case localTranscriptReplay

        var externalSessionID: String? {
            if case .nativeResume(let id) = self { return id }
            return nil
        }
    }

    let agentKind: AgentConfig.Kind
    /// CLI 返回的会话 id，用于继续对话（-s 或 --session-id）。
    private(set) var backendSessionID: String?
    /// 捕获 backendSessionID 时使用的模型 key，模型切换时清空会话 id。
    private(set) var backendSessionModel: String?
    /// Claude 输出流里实际解析到的模型 id（system/init 的顶层 `model` 或 assistant 的 `message.model`）。
    private(set) var resolvedModel: String?
    private var jsonBuffer = ""

    init(
        agentKind: AgentConfig.Kind,
        restoredSessionID: String? = nil,
        restoredSessionModel: String? = nil
    ) {
        self.agentKind = agentKind
        self.backendSessionID = restoredSessionID
        self.backendSessionModel = restoredSessionModel
    }

    /// 模型 key 归一化：空白/空串视为 "default"。
    static func modelKey(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    private var supportsBackendSession: Bool {
        agentKind == .claudeCode || agentKind == .openCode || agentKind == .codex
    }

    /// 本次调用可透传的外部会话 id。
    /// 模型切换:claude 的 `--resume` 跨模型合法(2026-06-10 实测同 id 换 --model 续聊成功),
    /// 保留会话只更新 key——此前一律作废是 #4 丢上下文的实证根因之一;
    /// opencode/codex 的会话与模型绑定关系未证实,保守维持作废。
    mutating func externalSessionIDForInvocation(modelKey: String) -> String? {
        guard supportsBackendSession else { return nil }
        if backendSessionModel != modelKey {
            if agentKind == .claudeCode {
                backendSessionModel = modelKey
            } else {
                backendSessionID = nil
                backendSessionModel = modelKey
                jsonBuffer = ""
            }
        }
        return backendSessionID
    }

    /// 仅 opencode 全新会话需要标题（服务端按标题建会话）。
    func conversationTitle(externalSessionID: String?, command: AgentCommand, sessionUUID: UUID) -> String? {
        guard agentKind == .openCode, externalSessionID == nil, command == .new else { return nil }
        return "AgentDeck \(sessionUUID.uuidString)"
    }

    /// 决定 Claude 本轮的续聊方式。注意会触发模型切换失效检查（与取 externalSessionID 同路径）。
    mutating func claudeStrategy(
        for prompt: String,
        command: AgentCommand,
        modelKey: String,
        messages: [ChatMessage]
    ) -> ClaudeStrategy {
        guard agentKind == .claudeCode, command == .new else { return .none }

        if let id = externalSessionIDForInvocation(modelKey: modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            return .nativeResume(id)
        }

        if let transcript = Self.localHistoryTranscript(messages: messages, excludingUserPrompt: prompt),
           !transcript.isEmpty {
            return .localTranscriptReplay
        }

        return .none
    }

    /// localTranscriptReplay 时把本地转录包进 prompt（<agentdeck_history>），其余情形原样返回。
    static func promptForInvocation(
        _ prompt: String,
        strategy: ClaudeStrategy,
        agentKind: AgentConfig.Kind,
        command: AgentCommand,
        messages: [ChatMessage]
    ) -> String {
        guard agentKind == .claudeCode,
              command == .new,
              strategy == .localTranscriptReplay,
              let transcript = localHistoryTranscript(messages: messages, excludingUserPrompt: prompt),
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

    /// 原生 resume 失败转本地回放前：丢弃失效的后端会话 id。
    mutating func clearBackendSessionForLocalReplay(modelKey: String) {
        backendSessionID = nil
        backendSessionModel = modelKey
        jsonBuffer = ""
    }

    /// 用户改选模型后清掉上一次解析到的具体版本（下一轮重新捕获）。
    mutating func clearResolvedModel() {
        resolvedModel = nil
    }

    mutating func captureBackendSessionID(from chunk: String, modelKey: String) {
        guard supportsBackendSession else { return }
        jsonBuffer += chunk

        while let newline = jsonBuffer.firstIndex(of: "\n") {
            let line = String(jsonBuffer[..<newline])
            jsonBuffer.removeSubrange(...newline)
            capture(fromJSONLine: line, modelKey: modelKey)
        }
    }

    mutating func flushBackendSessionCapture(modelKey: String) {
        guard !jsonBuffer.isEmpty else { return }
        let line = jsonBuffer
        jsonBuffer = ""
        capture(fromJSONLine: line, modelKey: modelKey)
    }

    private mutating func capture(fromJSONLine line: String, modelKey: String) {
        // 已拿到会话 id、且本轮模型也已解析时，无需再逐行解析 JSON（模型在 init 行即出现、单轮内不变）。
        let needsSession = backendSessionID == nil
        let needsModel = agentKind == .claudeCode && resolvedModel == nil
        guard needsSession || needsModel,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if needsModel { captureResolvedModel(from: object) }
        guard needsSession else { return }

        switch agentKind {
        case .claudeCode:
            if let sessionID = (object["session_id"] as? String) ?? (object["sessionID"] as? String),
               !sessionID.isEmpty {
                backendSessionID = sessionID
                backendSessionModel = modelKey
            }
        case .openCode:
            if let sessionID = object["sessionID"] as? String, !sessionID.isEmpty {
                backendSessionID = sessionID
                backendSessionModel = modelKey
            }
        case .codex:
            if object["type"] as? String == "thread.started",
               let threadID = object["thread_id"] as? String,
               !threadID.isEmpty {
                backendSessionID = threadID
                backendSessionModel = modelKey
            }
        case .pi, .custom:
            break
        }
    }

    /// 从 Claude 输出流捕获实际解析到的模型：优先 system/init 的顶层 `model`，回退 assistant 的 `message.model`。
    private mutating func captureResolvedModel(from object: [String: Any]) {
        let candidate = (object["model"] as? String)
            ?? ((object["message"] as? [String: Any])?["model"] as? String)
        guard let candidate, !candidate.isEmpty, candidate != resolvedModel else { return }
        resolvedModel = candidate
    }

    // MARK: - 本地转录回放

    static func localHistoryTranscript(
        messages: [ChatMessage],
        excludingUserPrompt currentPrompt: String,
        maxMessages: Int = 8,
        maxCharacters: Int = 4_000
    ) -> String? {
        let currentUserText = normalizedHistoryText(currentPrompt)
        var seen = Set<String>()
        var chunks: [String] = []

        for message in messages.reversed() {
            guard chunks.count < maxMessages,
                  message.role == .user || message.role == .assistant else { continue }
            let text = sanitizedHistoryText(message.text)
            guard !text.isEmpty else { continue }
            if message.role == .user, normalizedHistoryText(text) == currentUserText {
                continue
            }
            let key = "\(message.role.rawValue):\(normalizedHistoryText(text))"
            guard seen.insert(key).inserted else { continue }
            chunks.append("\(historyRoleLabel(message.role)):\n\(text)")
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
}
