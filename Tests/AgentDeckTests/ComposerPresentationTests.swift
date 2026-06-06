import XCTest
@testable import AgentDeckApp

final class ComposerPresentationTests: XCTestCase {
    func testBroadcastPresentationUsesSharedChatBoxCopy() {
        let chat = ComposerModePresentation(isBroadcast: false, targetCount: 1, agentName: "Claude")
        XCTAssertEqual(chat.placeholder, "Message Claude")
        XCTAssertTrue(chat.resolvesSlashCommands)
        XCTAssertEqual(chat.submitHelp, "发送")

        let broadcast = ComposerModePresentation(isBroadcast: true, targetCount: 3, agentName: "Claude")
        XCTAssertEqual(broadcast.placeholder, "输入要广播给所有agent的请求")
        XCTAssertFalse(broadcast.resolvesSlashCommands)
        XCTAssertEqual(broadcast.submitHelp, "广播给 3 个 agent")
    }
}
