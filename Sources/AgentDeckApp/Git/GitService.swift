import Foundation

/// 一个改动文件的 git 状态（porcelain v1 的 XY 两位 + 路径）。
public struct GitFileChange: Identifiable, Equatable, Sendable {
    public var path: String
    public var index: Character    // 暂存区状态（XY 的 X）
    public var worktree: Character // 工作区状态（XY 的 Y）

    public var id: String { path }
    public var isUntracked: Bool { index == "?" && worktree == "?" }
    public var isStaged: Bool { !isUntracked && index != " " }

    public init(path: String, index: Character, worktree: Character) {
        self.path = path
        self.index = index
        self.worktree = worktree
    }
}

public struct GitStatus: Equatable, Sendable {
    public var branch: String?
    public var changes: [GitFileChange]

    public init(branch: String?, changes: [GitFileChange]) {
        self.branch = branch
        self.changes = changes
    }

    public var isClean: Bool { changes.isEmpty }
}

/// 解析 `git status --porcelain=v1 --branch` 与 `git branch` 输出（纯函数，便于测试）。
public enum GitStatusParser {
    public static func parse(_ output: String) -> GitStatus {
        var branch: String?
        var changes: [GitFileChange] = []

        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("## ") {
                branch = parseBranch(String(line.dropFirst(3)))
            } else if line.count >= 4 {
                let chars = Array(line)
                var path = String(line.dropFirst(3)) // 跳过 "XY "
                // 重命名 "old -> new"：展示新路径。
                if let range = path.range(of: " -> ") {
                    path = String(path[range.upperBound...])
                }
                path = unquote(path)
                changes.append(GitFileChange(path: path, index: chars[0], worktree: chars[1]))
            }
        }
        return GitStatus(branch: branch, changes: changes)
    }

    /// 解析当前分支名。形如 "main...origin/main [ahead 1]"、"main"、"No commits yet on main"、"HEAD (no branch)"。
    static func parseBranch(_ text: String) -> String? {
        if text.hasPrefix("No commits yet on ") {
            return String(text.dropFirst("No commits yet on ".count))
        }
        if let range = text.range(of: "...") {
            return String(text[..<range.lowerBound])
        }
        let token = text.split(separator: " ").first.map(String.init)
        return token == "HEAD" ? nil : token // 分离头指针视为无分支
    }

    /// 解析 `git branch --format=%(refname:short)` 的分支列表（每行一个）。
    public static func parseBranchList(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ path: String) -> String {
        guard path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 else { return path }
        return String(path.dropFirst().dropLast())
    }
}

/// 在某工作目录上跑 git 命令：状态、暂存/取消暂存、提交、分支、切换分支。
public struct GitService: Sendable {
    private let runner: ProcessRunner
    private let gitPath: String

    public init(runner: ProcessRunner = ProcessRunner(), gitPath: String = GitService.resolveGit()) {
        self.runner = runner
        self.gitPath = gitPath
    }

    public static func resolveGit() -> String {
        AgentDetection.resolveExecutable(named: "git") ?? "/usr/bin/git"
    }

    /// 仓库状态；非 git 目录或出错返回 nil。
    public func status(in directory: URL) async -> GitStatus? {
        guard let result = try? await run(["status", "--porcelain=v1", "--branch"], in: directory),
              result.exitCode == 0 else { return nil }
        return GitStatusParser.parse(result.stdout)
    }

    public func branches(in directory: URL) async -> [String] {
        guard let result = try? await run(["branch", "--format=%(refname:short)"], in: directory),
              result.exitCode == 0 else { return [] }
        return GitStatusParser.parseBranchList(result.stdout)
    }

    @discardableResult
    public func stage(_ path: String, in directory: URL) async -> Bool {
        await succeeds(["add", "--", path], in: directory)
    }

    @discardableResult
    public func unstage(_ path: String, in directory: URL) async -> Bool {
        await succeeds(["restore", "--staged", "--", path], in: directory)
    }

    @discardableResult
    public func commit(message: String, in directory: URL) async -> Bool {
        await succeeds(["commit", "-m", message], in: directory)
    }

    @discardableResult
    public func checkout(branch: String, in directory: URL) async -> Bool {
        await succeeds(["checkout", branch], in: directory)
    }

    /// 取某文件相对 HEAD 的统一 diff（含已暂存 + 未暂存改动）。
    /// untracked / 仓库尚无提交时回退 `--no-index`，整体呈现为新增。
    /// 注意：diff 命令在有差异时退出码为 1，故按 stdout 取值、不以 exitCode 判失败。
    public func diff(forPath path: String, in directory: URL) async -> String {
        if let result = try? await run(["diff", "--no-color", "HEAD", "--", path], in: directory),
           !result.stdout.isEmpty {
            return result.stdout
        }
        if let result = try? await run(["diff", "--no-color", "--no-index", "--", "/dev/null", path], in: directory),
           !result.stdout.isEmpty {
            return result.stdout
        }
        return ""
    }

    /// 比较两段文本的统一 diff（写临时文件后 `git diff --no-index`）。
    /// 用于「运行前基线 → 运行后内容」的本轮逐行 diff——不依赖 HEAD、不把整文件当新增。
    /// 有差异时 git 退出码为 1，按 stdout 取值。
    public func diff(oldText: String, newText: String) async -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-diff-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("old")
        let newURL = dir.appendingPathComponent("new")
        guard (try? oldText.write(to: oldURL, atomically: true, encoding: .utf8)) != nil,
              (try? newText.write(to: newURL, atomically: true, encoding: .utf8)) != nil else {
            return ""
        }
        if let result = try? await run(
            ["diff", "--no-color", "--no-index", "--", oldURL.path, newURL.path],
            in: dir
        ) {
            return result.stdout
        }
        return ""
    }

    private func succeeds(_ args: [String], in directory: URL) async -> Bool {
        ((try? await run(args, in: directory))?.exitCode ?? 1) == 0
    }

    private func run(_ args: [String], in directory: URL) async throws -> ProcessResult {
        try await runner.runOneShot(command: gitPath, args: args, environment: [:], workingDirectory: directory)
    }
}
