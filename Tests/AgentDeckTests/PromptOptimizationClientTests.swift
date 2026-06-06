import XCTest
@testable import AgentDeckApp

final class PromptOptimizationClientTests: XCTestCase {
    func testDefaultSettingsUseProviderPresetAndRequireAPIKey() {
        let suite = "prompt-opt-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = PromptOptimizationSettings.current(defaults: defaults)

        XCTAssertEqual(settings.providerID, "deepseek")
        XCTAssertEqual(settings.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(settings.model, "deepseek-v4-flash")
        XCTAssertEqual(settings.missingConfigurationMessage, "请在 Settings 配置 Prompt 优化 API Key")
    }

    func testUseDefaultModeIgnoresStaleCustomProviderFields() {
        let suite = "prompt-opt-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(PromptOptimizationMode.useDefault.rawValue, forKey: PromptOptimizationMode.storageKey)
        defaults.set("custom", forKey: PromptOptimizationSettings.providerKey)
        defaults.set("https://api.example.test/v1", forKey: PromptOptimizationSettings.baseURLKey)
        defaults.set("custom-model", forKey: PromptOptimizationSettings.modelKey)
        defaults.set("secret", forKey: PromptOptimizationSettings.apiKeyKey)

        let settings = PromptOptimizationSettings.current(defaults: defaults)

        XCTAssertEqual(settings.providerID, PromptOptimizationProvider.defaultProvider.id)
        XCTAssertEqual(settings.baseURL, PromptOptimizationProvider.defaultProvider.baseURL)
        XCTAssertEqual(settings.model, PromptOptimizationProvider.defaultProvider.defaultModel)
        XCTAssertEqual(settings.apiKey, "secret")
    }

    func testChatCompletionsURLTrimsTrailingSlash() {
        XCTAssertEqual(
            PromptOptimizationClient.chatCompletionsURL(baseURL: "https://api.example.com/v1/")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
    }
}
