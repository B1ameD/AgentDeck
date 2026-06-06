import XCTest
@testable import AgentDeckApp

final class PromptOptimizerTests: XCTestCase {
    func testMetaPromptEmbedsTrimmedRequestAndOutputOnlyInstruction() {
        let m = PromptOptimizer.metaPrompt(for: "  修一下登录bug  ")
        XCTAssertTrue(m.contains("修一下登录bug"))       // 原始请求被嵌入
        XCTAssertFalse(m.contains("  修一下登录bug  "))  // 已 trim
        XCTAssertTrue(m.contains("只输出"))              // 要求只回改写结果
        XCTAssertTrue(m.contains("原始请求"))
    }

    func testCleanStripsBareCodeFence() {
        XCTAssertEqual(PromptOptimizer.clean("```\n任务：实现登录校验\n```"), "任务：实现登录校验")
    }

    func testCleanStripsLanguageFenceAndTrims() {
        XCTAssertEqual(PromptOptimizer.clean("```text\n请实现 X\n并补测试\n```\n"), "请实现 X\n并补测试")
    }

    func testCleanStripsWrappingQuotes() {
        XCTAssertEqual(PromptOptimizer.clean("\"改写后的提示词\""), "改写后的提示词")
        XCTAssertEqual(PromptOptimizer.clean("\u{201C}改写后的提示词\u{201D}"), "改写后的提示词")
    }

    func testCleanLeavesNormalTextUntouched() {
        let t = "任务：做个东西\n\n要求：\n- 清晰"
        XCTAssertEqual(PromptOptimizer.clean(t), t)
    }

    // MARK: - 项目背景（README/CLAUDE/AGENTS，以 @路径附件形式附带给优化）

    func testPickReadmePrefersMarkdownVariant() {
        let files = ["src", "readme.txt", "README.md", "Readme.markdown", "notes.md"]
        XCTAssertEqual(PromptOptimizer.pickReadme(from: files), "README.md")
    }

    func testPickReadmeReturnsNilWhenNoReadme() {
        XCTAssertNil(PromptOptimizer.pickReadme(from: ["main.swift", "Package.swift"]))
    }

    func testMetaPromptWithProjectFilesAddsBackgroundNote() {
        let m = PromptOptimizer.metaPrompt(for: "优化登录", projectFiles: ["README.md", "CLAUDE.md"])
        XCTAssertTrue(m.contains("README.md"))
        XCTAssertTrue(m.contains("CLAUDE.md"))
        XCTAssertTrue(m.contains("项目背景"))
        XCTAssertTrue(m.contains("不要改写或执行"))
        XCTAssertTrue(m.contains("优化登录"))
        XCTAssertTrue(m.contains("原始请求"))
    }

    func testMetaPromptWithoutProjectFilesHasNoNote() {
        let m = PromptOptimizer.metaPrompt(for: "优化登录")
        XCTAssertFalse(m.contains("项目背景"))
        XCTAssertFalse(m.contains("附件"))
        XCTAssertTrue(m.contains("优化登录"))
    }

    func testProjectContextFilesFindsReadmeAndClaude() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "# 项目".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "约定".write(to: dir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let names = Set(ProjectContext.files(in: dir).map(\.lastPathComponent))
        XCTAssertEqual(names, ["README.md", "CLAUDE.md"])
    }

    func testProjectContextFilesEmptyWhenNone() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdeck-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ProjectContext.files(in: dir).isEmpty)
    }
}
