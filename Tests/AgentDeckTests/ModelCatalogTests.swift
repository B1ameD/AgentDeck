import XCTest
@testable import AgentDeckApp

final class ModelCatalogTests: XCTestCase {
    func testClaudeCatalogFetchReturnsAnUncachedSettingsSnapshot() async throws {
        let settingsURL = try temporaryClaudeSettings(#"{"env":{"ANTHROPIC_MODEL":"old/model"}}"#)
        defer { try? FileManager.default.removeItem(at: settingsURL.deletingLastPathComponent()) }

        let first = await ModelCatalog.fetchClaudeSnapshot(settingsURL: settingsURL)
        try #"{"env":{"ANTHROPIC_MODEL":"new/model"}}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)
        let second = await ModelCatalog.fetchClaudeSnapshot(settingsURL: settingsURL)

        XCTAssertEqual(first.candidates, ["old/model"])
        XCTAssertEqual(second.candidates, ["new/model"])
    }

    func testClaudeSettingsExtractsEnvironmentAndModelNames() throws {
        let settingsURL = try temporaryClaudeSettings("""
        {
          "env": {
            "ANTHROPIC_AUTH_TOKEN": "secret",
            "ANTHROPIC_MODEL": "MiniMax-M2.7",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "MiniMax-Haiku",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "MiniMax-Sonnet",
            "API_TIMEOUT_MS": 3000000
          },
          "model": "haiku"
        }
        """)

        XCTAssertEqual(ClaudeSettings.loadEnvironment(settingsURL: settingsURL), [
            "ANTHROPIC_AUTH_TOKEN": "secret",
            "ANTHROPIC_MODEL": "MiniMax-M2.7",
            "ANTHROPIC_DEFAULT_HAIKU_MODEL": "MiniMax-Haiku",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "MiniMax-Sonnet",
            "API_TIMEOUT_MS": "3000000"
        ])
        XCTAssertEqual(
            ClaudeSettings.modelCandidates(settingsURL: settingsURL),
            ["MiniMax-M2.7", "MiniMax-Haiku", "MiniMax-Sonnet", "haiku"]
        )
    }

    func testParsesProviderModelLines() {
        let output = """
        opencode/big-pickle
          opencode-go/qwen3.7-max

        anthropic/claude-sonnet-4-6
        """
        XCTAssertEqual(ModelCatalog.parse(output), [
            "opencode/big-pickle",
            "opencode-go/qwen3.7-max",
            "anthropic/claude-sonnet-4-6"
        ])
    }

    func testModelSuggestionsUseCatalogWhenProvidedWithDefaultPrepended() {
        let catalog = ["opencode-go/qwen3.7-max", "opencode-go/glm-5", "anthropic/claude-sonnet-4-6"]

        // 空 query：全量（前置 default）。
        XCTAssertEqual(
            SlashCommandMenu.modelSuggestions(for: .openCode, query: "", catalog: catalog),
            ["default"] + catalog
        )
        // 带 query：在 default+目录 上做子串过滤。
        XCTAssertEqual(
            SlashCommandMenu.modelSuggestions(for: .openCode, query: "qwen", catalog: catalog),
            ["opencode-go/qwen3.7-max"]
        )
    }

    func testGroupModelsByProviderPrefixPreservingOrder() {
        let models = ["default", "opencode/big-pickle", "opencode-go/qwen", "opencode/deepseek", "minimax/m2"]
        XCTAssertEqual(SlashCommandMenu.groupModels(models), [
            ModelGroup(provider: "", models: ["default"]),
            ModelGroup(provider: "opencode", models: ["opencode/big-pickle", "opencode/deepseek"]),
            ModelGroup(provider: "opencode-go", models: ["opencode-go/qwen"]),
            ModelGroup(provider: "minimax", models: ["minimax/m2"])
        ])
    }

    func testModelSuggestionsFallBackToPresetsWhenCatalogEmpty() {
        XCTAssertEqual(
            SlashCommandMenu.modelSuggestions(for: .claudeCode, query: "", catalog: []),
            ["default", "sonnet", "opus", "haiku", "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        )
    }

    func testClaudeSuggestionsAlwaysIncludeVersionPresetsEvenWithCatalog() {
        // 官方登录时 settings.json 常只暴露一个别名（如 "opus"）。即便目录非空，也要并入内置
        // 版本全名，保证用户仍能看到/选到具体版本（如 claude-opus-4-8），而非只剩一个 "opus"。
        XCTAssertEqual(
            SlashCommandMenu.modelSuggestions(for: .claudeCode, query: "", catalog: ["opus"]),
            ["default", "opus", "sonnet", "haiku", "claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
        )
        // 目录里已是具体版本时不重复，且保持「目录在前、预设在后」的顺序。
        XCTAssertEqual(
            SlashCommandMenu.modelSuggestions(for: .claudeCode, query: "opus", catalog: ["claude-opus-4-8"]),
            ["claude-opus-4-8", "opus"]
        )
    }

    private func temporaryClaudeSettings(_ json: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClaudeSettingsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "settings.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
