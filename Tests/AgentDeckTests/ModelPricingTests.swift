import XCTest
@testable import AgentDeckApp

final class ModelPricingTests: XCTestCase {
    private let rules = [
        ModelPricingRule(match: "deepseek", inputPer1M: 4, outputPer1M: 12, cacheReadPer1M: 0.8, currency: "¥"),
        ModelPricingRule(match: "mimo", inputPer1M: 2, outputPer1M: 6, currency: "¥"),
        ModelPricingRule(match: "mimo-v2.5-pro", inputPer1M: 99, outputPer1M: 99)
    ]

    func testRuleMatchingIsCaseInsensitiveFirstWins() {
        XCTAssertEqual(ModelPricing.rule(for: "DeepSeek-V3", in: rules)?.currency, "¥")
        XCTAssertEqual(
            ModelPricing.rule(for: "mimo-v2.5-pro", in: rules)?.inputPer1M, 2,
            "自上而下首个匹配生效(更具体的规则应放前面)"
        )
        XCTAssertNil(ModelPricing.rule(for: "claude-opus-4-8", in: rules))
        XCTAssertNil(ModelPricing.rule(for: nil, in: rules))
        XCTAssertNil(ModelPricing.rule(for: "", in: rules))
    }

    func testCostComputationWithCacheFallback() {
        var turn = TurnUsage()
        turn.inputTokens = 1_000_000
        turn.outputTokens = 500_000
        turn.cacheReadTokens = 1_000_000
        turn.cacheCreationTokens = 100_000

        let deepseek = rules[0]
        // 1M×4 + 0.5M×12 + 1M×0.8(缓存读专价) + 0.1M×4(缓存写回落输入价)
        XCTAssertEqual(ModelPricing.cost(of: turn, rule: deepseek), 4 + 6 + 0.8 + 0.4, accuracy: 0.000_001)

        let mimo = rules[1]
        // 缓存读未配 → 回落输入价
        XCTAssertEqual(ModelPricing.cost(of: turn, rule: mimo), 2 + 3 + 2 + 0.2, accuracy: 0.000_001)
    }

    func testTemplateRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model-pricing.json")

        XCTAssertEqual(ModelPricing.loadRules(from: url), [], "文件缺失 → 空表")

        ModelPricing.writeTemplateIfMissing(at: url)
        let loaded = ModelPricing.loadRules(from: url)
        XCTAssertEqual(loaded.count, 4, "模板含 deepseek/kimi/qwen/mimo 四条示例")
        XCTAssertEqual(loaded.first?.match, "deepseek")
        XCTAssertEqual(loaded.first?.currency, "¥")

        // 已存在则不覆盖
        try "{\"rules\":[{\"match\":\"x\",\"inputPer1M\":1,\"outputPer1M\":2}]}".write(to: url, atomically: true, encoding: .utf8)
        ModelPricing.writeTemplateIfMissing(at: url)
        XCTAssertEqual(ModelPricing.loadRules(from: url).count, 1, "writeTemplateIfMissing 不得覆盖既有配置")
    }

    func testCurrencyFlowsIntoSessionUsageLabels() {
        var usage = SessionUsage()
        var turn = TurnUsage()
        turn.inputTokens = 100
        turn.costUSD = 0.5
        turn.costCurrency = "¥"
        usage.add(turn)
        XCTAssertEqual(usage.costLabel, "¥0.500")
        XCTAssertTrue(usage.compactSummary.hasSuffix("¥0.500"))

        var plain = SessionUsage()
        var freeTurn = TurnUsage()
        freeTurn.inputTokens = 1500
        freeTurn.outputTokens = 200
        plain.add(freeTurn)
        XCTAssertEqual(plain.tokensLabel, "↑1.5k ↓200", "未配价 → 仅 token 标签")
    }
}
