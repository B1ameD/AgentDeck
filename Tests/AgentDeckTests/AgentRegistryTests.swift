import XCTest
@testable import AgentDeckApp

final class AgentRegistryTests: XCTestCase {
    func testExecutableResolutionUsesPathEntriesBeforeFallbacks() throws {
        let pathDirectory = try makeTemporaryDirectory()
        let fallbackDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: pathDirectory)
            try? FileManager.default.removeItem(at: fallbackDirectory)
        }

        let pathExecutable = try writeExecutable(named: "agent", in: pathDirectory)
        _ = try writeExecutable(named: "agent", in: fallbackDirectory)

        let resolved = AgentDetection.resolveExecutable(
            named: "agent",
            pathEnvironment: pathDirectory.path,
            fallbackPaths: [fallbackDirectory.path]
        )

        XCTAssertEqual(resolved, pathExecutable.path)
    }

    func testExecutableResolutionUsesFallbackOrder() throws {
        let firstFallback = try makeTemporaryDirectory()
        let secondFallback = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstFallback)
            try? FileManager.default.removeItem(at: secondFallback)
        }

        let firstExecutable = try writeExecutable(named: "agent", in: firstFallback)
        _ = try writeExecutable(named: "agent", in: secondFallback)

        let resolved = AgentDetection.resolveExecutable(
            named: "agent",
            pathEnvironment: nil,
            fallbackPaths: [firstFallback.path, secondFallback.path]
        )

        XCTAssertEqual(resolved, firstExecutable.path)
    }

    func testExecutableResolutionReturnsNilForMissingExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let resolved = AgentDetection.resolveExecutable(
            named: "missing-agent",
            pathEnvironment: directory.path,
            fallbackPaths: []
        )

        XCTAssertNil(resolved)
    }

    func testExecutableResolutionIgnoresNonExecutableFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeFile(named: "agent", in: directory, permissions: 0o644)

        let resolved = AgentDetection.resolveExecutable(
            named: "agent",
            pathEnvironment: directory.path,
            fallbackPaths: []
        )

        XCTAssertNil(resolved)
    }

    func testBuiltInPresetsContainExpectedAgents() {
        let presets = AgentRegistry.builtInPresets(executableResolver: { name in "/usr/local/bin/\(name)" })

        XCTAssertEqual(presets.map(\.id), ["claude-code", "codex", "opencode", "pi-local"])
        XCTAssertEqual(presets.first?.command, "/usr/local/bin/claude")
        XCTAssertEqual(
            presets.first(where: { $0.id == "claude-code" })?.args,
            ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        )
        XCTAssertEqual(presets.first(where: { $0.id == "claude-code" })?.inputMode, .oneShotArgument)
        XCTAssertEqual(presets.first(where: { $0.id == "claude-code" })?.outputMode, .jsonLines)
        XCTAssertEqual(presets.first(where: { $0.id == "codex" })?.args, ["exec"])
        XCTAssertEqual(presets.first(where: { $0.id == "codex" })?.inputMode, .oneShotArgument)
        XCTAssertEqual(presets.first(where: { $0.id == "codex" })?.outputMode, .jsonLines)
        XCTAssertEqual(presets.first(where: { $0.id == "opencode" })?.args, ["run"])
        XCTAssertEqual(presets.first(where: { $0.id == "opencode" })?.inputMode, .oneShotArgument)
        XCTAssertEqual(presets.first(where: { $0.id == "opencode" })?.outputMode, .jsonLines)
        XCTAssertEqual(presets.first(where: { $0.id == "pi-local" })?.args, ["chat", "--stdio"])
        XCTAssertEqual(presets.first(where: { $0.id == "pi-local" })?.inputMode, .stdin)
    }

    func testBuiltInPresetsSkipMissingExecutables() {
        let presets = AgentRegistry.builtInPresets(executableResolver: { name in
            name == "codex" ? "/opt/homebrew/bin/codex" : nil
        })

        XCTAssertEqual(presets.map(\.id), ["codex"])
    }

    func testLoadsCustomAgentsFromDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = """
        {
          "id": "custom-echo",
          "name": "Echo",
          "command": "/bin/cat",
          "args": [],
          "env": {},
          "workingDirectoryPolicy": "workspace",
          "inputMode": "stdin",
          "outputMode": "stream",
          "supportsStop": true,
          "stopSignal": "interrupt"
        }
        """
        try json.write(to: directory.appendingPathComponent("echo.json"), atomically: true, encoding: .utf8)

        let registry = AgentRegistry.load(
            customDirectory: directory,
            executableResolver: { _ in nil }
        )

        XCTAssertEqual(registry.agents.map(\.id), ["custom-echo"])
        XCTAssertTrue(registry.warnings.isEmpty)
    }

    func testDuplicateBuiltInIDIsSkippedAndBuiltInWins() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAgentJSON(id: "codex", to: directory.appendingPathComponent("codex.json"))

        let registry = AgentRegistry.load(
            customDirectory: directory,
            executableResolver: { name in name == "codex" ? "/opt/homebrew/bin/codex" : nil }
        )

        // 内置 codex 保留，自定义同 id 被跳过，codex 只出现一次。
        XCTAssertEqual(registry.agents.map(\.id), ["codex"])
        XCTAssertEqual(registry.agents.first?.command, "/opt/homebrew/bin/codex")
        XCTAssertEqual(registry.warnings.count, 1)
        XCTAssertTrue(registry.warnings[0].contains("codex.json"))
        XCTAssertTrue(registry.warnings[0].contains("codex"))
    }

    func testDuplicateCustomIDKeepsFirstAndWarns() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAgentJSON(id: "custom-echo", to: directory.appendingPathComponent("a.json"))
        try writeAgentJSON(id: "custom-echo", to: directory.appendingPathComponent("b.json"))

        let registry = AgentRegistry.load(
            customDirectory: directory,
            executableResolver: { _ in nil }
        )

        // 文件名排序后 a.json 先加载并保留，b.json 被跳过。
        XCTAssertEqual(registry.agents.map(\.id), ["custom-echo"])
        XCTAssertEqual(registry.warnings.count, 1)
        XCTAssertTrue(registry.warnings[0].contains("b.json"))
    }

    func testMalformedCustomAgentIsSkippedAndOthersSurvive() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try "{".write(to: directory.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try writeAgentJSON(id: "good", to: directory.appendingPathComponent("good.json"))

        let registry = AgentRegistry.load(
            customDirectory: directory,
            executableResolver: { _ in nil }
        )

        // 坏文件被跳过，正常的 good 仍然加载成功。
        XCTAssertEqual(registry.agents.map(\.id), ["good"])
        XCTAssertEqual(registry.warnings.count, 1)
        XCTAssertTrue(registry.warnings[0].contains("bad.json"))
    }

    func testInvalidCustomAgentIsSkippedWithFilenameWarning() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try writeAgentJSON(id: "", to: directory.appendingPathComponent("empty-id.json"))

        let registry = AgentRegistry.load(
            customDirectory: directory,
            executableResolver: { _ in nil }
        )

        XCTAssertTrue(registry.agents.isEmpty)
        XCTAssertEqual(registry.warnings.count, 1)
        XCTAssertTrue(registry.warnings[0].contains("empty-id.json"))
    }

    func testExecutableResolutionIgnoresBrokenSymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Create a broken symlink: points to a non-existent target.
        let linkURL = directory.appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: directory.appendingPathComponent("nonexistent"))

        // isExecutableFile alone would return true for the symlink itself,
        // but our helper should reject it because the destination does not exist.
        let resolved = AgentDetection.resolveExecutable(
            named: "agent",
            pathEnvironment: directory.path,
            fallbackPaths: []
        )

        XCTAssertNil(resolved)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func writeExecutable(named name: String, in directory: URL) throws -> URL {
        try writeFile(named: name, in: directory, permissions: 0o755)
    }

    @discardableResult
    private func writeFile(named name: String, in directory: URL, permissions: Int) throws -> URL {
        let file = directory.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        return file
    }

    private func writeAgentJSON(id: String, to file: URL) throws {
        let json = """
        {
          "id": "\(id)",
          "name": "Echo",
          "command": "/bin/cat",
          "args": [],
          "env": {},
          "workingDirectoryPolicy": "workspace",
          "inputMode": "stdin",
          "outputMode": "stream",
          "supportsStop": true,
          "stopSignal": "interrupt"
        }
        """
        try json.write(to: file, atomically: true, encoding: .utf8)
    }
}
