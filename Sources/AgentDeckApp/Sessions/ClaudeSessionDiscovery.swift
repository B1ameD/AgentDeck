import Foundation

/// 在 ~/.claude 里发现的一次历史会话。
public struct DiscoveredSession: Identifiable, Equatable, Sendable {
    public let id: String        // session UUID（即 .jsonl 文件名去扩展名）
    public let title: String     // 首条用户消息（截断），无则回落为 id
    public let modifiedAt: Date
    public let url: URL          // .jsonl 文件路径

    public init(id: String, title: String, modifiedAt: Date, url: URL) {
        self.id = id
        self.title = title
        self.modifiedAt = modifiedAt
        self.url = url
    }
}

/// 读取 Claude Code 原生会话存储（~/.claude/projects/<编码目录>/<sessionId>.jsonl），
/// 用于「发现历史会话 + 按 id 恢复 + 展示转录」。仅适用于 Claude Code（其它 agent 存储各异）。
public enum ClaudeSessionDiscovery {
    public static func defaultClaudeHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// Claude 把工作目录编码成项目目录名：每个非 [A-Za-z0-9] 字符替换为 “-”。
    /// 例：/Users/jean/Desktop/Codex → -Users-jean-Desktop-Codex；
    /// 含空格的 “/Users/jean/Desktop/Claude Code” → -Users-jean-Desktop-Claude-Code。
    public static func encodedProjectDirName(forPath path: String) -> String {
        String(path.map { ch in (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-" })
    }

    /// 列出某工作目录下的历史会话，按修改时间倒序。
    public static func sessions(
        claudeHome: URL,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> [DiscoveredSession] {
        let projectDir = claudeHome
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: encodedProjectDirName(forPath: workingDirectory.path), directoryHint: .isDirectory)

        guard let files = try? fileManager.contentsOfDirectory(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.pathExtension == "jsonl" }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return DiscoveredSession(
                    id: id,
                    title: firstUserTitle(in: url) ?? id,
                    modifiedAt: modified,
                    url: url
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 首条非空用户消息文本（截断为标题）。只读文件前缀，避免为取标题读入整块大文件。
    public static func firstUserTitle(in url: URL, byteLimit: Int = 65_536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: byteLimit)) ?? Data()
        guard let content = String(data: data, encoding: .utf8) else { return nil }

        for line in content.split(separator: "\n") {
            guard let object = jsonObject(from: line), object["type"] as? String == "user",
                  let message = object["message"] as? [String: Any] else { continue }
            let text = extractText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(100)) }
        }
        return nil
    }

    /// 把会话转录解析成聊天消息（仅取 user / assistant 的文本，跳过工具调用等噪声），
    /// 只保留最后 `limit` 条，供恢复时回填到聊天区。
    public static func transcript(in url: URL, limit: Int = 100) -> [ChatMessage] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var messages: [ChatMessage] = []
        for line in content.split(separator: "\n") {
            guard let object = jsonObject(from: line),
                  let type = object["type"] as? String,
                  type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            let text = extractText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            messages.append(ChatMessage(role: type == "user" ? .user : .assistant, text: text))
        }
        return Array(messages.suffix(limit))
    }

    // MARK: - 私有

    private static func jsonObject(from line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// content 可能是字符串，或 [{type:"text", text:…}, {type:"tool_use", …}] 形式的块数组；
    /// 只抽取其中的纯文本块。
    private static func extractText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
    }
}
