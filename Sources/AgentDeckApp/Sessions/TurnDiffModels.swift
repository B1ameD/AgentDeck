import Foundation

/// 运行前对单个文件的内容快照——和运行后内容比对，算出「本轮」逐行 diff 的基线。
/// 仅对存在的文件生成；二进制 / 过大文件不存正文（text == nil），仅留元数据供 UI 说明原因。
public struct FileSnapshot: Equatable, Sendable, Codable {
    public var relativePath: String
    public var text: String?     // UTF-8 文本内容；二进制或过大则为 nil
    public var isBinary: Bool
    public var byteCount: Int

    public init(relativePath: String, text: String?, isBinary: Bool, byteCount: Int) {
        self.relativePath = relativePath
        self.text = text
        self.isBinary = isBinary
        self.byteCount = byteCount
    }
}

/// 本轮某个文件的结构化 diff（与右侧栏审核、聊天内联卡片共用同一数据，不重复算第二份）。
public struct TurnFileDiff: Equatable, Sendable, Identifiable, Codable {
    public enum Status: String, Equatable, Sendable, Codable {
        case added      // 本轮新建的文件
        case modified   // 本轮修改（有运行前基线，逐行 diff 精确）
        case deleted    // 本轮删除
        case binary     // 二进制，无逐行 diff
        case tooLarge   // 过大，未生成逐行 diff
    }

    public var path: String
    public var status: Status
    public var diff: FileDiff
    public var note: String?

    public var id: String { path }
    public var addedCount: Int { diff.addedCount }
    public var removedCount: Int { diff.removedCount }

    public init(path: String, status: Status, diff: FileDiff, note: String? = nil) {
        self.path = path
        self.status = status
        self.diff = diff
        self.note = note
    }

    public var statusLabel: String {
        switch status {
        case .added: "新增"
        case .modified: "修改"
        case .deleted: "删除"
        case .binary: "二进制"
        case .tooLarge: "过大"
        }
    }

    /// 是否有可展开的逐行 hunk（binary/tooLarge 没有）。
    public var hasInlineDiff: Bool {
        !diff.isBinary && !diff.hunks.isEmpty
    }
}

/// 一轮 agent 运行的全部改动。运行结束后算一次、之后**只读不重算**（保证审核栏展示的是该轮的不可变结果）。
public struct TurnDiffSummary: Equatable, Sendable, Codable {
    public var workingDirectory: String
    public var generatedAt: Date
    public var files: [TurnFileDiff]

    public init(workingDirectory: String, generatedAt: Date = Date(), files: [TurnFileDiff]) {
        self.workingDirectory = workingDirectory
        self.generatedAt = generatedAt
        self.files = files
    }

    public var totalAdded: Int { files.reduce(0) { $0 + $1.addedCount } }
    public var totalRemoved: Int { files.reduce(0) { $0 + $1.removedCount } }
    public var isEmpty: Bool { files.isEmpty }
    public var paths: [String] { files.map(\.path) }

    /// 找出与某个工具编辑路径对应的文件 diff：先按相对路径精确匹配，再按文件名兜底。
    /// 供聊天里「编辑 X」工具行就地展开该文件本轮的逐行 diff。
    public func fileDiff(forRelativePath relativePath: String) -> TurnFileDiff? {
        let target = relativePath.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        if let exact = files.first(where: { $0.path == target }) { return exact }
        let base = (target as NSString).lastPathComponent
        guard !base.isEmpty else { return nil }
        return files.first(where: { ($0.path as NSString).lastPathComponent == base })
    }
}
