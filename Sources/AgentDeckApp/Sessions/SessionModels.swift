import Foundation

public struct ChatMessage: Identifiable, Equatable, Sendable, Codable {
    public enum Role: String, Equatable, Sendable, Codable {
        case user
        case assistant
        case system
        case error
    }

    /// 消息种类。`changeReview` 标记「改动审核」消息——本轮 agent 改动的文件清单（路径在 fileLinks），
    /// UI 据此渲染成审核摘要 + 「审核改动」入口，而非普通 markdown 文本。
    public enum Kind: String, Equatable, Sendable, Codable {
        case normal
        case changeReview
    }

    public let id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    public var fileLinks: [String]
    public var toolCalls: [String]
    public var kind: Kind
    public var turnDiffSummary: TurnDiffSummary?
    /// 本轮 agent 运行起止时间。仅 assistant 输出消息使用；旧历史记录为空。
    public var runStartedAt: Date?
    public var runEndedAt: Date?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        fileLinks: [String] = [],
        toolCalls: [String] = [],
        kind: Kind = .normal,
        turnDiffSummary: TurnDiffSummary? = nil,
        runStartedAt: Date? = nil,
        runEndedAt: Date? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.fileLinks = fileLinks
        self.toolCalls = toolCalls
        self.kind = kind
        self.turnDiffSummary = turnDiffSummary
        self.runStartedAt = runStartedAt
        self.runEndedAt = runEndedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case fileLinks
        case toolCalls
        case kind
        case turnDiffSummary
        case runStartedAt
        case runEndedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        fileLinks = try container.decodeIfPresent([String].self, forKey: .fileLinks) ?? []
        toolCalls = try container.decodeIfPresent([String].self, forKey: .toolCalls) ?? []
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .normal
        turnDiffSummary = try container.decodeIfPresent(TurnDiffSummary.self, forKey: .turnDiffSummary)
        runStartedAt = try container.decodeIfPresent(Date.self, forKey: .runStartedAt)
        runEndedAt = try container.decodeIfPresent(Date.self, forKey: .runEndedAt)
    }
}

public enum SessionStatus: Equatable, Sendable {
    case idle
    case running
    case failed(String)
}

public enum WorkspaceLayout: Int, CaseIterable, Equatable, Sendable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
}

public enum ReasoningEffort: String, CaseIterable, Equatable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    /// 选择器展示名。rawValue（low/medium/high/xhigh/max）直接喂给 CLI（如 claude --effort）。
    public var label: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "X-High"
        case .max: "Max"
        }
    }
}

public enum InteractionMode: String, CaseIterable, Equatable, Sendable {
    case plan
    case build

    public static func restore(_ storedValue: String?) -> InteractionMode {
        storedValue == plan.rawValue ? .plan : .build
    }
}

public enum AgentCommand: String, CaseIterable, Equatable, Sendable {
    case new
    case resume
    case continueLast
}

public enum PromptOptimizationResult: Equatable, Sendable {
    case success(String)
    case failure(String)
}

/// 内联工具活动标记。把一次工具调用的中文摘要（如「读取 foo.swift」）用控制字符包裹后
/// 直接嵌进 assistant 文本流中，让工具状态按**时间顺序**穿插在输出文本里
/// （参考 Codex / Claude Code 的「⏺ 运行 / 编辑 / 创建」），而非收拢成单独一块。
///
/// 分隔符用 U+001F（单元分隔符）：它在模型正文里几乎不可能出现，故不会与正常内容冲突，
/// 即便意外漏到界面上也不可见。展示层用 `segments(in:)` 把文本切回「普通文本 / 工具活动」。
public enum ToolActivity {
    static let open = "\u{1F}tool\u{1F}"
    static let close = "\u{1F}/tool\u{1F}"

    public struct FileTarget: Equatable, Sendable {
        public let prefix: String
        /// 用于界面展示的短标签（仅文件名）。
        public let path: String
        /// 用于右键“复制相对链接”的路径；工作区外文件回落为原始路径。
        public let relativePath: String
        /// 真实文件 URL，用于点击打开和复制绝对链接。
        public let url: URL
    }

    public enum DisplayPart: Equatable, Sendable {
        case text(String)
        case file(FileTarget)
    }

    /// 把工具摘要包成内联标记，供 AgentSession 追加到 assistant 文本。
    public static func marker(_ summary: String) -> String {
        open + summary + close
    }

    public enum Segment: Equatable, Sendable {
        case text(String)
        case tool(String)
    }

