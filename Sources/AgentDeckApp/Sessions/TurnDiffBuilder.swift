import Foundation

/// 用「运行前内容快照 + 运行后磁盘内容」算出本轮每个改动文件的结构化 diff。
/// 关键：modified 文件比对的是**运行前基线**而非 git HEAD / /dev/null，所以未跟踪文件、运行前已 dirty
/// 的文件，也只展示本轮真正改动的几行，而不是整文件标绿。无基线时才回退 git HEAD。
public enum TurnDiffBuilder {
    public static func build(
        changedPaths: [String],
        in directory: URL,
        since snapshot: WorkspaceChangeSnapshot,
        git: GitService = GitService(),
        maxFiles: Int = 100,
        maxFileBytes: Int = 1_000_000
    ) async -> TurnDiffSummary {
        let paths = Array(changedPaths.prefix(maxFiles))
        var files: [TurnFileDiff] = []
        for path in paths {
            if let file = await buildOne(
                path: path, in: directory, since: snapshot, git: git, maxFileBytes: maxFileBytes
            ) {
                files.append(file)
            }
        }
        files.sort { $0.path < $1.path }
        return TurnDiffSummary(workingDirectory: directory.path, files: files)
    }

    private static func buildOne(
        path: String,
        in directory: URL,
        since snapshot: WorkspaceChangeSnapshot,
        git: GitService,
        maxFileBytes: Int
    ) async -> TurnFileDiff? {
        let fm = FileManager.default
        let newURL = directory.appending(path: path)
        let old = snapshot.fileSnapshots[path]
        let existedBefore = snapshot.fingerprints[path] != nil || old != nil
        let newExists = fm.fileExists(atPath: newURL.path)

        if !newExists {
            guard existedBefore else { return nil } // 从未见过又不存在 → 多半是路径形态不一致，跳过
            if let oldText = old?.text {
                return TurnFileDiff(
                    path: path, status: .deleted,
                    diff: UnifiedDiffParser.parse(await git.diff(oldText: oldText, newText: ""))
                )
            }
            return TurnFileDiff(path: path, status: .deleted, diff: .empty, note: "已删除（无基线正文）")
        }

        let newSize = (try? newURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if newSize > maxFileBytes {
            return TurnFileDiff(path: path, status: .tooLarge, diff: .empty, note: "文件过大，未生成逐行 diff")
        }
        guard let newData = try? Data(contentsOf: newURL) else { return nil }
        guard let newText = String(data: newData, encoding: .utf8) else {
            return TurnFileDiff(path: path, status: .binary, diff: FileDiff(hunks: [], isBinary: true), note: "二进制文件")
        }

        // 有运行前基线正文 → 精确的本轮 diff。
        if let oldText = old?.text {
            if oldText == newText { return nil } // 内容没变（仅 mtime 变）→ 不列入
            let parsed = UnifiedDiffParser.parse(await git.diff(oldText: oldText, newText: newText))
            return parsed.isEmpty ? nil : TurnFileDiff(path: path, status: .modified, diff: parsed)
        }

        // 本轮新建的文件 → 全文新增。
        if !existedBefore {
            return TurnFileDiff(
                path: path, status: .added,
                diff: UnifiedDiffParser.parse(await git.diff(oldText: "", newText: newText)),
                note: "新增文件"
            )
        }

        // 存在过但未捕获基线（超界 / 原为二进制）→ 回退 git HEAD（tracked），否则显示当前全文。
        let head = await git.diff(forPath: path, in: directory)
        if !head.isEmpty {
            return TurnFileDiff(
                path: path, status: .modified,
                diff: UnifiedDiffParser.parse(head), note: "基线未捕获，回退 git HEAD diff"
            )
        }
        return TurnFileDiff(
            path: path, status: .modified,
            diff: UnifiedDiffParser.parse(await git.diff(oldText: "", newText: newText)),
            note: "基线未捕获，显示当前全文"
        )
    }
}
