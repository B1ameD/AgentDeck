import Foundation

/// 工作目录的「文件路径快照」：把一次有界递归枚举的结果固化为可同步查询的值类型，
/// 供链接渲染廉价地判断「某 token 是否是仓库里存在的文件」「按文件名兜底解析过期路径」，
/// 取代过去在每次渲染（尤其流式逐分片）里对整棵目录树反复递归走盘。
public struct WorkspaceFileSnapshot: Sendable, Equatable {
    /// 根目录下所有常规文件的相对路径（以 "/" 分隔，已去掉根前缀）。
    public let relativePaths: Set<String>
    /// 文件名（lastPathComponent）→ 对应相对路径列表，用于按文件名兜底解析。
    public let basenameToRelative: [String: [String]]
    /// 是否因命中条目上限而被截断（截断时兜底可能不完整）。
    public let truncated: Bool

    public static let empty = WorkspaceFileSnapshot(relativePaths: [], basenameToRelative: [:], truncated: false)

    public init(relativePaths: Set<String>, basenameToRelative: [String: [String]], truncated: Bool) {
        self.relativePaths = relativePaths
        self.basenameToRelative = basenameToRelative
        self.truncated = truncated
    }

    /// 散文里抓到的疑似文件名/相对路径若指向仓库内存在的文件，返回其相对路径；否则 nil。纯内存、O(1)。
    public func relativePath(forToken token: String) -> String? {
        let normalized = Self.normalize(token)
        guard !normalized.isEmpty else { return nil }
        if relativePaths.contains(normalized) { return normalized }
        // 直接相对路径未命中：按文件名兜底（取最短候选，贴近根优先）。
        return firstRelativePath(forBasename: (normalized as NSString).lastPathComponent)
    }

    /// 某相对路径是否存在于快照。
    public func contains(relative path: String) -> Bool {
        relativePaths.contains(Self.normalize(path))
    }

    /// 按文件名取一个存在的相对路径（贴近根优先），用于过期路径兜底。
    public func firstRelativePath(forBasename basename: String) -> String? {
        guard let candidates = basenameToRelative[basename], !candidates.isEmpty else { return nil }
        return candidates.min { lhs, rhs in
            lhs.count != rhs.count ? lhs.count < rhs.count : lhs < rhs
        }
    }

    /// 去掉前导 "./"、首尾空白，统一成相对索引里的键形态。
    static func normalize(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }

    /// 有界递归枚举：跳过隐藏项 / package 内容，排除重目录，达到上限即停。纯函数，可在任意线程构建。
    public static func build(
        directory: URL,
        maxEntries: Int = 20_000,
        fileManager: FileManager = .default
    ) -> WorkspaceFileSnapshot {
        let root = directory.standardizedFileURL
        let rootPath = root.path

        var relativePaths = Set<String>()
        var basenameToRelative: [String: [String]] = [:]
        var truncated = false

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .empty
        }

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            guard !relative.isEmpty else { continue }

            relativePaths.insert(relative)
            basenameToRelative[url.lastPathComponent, default: []].append(relative)

            if relativePaths.count >= maxEntries {
                truncated = true
                break
            }
        }

        return WorkspaceFileSnapshot(
            relativePaths: relativePaths,
            basenameToRelative: basenameToRelative,
            truncated: truncated
        )
    }

    /// 与源码无关 / 沉重的目录（枚举时整棵跳过）。点开头的目录已由 skipsHiddenFiles 跳过，这里补非点开头者。
    static let excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", ".next", ".gradle", ".venv",
        "node_modules", "DerivedData", "Pods", "build", "dist", "target",
        "venv", "__pycache__", ".mypy_cache", ".pytest_cache"
    ]
}

/// 按工作目录缓存 `WorkspaceFileSnapshot`：首次访问或被 invalidate 后有界重建，
/// 之后命中缓存供渲染同步查询。`version(for:)` 供渲染层纳入 renderKey，使「新文件出现 / 索引刷新」正确失效。
@MainActor
public final class WorkspaceFileIndex {
    public static let shared = WorkspaceFileIndex()

    private struct Entry {
        var snapshot: WorkspaceFileSnapshot
        var version: Int
        var dirty = false
    }

    private var cache: [String: Entry] = [:]
    /// 单调递增的版本号：任一目录快照**内容变化**时自增。
    private var globalVersion = 0

    /// `ttl` 保留为兼容测试/旧调用；索引不再按时间在渲染路径自动过期，避免滚动时主线程递归枚举项目。
    public init(ttl: TimeInterval = 3) {
    }

    /// 取某目录的缓存快照（必要时有界重建）。
    public func snapshot(for directory: URL) -> WorkspaceFileSnapshot {
        ensureFresh(directory).snapshot
    }

    /// 取某目录当前快照的版本号（必要时有界重建）。
    public func version(for directory: URL) -> Int {
        ensureFresh(directory).version
    }

    /// 标记某目录索引待刷新（如 agent 跑完后调用）。下次访问重建快照；
    /// **内容没变则版本号不动**——版本号进了每条消息的 renderKey,无谓 bump 会让
    /// 所有可见气泡全量重设文本:正在进行的选中被刷掉、链接闪烁(#6 不稳定根因)。
    public func invalidate(_ directory: URL) {
        cache[key(for: directory)]?.dirty = true
    }

    public func invalidateAll() {
        for cacheKey in cache.keys {
            cache[cacheKey]?.dirty = true
        }
    }

    private func ensureFresh(_ directory: URL) -> Entry {
        let cacheKey = key(for: directory)
        if let entry = cache[cacheKey], !entry.dirty {
            return entry
        }
        let snapshot = WorkspaceFileSnapshot.build(directory: directory)
        if var entry = cache[cacheKey] {
            // 瞬态枚举失败会返回空快照:目录仍在且旧快照非空时保留旧值,避免链接集体消失。
            let transientFailure = snapshot.relativePaths.isEmpty
                && !entry.snapshot.relativePaths.isEmpty
                && FileManager.default.fileExists(atPath: directory.standardizedFileURL.path)
            if !transientFailure, entry.snapshot != snapshot {
                globalVersion += 1
                entry.snapshot = snapshot
                entry.version = globalVersion
            }
            entry.dirty = false
            cache[cacheKey] = entry
            return entry
        }
        globalVersion += 1
        let entry = Entry(snapshot: snapshot, version: globalVersion)
        cache[cacheKey] = entry
        return entry
    }

    private func key(for directory: URL) -> String {
        directory.standardizedFileURL.path
    }
}
