import Foundation

/// 上下文用量的**粗略估算**。AgentDeck 是 CLI 包装，拿不到 agent 的真实 token 计数，
/// 故按字符量级估算，仅作「大概用了多少」的提示，UI 会标注「估算」。
public enum ContextEstimate {
    /// 估算 token 数：UTF-8 字节数 / 4（英文 ≈0.25 token/字节，CJK 3 字节 ≈0.75 token，量级够用）。
    public static func estimatedTokens(_ text: String) -> Int {
        text.isEmpty ? 0 : max(1, text.utf8.count / 4)
    }

    /// 一组消息的合计估算 token。
    public static func estimatedTokens(forTexts texts: [String]) -> Int {
        texts.reduce(0) { $0 + estimatedTokens($1) }
    }

    /// 名义上下文窗口（拿不到真实值，给量级）。
    public static func contextWindow(forModel model: String) -> Int {
        200_000
    }

    /// 占用比例，夹在 [0, 1]。
    public static func usageFraction(tokens: Int, window: Int) -> Double {
        guard window > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(window)))
    }

    /// 紧凑展示，如 1234 → "1.2k"、950 → "950"。
    public static func compact(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000)
        }
        return "\(count)"
    }
}
