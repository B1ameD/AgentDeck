import Foundation

/// 广播轮次对比（#27）：同一 broadcastID 在各会话的「问与答」抽取。纯函数，可单测。
enum BroadcastCompare {
    /// 全部会话中最近一轮广播的 id（按打标用户消息的 createdAt 取最新）。
    static func latestBroadcastID(in messageLists: [[ChatMessage]]) -> String? {
        var latest: (id: String, at: Date)?
        for messages in messageLists {
            for message in messages where message.role == .user {
                guard let id = message.broadcastID else { continue }
                if latest == nil || message.createdAt > (latest?.at ?? .distantPast) {
                    latest = (id, message.createdAt)
                }
            }
        }
        return latest?.id
    }

    /// 该轮广播的提问文本（各会话内容相同，取首个命中）。
    static func prompt(in messageLists: [[ChatMessage]], broadcastID: String) -> String? {
        for messages in messageLists {
            if let hit = messages.first(where: { $0.role == .user && $0.broadcastID == broadcastID }) {
                return hit.text
            }
        }
        return nil
    }

    /// 单会话中该轮的回答：打标用户消息之后、下一条用户消息之前的全部 assistant 文本拼接。
    /// 会话未参与该轮 → nil；参与但尚无输出 → 空串（UI 据 isRunning 显示「生成中」或「无输出」）。
    static func response(in messages: [ChatMessage], broadcastID: String) -> String? {
        guard let start = messages.firstIndex(where: { $0.role == .user && $0.broadcastID == broadcastID }) else {
            return nil
        }
        var chunks: [String] = []
        for message in messages[(start + 1)...] {
            if message.role == .user { break }
            if message.role == .assistant, !message.text.isEmpty {
                chunks.append(message.text)
            }
        }
        return chunks.joined(separator: "\n\n")
    }
}
