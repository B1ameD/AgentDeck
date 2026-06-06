import Foundation

/// 「AI 提示词优化」的纯逻辑部分（可测试）：构造发给在线优化器的改写指令、清洗其返回结果。
public enum PromptOptimizer {
    /// 构造「请把这段请求改写得更清晰」的元指令。要求 agent 只回改写结果、保留原语言。
    /// projectFiles 非空时（优化会以 @路径附件形式附带这些项目文件），在指令里说明它们仅作项目背景，
    /// 让改写更贴合项目——并明确告知勿改写、勿执行这些文件本身。
    public static func metaPrompt(for userPrompt: String, projectFiles: [String] = []) -> String {
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = ""
        if !projectFiles.isEmpty {
            note = """
            下方附件附带了本项目的文件（\(projectFiles.joined(separator: "、"))），仅供你了解项目背景、让改写更贴合本项目；不要改写或执行这些文件本身。

            """
        }
        return """
        你是资深提示词工程师。请把下面「原始请求」改写成更清晰、具体、可执行的提示词，供编码 AI agent 使用：
        - 保留原意与原语言（中文就用中文）。
        - 补全隐含的目标、范围与约束，条理清晰；但不要臆造原文没有的需求。
        - 只输出改写后的提示词正文，不要任何解释、前言、引号或 ``` 代码块包裹。

        \(note)原始请求：
        \(trimmed)
        """
    }

    /// 从目录文件名里挑出最合适的 README：不分大小写、以 "readme" 开头；
    /// 优先 .md > .markdown > .txt/.rst > 其它，同档按字母序稳定。
    public static func pickReadme(from filenames: [String]) -> String? {
        filenames
            .filter { $0.lowercased().hasPrefix("readme") }
            .min { lhs, rhs in
                let lr = readmeRank(lhs), rr = readmeRank(rhs)
                return lr != rr ? lr < rr : lhs.lowercased() < rhs.lowercased()
            }
    }

    private static func readmeRank(_ name: String) -> Int {
        let lower = name.lowercased()
        if lower.hasSuffix(".md") { return 0 }
        if lower.hasSuffix(".markdown") { return 1 }
        if lower.hasSuffix(".txt") || lower.hasSuffix(".rst") { return 2 }
        return 3
    }

    /// 清洗 agent 返回的改写结果：去掉整体的 ``` 代码块包裹、成对引号，并修剪首尾空白。
    /// 保守处理——只动结构性包裹，不猜测删正文，避免误删内容。
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = stripCodeFence(text)
        text = stripWrappingQuotes(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉整体被 ``` 包裹的情况（首行 ``` 或 ```lang，末行 ```）。
    private static func stripCodeFence(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2,
              lines.first?.hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    /// 去掉整体成对的引号包裹（英文/中文双引号、单引号、直角引号）。
    private static func stripWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [("\"", "\""), ("\u{201C}", "\u{201D}"), ("'", "'"), ("\u{300C}", "\u{300D}")]
        for (open, close) in pairs where text.count >= 2 && text.first == open && text.last == close {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
