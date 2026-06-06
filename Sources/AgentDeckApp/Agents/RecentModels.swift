import Foundation

/// 记录每个 agent 最近选过的模型（持久化到 UserDefaults），供 /model 菜单的「Recent」分组使用。
public enum RecentModels {
    public static let limit = 6

    public static func get(forAgent agentID: String, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key(agentID)) ?? []
    }

    public static func record(_ model: String, forAgent agentID: String, defaults: UserDefaults = .standard) {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "default" else { return } // default 不记
        var list = get(forAgent: agentID, defaults: defaults).filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        defaults.set(Array(list.prefix(limit)), forKey: key(agentID))
    }

    private static func key(_ agentID: String) -> String { "recentModels.\(agentID)" }
}
