import Foundation

// 把 ACP `session/update` 通知翻译成应用内部的 OutputEvent —— 与 OpenCodeEventTranslator 同构,
// 让 ACP 路径复用 AgentSession 既有的消费链(气泡装配/思考块/工具摘要/usage)。纯逻辑,单测主目标。

public struct ACPTranslation: Sendable, Equatable {
    public var events: [OutputEvent] = []
    /// 本轮 usage(若该通知是 usage_update):token + 费用,喂 SessionUsage(#28)。
    public var usage: TurnUsage?
    /// 模式变更后的当前模式 id(current_mode_update)。
    public var currentModeId: String?
}

public enum ACPEventTranslator {
    /// 翻译一条 `session/update` 通知的 params(`{sessionId, update:{sessionUpdate:...}}`)。
    public static func translate(updateParams params: JSONValue) -> ACPTranslation {
        guard let update = params["update"], let kind = update["sessionUpdate"]?.stringValue else {
            return ACPTranslation()
        }
        var out = ACPTranslation()
        switch kind {
        case "agent_message_chunk":
            if let text = contentText(update["content"]), !text.isEmpty {
                out.events.append(OutputEvent(kind: .message, text: text))
            }
        case "agent_thought_chunk":
            if let text = contentText(update["content"]), !text.isEmpty {
                // 复用现有思考块约定(<think>…</think>),UI 折叠展示。
                out.events.append(OutputEvent(kind: .message, text: "<think>\(text)</think>"))
            }
        case "tool_call", "tool_call_update":
            if let summary = toolSummary(update) {
                out.events.append(OutputEvent(kind: .tool, text: summary))
            }
        case "usage_update":
            out.usage = parseUsage(update)
        case "current_mode_update":
            out.currentModeId = update["currentModeId"]?.stringValue
        case "plan", "available_commands_update", "config_option_update",
             "session_info_update", "user_message_chunk":
            break // spike 阶段不投递到聊天(plan/命令列表等留待 phase 2 接 UI)
        default:
            break
        }
        return out
    }

    /// ContentBlock → 纯文本(spike 只取 text;image/resource 留 phase 3)。
    static func contentText(_ content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let s = content.stringValue { return s }
        if content["type"]?.stringValue == "text" { return content["text"]?.stringValue }
        // content 可能是数组形态
        if let arr = content.arrayValue {
            let joined = arr.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// 工具调用一行紧凑摘要(标题 + 状态),不灌入庞大 output。
    static func toolSummary(_ update: JSONValue) -> String? {
        let title = update["title"]?.stringValue
            ?? update["rawInput"]?["description"]?.stringValue
            ?? update["kind"]?.stringValue
            ?? update["toolCallId"]?.stringValue
        guard let title else { return nil }
        if let status = update["status"]?.stringValue {
            return "\(title) · \(status)"
        }
        return title
    }

    static func parseUsage(_ update: JSONValue) -> TurnUsage {
        var turn = TurnUsage()
        // ACP usage_update: used = 当前上下文 token 总量;无 input/output 拆分。
        // spike 先把 used 记为 inputTokens 量级用于展示;phase 2 再细化语义(累计 vs 快照)。
        turn.inputTokens = update["used"]?.intValue ?? 0
        if let cost = update["cost"] {
            if case .number(let amount)? = cost["amount"] { turn.costUSD = amount }
            if let currency = cost["currency"]?.stringValue, currency != "USD" {
                turn.costCurrency = currency
            }
        }
        return turn
    }
}
