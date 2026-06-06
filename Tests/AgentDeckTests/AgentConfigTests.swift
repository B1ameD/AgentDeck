import XCTest
@testable import AgentDeckApp

final class AgentConfigTests: XCTestCase {
    func testDecodesPiAgentConfig() throws {
        let json = """
        {
          "id": "pi-local",
          "name": "Pi Local",
          "command": "/usr/local/bin/pi",
          "args": ["chat", "--stdio"],
          "env": {"PI_PROFILE": "default"},
          "workingDirectoryPolicy": "workspace",
          "inputMode": "stdin",
          "outputMode": "stream",
          "supportsStop": true,
          "stopSignal": "interrupt"
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(AgentConfig.self, from: json)

        XCTAssertEqual(config.id, "pi-local")
        XCTAssertEqual(config.name, "Pi Local")
        XCTAssertEqual(config.command, "/usr/local/bin/pi")
        XCTAssertEqual(config.args, ["chat", "--stdio"])
        XCTAssertEqual(config.env["PI_PROFILE"], "default")
        XCTAssertEqual(config.workingDirectoryPolicy, .workspace)
        XCTAssertEqual(config.inputMode, .stdin)
        XCTAssertEqual(config.outputMode, .stream)
        XCTAssertTrue(config.supportsStop)
        XCTAssertEqual(config.stopSignal, .interrupt)
    }

    func testValidationRejectsEmptyId() {
        let config = AgentConfig(
            id: "",
            name: "Broken",
            command: "broken",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .stdin,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt
        )

        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .emptyID)
        }
    }

    func testValidationRejectsEmptyCommand() {
        let config = AgentConfig(
            id: "broken",
            name: "Broken",
            command: "",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .stdin,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt
        )

        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .emptyCommand)
        }
    }

    func testValidationRejectsFixedPathPolicyWithoutDirectory() {
        let config = AgentConfig(
            id: "fixed",
            name: "Fixed",
            command: "/usr/bin/agent",
            args: [],
            env: [:],
            workingDirectoryPolicy: .fixedPath,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt,
            fixedWorkingDirectory: "   "
        )

        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .missingFixedDirectory)
        }
    }

    func testValidationRejectsCustomStopSignalWithoutCommand() {
        let config = AgentConfig(
            id: "custom-stop",
            name: "Custom Stop",
            command: "/usr/bin/agent",
            args: [],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .customCommand,
            stopCommand: []
        )

        XCTAssertThrowsError(try config.validate()) { error in
            XCTAssertEqual(error as? AgentConfig.ValidationError, .missingStopCommand)
        }
    }

    func testFixedPathConfigWithDirectoryAndCustomStopWithCommandAreValid() throws {
        let fixed = AgentConfig(
            id: "fixed", name: "Fixed", command: "/usr/bin/agent", args: [], env: [:],
            workingDirectoryPolicy: .fixedPath, inputMode: .oneShotArgument, outputMode: .stream,
            supportsStop: true, stopSignal: .interrupt, fixedWorkingDirectory: "~/Projects/x"
        )
        let customStop = AgentConfig(
            id: "cs", name: "CS", command: "/usr/bin/agent", args: [], env: [:],
            workingDirectoryPolicy: .workspace, inputMode: .oneShotArgument, outputMode: .stream,
            supportsStop: true, stopSignal: .customCommand, stopCommand: ["/usr/bin/agentctl", "stop"]
        )
        XCTAssertNoThrow(try fixed.validate())
        XCTAssertNoThrow(try customStop.validate())
    }

    func testClaudeRuntimeEnvironmentMergesClaudeSettingsAndAgentEnvOverrides() throws {
        let settingsURL = try temporaryClaudeSettings("""
        {
          "env": {
            "ANTHROPIC_BASE_URL": "https://api.example.test/anthropic",
            "ANTHROPIC_MODEL": "MiniMax-M2.7",
            "API_TIMEOUT_MS": 3000000
          }
        }
        """)
        let config = AgentConfig(
            id: "claude-code",
            name: "Claude Code",
            command: "/usr/bin/claude",
            args: ["-p"],
            env: [
                "ANTHROPIC_MODEL": "override-model",
                "EXTRA": "1"
            ],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .stream,
            supportsStop: true,
            stopSignal: .interrupt
        )

        XCTAssertEqual(config.runtimeEnvironment(claudeSettingsURL: settingsURL), [
            "ANTHROPIC_BASE_URL": "https://api.example.test/anthropic",
            "ANTHROPIC_MODEL": "override-model",
            "API_TIMEOUT_MS": "3000000",
            "EXTRA": "1"
        ])
    }

    func testOpenCodeRuntimeEnvironmentDisablesSnapshotByDefault() {
        let config = AgentConfig(
            id: "opencode",
            name: "OpenCode",
            command: "/usr/bin/opencode",
            args: ["run"],
            env: [:],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )

        XCTAssertEqual(config.runtimeEnvironment()["OPENCODE_CONFIG_CONTENT"], #"{"snapshot":false}"#)
    }

    func testOpenCodeRuntimeEnvironmentKeepsExplicitConfigContent() {
        let config = AgentConfig(
            id: "opencode",
            name: "OpenCode",
            command: "/usr/bin/opencode",
            args: ["run"],
            env: ["OPENCODE_CONFIG_CONTENT": #"{"snapshot":true}"#],
            workingDirectoryPolicy: .workspace,
            inputMode: .oneShotArgument,
            outputMode: .jsonLines,
            supportsStop: true,
            stopSignal: .interrupt
        )

        XCTAssertEqual(config.runtimeEnvironment()["OPENCODE_CONFIG_CONTENT"], #"{"snapshot":true}"#)
    }

    private func temporaryClaudeSettings(_ json: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentConfigClaudeSettings-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "settings.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
