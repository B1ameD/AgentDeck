import Foundation

/// 单个文件的解析后 diff：若干 hunk + 是否二进制。增删计数由解析行直接得出。
public struct FileDiff: Equatable, Sendable, Codable {
    public var hunks: [DiffHunk]
    public var isBinary: Bool

    public init(hunks: [DiffHunk], isBinary: Bool) {
        self.hunks = hunks
        self.isBinary = isBinary
    }

    public static let empty = FileDiff(hunks: [], isBinary: false)

    public var addedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.lazy.filter { $0.kind == .addition }.count }
    }

    public var removedCount: Int {
        hunks.reduce(0) { $0 + $1.lines.lazy.filter { $0.kind == .deletion }.count }
    }

    /// 既无 hunk 也非二进制（无可视差异）。
    public var isEmpty: Bool { hunks.isEmpty && !isBinary }
}

/// 一个 hunk：`@@ -a,b +c,d @@` 头 + 若干带行号的行。
public struct DiffHunk: Equatable, Sendable, Codable {
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

/// diff 里的一行：种类 + 旧/新行号（不适用的一侧为 nil）+ 去掉前导标记的正文。
public struct DiffLine: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        case context
        case addition
        case deletion
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String

    public init(kind: Kind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

/// 解析 git 统一 diff（`git diff` / `git diff --no-index`）为结构化 `FileDiff`。纯函数，便于测试。
public enum UnifiedDiffParser {
    public static func parse(_ diff: String) -> FileDiff {
        guard !diff.isEmpty else { return .empty }

        var hunks: [DiffHunk] = []
        var isBinary = false
        var currentHeader: String?
        var currentLines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flush() {
            if let header = currentHeader {
                hunks.append(DiffHunk(header: header, lines: currentLines))
            }
            currentHeader = nil
            currentLines = []
        }

        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if raw.hasPrefix("Binary files"), raw.hasSuffix("differ") {
                isBinary = true
                continue
            }
            if isMetadataLine(raw) { continue }

            if raw.hasPrefix("@@") {
                flush()
                let (oldStart, newStart) = parseHunkHeader(raw)
                oldLine = oldStart
                newLine = newStart
                currentHeader = raw
                continue
            }

            // hunk 之外的内容（及切分尾部的空串）忽略。
            guard currentHeader != nil, let marker = raw.first else { continue }

            let body = String(raw.dropFirst())
            switch marker {
            case "+":
                currentLines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newLine, text: body))
                newLine += 1
            case "-":
                currentLines.append(DiffLine(kind: .deletion, oldNumber: oldLine, newNumber: nil, text: body))
                oldLine += 1
            case " ":
                currentLines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: body))
                oldLine += 1
                newLine += 1
            default:
                break // "\ No newline…" 已在 metadata 过滤；其余异常行跳过。
            }
        }
        flush()

        return FileDiff(hunks: hunks, isBinary: isBinary)
    }

    /// 解析 hunk 头取旧/新起始行号：`@@ -a,b +c,d @@`（计数省略时记为 1 行）。
    static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let oldRange = Range(match.range(at: 1), in: header),
              let newRange = Range(match.range(at: 2), in: header) else {
            return (1, 1)
        }
        return (Int(header[oldRange]) ?? 1, Int(header[newRange]) ?? 1)
    }

    /// diff 元数据行（不计入 hunk 内容）。
    private static func isMetadataLine(_ line: String) -> Bool {
        let prefixes = [
            "diff --git", "index ", "--- ", "+++ ",
            "new file mode", "deleted file mode", "old mode", "new mode",
            "similarity index", "dissimilarity index", "rename ", "copy ",
            "\\ No newline"
        ]
        return prefixes.contains { line.hasPrefix($0) }
    }
}
