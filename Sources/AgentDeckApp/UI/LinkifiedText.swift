import Foundation

public enum LinkifiedText {
    public enum Part: Equatable, Sendable {
        case text(String)
        case file(label: String, relativePath: String)
        case webURL(String)
    }

    private struct Match {
        var range: Range<String.Index>
        var part: Part
        var priority: Int
    }

    public static func parts(in text: String, fileLinks: [String], workingDirectory: URL) -> [Part] {
        guard !text.isEmpty else { return [] }

        var matches: [Match] = []
        matches.append(contentsOf: urlMatches(in: text))
        matches.append(contentsOf: fileMatches(in: text, fileLinks: fileLinks))

        let selected = selectNonOverlapping(matches)
        guard !selected.isEmpty else { return [.text(text)] }

        var result: [Part] = []
        var cursor = text.startIndex
        for match in selected {
            if cursor < match.range.lowerBound {
                result.append(.text(String(text[cursor..<match.range.lowerBound])))
            }
            result.append(match.part)
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex {
            result.append(.text(String(text[cursor...])))
        }
        return mergeAdjacentText(result)
    }

    public static func fileURL(relativePath: String, workingDirectory: URL) -> URL {
        if relativePath.hasPrefix("/") {
            return URL(filePath: relativePath)
        }
        return workingDirectory.appending(path: relativePath)
    }

    /// 用工作目录快照解析文件 URL：直接相对路径 / label 相对路径 → 单次 `fileExists`（廉价）；
    /// 仍未命中则按文件名经快照兜底（O(1)，取代过去的整树递归枚举）。
    public static func resolvedFileURL(
        label: String,
        relativePath: String,
        workingDirectory: URL,
        snapshot: WorkspaceFileSnapshot,
        fileManager: FileManager = .default
    ) -> URL {
        let direct = fileURL(relativePath: relativePath, workingDirectory: workingDirectory)
        if snapshot.contains(relative: relativePath) || fileManager.fileExists(atPath: direct.path) {
            return direct
        }

        if label != relativePath {
            let labelPath = fileURL(relativePath: label, workingDirectory: workingDirectory)
            if snapshot.contains(relative: label) || fileManager.fileExists(atPath: labelPath.path) {
                return labelPath
            }
        }

        let targetName = URL(filePath: label).lastPathComponent.isEmpty
            ? URL(filePath: relativePath).lastPathComponent
            : URL(filePath: label).lastPathComponent
        guard !targetName.isEmpty,
              let found = snapshot.firstRelativePath(forBasename: targetName) else {
            return direct
        }
        return fileURL(relativePath: found, workingDirectory: workingDirectory)
    }

    /// 兼容旧调用点（无快照）：基于一次性快照解析。热路径请改用带 `snapshot:` 的重载，避免重复枚举。
    public static func resolvedFileURL(
        label: String,
        relativePath: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        resolvedFileURL(
            label: label,
            relativePath: relativePath,
            workingDirectory: workingDirectory,
            snapshot: WorkspaceFileSnapshot.build(directory: workingDirectory, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    public static func folderRelativePath(for fileURL: URL, workingDirectory: URL) -> String {
        let folder = fileURL.deletingLastPathComponent().standardizedFileURL.path
        let root = workingDirectory.standardizedFileURL.path
        if folder == root { return "." }
        if folder.hasPrefix(root + "/") {
            return String(folder.dropFirst(root.count + 1))
        }
        return folder
    }

    /// 在散文里抓出形如 `*.ext` 的 token，仅保留经工作目录快照确认存在的文件（返回相对路径）。
    /// 纯内存解析：不再对每个 token 走盘（更不会递归枚举整棵目录树）。
    public static func existingFileReferences(
        in text: String,
        snapshot: WorkspaceFileSnapshot
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let pattern = #"[^ \t\r\n\[\]\(\)<>"'，。！？、；：]+?\.[A-Za-z0-9]{1,12}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var links: [String] = []
        var seen = Set<String>()

        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let token = normalizedReferenceToken(String(text[range]))
            guard !token.isEmpty, let relative = snapshot.relativePath(forToken: token) else { continue }
            if seen.insert(relative).inserted {
                links.append(relative)
            }
        }
        return links.sorted()
    }

    /// 兼容旧调用点（无快照）：基于一次性快照检测。热路径请改用带 `snapshot:` 的重载。
    public static func existingFileReferences(
        in text: String,
        workingDirectory: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        existingFileReferences(
            in: text,
            snapshot: WorkspaceFileSnapshot.build(directory: workingDirectory, fileManager: fileManager)
        )
    }

    private static func urlMatches(in text: String) -> [Match] {
        let pattern = #"https?://[^\s<>\]\)"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let url = String(text[range])
            return Match(range: range, part: .webURL(url), priority: url.count + 10_000)
        }
    }

    private static func fileMatches(in text: String, fileLinks: [String]) -> [Match] {
        var matches: [Match] = []
        for path in Array(Set(fileLinks)).sorted(by: { $0.count > $1.count }) {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }

            var labels = [normalized]
            let basename = URL(filePath: normalized).lastPathComponent
            if !basename.isEmpty, basename != normalized { labels.append(basename) }

            for label in labels {
                matches.append(contentsOf: ranges(of: label, in: text).map {
                    Match(range: $0, part: .file(label: label, relativePath: normalized), priority: label.count)
                })
            }
        }
        return matches
    }

    private static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
              let range = haystack.range(of: needle, options: [], range: searchStart..<haystack.endIndex) {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func selectNonOverlapping(_ matches: [Match]) -> [Match] {
        let sorted = matches.sorted {
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.priority > $1.priority
        }

        var selected: [Match] = []
        for match in sorted {
            guard !selected.contains(where: { overlaps($0.range, match.range) }) else { continue }
            selected.append(match)
        }
        return selected.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    private static func overlaps(_ lhs: Range<String.Index>, _ rhs: Range<String.Index>) -> Bool {
        lhs.lowerBound < rhs.upperBound && rhs.lowerBound < lhs.upperBound
    }

    private static func mergeAdjacentText(_ parts: [Part]) -> [Part] {
        var result: [Part] = []
        for part in parts {
            if case .text(let text) = part,
               case .text(let previous) = result.last {
                result[result.count - 1] = .text(previous + text)
            } else {
                result.append(part)
            }
        }
        return result
    }

    private static func normalizedReferenceToken(_ token: String) -> String {
        var value = token
        let leading = CharacterSet(charactersIn: "`\"'“‘([{<")
        let trailing = CharacterSet(charactersIn: "`\"'”’)]}>.,;:!?，。！？、；：")
        value = value.trimmingCharacters(in: leading)
        value = value.trimmingCharacters(in: trailing)
        return value
    }
}
