import Foundation

/// 发现某 agent 在非交互模式下可透传的「原生指令」。
/// 目前支持 Claude Code：读取 ~/.claude/commands 与 <工作目录>/.claude/commands 下的 *.md 自定义命令，
/// 这些命令以 `/名字` 形式在 `claude -p` 下可解析。其它 agent 暂无可靠的文件式命令清单，返回空。
public enum NativeSlashCommands {
    public static func discover(
        for agent: AgentConfig,
        workingDirectory: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [SlashCommand] {
        guard agent.kind == .claudeCode else { return [] }

        let directories = [
            homeDirectory.appending(path: ".claude/commands", directoryHint: .isDirectory),
            workingDirectory.appending(path: ".claude/commands", directoryHint: .isDirectory)
        ]

        var byToken: [String: SlashCommand] = [:]
        for directory in directories {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "md" {
                let token = "/\(file.deletingPathExtension().lastPathComponent)"
                if byToken[token] == nil {
                    byToken[token] = SlashCommand(
                        token: token,
                        summary: summary(of: file) ?? "自定义指令（透传给 CLI）",
                        action: .passthrough
                    )
                }
            }
        }
        return byToken.values.sorted { $0.token < $1.token }
    }

    /// 命令说明：优先用 frontmatter 里的 `description:`，否则取正文第一行有意义的文本。
    private static func summary(of url: URL) -> String? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        var index = 0
        if lines.first == "---" {
            index = 1
            while index < lines.count {
                let line = lines[index]
                index += 1
                if line == "---" { break }
                if line.lowercased().hasPrefix("description:") {
                    let value = line.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { return String(value.prefix(60)) }
                }
            }
        }
        while index < lines.count {
            let line = lines[index]
            index += 1
            if !line.isEmpty && !line.hasPrefix("#") { return String(line.prefix(60)) }
        }
        return nil
    }
}
