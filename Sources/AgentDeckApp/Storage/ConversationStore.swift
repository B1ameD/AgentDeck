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

/// 单条会话的轻量摘要（Recent 列表用）：避免为显示一行标题而解码全部消息正文（#31）。
public struct ConversationSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var agentName: String
    public var updatedAt: Date

    public init(id: String, title: String, agentName: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.agentName = agentName
        self.updatedAt = updatedAt
    }
}

/// 把会话转录以 JSON 落盘（每会话一个文件），并支持加载/全量/删除，供持久化与搜索使用。
/// 性能（#31）：
/// - 编码+写盘走串行后台队列——每轮对话尾的全量重写（曾达 2.8MB pretty JSON）不再卡主线程；
///   读路径（load/all）经同一队列串行，天然读后写一致。
/// - 紧凑编码（去 pretty）：文件只供程序读写，编码/解码/体积三赢。
/// - Recent 列表走摘要索引（目录内 index.json）：save/delete 同步维护内存缓存，刷新零读盘；
///   旧版无索引时全量扫描重建一次（迁移成本只付一次）。
public final class ConversationStore: @unchecked Sendable {
    public let directory: URL
    private static let indexFilename = "index.json"
    private let ioQueue = DispatchQueue(label: "agentdeck.conversation-io", qos: .utility)
    private let lock = NSLock()
    /// 摘要缓存：nil＝尚未加载（首次访问时从 index.json 载入或重建）。
    private var summaryCache: [String: ConversationSummary]?

    public init(directory: URL = ConversationStore.defaultDirectory()) {
        self.directory = directory
    }

    public func save(_ conversation: StoredConversation) {
        updateSummary(ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            agentName: conversation.agentName,
            updatedAt: conversation.updatedAt
        ))
        let indexSnapshot = summariesSnapshot()
        let target = fileURL(for: conversation.id)
        let directory = directory
        let indexURL = indexURL
        ioQueue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(conversation) {
                try? data.write(to: target, options: .atomic)
            }
            Self.writeIndex(indexSnapshot, to: indexURL)
        }
    }

    public func load(id: String) -> StoredConversation? {
        let url = fileURL(for: id)
        return ioQueue.sync {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(StoredConversation.self, from: data)
        }
    }

    /// 全部会话（含消息正文），按更新时间倒序。仅历史检索等用户触发路径使用；
    /// Recent 列表请用 summaries()。
    public func all() -> [StoredConversation] {
        ioQueue.sync { allOnQueue() }
    }

    /// 全部会话摘要，按更新时间倒序（Recent 列表用，不解码消息正文）。
    public func summaries() -> [ConversationSummary] {
        lock.lock()
        defer { lock.unlock() }
        ensureCacheLocked()
        return (summaryCache ?? [:]).values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(id: String) {
        lock.lock()
        ensureCacheLocked()
        summaryCache?[id] = nil
        let snapshot = (summaryCache ?? [:]).values.sorted { $0.updatedAt > $1.updatedAt }
        lock.unlock()
        let url = fileURL(for: id)
        let indexURL = indexURL
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            Self.writeIndex(Array(snapshot), to: indexURL)
        }
    }

    /// 等待后台写盘全部落定（测试/退出前用；常规路径不需要——读已经过同一队列串行）。
    public func waitForPendingWrites() {
        ioQueue.sync {}
    }

    private func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    private var indexURL: URL {
        directory.appendingPathComponent(Self.indexFilename)
    }

    private func updateSummary(_ summary: ConversationSummary) {
        lock.lock()
        defer { lock.unlock() }
        ensureCacheLocked()
        summaryCache?[summary.id] = summary
    }

    private func summariesSnapshot() -> [ConversationSummary] {
        lock.lock()
        defer { lock.unlock() }
        return Array((summaryCache ?? [:]).values)
    }

    /// 持锁调用。索引文件缺失/损坏时全量扫描重建并异步落盘（旧版迁移路径）。
    private func ensureCacheLocked() {
        guard summaryCache == nil else { return }
        if let data = try? Data(contentsOf: indexURL),
           let entries = try? JSONDecoder().decode([ConversationSummary].self, from: data) {
            summaryCache = entries.reduce(into: [:]) { $0[$1.id] = $1 }
            return
        }
        let rebuilt = ioQueue.sync { allOnQueue() }.reduce(into: [String: ConversationSummary]()) { acc, convo in
            acc[convo.id] = ConversationSummary(
                id: convo.id,
                title: convo.title,
                agentName: convo.agentName,
                updatedAt: convo.updatedAt
            )
        }
        summaryCache = rebuilt
        let snapshot = Array(rebuilt.values)
        let indexURL = indexURL
        ioQueue.async { Self.writeIndex(snapshot, to: indexURL) }
    }

    /// 仅在 ioQueue 上调用。
    private func allOnQueue() -> [StoredConversation] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != Self.indexFilename }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(StoredConversation.self, from: $0) } }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func writeIndex(_ entries: [ConversationSummary], to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgentDeck/conversations", isDirectory: true)
    }
}
