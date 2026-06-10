import Foundation

/// 第三方/国产模型计价规则（#28）。claude CLI 只认 Anthropic 官方价目，
/// 经中转站跑 kimi / mimo / deepseek / qwen 等模型时 `total_cost_usd` 报 0——
/// 此时按本表用真实 token 数本地补算费用（token 计数本身来自 API 响应，任何模型都真实）。
public struct ModelPricingRule: Codable, Equatable, Sendable {
    /// 模型名匹配子串（忽略大小写），如 "deepseek"、"mimo-v2.5-pro"；自上而下首个匹配生效。
    public var match: String
    /// 每百万 token 单价（与 currency 同币种）。
    public var inputPer1M: Double
    public var outputPer1M: Double
    /// 缓存读/写单价；缺省按 inputPer1M 计。
    public var cacheReadPer1M: Double?
    public var cacheWritePer1M: Double?
    /// 展示用货币符号，如 "¥"；缺省显示 "$"。
    public var currency: String?

    public init(
        match: String,
        inputPer1M: Double,
        outputPer1M: Double,
        cacheReadPer1M: Double? = nil,
        cacheWritePer1M: Double? = nil,
        currency: String? = nil
    ) {
        self.match = match
        self.inputPer1M = inputPer1M
        self.outputPer1M = outputPer1M
        self.cacheReadPer1M = cacheReadPer1M
        self.cacheWritePer1M = cacheWritePer1M
        self.currency = currency
    }
}

public enum ModelPricing {
    struct ConfigFile: Codable {
        var doc: String?
        var rules: [ModelPricingRule]

        enum CodingKeys: String, CodingKey {
            case doc = "_doc"
            case rules
        }
    }

    public static func configURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDeck", isDirectory: true)
            .appendingPathComponent("model-pricing.json")
    }

    /// 读取规则；文件不存在 / 解析失败 → 空表（只统计 token，不计费）。
    /// 每轮结束才读一次，文件改完保存即生效，无需重启。
    public static func loadRules(from url: URL = configURL()) -> [ModelPricingRule] {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ConfigFile.self, from: data) else { return [] }
        return config.rules
    }

    public static func rule(for model: String?, in rules: [ModelPricingRule]) -> ModelPricingRule? {
        guard let model = model?.lowercased(), !model.isEmpty else { return nil }
        return rules.first { !$0.match.isEmpty && model.contains($0.match.lowercased()) }
    }

    /// 按规则给一轮用量计价。
    public static func cost(of turn: TurnUsage, rule: ModelPricingRule) -> Double {
        func per(_ price: Double) -> Double { price / 1_000_000 }
        return Double(turn.inputTokens) * per(rule.inputPer1M)
            + Double(turn.outputTokens) * per(rule.outputPer1M)
            + Double(turn.cacheReadTokens) * per(rule.cacheReadPer1M ?? rule.inputPer1M)
            + Double(turn.cacheCreationTokens) * per(rule.cacheWritePer1M ?? rule.inputPer1M)
    }

    /// 生成配置模板（已存在则不动），供设置页「打开计价配置」首次落地。
    @discardableResult
    public static func writeTemplateIfMissing(at url: URL = configURL()) -> URL {
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let template = """
        {
          "_doc": "第三方模型计价（每百万 token，币种见 currency）。match 为模型名子串（忽略大小写），自上而下首个匹配生效。示例单价均为 0：请按所用服务商价目填写；0 = 只统计 token 不计费。保存即生效（每轮结束时读取）。",
          "rules": [
            { "match": "deepseek", "inputPer1M": 0, "outputPer1M": 0, "cacheReadPer1M": 0, "currency": "¥" },
            { "match": "kimi", "inputPer1M": 0, "outputPer1M": 0, "currency": "¥" },
            { "match": "qwen", "inputPer1M": 0, "outputPer1M": 0, "currency": "¥" },
            { "match": "mimo", "inputPer1M": 0, "outputPer1M": 0, "currency": "¥" }
          ]
        }
        """
        try? template.data(using: .utf8)?.write(to: url)
        return url
    }
}
