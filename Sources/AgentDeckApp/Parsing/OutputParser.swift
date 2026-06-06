import Foundation

public struct OutputEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message
        case status
        case tool
        case error
    }

    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public final class OutputParser {
    public let mode: AgentConfig.OutputMode
    private var pendingJSONL = ""
    /// 本轮是否已产出过「答案正文」（非思考块）。用于让最终的 assistant / result 事件：
    /// 流式后端已逐字产出时不重复；非流式后端（只给整段 assistant）时兜底产出，避免答案被丢弃。
    private var emittedAnswerText = false
    /// 流式中的工具调用：start 时记下工具名、delta 累积 input JSON、stop 时汇成一行紧凑摘要。
    /// 只摘要「工具调用」（如读了哪个文件），不把庞大的工具结果灌进聊天——避免刷屏。
    private var pendingToolName: String?
    private var pendingToolInput = ""        // 来自 input_json_delta 的分片累积
    private var pendingToolStartInput = ""   // content_block_start 自带的完整 input（部分实现一次性给出）

    public init(mode: AgentConfig.OutputMode) {
        self.mode = mode
    }

    public func parse(_ chunk: String) -> [OutputEvent] {
        switch mode {
        case .stream:
            return chunk.isEmpty ? [] : [OutputEvent(kind: .message, text: chunk)]
        case .ansiStream:
            let stripped = stripANSI(chunk)
            return stripped.isEmpty ? [] : [OutputEvent(kind: .message, text: stripped)]
        case .jsonLines:
            pendingJSONL += chunk
            return drainJSONLBuffer(keepingTrailingPartial: true)
        }
    }

    public func flush() -> [OutputEvent] {
        guard mode == .jsonLines else { return [] }
        defer { pendingJSONL = "" }
        return drainJSONLBuffer(keepingTrailingPartial: false)
    }

    private func drainJSONLBuffer(keepingTrailingPartial: Bool) -> [OutputEvent] {
        var events: [OutputEvent] = []

        while let newlineIndex = pendingJSONL.firstIndex(of: "\n") {
            let line = String(pendingJSONL[..<newlineIndex])
            pendingJSONL.removeSubrange(...newlineIndex)
            if !line.isEmpty, let event = parseJSONLine(line) {
                events.append(event)
            }
        }

        guard !keepingTrailingPartial, !pendingJSONL.isEmpty else {
            return events
        }

        let trailing = pendingJSONL
        pendingJSONL = ""
        if let event = parseJSONLine(trailing) {
            events.append(event)
        }
        return events
    }

    private func parseJSONLine(_ line: String) -> OutputEvent? {
        let event = classify(line)
        // 标记本轮已产出过答案正文（思考块以 <think> 包裹，不计入），供 assistant/result 去重与兜底判断。
        if let event, event.kind == .message, !event.text.hasPrefix("<think>") {
            emittedAnswerText = true
        }
        return event
    }

    private func classify(_ line: String) -> OutputEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return OutputEvent(kind: .error, text: line)
        }

        if let errorText = Self.errorText(in: object) {
            return OutputEvent(kind: .error, text: errorText)
        }

        let type = object["type"] as? String
        let text = Self.messageText(in: object)
        switch type {
        case "stream_event":
            return streamEvent(in: object)
        case "status":
            return text.map { OutputEvent(kind: .status, text: $0) }
        case "error":
            return OutputEvent(kind: .error, text: text ?? line)
        case "reasoning", "thinking", "thought":
            return text.map { OutputEvent(kind: .message, text: Self.thinkingBlock($0)) }
        case "assistant":
            // 非流式后端（部分第三方 Anthropic 兼容中转站）只在最终 assistant 事件里给整段答案、
            // 不发 content_block_delta。本轮还没产出过答案正文时用它兜底，避免答案被整段丢弃；
            // 流式后端此时已逐字产出过，跳过以免重复。
            if !emittedAnswerText, let text, !text.isEmpty {
                return OutputEvent(kind: .message, text: text)
            }
            return nil
        case "result":
            let resultText = object["result"] as? String
            if object["is_error"] as? Bool == true {
                // 已由 assistant 兜底显示过同样文本就不再重复报错；否则用 result 里的可读错误文本。
                return emittedAnswerText ? nil : OutputEvent(kind: .error, text: resultText ?? text ?? line)
            }
            // 极端兜底：既没流式也没 assistant 文本时，用 result 的最终文本。
            if !emittedAnswerText, let resultText, !resultText.isEmpty {
                return OutputEvent(kind: .message, text: resultText)
            }
            return nil
        case "user":
            // Claude 的工具结果以顶层 {"type":"user", content:[{type:"tool_result", content:"..."}]} 回灌，
            // 内容可能极大（文件全文 / 命令输出）。**不**把它当普通文本灌进聊天（否则刷屏）——
            // 工具调用已由 content_block_start 的 tool_use 摘要过；这里仅在工具报错时给一行紧凑提示。
            return Self.toolResultError(in: object).map { OutputEvent(kind: .tool, text: $0) }
        case "tool_use":
            // OpenCode `run --format json` 在工具完成/失败时输出：
            // {"type":"tool_use","part":{"type":"tool","tool":"read","state":{...}}}
            // 同样只展示调用摘要，不把 output 灌进聊天。
            return Self.openCodeToolEvent(in: object)
        case "thread.started", "thread.completed", "turn.started", "turn.completed", "step_start", "step_finish":
            return nil
        case "item.completed":
            if let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = Self.messageText(in: item) {
                return OutputEvent(kind: .message, text: text)
            }
            if let item = object["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               ["reasoning", "thinking", "thought"].contains(itemType),
               let text = Self.messageText(in: item) {
                return OutputEvent(kind: .message, text: Self.thinkingBlock(text))
            }
            return nil
        default:
            // OpenCode 等：以 part.type 标记内容类型。reasoning/thinking 的 part 折叠为思考块，
            // 与 Claude 的 thinking 一致地走可折叠「思考过程」UI（之前会被当普通正文直接铺开）。
            if let part = object["part"] as? [String: Any],
               let partType = (part["type"] as? String)?.lowercased(),
               ["reasoning", "thinking", "thought"].contains(partType) {
                return Self.messageText(in: part).map { OutputEvent(kind: .message, text: Self.thinkingBlock($0)) }
            }
            return text.map { OutputEvent(kind: .message, text: $0) }
        }
    }

    private func streamEvent(in object: [String: Any]) -> OutputEvent? {
        guard let event = object["event"] as? [String: Any],
              let eventType = event["type"] as? String else { return nil }

        switch eventType {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return nil }
            switch blockType {
            case "text":
                return Self.messageTextValue(block["text"]).map { OutputEvent(kind: .message, text: $0) }
            case "thinking":
                return Self.messageTextValue(block["thinking"]).map { OutputEvent(kind: .message, text: Self.thinkingBlock($0)) }
            case "tool_use":
                // 工具调用开始：记下工具名；input 通常是空占位 {}（真正参数走 input_json_delta），
                // 但少数实现会在此一次性给出完整 input——分开存，stop 时优先用分片累积、否则回落 start。
                pendingToolName = (block["name"] as? String) ?? "工具"
                pendingToolInput = ""
                pendingToolStartInput = ""
                if let input = block["input"] as? [String: Any], !input.isEmpty,
                   let data = try? JSONSerialization.data(withJSONObject: input),
                   let json = String(data: data, encoding: .utf8) {
                    pendingToolStartInput = json
                }
                return nil
            default:
                return nil
            }
        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return nil }
            switch deltaType {
            case "text_delta":
                return Self.messageTextValue(delta["text"]).map { OutputEvent(kind: .message, text: $0) }
            case "thinking_delta":
                return Self.messageTextValue(delta["thinking"]).map { OutputEvent(kind: .message, text: Self.thinkingBlock($0)) }
            case "input_json_delta":
                // 工具 input 是分片流式 JSON：累积，等 content_block_stop 再解析。
                if let partial = delta["partial_json"] as? String { pendingToolInput += partial }
                return nil
            default:
                return nil
            }
        case "content_block_stop":
            guard let name = pendingToolName else { return nil }
            let inputJSON = pendingToolInput.isEmpty ? pendingToolStartInput : pendingToolInput
            let summary = Self.toolSummary(name: name, inputJSON: inputJSON)
            pendingToolName = nil
            pendingToolInput = ""
            pendingToolStartInput = ""
            return OutputEvent(kind: .tool, text: summary)
        default:
            return nil
        }
    }

    /// 把一次工具调用压成一行紧凑摘要：中文动作动词 + 最有信息量的参数（文件 / 命令 / 模式 / 查询 / 网址）。
    /// 形如「读取 foo.swift」「编辑 a.ts」「运行 ls -la」（参考 Codex / Claude Code 的运行状态行），
    /// 让用户一眼看懂 agent 此刻在做什么。不展开庞大的工具结果正文，避免聊天被刷屏。
    static func toolSummary(name: String, inputJSON: String) -> String {
        let toolName = name.isEmpty ? "工具" : name
        let verb = actionVerb(for: toolName)
        let detail = detailArgument(inJSON: inputJSON)

        guard let detail else {
            // 没有可展示参数：plan/task 这类动词本身已达意；其余回落工具名（如「Read」）。
            if let verb, standaloneVerb(verb) { return verb }
            return toolName
        }

        let oneLine = detail.replacingOccurrences(of: "\n", with: " ")
        let compact = oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
        if let verb {
            return "\(verb) \(compact)"
        }
        return "\(toolName)：\(compact)"
    }

    /// 工具名 → 中文动作动词。覆盖 Claude / Codex / OpenCode 常见工具名及别名；未知工具返回 nil（回落原名）。
    private static func actionVerb(for name: String) -> String? {
        switch name.lowercased() {
        case "read", "readfile", "read_file", "cat", "view", "open":
            return "读取"
        case "edit", "multiedit", "multi_edit", "str_replace", "str_replace_editor",
             "str_replace_based_edit_tool", "apply_patch", "applypatch", "patch", "update", "edit_file":
            return "编辑"
        case "write", "writefile", "write_file", "create", "createfile", "create_file", "new_file":
            return "创建"
        case "bash", "shell", "sh", "run", "exec", "execute", "command", "terminal",
             "run_command", "run_terminal_cmd", "local_shell":
            return "运行"
        case "grep", "ripgrep", "rg", "search", "search_files", "code_search", "grep_search":
            return "搜索"
        case "glob", "find", "file_search", "findfiles":
            return "查找"
        case "ls", "list", "listdir", "list_dir", "list_directory":
            return "列出"
        case "webfetch", "web_fetch", "fetch", "http", "httprequest", "curl", "url":
            return "抓取"
        case "websearch", "web_search", "search_web", "browser_search":
            return "联网搜索"
        case "todowrite", "todo", "todo_write", "update_plan", "plan", "planner":
            return "更新计划"
        case "task", "agent", "dispatch", "dispatch_agent", "subagent":
            return "委派任务"
        case "notebook", "notebookedit", "notebook_edit":
            return "编辑笔记本"
        default:
            return nil
        }
    }

    /// 即便缺少具体参数也能独立达意的动词（如「更新计划」「委派任务」），无 detail 时照常展示。
    private static func standaloneVerb(_ verb: String) -> Bool {
        verb == "更新计划" || verb == "委派任务"
    }

    /// 从工具 input JSON 里挑出最有信息量的参数（文件 / 命令 / 模式 / 查询 / 网址）；无则 nil。
    private static func detailArgument(inJSON inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let detail = (object["file_path"] as? String)
            ?? (object["filePath"] as? String)
            ?? (object["path"] as? String)
            ?? (object["command"] as? String)
            ?? (object["pattern"] as? String)
            ?? (object["query"] as? String)
            ?? (object["url"] as? String)
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return detail
    }

    private static func thinkingBlock(_ text: String) -> String {
        "<think>\(text)</think>"
    }

    private static func openCodeToolEvent(in object: [String: Any]) -> OutputEvent? {
        guard let part = object["part"] as? [String: Any],
              (part["type"] as? String) == "tool",
              let state = part["state"] as? [String: Any] else { return nil }

        let name = (part["tool"] as? String) ?? "工具"
        if state["status"] as? String == "error" {
            let error = ((state["error"] as? String) ?? "").replacingOccurrences(of: "\n", with: " ")
            let compact = error.count > 100 ? String(error.prefix(100)) + "…" : error
            let detail = compact.isEmpty ? name : "\(name) \(compact)"
            return OutputEvent(kind: .tool, text: "工具出错：\(detail)")
        }

        let inputJSON: String
        if let input = state["input"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: input),
           let json = String(data: data, encoding: .utf8) {
            inputJSON = json
        } else {
            inputJSON = ""
        }
        return OutputEvent(kind: .tool, text: toolSummary(name: name, inputJSON: inputJSON))
    }

    /// 工具结果（tool_result）若标了 is_error，抽出一行紧凑错误提示；否则 nil（正常结果丢弃、不刷屏）。
    static func toolResultError(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return nil }
        for case let block as [String: Any] in content
        where (block["type"] as? String) == "tool_result" && (block["is_error"] as? Bool == true) {
            let text = (messageTextValue(block["content"]) ?? "").replacingOccurrences(of: "\n", with: " ")
            let compact = text.count > 100 ? String(text.prefix(100)) + "…" : text
            return compact.isEmpty ? "工具执行出错" : "工具出错：\(compact)"
        }
        return nil
    }

    private static func messageText(in object: [String: Any]) -> String? {
        for key in ["text", "content", "delta", "message", "summary"] {
            if let text = messageTextValue(object[key]) {
                return text
            }
        }
        if let part = object["part"] as? [String: Any] {
            return messageText(in: part)
        }
        return nil
    }

    private static func messageTextValue(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty {
            return text
        }
        if let object = value as? [String: Any] {
            return messageText(in: object)
        }
        if let array = value as? [Any] {
            let texts = array.compactMap(messageTextValue)
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    private static func errorText(in object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String, !message.isEmpty { return message }
            if let type = error["type"] as? String, !type.isEmpty { return type }
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error
        }
        return nil
    }

    private func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }
}
