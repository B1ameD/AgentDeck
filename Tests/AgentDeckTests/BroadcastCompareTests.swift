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

    func testReplyCollectsAssistantTextAndTimingUntilNextUserMessage() {
        let started = Date(timeIntervalSinceReferenceDate: 10)
        let ended = Date(timeIntervalSinceReferenceDate: 25)
        var first = message(.assistant, "第一段")
        first.runStartedAt = started
        var second = message(.assistant, "第二段")
        second.runEndedAt = ended
        let messages = [
            message(.user, "问题", broadcastID: "b1"),
            first,
            message(.system, "已停止。"),
            second,
            message(.user, "下一轮普通提问"),
            message(.assistant, "不该被算进 b1")
        ]
        let reply = BroadcastCompare.reply(in: messages, broadcastID: "b1")
        XCTAssertEqual(reply?.text, "第一段\n\n第二段")
        XCTAssertEqual(reply?.runStartedAt, started, "取首条 assistant 的开始时间")
        XCTAssertEqual(reply?.runEndedAt, ended, "取末条 assistant 的结束时间")
    }

    func testReplyDistinguishesAbsentAndPendingSessions() {
        XCTAssertNil(
            BroadcastCompare.reply(in: [message(.user, "无关")], broadcastID: "b1"),
            "未参与该轮 → nil"
        )
        let pending = BroadcastCompare.reply(in: [message(.user, "问题", broadcastID: "b1")], broadcastID: "b1")
        XCTAssertEqual(pending?.text, "", "已参与但尚无输出 → 空文本")
        XCTAssertNil(pending?.runStartedAt)
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
