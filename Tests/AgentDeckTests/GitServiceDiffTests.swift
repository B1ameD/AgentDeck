import XCTest
import Foundation
@testable import AgentDeckApp

/// `GitService.diff` 的端到端测试：建临时 git 仓库跑真 git。git 不可用时跳过。
final class GitServiceDiffTests: XCTestCase {
    private let gitPath = "/usr/bin/git"

    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: root)
        return root
    }

    private func runGit(_ args: [String], in dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        process.currentDirectoryURL = dir
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "t@example.com"
        ]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
    }

    func testDiffShowsModificationForTrackedFile() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: gitPath), "git 不可用")
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "hello.txt")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)
        try runGit(["add", "."], in: root)
        try runGit(["commit", "-q", "-m", "init"], in: root)
        try "line1\nline2 changed\nline3\n".write(to: file, atomically: true, encoding: .utf8)

        let parsed = UnifiedDiffParser.parse(await GitService().diff(forPath: "hello.txt", in: root))
        XCTAssertGreaterThan(parsed.addedCount, 0)
        XCTAssertGreaterThan(parsed.removedCount, 0)
        XCTAssertFalse(parsed.isBinary)
    }

    func testDiffShowsUntrackedFileAsAdditions() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: gitPath), "git 不可用")
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }

        try "a\nb\nc\n".write(to: root.appending(path: "new.txt"), atomically: true, encoding: .utf8)

        let parsed = UnifiedDiffParser.parse(await GitService().diff(forPath: "new.txt", in: root))
        XCTAssertEqual(parsed.removedCount, 0)
        XCTAssertGreaterThan(parsed.addedCount, 0)
    }
}
