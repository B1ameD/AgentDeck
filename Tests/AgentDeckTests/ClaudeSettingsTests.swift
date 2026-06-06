import XCTest
@testable import AgentDeckApp

final class ClaudeSettingsModelRolesTests: XCTestCase {
    private func writeSettings(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testModelRolesLabelsEachRoleAndExposesDefault() throws {
        let url = try writeSettings(#"""
        {"env":{
          "ANTHROPIC_MODEL":"heavy-pro",
          "ANTHROPIC_DEFAULT_HAIKU_MODEL":"fast-haiku",
          "ANTHROPIC_DEFAULT_SONNET_MODEL":"mid-sonnet",
          "ANTHROPIC_DEFAULT_OPUS_MODEL":"big-opus"
        }}
        """#)
        defer { try? FileManager.default.removeItem(at: url) }

        let roles = ClaudeSettings.modelRoles(settingsURL: url)
        XCTAssertEqual(roles.defaultModel, "heavy-pro")
        XCTAssertEqual(roles.labels["fast-haiku"], "Haiku · 快")
        XCTAssertEqual(roles.labels["mid-sonnet"], "Sonnet")
        XCTAssertEqual(roles.labels["big-opus"], "Opus")
        XCTAssertEqual(roles.labels["heavy-pro"], "默认")
    }

    func testModelRolesCombinesLabelsWhenOneModelServesMultipleRoles() throws {
        let url = try writeSettings(#"""
        {"env":{
          "ANTHROPIC_MODEL":"m",
          "ANTHROPIC_DEFAULT_HAIKU_MODEL":"m",
          "ANTHROPIC_DEFAULT_SONNET_MODEL":"m"
        }}
        """#)
        defer { try? FileManager.default.removeItem(at: url) }

        let roles = ClaudeSettings.modelRoles(settingsURL: url)
        XCTAssertEqual(roles.labels["m"], "Haiku · 快 / Sonnet / 默认")
    }

    func testModelRolesEmptyWhenNoSettingsFile() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let roles = ClaudeSettings.modelRoles(settingsURL: missing)
        XCTAssertNil(roles.defaultModel)
        XCTAssertTrue(roles.labels.isEmpty)
    }

    func testModelSnapshotKeepsCandidatesRolesAndDefaultConsistent() throws {
        let url = try writeSettings(#"""
        {
          "env": {
            "ANTHROPIC_MODEL": "provider/model-a",
            "ANTHROPIC_DEFAULT_SONNET_MODEL": "provider/model-b"
          },
          "model": "provider/model-c"
        }
        """#)
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = ClaudeSettings.modelSnapshot(settingsURL: url)

        XCTAssertEqual(snapshot.candidates, [
            "provider/model-a",
            "provider/model-b",
            "provider/model-c"
        ])
        XCTAssertEqual(snapshot.roles.defaultModel, "provider/model-a")
        XCTAssertEqual(snapshot.roles.labels["provider/model-a"], "默认")
        XCTAssertEqual(snapshot.roles.labels["provider/model-b"], "Sonnet")
    }

    func testModelSnapshotReflectsReplacedProviderWithoutProcessRestart() throws {
        let url = try writeSettings(#"{"env":{"ANTHROPIC_MODEL":"old/model"}}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ClaudeSettings.modelSnapshot(settingsURL: url).candidates, ["old/model"])

        try #"{"env":{"ANTHROPIC_MODEL":"new/model","ANTHROPIC_DEFAULT_HAIKU_MODEL":"new/fast"}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let refreshed = ClaudeSettings.modelSnapshot(settingsURL: url)
        XCTAssertEqual(refreshed.candidates, ["new/model", "new/fast"])
        XCTAssertNil(refreshed.roles.labels["old/model"])
    }

    func testMalformedSettingsProduceAnEmptySnapshot() throws {
        let url = try writeSettings("{not-json")
        defer { try? FileManager.default.removeItem(at: url) }

        let snapshot = ClaudeSettings.modelSnapshot(settingsURL: url)

        XCTAssertTrue(snapshot.candidates.isEmpty)
        XCTAssertTrue(snapshot.roles.labels.isEmpty)
        XCTAssertNil(snapshot.roles.defaultModel)
    }
}
