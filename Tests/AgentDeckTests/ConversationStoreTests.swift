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
        store.save(convo)

        let loaded = store.load(id: "c1")
        XCTAssertEqual(loaded, convo)
        XCTAssertEqual(loaded?.title, "你好")
    }

    func testAllSortedByUpdatedDescending() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        store.save(conversation(id: "old", agent: "a", texts: [(.user, "x")], updatedAt: Date(timeIntervalSince1970: 1)))
        store.save(conversation(id: "new", agent: "a", texts: [(.user, "y")], updatedAt: Date(timeIntervalSince1970: 2)))

        XCTAssertEqual(store.all().map(\.id), ["new", "old"])
    }

    func testDeleteRemovesConversation() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        store.save(conversation(id: "c1", agent: "a", texts: [(.user, "x")], updatedAt: Date()))
        store.delete(id: "c1")
        XCTAssertNil(store.load(id: "c1"))
    }

    // MARK: - 摘要索引(#31:Recent 列表不再解码全库消息正文)

    func testSummariesStayInSyncWithSavesAndDeletes() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }

        store.save(conversation(id: "old", agent: "claude", texts: [(.user, "第一问")], updatedAt: Date(timeIntervalSince1970: 1)))
        store.save(conversation(id: "new", agent: "codex", texts: [(.user, "第二问")], updatedAt: Date(timeIntervalSince1970: 2)))

        // 摘要缓存同步维护:无需等待后台写盘即可见
        XCTAssertEqual(store.summaries().map(\.id), ["new", "old"])
        XCTAssertEqual(store.summaries().first?.title, "第二问")
        XCTAssertEqual(store.summaries().first?.agentName, "codex")

        store.delete(id: "new")
        XCTAssertEqual(store.summaries().map(\.id), ["old"])
    }

    func testSummariesRebuildFromLegacyFilesWithoutIndex() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 直接落老格式文件(无 index.json),模拟旧版升级
        let legacy = conversation(id: "legacy", agent: "claude", texts: [(.user, "旧会话")], updatedAt: Date(timeIntervalSince1970: 9))
        try JSONEncoder().encode(legacy).write(to: dir.appendingPathComponent("legacy.json"))

        let store = ConversationStore(directory: dir)
        let summaries = store.summaries()
        XCTAssertEqual(summaries.map(\.id), ["legacy"], "无索引 → 全量扫描重建一次")
        XCTAssertEqual(summaries.first?.title, "旧会话")
    }

    func testSummariesPersistAcrossInstancesViaIndex() {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        store.save(conversation(id: "c1", agent: "claude", texts: [(.user, "标题来源")], updatedAt: Date(timeIntervalSince1970: 5)))
        store.waitForPendingWrites()

        let reopened = ConversationStore(directory: store.directory)
        XCTAssertEqual(reopened.summaries().first?.title, "标题来源", "新实例从 index.json 直接得到摘要")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("index.json").path)
        )
        XCTAssertEqual(reopened.all().map(\.id), ["c1"], "index.json 不会被当成会话文件")
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
