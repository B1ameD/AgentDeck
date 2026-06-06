import Foundation

/// 发现工作目录里可作为「项目背景」的文件（README 变体 + CLAUDE.md + AGENTS.md），
/// 供「提示词优化」以 @路径附件形式附带给改写 agent（内容由 agent 自行读取，本处不读内容）。
/// 含目录列举（轻量 I/O）——请在后台线程调用（AgentSession 用 Task.detached）。
enum ProjectContext {
    /// 返回作为项目背景的文件 URL（存在者）：README（最佳变体）→ CLAUDE.md → AGENTS.md。
    /// 跳过 >1MB 的文件，避免附带巨型文件。无任何文件返回空数组。
    static func files(in directory: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }

        var names: [String] = []
        if let readme = PromptOptimizer.pickReadme(from: entries) { names.append(readme) }
        for target in ["CLAUDE.md", "AGENTS.md"] {
            if let match = entries.first(where: { $0.caseInsensitiveCompare(target) == .orderedSame }) {
                names.append(match)
            }
        }

        return names.compactMap { name in
            let url = directory.appendingPathComponent(name)
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 { return nil }
            return url
        }
    }
}
