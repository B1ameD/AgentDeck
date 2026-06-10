import Foundation

/// 一个标签页（会话）的可恢复身份。用稳定的 session id 让重开后能按原 id 重建并载回聊天记录。
public struct SessionSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var agentID: String
    public var workingDirectory: String?
    public var model: String?
    public var focused: Bool?
    public var reasoningEffort: String?
    public var interactionMode: String?
    public var command: String?
    public var backendSessionID: String?
    public var backendSessionModel: String?
    /// 用户自定义标签名（双击/右键改名）；nil 则回落到生成名/首条消息/agent 名。
    public var customTitle: String?
    /// 是否置顶（左栏排序时排在前面）。
    public var pinned: Bool?
    /// 工作目录是否被手动锁定（右键「设置工作目录…」）；锁定的标签恢复后仍不随全局工作区切换而改变。
    public var directoryPinned: Bool?

    public init(
        id: String,
        agentID: String,
        workingDirectory: String?,
        model: String?,
        focused: Bool?,
        reasoningEffort: String? = nil,
        interactionMode: String? = nil,
        command: String? = nil,
        backendSessionID: String? = nil,
        backendSessionModel: String? = nil,
        customTitle: String? = nil,
        pinned: Bool? = nil,
        directoryPinned: Bool? = nil
    ) {
        self.id = id
        self.agentID = agentID
        self.workingDirectory = workingDirectory
        self.model = model
        self.focused = focused
        self.reasoningEffort = reasoningEffort
        self.interactionMode = interactionMode
        self.command = command
        self.backendSessionID = backendSessionID
        self.backendSessionModel = backendSessionModel
        self.customTitle = customTitle
        self.pinned = pinned
        self.directoryPinned = directoryPinned
    }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public var layout: WorkspaceLayout
    public var activeAgentIDs: [String]
    /// 新版恢复用的会话列表（带 id/目录/模型/焦点）；旧快照无此字段时回落到 activeAgentIDs。
    public var activeSessions: [SessionSnapshot]?
    public var recentWorkspace: String?
    /// 被用户从「最近」里移除的会话 id（仅隐藏出 Recent，转录本身仍在历史检索里可找回）。
    public var dismissedRecents: [String]?

    public static let `default` = WorkspaceSnapshot(
        layout: .one,
        activeAgentIDs: [],
        activeSessions: nil,
        recentWorkspace: nil
    )

    private enum CodingKeys: String, CodingKey {
        case layout
        case activeAgentIDs
        case activeSessions
        case recentWorkspace
        case dismissedRecents
    }

    public init(
        layout: WorkspaceLayout,
        activeAgentIDs: [String],
        activeSessions: [SessionSnapshot]? = nil,
        recentWorkspace: String?,
        dismissedRecents: [String]? = nil
    ) {
        self.layout = layout
        self.activeAgentIDs = activeAgentIDs
        self.activeSessions = activeSessions
        self.recentWorkspace = recentWorkspace
        self.dismissedRecents = dismissedRecents
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let layoutValue = try container.decode(Int.self, forKey: .layout)

        guard let layout = WorkspaceLayout(rawValue: layoutValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .layout,
                in: container,
                debugDescription: "Invalid workspace layout."
            )
        }

        self.layout = layout
        activeAgentIDs = try container.decode([String].self, forKey: .activeAgentIDs)
        activeSessions = try container.decodeIfPresent([SessionSnapshot].self, forKey: .activeSessions)
        recentWorkspace = try container.decodeIfPresent(String.self, forKey: .recentWorkspace)
        dismissedRecents = try container.decodeIfPresent([String].self, forKey: .dismissedRecents)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(layout.rawValue, forKey: .layout)
        try container.encode(activeAgentIDs, forKey: .activeAgentIDs)
        try container.encodeIfPresent(activeSessions, forKey: .activeSessions)
        try container.encodeIfPresent(recentWorkspace, forKey: .recentWorkspace)
        try container.encodeIfPresent(dismissedRecents, forKey: .dismissedRecents)
    }
}

public struct SessionStore: Sendable {
    public let baseDirectory: URL

    private var snapshotURL: URL {
        baseDirectory.appendingPathComponent("workspace.json")
    }

    public init(baseDirectory: URL = SessionStore.defaultBaseDirectory()) {
        self.baseDirectory = baseDirectory
    }

    public func save(_ snapshot: WorkspaceSnapshot) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(snapshot)
        try data.write(to: snapshotURL, options: .atomic)
    }

    public func loadSnapshot() throws -> WorkspaceSnapshot {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return .default
        }
        let data = try Data(contentsOf: snapshotURL)
        return try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    }

    public static func defaultBaseDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("AgentDeck", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
