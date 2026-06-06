import XCTest
@testable import AgentDeckApp

final class ConversationStoreTests: XCTestCase {
    private func tempStore() -> ConversationStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return ConversationStore(directory: dir)
    }

    private func conversation(id: String, agent: String, texts: [(ChatMessage.Role, String)], updatedAt: Date) -> StoredConversation {
        StoredConversation(
            id: id,
            agentID: agent,
            agentName: agent,
            workingDirectory: "/tmp",
            messages: texts.map { ChatMessage(role: $0.0, text: $0.1) },
            updatedAt: updatedAt
        )
    }

    func testSaveLoadRoundTrip() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        let convo = conversation(id: "c1", agent: "claude", texts: [(.user, "你好"), (.assistant, "在的")], updatedAt: Date(timeIntervalSince1970: 100))
        try store.save(convo)

        let loaded = store.load(id: "c1")
        XCTAssertEqual(loaded, convo)
        XCTAssertEqual(loaded?.title, "你好")
    }

    func testAllSortedByUpdatedDescending() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        try store.save(conversation(id: "old", agent: "a", texts: [(.user, "x")], updatedAt: Date(timeIntervalSince1970: 1)))
        try store.save(conversation(id: "new", agent: "a", texts: [(.user, "y")], updatedAt: Date(timeIntervalSince1970: 2)))

        XCTAssertEqual(store.all().map(\.id), ["new", "old"])
    }

    func testDeleteRemovesConversation() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(conversation(id: "c1", agent: "a", texts: [(.user, "x")], updatedAt: Date()))
        store.delete(id: "c1")
        XCTAssertNil(store.load(id: "c1"))
    }

    func testSearchFindsMatchesWithSnippetSortedByDate() {
        let convos = [
            conversation(id: "a", agent: "claude", texts: [(.user, "帮我修复登录 bug"), (.assistant, "好的")], updatedAt: Date(timeIntervalSince1970: 1)),
            conversation(id: "b", agent: "codex", texts: [(.user, "写个排序"), (.assistant, "用快排")], updatedAt: Date(timeIntervalSince1970: 2)),
            conversation(id: "c", agent: "claude", texts: [(.user, "登录页样式")], updatedAt: Date(timeIntervalSince1970: 3))
        ]

        let hits = ConversationSearch.search(convos, query: "登录")
        XCTAssertEqual(hits.map(\.id), ["c", "a"]) // 含「登录」，按时间倒序
        XCTAssertTrue(hits.first!.snippet.contains("登录"))

        XCTAssertTrue(ConversationSearch.search(convos, query: "  ").isEmpty) // 空查询无结果
        XCTAssertTrue(ConversationSearch.search(convos, query: "不存在").isEmpty)
    }
}