    /// 把含内联工具标记的文本切成有序段：普通文本与工具活动按出现顺序交替。
    public static func segments(in text: String) -> [Segment] {
        guard text.contains(open) else { return [.text(text)] }

        var segments: [Segment] = []
        var rest = Substring(text)
        while let openRange = rest.range(of: open) {
            let before = rest[rest.startIndex..<openRange.lowerBound]
            if !before.isEmpty { segments.append(.text(String(before))) }

            let afterOpen = rest[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: close) else {
                // 未闭合（理论上不会发生，标记总是整段追加）：剩余整体当作工具活动。
                if !afterOpen.isEmpty { segments.append(.tool(String(afterOpen))) }
                return segments
            }
            let tool = afterOpen[afterOpen.startIndex..<closeRange.lowerBound]
            if !tool.isEmpty { segments.append(.tool(String(tool))) }
            rest = afterOpen[closeRange.upperBound...]
        }
        if !rest.isEmpty { segments.append(.text(String(rest))) }
        return segments
    }

    /// 移除文本里所有内联工具标记（连同摘要）。用于历史回放给模型、纯文本场景等不需要工具行处。
    public static func strip(from text: String) -> String {
        guard text.contains(open) else { return text }
        return segments(in: text).reduce(into: "") { accumulated, segment in
            if case .text(let value) = segment { accumulated += value }
        }
    }

    /// 工具活动的展示切片：整行扫描工作区/绝对/相对路径，界面只显示最后一级名称，
    /// 但保留真实 URL 与相对路径，供点击和右键菜单使用。
    public static func displayParts(in summary: String, workingDirectory: URL) -> [DisplayPart] {
        guard !summary.isEmpty else { return [] }
        if summary.hasPrefix("运行 ") {
            return [.text(displayRunCommand(in: summary, workingDirectory: workingDirectory))]
        }

        let pattern = #"(?:~|/|\.\.?/|[A-Za-z0-9_.-]+/)[^\s"'`<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(summary)] }

        let nsRange = NSRange(summary.startIndex..<summary.endIndex, in: summary)
        let matches = regex.matches(in: summary, range: nsRange)
        guard !matches.isEmpty else { return [.text(summary)] }

        var parts: [DisplayPart] = []
        var cursor = summary.startIndex
        for match in matches {
            guard let matchRange = Range(match.range, in: summary) else { continue }
            let raw = String(summary[matchRange])
            guard !raw.contains("://"),
                  let split = splitPathCandidate(raw),
                  let target = fileTarget(forRawPath: split.path, prefix: "", workingDirectory: workingDirectory) else {
                continue
            }

            if cursor < matchRange.lowerBound {
                appendDisplayText(String(summary[cursor..<matchRange.lowerBound]), to: &parts)
            }
            parts.append(.file(target))
            appendDisplayText(split.suffix, to: &parts)
            cursor = matchRange.upperBound
        }

        if cursor < summary.endIndex {
            appendDisplayText(String(summary[cursor...]), to: &parts)
        }
        return parts.isEmpty ? [.text(summary)] : parts
    }

    public static func displayText(in summary: String, workingDirectory: URL) -> String {
        displayParts(in: summary, workingDirectory: workingDirectory)
            .map { part in
                switch part {
                case .text(let text): text
                case .file(let target): target.path
                }
            }
            .joined()
    }

    private struct ShellToken {
        let value: String
        let range: Range<String.Index>
        let wrappingQuote: Character?
    }

    private static let scriptInterpreters: Set<String> = [
        "bash", "node", "python", "python3", "ruby", "sh", "zsh"
    ]

    private static func displayRunCommand(in summary: String, workingDirectory: URL) -> String {
        let prefix = "运行 "
        let command = String(summary.dropFirst(prefix.count))
        guard let executableToken = shellPrefixTokens(in: command, limit: 1).first else {
            return summary
        }

        let executable = URL(filePath: executableToken.value).lastPathComponent
        let target: ShellToken
        if scriptInterpreters.contains(executable) {
            let tokens = shellPrefixTokens(in: command, limit: 2)
            guard tokens.count == 2 else { return summary }
            target = tokens[1]
        } else {
            target = executableToken
        }

        guard isAbsoluteWorkspacePath(target.value, workingDirectory: workingDirectory) else {
            return summary
        }

        let basename = URL(filePath: target.value).lastPathComponent
        guard !basename.isEmpty else { return summary }

        let replacement: String
        if let quote = target.wrappingQuote, basename.contains(where: { $0.isWhitespace }) {
            replacement = "\(quote)\(basename)\(quote)"
        } else {
            replacement = basename
        }

        var compactCommand = command
        compactCommand.replaceSubrange(target.range, with: replacement)
        return prefix + compactCommand
    }

