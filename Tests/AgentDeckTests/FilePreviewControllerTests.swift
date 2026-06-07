import Foundation
import XCTest
@testable import AgentDeckApp

@MainActor
final class FilePreviewControllerTests: XCTestCase {
    func testEditMakesDocumentDirtyAndSaveClearsDirty() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        defer { fixture.remove() }
        let controller = FilePreviewController(workspace: fixture.root)

        controller.open(fixture.file)
        controller.text = "after"
        XCTAssertTrue(controller.isDirty)

        XCTAssertTrue(controller.save())
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "after")
    }

    func testDiscardRestoresLoadedText() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        defer { fixture.remove() }
        let controller = FilePreviewController(workspace: fixture.root)

        controller.open(fixture.file)
        controller.text = "after"
        controller.discardChanges()

        XCTAssertEqual(controller.text, "before")
        XCTAssertFalse(controller.isDirty)
    }

    func testOpeningAnotherFileReplacesCleanDocument() throws {
        let fixture = try PreviewFixture(text: "first", name: "first.txt")
        defer { fixture.remove() }
        let second = fixture.root.appendingPathComponent("second.swift")
        try "let second = true".write(to: second, atomically: true, encoding: .utf8)
        let controller = FilePreviewController(workspace: fixture.root)

        controller.open(fixture.file)
        controller.open(second)

        XCTAssertEqual(controller.selectedFile, second.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(controller.text, "let second = true")
        XCTAssertEqual(controller.kind, .code(language: "swift"))
        XCTAssertFalse(controller.isDirty)
    }

    func testOpeningFileResetsDisplayModeToPreview() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        defer { fixture.remove() }
        let controller = FilePreviewController(workspace: fixture.root)
        controller.displayMode = .edit

        controller.open(fixture.file)

        XCTAssertEqual(controller.displayMode, .preview)
    }

    func testDirtyDocumentDefersNavigationUntilDiscard() throws {
        let (fixture, controller) = try makeDirtyController()
        defer { fixture.remove() }
        var committed: FilePreviewNavigation?

        controller.request(.switchMode(.browser)) { committed = $0 }

        XCTAssertEqual(controller.pendingNavigation, .switchMode(.browser))
        XCTAssertNil(committed)

        controller.resolvePendingNavigation(.discard)

        XCTAssertEqual(committed, .switchMode(.browser))
        XCTAssertNil(controller.pendingNavigation)
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(controller.text, "before")
    }

    func testSaveResolutionWritesThenCommits() throws {
        let (fixture, controller) = try makeDirtyController()
        defer { fixture.remove() }
        var committed = false

        controller.request(.closeSidebar) { _ in committed = true }
        controller.resolvePendingNavigation(.save)

        XCTAssertTrue(committed)
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "after")
    }

    func testCancelLeavesDirtyDocumentAndDoesNotCommit() throws {
        let (fixture, controller) = try makeDirtyController()
        defer { fixture.remove() }
        var committed = false

        controller.request(.closeSidebar) { _ in committed = true }
        controller.resolvePendingNavigation(.cancel)

        XCTAssertFalse(committed)
        XCTAssertNil(controller.pendingNavigation)
        XCTAssertTrue(controller.isDirty)
        XCTAssertEqual(controller.text, "after")
    }

    func testCleanDocumentCommitsNavigationImmediately() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        defer { fixture.remove() }
        let controller = FilePreviewController(workspace: fixture.root)
        controller.open(fixture.file)
        var committed: FilePreviewNavigation?

        controller.request(.switchMode(.review)) { committed = $0 }

        XCTAssertEqual(committed, .switchMode(.review))
        XCTAssertNil(controller.pendingNavigation)
    }

    func testChangingWorkspaceClearsDocumentState() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        defer { fixture.remove() }
        let nextRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: nextRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nextRoot) }
        let controller = FilePreviewController(workspace: fixture.root)
        controller.open(fixture.file)

        controller.setWorkspace(nextRoot)

        XCTAssertNil(controller.selectedFile)
        XCTAssertNil(controller.kind)
        XCTAssertEqual(controller.text, "")
        XCTAssertFalse(controller.isDirty)
    }

    private func makeDirtyController() throws -> (PreviewFixture, FilePreviewController) {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        let controller = FilePreviewController(workspace: fixture.root)
        controller.open(fixture.file)
        controller.text = "after"
        return (fixture, controller)
    }
}
