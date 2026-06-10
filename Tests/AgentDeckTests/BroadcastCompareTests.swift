import XCTest
@testable import AgentDeckApp

final class BroadcastCompareTests: XCTestCase {
    private func message(
        _ role: ChatMessage.Role,
        _ text: String,
        broadcastID: String? = nil,
        at: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> ChatMessage {
        ChatMessage(role: role, text: text, createdAt: at, broadcastID: broadcastID)
    }

    func testLatestBroadcastIDPicksNewestAcrossSessions() {
        let early = Date(timeIntervalSinceReferenceDate: 100)
        let late = Date(timeIntervalSinceReferenceDate: 200)
        let sessionA = [
            message(.user, "第一轮", broadcastID: "b1", at: early),
            message(.assistant, "答A1"),
            message(.user, "第二轮", broadcastID: "b2", at: late)
        ]
        let sessionB = [message(.user, "第一轮", broadcastID: "b1", at: early)]
        XCTAssertEqual(BroadcastCompare.latestBroadcastID(in: [sessionA, sessionB]), "b2")
        XCTAssertNil(BroadcastCompare.latestBroadcastID(in: [[message(.user, "非广播")]]))
        XCTAssertEqual(
            BroadcastCompare.prompt(in: [sessionB, sessionA], broadcastID: "b2"),
            "第二轮"
        )
    }

    func testResponseCollectsAssistantTextUntilNextUserMessage() {
        let messages = [
            message(.user, "问题", broadcastID: "b1"),
            message(.assistant, "第一段"),
            message(.system, "已停止。"),
            message(.assistant, "第二段"),
            message(.user, "下一轮普通提问"),
            message(.assistant, "不该被算进 b1")
        ]
        XCTAssertEqual(
            BroadcastCompare.response(in: messages, broadcastID: "b1"),
            "第一段\n\n第二段"
        )
    }

    func testResponseDistinguishesAbsentAndPendingSessions() {
        XCTAssertNil(
            BroadcastCompare.response(in: [message(.user, "无关")], broadcastID: "b1"),
            "未参与该轮 → nil"
        )
        XCTAssertEqual(
            BroadcastCompare.response(in: [message(.user, "问题", broadcastID: "b1")], broadcastID: "b1"),
            "",
            "已参与但尚无输出 → 空串"
        )
    }

    func testBroadcastIDSurvivesCodableRoundTrip() throws {
        let original = message(.user, "广播", broadcastID: "b9")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.broadcastID, "b9")

        // 旧文件(无 broadcastID 字段)兼容
        let legacy = try JSONEncoder().encode(message(.user, "旧消息"))
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: legacy).broadcastID)
    }
}
