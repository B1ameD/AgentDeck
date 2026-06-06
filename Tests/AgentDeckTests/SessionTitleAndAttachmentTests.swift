import AppKit
import XCTest
@testable import AgentDeckApp

final class SessionTitleTests: XCTestCase {
    func testSummarizeTakesFirstNonEmptyLine() {
        XCTAssertEqual(SessionTitle.summarize("\n  Build the parser  \n more"), "Build the parser")
    }

    func testSummarizeTruncatesLongText() {
        let long = String(repeating: "字", count: 100)
        let summary = SessionTitle.summarize(long, maxLength: 40)
        XCTAssertEqual(summary?.count, 41) // 40 + 省略号
        XCTAssertEqual(summary?.hasSuffix("…"), true)
    }

    func testSummarizeReturnsNilForEmptyOrNil() {
        XCTAssertNil(SessionTitle.summarize(nil))
        XCTAssertNil(SessionTitle.summarize("   \n  "))
    }

    func testStoredConversationTitlePrefersCustomTitle() {
        let convo = StoredConversation(
            id: "1", agentID: "a", agentName: "A", workingDirectory: "/x",
            messages: [ChatMessage(role: .user, text: "first message")],
            updatedAt: Date(),
            customTitle: "重命名后的标题"
        )
        XCTAssertEqual(convo.title, "重命名后的标题")
    }

    func testStoredConversationTitleFallsBackToFirstUserMessage() {
        let convo = StoredConversation(
            id: "1", agentID: "a", agentName: "A", workingDirectory: "/x",
            messages: [ChatMessage(role: .user, text: "first user line\nsecond line")],
            updatedAt: Date()
        )
        XCTAssertEqual(convo.title, "first user line")
    }
}

final class AttachmentInfoTests: XCTestCase {
    func testIsImageByExtension() {
        XCTAssertTrue(AttachmentInfo.isImage(URL(filePath: "/tmp/a.PNG")))
        XCTAssertTrue(AttachmentInfo.isImage(URL(filePath: "/tmp/a.jpeg")))
        XCTAssertFalse(AttachmentInfo.isImage(URL(filePath: "/tmp/a.pdf")))
        XCTAssertFalse(AttachmentInfo.isImage(URL(filePath: "/tmp/a")))
    }

    func testIconBucketsByType() {
        XCTAssertEqual(AttachmentInfo.icon(for: URL(filePath: "/tmp/a.png")), "photo")
        XCTAssertEqual(AttachmentInfo.icon(for: URL(filePath: "/tmp/a.pdf")), "doc.richtext")
        XCTAssertEqual(AttachmentInfo.icon(for: URL(filePath: "/tmp/a.swift")), "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(AttachmentInfo.icon(for: URL(filePath: "/tmp/a.unknownext")), "doc")
    }

    func testSizeStringReadsRealFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(repeating: 0, count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = AttachmentInfo.sizeString(url)
        XCTAssertNotNil(size)
        XCTAssertTrue(size?.contains("KB") == true || size?.contains("bytes") == true)
    }

    @MainActor
    func testPromptAttachmentDropExtractsFileURLsFromPasteboard() {
        let first = URL(filePath: "/tmp/AgentDeck/a.png")
        let second = URL(filePath: "/tmp/AgentDeck/spec.md")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AgentDeckTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([first as NSURL, second as NSURL])

        XCTAssertEqual(PromptAttachmentDrop.fileURLs(from: pasteboard), [first, second])
    }

    func testPromptAttachmentDropIgnoresNonFileURLsAndDeduplicates() {
        let file = URL(filePath: "/tmp/AgentDeck/a.png")

        XCTAssertEqual(
            PromptAttachmentDrop.normalizedFileURLs([
                file,
                URL(string: "https://example.com/a.png")!,
                file
            ]),
            [file]
        )
    }
}
