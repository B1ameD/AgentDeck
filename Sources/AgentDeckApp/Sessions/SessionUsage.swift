import Foundation

/// 会话累计 token/费用（#28）。数据来自 claude `result` 事件的**真实计量**
/// （`total_cost_usd` + `usage.*_tokens`），非估算；其它 agent 暂无此数据，保持 isEmpty。
public struct SessionUsage: Equatable, Codable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public var costUSD = 0.0
    /// 已计量的轮数（每条 result 行一轮）。
    public var turns = 0

    public init() {}

    public var isEmpty: Bool { turns == 0 }

    public mutating func add(_ turn: TurnUsage) {
        inputTokens += turn.inputTokens
        outputTokens += turn.outputTokens
        cacheReadTokens += turn.cacheReadTokens
        cacheCreationTokens += turn.cacheCreationTokens
        costUSD += turn.costUSD
        turns += 1
    }

    /// 紧凑摘要：↑输入（含缓存写）/↓输出/费用，如 "↑12.3k ↓4.5k · $0.043"。
    public var compactSummary: String {
        "↑\(Self.compact(inputTokens + cacheCreationTokens)) ↓\(Self.compact(outputTokens)) · \(costLabel)"
    }

    /// 费用标签：≥$1 显示两位小数，更小显示三位（避免 "$0.00"）。
    public var costLabel: String {
        costUSD >= 0.995 ? String(format: "$%.2f", costUSD) : String(format: "$%.3f", costUSD)
    }

    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1000: "\(tokens)"
        case ..<1_000_000: String(format: "%.1fk", Double(tokens) / 1000)
        default: String(format: "%.2fM", Double(tokens) / 1_000_000)
        }
    }
}

/// 单轮用量（解析自一条 claude result 行）。
public struct TurnUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public var costUSD = 0.0

    public init() {}
}

/// 从输出流捕获单轮 usage：行缓冲；只有含 "total_cost_usd" 的行才付出 JSON 解析
/// （claude 每轮只在最终 result 行携带，其余行一个 contains 就跳过）。
struct UsageCapture {
    private var buffer = ""

    mutating func consume(_ chunk: String) -> TurnUsage? {
        buffer += chunk
        var captured: TurnUsage?
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let turn = Self.turnUsage(fromJSONLine: line) {
                captured = turn // 理论上每轮至多一行；防御性取最后一条
            }
        }
        return captured
    }

    /// 流结束时处理无尾随换行的最后一行。
    mutating func flush() -> TurnUsage? {
        guard !buffer.isEmpty else { return nil }
        let line = buffer
        buffer = ""
        return Self.turnUsage(fromJSONLine: line)
    }

    /// claude result 行：{"type":"result",…,"total_cost_usd":0.01,"usage":{"input_tokens":…}}。
    static func turnUsage(fromJSONLine line: String) -> TurnUsage? {
        guard line.contains("total_cost_usd"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "result" else { return nil }
        var turn = TurnUsage()
        turn.costUSD = (object["total_cost_usd"] as? Double) ?? 0
        if let usage = object["usage"] as? [String: Any] {
            turn.inputTokens = intValue(usage["input_tokens"])
            turn.outputTokens = intValue(usage["output_tokens"])
            turn.cacheReadTokens = intValue(usage["cache_read_input_tokens"])
            turn.cacheCreationTokens = intValue(usage["cache_creation_input_tokens"])
        }
        guard turn.costUSD > 0 || turn.inputTokens > 0 || turn.outputTokens > 0 else { return nil }
        return turn
    }

    private static func intValue(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? 0
    }
}