    private static func shellPrefixTokens(in command: String, limit: Int) -> [ShellToken] {
        var tokens: [ShellToken] = []
        var cursor = command.startIndex

        while cursor < command.endIndex, tokens.count < limit {
            while cursor < command.endIndex, command[cursor].isWhitespace {
                cursor = command.index(after: cursor)
            }
            guard cursor < command.endIndex,
                  !isAmbiguousShellOperator(at: cursor, in: command) else {
                return []
            }

            let start = cursor
            let wrappingQuote: Character? = command[cursor] == "'" || command[cursor] == "\""
                ? command[cursor]
                : nil
            var activeQuote: Character?
            var value = ""
            var escaped = false

            while cursor < command.endIndex {
                let character = command[cursor]

                if escaped {
                    value.append(character)
                    escaped = false
                    cursor = command.index(after: cursor)
                    continue
                }
                if character == "\\", activeQuote != "'" {
                    escaped = true
                    cursor = command.index(after: cursor)
                    continue
                }
                if let quote = activeQuote {
                    if character == quote {
                        activeQuote = nil
                    } else {
                        value.append(character)
                    }
                    cursor = command.index(after: cursor)
                    continue
                }
                if character == "'" || character == "\"" {
                    activeQuote = character
                    cursor = command.index(after: cursor)
                    continue
                }
                if character.isWhitespace {
                    break
                }
                if isAmbiguousShellOperator(at: cursor, in: command) {
                    return []
                }

                value.append(character)
                cursor = command.index(after: cursor)
            }

            guard activeQuote == nil, !escaped, !value.isEmpty else { return [] }
            tokens.append(ShellToken(
                value: value,
                range: start..<cursor,
                wrappingQuote: wrappingQuote
            ))
        }

        return tokens
    }

    private static func isAmbiguousShellOperator(at index: String.Index, in command: String) -> Bool {
        let character = command[index]
        if "|;<>`".contains(character) { return true }
        guard character == "$" else { return false }

        let next = command.index(after: index)
        return next < command.endIndex && command[next] == "("
    }

    private static func isAbsoluteWorkspacePath(_ path: String, workingDirectory: URL) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let filePath = URL(filePath: path).standardizedFileURL.path
        let root = workingDirectory.standardizedFileURL.path
        return filePath == root || filePath.hasPrefix(root + "/")
    }

    /// 「文件类」动词：其摘要的参数是一个文件路径，可解析成可点击链接（点开在右侧栏显示）。
    private static let fileVerbs: Set<String> = ["读取", "编辑", "创建", "编辑笔记本"]

    /// 把「动词 路径」形态的工具摘要解析成文件链接目标：前缀（含动词与空格）、显示路径、解析后的绝对 URL。
    /// 非文件动词、无参数、或路径被截断（以 … 结尾、无法可靠定位）时返回 nil。
    public static func fileTarget(in summary: String, workingDirectory: URL) -> FileTarget? {
        guard let space = summary.firstIndex(of: " ") else { return nil }
        let verb = String(summary[..<space])
        guard fileVerbs.contains(verb) else { return nil }

        let rawPath = String(summary[summary.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty, !rawPath.hasSuffix("…") else { return nil }

        return fileTarget(forRawPath: rawPath, prefix: verb + " ", workingDirectory: workingDirectory)
    }

    private static func fileTarget(forRawPath rawPath: String, prefix: String, workingDirectory: URL) -> FileTarget? {
        guard !rawPath.isEmpty, !rawPath.hasSuffix("…") else { return nil }

        let url: URL
        if rawPath.hasPrefix("/") {
            url = URL(filePath: rawPath)
        } else if rawPath.hasPrefix("~") {
            url = URL(filePath: (rawPath as NSString).expandingTildeInPath)
        } else {
            url = workingDirectory.appending(path: rawPath)
        }

        let filename = url.lastPathComponent.isEmpty ? rawPath : url.lastPathComponent
        return FileTarget(
            prefix: prefix,
            path: filename,
            relativePath: relativePath(for: url, originalPath: rawPath, workingDirectory: workingDirectory),
            url: url
        )
    }

    private static func splitPathCandidate(_ raw: String) -> (path: String, suffix: String)? {
        var path = raw
        var suffix = ""
        let trailing = CharacterSet(charactersIn: ".,;:!?)]}，。！？、；：")
        while let scalar = path.unicodeScalars.last, trailing.contains(scalar) {
            suffix = String(scalar) + suffix
            path.removeLast()
        }
        return path.isEmpty ? nil : (path, suffix)
    }

    private static func appendDisplayText(_ text: String, to parts: inout [DisplayPart]) {
        guard !text.isEmpty else { return }
        if case .text(let previous) = parts.last {
            parts[parts.count - 1] = .text(previous + text)
        } else {
            parts.append(.text(text))
        }
    }

    private static func relativePath(for url: URL, originalPath: String, workingDirectory: URL) -> String {
        let filePath = url.standardizedFileURL.path
        let root = workingDirectory.standardizedFileURL.path
        if filePath == root { return url.lastPathComponent }
        if filePath.hasPrefix(root + "/") {
            return String(filePath.dropFirst(root.count + 1))
        }
        return originalPath
    }
}
