import Foundation

/// Reads Claude Code's user settings so AgentDeck can run `claude` with the same
/// third-party API environment configured by tools such as cc-switch.
public enum ClaudeSettings {
    public static var defaultSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "settings.json")
    }

    public static func loadEnvironment(settingsURL: URL = defaultSettingsURL) -> [String: String] {
        guard let object = loadObject(settingsURL: settingsURL),
              let env = object["env"] as? [String: Any] else { return [:] }
        return env.compactMapValues(stringValue)
    }

    /// settings.json 里的「角色 → 模型」映射，连同 AgentDeck 选「default」时 claude 实际所用的模型。
    /// 参考 claude-code-haha 的 .env：ANTHROPIC_MODEL / ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL。
    public struct ModelRoles: Equatable, Sendable {
        /// 模型值 → 角色标签（如 "mimo-v2.5" → "Haiku · 快"）。供模型选择器给每行打标签。
        public var labels: [String: String]
        /// ANTHROPIC_MODEL 的值：AgentDeck 选「default」(不传 --model) 时 claude 实际使用的模型。
        public var defaultModel: String?

        public init(labels: [String: String], defaultModel: String?) {
            self.labels = labels
            self.defaultModel = defaultModel
        }
    }

    public static func modelRoles(settingsURL: URL = defaultSettingsURL) -> ModelRoles {
        let env = (loadObject(settingsURL: settingsURL)?["env"] as? [String: Any])?.compactMapValues(stringValue) ?? [:]
        let defaultModel = normalized(env["ANTHROPIC_MODEL"])
        var labels: [String: String] = [:]
        func tag(_ model: String?, _ role: String) {
            guard let model else { return }
            labels[model] = labels[model].map { "\($0) / \(role)" } ?? role
        }
        tag(normalized(env["ANTHROPIC_DEFAULT_HAIKU_MODEL"]), "Haiku · 快")
        tag(normalized(env["ANTHROPIC_DEFAULT_SONNET_MODEL"]), "Sonnet")
        tag(normalized(env["ANTHROPIC_DEFAULT_OPUS_MODEL"]), "Opus")
        tag(defaultModel, "默认")
        return ModelRoles(labels: labels, defaultModel: defaultModel)
    }

    public static func modelCandidates(settingsURL: URL = defaultSettingsURL) -> [String] {
        guard let object = loadObject(settingsURL: settingsURL) else { return [] }
        let env = (object["env"] as? [String: Any])?.compactMapValues(stringValue) ?? [:]
        let keys = [
            "ANTHROPIC_MODEL",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL",
            "ANTHROPIC_DEFAULT_OPUS_MODEL"
        ]
        var values = keys.compactMap { normalized(env[$0]) }
        if let model = normalized(stringValue(object["model"])) {
            values.append(model)
        }
        return unique(values)
    }

    private static func loadObject(settingsURL: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
