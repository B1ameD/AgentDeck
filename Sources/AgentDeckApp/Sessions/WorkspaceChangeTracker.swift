import Foundation

public struct WorkspaceChangeSnapshot: Equatable, Sendable {
    /// 基线时的 git 改动集合（非 git 目录为空）。
    public var paths: Set<String>
    /// 基线时的文件系统指纹（相对路径 -> "字节数:修改时间"）。用于无 git 时检测改动。
    public var fingerprints: [String: String]
    /// 基线时的文件内容快照（相对路径 -> FileSnapshot）。用于算「本轮」逐行 diff（before→after）。
    /// 只对存在的、未超界的文件捕获；超出文件数/大小上限的文件不在此（diff 时回退 git HEAD 或全文）。
    public var fileSnapshots: [String: FileSnapshot]

    public init(
        paths: Set<String>,
        fingerprints: [String: String] = [:],
        fileSnapshots: [String: FileSnapshot] = [:]
    ) {
        self.paths = paths
        self.fingerprints = fingerprints
        self.fileSnapshots = fileSnapshots
    }
}

public protocol WorkspaceChangeTracking: Sendable {
    func snapshot(in directory: URL) async -> WorkspaceChangeSnapshot
    func changedFiles(in directory: URL) async -> [String]
    func changedFiles(in directory: URL, since snapshot: WorkspaceChangeSnapshot) async -> [String]
}

public extension WorkspaceChangeTracking {
    func snapshot(in directory: URL) async -> WorkspaceChangeSnapshot {
        WorkspaceChangeSnapshot(paths: Set(await changedFiles(in: directory)))
    }

    func changedFiles(in directory: URL, since snapshot: WorkspaceChangeSnapshot) async -> [String] {
        let current = Set(await changedFiles(in: directory))
        return Array(current.subtracting(snapshot.paths)).sorted()
    }
}

public struct GitWorkspaceChangeTracker: WorkspaceChangeTracking {
    private let git: GitService

    public init(git: GitService = GitService()) {
        self.git = git
    }

    public func changedFiles(in directory: URL) async -> [String] {
        guard let status = await git.status(in: directory) else { return [] }
        return Array(Set(status.changes.map(\.path))).sorted()
    }

    /// 基线快照：git 改动集合 + 文件系统指纹 + **运行前文件内容**（小文本文件）。
    /// 指纹让非 git 目录也能检测改动；内容快照让审核栏算出「本轮」逐行 diff，而不是把整文件标成新增。
    public func snapshot(in directory: URL) async -> WorkspaceChangeSnapshot {
        let gitChanges = Set(await changedFiles(in: directory))
        let scan = await Task.detached(priority: .utility) {
            Self.scanSync(in: directory, captureContent: true)
        }.value
        return WorkspaceChangeSnapshot(
            paths: gitChanges,
            fingerprints: scan.fingerprints,
            fileSnapshots: scan.snapshots
        )
    }

    /// 本轮改动 =（git 相对基线的新增改动）∪（文件系统指纹发生变化/新增的文件）。
    public func changedFiles(in directory: URL, since snapshot: WorkspaceChangeSnapshot) async -> [String] {
        let currentGit = Set(await changedFiles(in: directory))
        let gitNew = currentGit.subtracting(snapshot.paths)

        let currentPrints = await Self.fingerprints(in: directory)
        var fsChanged = Set<String>()
        for (path, fingerprint) in currentPrints where snapshot.fingerprints[path] != fingerprint {
            fsChanged.insert(path)
        }
        // 删除的文件：基线指纹里有、现在没了。
        for path in snapshot.fingerprints.keys where currentPrints[path] == nil {
            fsChanged.insert(path)
        }
        return gitNew.union(fsChanged).sorted()
    }

    static func fingerprints(in directory: URL, maxEntries: Int = 20_000) async -> [String: String] {
        await Task.detached(priority: .utility) {
            scanSync(in: directory, captureContent: false, maxEntries: maxEntries).fingerprints
        }.value
    }

    // MARK: - 目录扫描（指纹 + 可选内容快照）

    struct Scan {
        var fingerprints: [String: String]
        var snapshots: [String: FileSnapshot]
    }

    /// 同步扫描（DirectoryEnumerator 的 for-in 在 async 上下文不可用，故枚举走这里）。
    /// captureContent 为 true 时一并读小文本文件内容做基线快照。
    static func scanSync(
        in directory: URL,
        captureContent: Bool,
        maxEntries: Int = 20_000,
        maxContentFiles: Int = 2_000,
        maxFileBytes: Int = 1_000_000,
        maxTotalContentBytes: Int = 25_000_000
    ) -> Scan {
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        let rootPath = root.path
        let excludedDirs: Set<String> = [
            ".git", "node_modules", ".build", "build", "dist", ".next", "out",
            ".venv", "venv", "__pycache__", ".swiftpm", "DerivedData", "Pods", "target", ".gradle"
        ]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return Scan(fingerprints: [:], snapshots: [:]) }

        var fingerprints: [String: String] = [:]
        var snapshots: [String: FileSnapshot] = [:]
        var contentFiles = 0
        var contentBytes = 0

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey
            ])
            if values?.isDirectory == true {
                if excludedDirs.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : path
            let size = values?.fileSize ?? 0
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            fingerprints[relative] = "\(size):\(mtime)"

            if captureContent, contentFiles < maxContentFiles {
                snapshots[relative] = makeSnapshot(
                    url: url, relative: relative, size: size,
                    maxFileBytes: maxFileBytes,
                    remainingBytes: maxTotalContentBytes - contentBytes
                )
                contentFiles += 1
                if let captured = snapshots[relative]?.text { contentBytes += captured.utf8.count }
            }

            if fingerprints.count >= maxEntries { break }
        }
        return Scan(fingerprints: fingerprints, snapshots: snapshots)
    }

    /// 为一个文件造内容快照：过大 / 超总量 → 不读正文（仅记元数据）；二进制（非 UTF-8）→ 标记 isBinary。
    private static func makeSnapshot(
        url: URL, relative: String, size: Int, maxFileBytes: Int, remainingBytes: Int
    ) -> FileSnapshot {
        guard size <= maxFileBytes, size <= remainingBytes else {
            return FileSnapshot(relativePath: relative, text: nil, isBinary: false, byteCount: size)
        }
        guard let data = try? Data(contentsOf: url) else {
            return FileSnapshot(relativePath: relative, text: nil, isBinary: false, byteCount: size)
        }
        if let text = String(data: data, encoding: .utf8) {
            return FileSnapshot(relativePath: relative, text: text, isBinary: false, byteCount: size)
        }
        return FileSnapshot(relativePath: relative, text: nil, isBinary: true, byteCount: size)
    }

    /// 兼容旧测试入口：仅指纹的同步扫描。
    static func fingerprintsSync(in directory: URL, maxEntries: Int = 20_000) -> [String: String] {
        scanSync(in: directory, captureContent: false, maxEntries: maxEntries).fingerprints
    }
}
