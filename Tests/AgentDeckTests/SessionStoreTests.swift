import XCTest
@testable import AgentDeckApp

final class SessionStoreTests: XCTestCase {
    func testSavesAndLoadsWorkspaceSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(baseDirectory: directory)
        let snapshot = WorkspaceSnapshot(
            layout: .two,
            activeAgentIDs: ["claude-code", "codex"],
            recentWorkspace: "/Users/test/project"
        )

        try store.save(snapshot)
        let loaded = try store.loadSnapshot()

        XCTAssertEqual(loaded, snapshot)
    }

    func testMissingSnapshotReturnsDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = SessionStore(baseDirectory: directory)
        XCTAssertEqual(try store.loadSnapshot(), WorkspaceSnapshot.default)
    }
}
