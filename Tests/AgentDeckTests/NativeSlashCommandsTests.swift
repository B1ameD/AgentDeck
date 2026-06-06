import XCTest
@testable import AgentDeckApp

final class NativeSlashCommandsTests: XCTestCase {
    func testDiscoversClaudeCustomCommandsFromHomeAndProjectSortedAndDeduped() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let project = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: project)
        }
        let homeCmds = home.appending(path: ".claude/commands", directoryHint: .isDirectory)
        let projCmds = project.appending(path: ".claude/commands", directoryHint: .isDirectory)
        try fm.createDirectory(at: homeCmds, withIntermediateDirectories: true)
        try fm.createDirectory(at: projCmds, withIntermediateDirectories: true)
        try "---\ndescription: Review the diff\n---\nbody".write(to: homeCmds.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        try "Deploy to staging".write(to: projCmds.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8)
        try "Home version".write(to: homeCmds.appendingPathComponent("deploy.md"), atomically: true, encoding: .utf8) // 与项目同名，home 优先去重

        let commands = NativeSlashCommands.discover(
            for: claudeAgent(),
            workingDirectory: project,
            homeDirectory: home
        )

        XCTAssertEqual(commands.map(\.token), ["/deploy", "/review"]) // 按 token 排序、去重
        XCTAssertTrue(commands.allSatisfy { $0.action == .passthrough })
        XCTAssertEqual(commands.first { $0.token == "/review" }?.summary, "Review the diff") // frontmatter description
        XCTAssertEqual(commands.first { $0.token == "/deploy" }?.summary, "Home version") // home 优先
    }

    func testNonClaudeAgentDiscoversNothing() {
        let custom = AgentConfig(
            id: "my-agent", name: "Mine", command: "/usr/bin/x", args: [], env: [:],
            workingDirectoryPolicy: .workspace, inputMode: .stdin, outputMode: .stream,
            supportsStop: true, stopSignal: .interrupt
        )
        XCTAssertTrue(NativeSlashCommands.discover(for: custom, workingDirectory: FileManager.default.temporaryDirectory).isEmpty)
    }

    private func claudeAgent() -> AgentConfig {
        AgentConfig(
            id: "claude-code", name: "Claude Code", command: "/usr/bin/claude", args: ["-p"], env: [:],
            workingDirectoryPolicy: .workspace, inputMode: .oneShotArgument, outputMode: .stream,
            supportsStop: true, stopSignal: .interrupt
        )
    }
}
