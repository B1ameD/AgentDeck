import Foundation

/// AskUserQuestion 工具的结构化问题（解析自 Claude stream-json 的 tool_use input）。
///
/// AgentDeck 以 `-p` 非交互方式运行 Claude，无法把答案回灌进**同一**进程（没有 stdin 回传通道），
/// 因此把问题渲染成可点选卡片：用户选完后，选择作为**下一轮**消息发出。Claude 会话续接（--resume），
/// 能看到自己刚才的提问与用户的选择，从而继续——这就把原本「卡住、无弹窗」的工具变得可用。
public struct AskUserQuestion: Equatable, Sendable, Codable {
    public struct Option: Equatable, Sendable, Codable, Identifiable {
        public var label: String
        public var description: String
        public var id: String { label }
        public init(label: String, description: String = "") {
            self.label = label
            self.description = description
        }
    }

    public struct Item: Equatable, Sendable, Codable, Identifiable {
        public var header: String
        public var question: String
        public var multiSelect: Bool
        public var options: [Option]
        public var id: String { header + "\u{1F}" + question }

        public init(header: String, question: String, multiSelect: Bool, options: [Option]) {
            self.header = header
            self.question = question
            self.multiSelect = multiSelect
            self.options = options
        }

        /// 卡片标题：优先用 question，回退 header。
        public var title: String { question.isEmpty ? header : question }
    }

    public var questions: [Item]
    /// opencode `question.asked` 的回传句柄：非空 → 答案经 POST /question/{requestID}/reply 回传给运行中的 agent。
    /// Claude 为 nil（答案作为下一条消息追加）。
    public var requestID: String?
    /// 仅运行时：Claude 经 AgentDeck 内置 MCP `ask_user` 工具阻塞提问时的回传句柄（不持久化）。
    /// 非空 → 答案经 AskUserBroker 唤醒挂起的工具调用，Claude 原地继续。
    public var mcpRequestID: String? = nil

    public init(questions: [Item], requestID: String? = nil) {
        self.questions = questions
        self.requestID = requestID
    }

    // mcpRequestID 是运行时句柄，不入 Codable（重载历史时不应残留）。
    private enum CodingKeys: String, CodingKey {
        case questions
        case requestID
    }

    /// 持久化 / 历史 / 复制用的纯文本回退（卡片不可用场景）。
    public var plainSummary: String {
        let lines = questions.map { item -> String in
            "❓ \(item.title)\n选项：\(item.options.map(\.label).joined(separator: " / "))"
        }
        return (["需要你的选择："] + lines).joined(separator: "\n")
    }
}

/// 一次可持久化的提问工具记录。运行时卡片与回答后的折叠详情共用同一条记录，
/// 因此关闭并重开会话后不会重新变成可作答状态。
public struct QuestionToolRecord: Equatable, Sendable, Codable, Identifiable {
    public enum Resolution: Equatable, Sendable, Codable {
        case pending
        case answered([[String]])
        case skipped
    }

    public let id: UUID
    public var question: AskUserQuestion
    public private(set) var resolution: Resolution

    public init(
        id: UUID = UUID(),
        question: AskUserQuestion,
        resolution: Resolution = .pending
    ) {
        self.id = id
        self.question = question
        self.resolution = resolution
    }

    public var isPending: Bool {
        resolution == .pending
    }

    public mutating func answer(_ selections: [[String]]) {
        resolution = .answered(selections)
    }

    public mutating func skip() {
        resolution = .skipped
    }

    public var detailLines: [String] {
        switch resolution {
        case .pending:
            return question.questions.flatMap { item in
                [
                    "Question：\(item.title)",
                    "Choose：等待回答"
                ]
            }
        case .answered(let selections):
            return zip(question.questions, selections).flatMap { item, labels in
                [
                    "Question：\(item.title)",
                    "Choose：\(labels.joined(separator: " / "))"
                ]
            }
        case .skipped:
            return question.questions.flatMap { item in
                [
                    "Question：\(item.title)",
                    "Choose：已跳过"
                ]
            }
        }
    }
}

/// 从 Claude 工具调用 input 解析 AskUserQuestion（纯函数，便于测试）。
public enum AskUserQuestionParser {
    /// 工具名是否为 AskUserQuestion（容忍下划线 / 复数等写法差异）。
    public static func isAskUserQuestion(toolName: String) -> Bool {
        let normalized = toolName.lowercased().replacingOccurrences(of: "_", with: "")
        return normalized == "askuserquestion" || normalized == "askuserquestions"
    }

    /// 从工具 input JSON 解析问题；结构不符合（无 questions / 无选项）则返回 nil，由调用方回落普通工具行。
    public static func parse(inputJSON: String) -> AskUserQuestion? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(object: object)
    }

    static func parse(object: [String: Any]) -> AskUserQuestion? {
        let requestID = object["requestID"] as? String
        let nested = object["input"] as? [String: Any] // opencode：questions 嵌在 input 下
        // 嵌套形态：{questions:[{question, header, options:[{label,description}], multiple}, ...]}（Claude 顶层 / opencode input 下）。
        let rawQuestions = (object["questions"] as? [[String: Any]]) ?? (nested?["questions"] as? [[String: Any]])
        if let rawQuestions {
            let items = rawQuestions.compactMap(parseItem)
            if !items.isEmpty { return AskUserQuestion(questions: items, requestID: requestID) }
        }
        // 扁平单问形态（{question|message|prompt, options|choices:[...]}）：先看顶层，再看 input。
        if let item = parseItem(object) { return AskUserQuestion(questions: [item], requestID: requestID) }
        if let nested, let item = parseItem(nested) { return AskUserQuestion(questions: [item], requestID: requestID) }
        return nil
    }

    /// 从工具 input 抽出一句可读的问题文本（无结构化选项时的兜底提示用）。
    public static func fallbackPrompt(inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return questionText(in: object)
    }

    private static func parseItem(_ raw: [String: Any]) -> AskUserQuestion.Item? {
        let question = questionText(in: raw) ?? ""
        let header = (raw["header"] as? String) ?? ""
        let multiSelect = (raw["multiSelect"] as? Bool) ?? (raw["multiple"] as? Bool) ?? false
        let options = parseOptions(raw["options"] ?? raw["choices"] ?? raw["answers"])
        guard !options.isEmpty, !(question.isEmpty && header.isEmpty) else { return nil }
        return AskUserQuestion.Item(
            header: header,
            question: question,
            multiSelect: multiSelect,
            options: options
        )
    }

    /// 兼容不同 agent 的问题字段名：question / message / prompt / title。
    private static func questionText(in raw: [String: Any]) -> String? {
        for key in ["question", "message", "prompt", "title"] {
            if let text = raw[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    /// 选项既可能是 `{label, description}` 对象，也可能是裸字符串。
    private static func parseOptions(_ value: Any?) -> [AskUserQuestion.Option] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { element in
            if let string = element as? String, !string.isEmpty {
                return AskUserQuestion.Option(label: string)
            }
            if let object = element as? [String: Any],
               let label = (object["label"] as? String) ?? (object["value"] as? String) ?? (object["text"] as? String),
               !label.isEmpty {
                return AskUserQuestion.Option(label: label, description: (object["description"] as? String) ?? "")
            }
            return nil
        }
    }
}
