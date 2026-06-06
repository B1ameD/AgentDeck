import XCTest
@testable import AgentDeckApp

final class ClaudeSessionDiscoveryTests: XCTestCase {
    func testEncodesWorkingDirectoryLikeClaude() {
        XCTAssertEqual(
            ClaudeSessionDiscovery.encodedProjectDirName(forPath: "/Users/jean/Desktop/Codex"),
            "-Users-jean-Desktop-Codex"
        )
        // 空格等非字母数字字符也替换为 “-”。
        XCTAssertEqual(
            ClaudeSessionDiscovery.encodedProjectDirName(forPath: "/Users/jean/Desktop/Claude Code"),
            "-Users-jean-Desktop-Claude-Code"
        )
    }

    func testDiscoversSessionsWithTitlesSortedByModifiedDate() throws {
        let fixture = try makeClaudeHome(workingDirectory: "/Users/test/MyProject")
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        try writeSession(in: fixture.projectDir, id: "old", userText: "旧会话", modified: Date(timeIntervalSince1970: 1000))
        try writeSession(in: fixture.projectDir, id: "new", userText: "新会话", modified: Date(timeIntervalSince1970: 2000))

        let sessions = ClaudeSessionDiscovery.sessions(
            claudeHome: fixture.home,
            workingDirectory: URL(filePath: "/Users/test/MyProject")
        )

        XCTAssertEqual(sessions.map(\.id), ["new", "old"]) // 倒序
        XCTAssertEqual(sessions.map(\.title), ["新会话", "旧会话"])
    }

    func testUnknownWorkingDirectoryYieldsNoSessions() throws {
        let fixture = try makeClaudeHome(workingDirectory: "/Users/test/MyProject")
        defer { try? FileManager.default.removeItem(at: fixture.home) }

        let sessions = ClaudeSessionDiscovery.sessions(
            claudeHome: fixture.home,
            workingDirectory: URL(filePath: "/Users/test/Other")
        )
        XCTAssertTrue(sessions.isEmpty)
    }

    func testTranscriptExtractsUserAndAssistantText() throws {
        let fixture = try makeClaudeHome(workingDirectory: "/Users/test/MyProject")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let url = try writeSession(in: fixture.projectDir, id: "s1", userText: "你好", modified: Date())

        let transcript = ClaudeSessionDiscovery.transcript(in: url)
        XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
        XCTAssertEqual(transcript.map(\.text), ["你好", "好的，开始。"])
    }

    // MARK: - 夹具

    private func makeClaudeHome(workingDirectory: String) throws -> (home: URL, projectDir: URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectDir = home
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: ClaudeSessionDiscovery.encodedProjectDirName(forPath: workingDirectory), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return (home, projectDir)
    }

    @discardableResult
    private func writeSession(in dir: URL, id: String, userText: String, modified: Date) throws -> URL {
        // 模拟真实 jsonl：含 queue-operation（无 message）、user（字符串 content）、assistant（文本块数组）。
        let lines = [
            #"{"type":"queue-operation","sessionId":"\#(id)","timestamp":"t"}"#,
            #"{"type":"user","message":{"role":"user","content":"\#(userText)"},"sessionId":"\#(id)"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好的，开始。"}]},"sessionId":"\#(id)"}"#
        ]
        let url = dir.appendingPathComponent("\(id).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }
}
