import Foundation

/// 一段落盘的会话转录。
public struct StoredConversation: Codable, Equatable, Sendable, Identifiable {
    public var id: String            // session UUID 字符串
    public var agentID: String
    public var agentName: String
    public var workingDirectory: String
    public var messages: [ChatMessage]
    public var updatedAt: Date
    // 续接相关状态（可选；旧文件缺失则解码为 nil）：让「关闭→Recent 重开」也能恢复模型上下文，
    // 与 app 重启恢复（SessionSnapshot）保持一致。
    public var model: String?
    public var reasoningEffort: String?
    public var interactionMode: String?
    public var command: String?
    public var backendSessionID: String?
    public var backendSessionModel: String?
    /// 用户自定义标题（改名）；优先于首条消息生成的标题。
    public var customTitle: String?
    /// 是否置顶。
    public var pinned: Bool?
    /// 累计 token/费用（真实计量；旧文件缺失解码为 nil）。
    public var usage: SessionUsage?

    public init(
        id: String,
        agentID: String,
        agentName: String,
        workingDirectory: String,
        messages: [ChatMessage],
        updatedAt: Date,
        model: String? = nil,
        reasoningEffort: String? = nil,
        interactionMode: String? = nil,
        command: String? = nil,
        backendSessionID: String? = nil,
        backendSessionModel: String? = nil,
        customTitle: String? = nil,
        pinned: Bool? = nil,
        usage: SessionUsage? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        self.messages = messages
        self.updatedAt = updatedAt
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.interactionMode = interactionMode
        self.command = command
        self.backendSessionID = backendSessionID
        self.backendSessionModel = backendSessionModel
        self.customTitle = customTitle
        self.pinned = pinned
        self.usage = usage
    }

    /// 展示标题：自定义标题优先；否则取首条用户消息的首行摘要；都没有则「新会话」。
    public var title: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return SessionTitle.summarize(messages.first { $0.role == .user }?.text) ?? "新会话"
    }
}

/// 标签/会话标题的统一推导与首行摘要工具。
public enum SessionTitle {
    /// 把一段用户消息压成一个简短单行标题（取首个非空行，截断到 ~40 字）。
    public static func summarize(_ text: String?, maxLength: Int = 40) -> String? {
        guard let raw = text else { return nil }
        let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !firstLine.isEmpty else { return nil }
        if firstLine.count <= maxLength { return firstLine }
        let end = firstLine.index(firstLine.startIndex, offsetBy: maxLength)
        return String(firstLine[..<end]) + "…"
    }
}

/// 一条搜索命中。
public struct ConversationHit: Equatable, Sendable, Identifiable {
    public var id: String
    public var agentName: String
    public var title: String
    public var snippet: String
    public var updatedAt: Date

    public init(id: String, agentName: String, title: String, snippet: String, updatedAt: Date) {
        self.id = id
        self.agentName = agentName
        self.title = title
        self.snippet = snippet
        self.updatedAt = updatedAt
    }
}

/// 在落盘会话里做全文搜索（纯函数，便于测试）。
public enum ConversationSearch {
    public static func search(_ conversations: [StoredConversation], query: String) -> [ConversationHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }

        return conversations.compactMap { conversation -> ConversationHit? in
            guard let match = conversation.messages.first(where: { $0.text.lowercased().contains(needle) }) else {
                return nil
            }
            return ConversationHit(
                id: conversation.id,
                agentName: conversation.agentName,
                title: conversation.title,
                snippet: snippet(of: match.text, around: needle),
                updatedAt: conversation.updatedAt
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 命中处前后各取一段，便于预览。
    static func snippet(of text: String, around needle: String, radius: Int = 40) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: needle) else { return String(text.prefix(2 * radius)) }
        let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start > text.startIndex { snippet = "…" + snippet }
        if end < text.endIndex { snippet += "…" }
        return snippet
    }
}

/// 把会话转录以 JSON 落盘（每会话一个文件），并支持加载/全量/删除，供持久化与搜索使用。
public struct ConversationStore: Sendable {
    public let directory: URL

    public init(directory: URL = ConversationStore.defaultDirectory()) {
        self.directory = directory
    }

    public func save(_ conversation: StoredConversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(conversation)
        try data.write(to: fileURL(for: conversation.id), options: .atomic)
    }

    public func load(id: String) -> StoredConversation? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(StoredConversation.self, from: data)
    }

    /// 全部会话，按更新时间倒序。
    public func all() -> [StoredConversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StoredConversation.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgentDeck/conversations", isDirectory: true)
    }
}

private extension JSONEncoder {
    // 默认日期策略（自参考日起的秒数），与默认 JSONDecoder 对称，保证 round-trip。
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
