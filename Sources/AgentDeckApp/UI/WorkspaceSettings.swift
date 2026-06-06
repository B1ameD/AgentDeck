import Foundation

/// 「工作区」分类的用户偏好。键名带 `workspace.` 前缀。

/// 工作区预设配置。作为偏好持久化，描述当前工作区的协作 / 权限基调。
enum WorkspaceMode: String, CaseIterable, Identifiable {
    case development  // 开发模式
    case readOnly     // 只读模式
    case shared       // 共享模式

    static let storageKey = "workspace.mode"
    static let defaultID = WorkspaceMode.development.rawValue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .development: "开发模式"
        case .readOnly: "只读模式"
        case .shared: "共享模式"
        }
    }

    static func resolve(_ id: String) -> WorkspaceMode {
        WorkspaceMode(rawValue: id) ?? .development
    }
}

/// 一个已配置的工作区（项目）：名称 + 文件系统路径。
struct KnownProject: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var path: String

    /// 以 ~ 缩写后的展示路径。
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }

    init(id: String = UUID().uuidString, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// 已知工作区列表的持久化（@AppStorage 存 JSON 字符串）。
enum KnownProjectsStore {
    static let storageKey = "workspace.knownProjects"
    static let currentIDKey = "workspace.currentProjectID"

    /// 首次运行的示例项目。路径指向用户主目录——选中即切到主目录，安全有效，不会让 agent 跑进无效路径。
    static func seedProjects() -> [KnownProject] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            KnownProject(id: "example-a", name: "Project A", path: home),
            KnownProject(id: "example-b", name: "Project B", path: home),
            KnownProject(id: "example-c", name: "Project C", path: home)
        ]
    }

    static func decode(_ raw: String) -> [KnownProject] {
        guard let data = raw.data(using: .utf8),
              let list = try? JSONDecoder().decode([KnownProject].self, from: data),
              !list.isEmpty
        else { return [] }
        return list
    }

    static func encode(_ projects: [KnownProject]) -> String {
        guard let data = try? JSONEncoder().encode(projects),
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }
}
