import XCTest
@testable import AgentDeckApp

final class LinkifiedTextTests: XCTestCase {
    func testCreatesFilePartsForRelativePathAndBasename() {
        let parts = LinkifiedText.parts(
            in: "Changed Sources/App.swift and App.swift.",
            fileLinks: ["Sources/App.swift"],
            workingDirectory: URL(filePath: "/tmp/project")
        )

        XCTAssertEqual(parts, [
            .text("Changed "),
            .file(label: "Sources/App.swift", relativePath: "Sources/App.swift"),
            .text(" and "),
            .file(label: "App.swift", relativePath: "Sources/App.swift"),
            .text(".")
        ])
    }

    func testCreatesURLParts() {
        let parts = LinkifiedText.parts(
            in: "Open https://example.com/docs now.",
            fileLinks: [],
            workingDirectory: URL(filePath: "/tmp/project")
        )

        XCTAssertEqual(parts, [
            .text("Open "),
            .webURL("https://example.com/docs"),
            .text(" now.")
        ])
    }

    func testFolderRelativePathUsesWorkspaceRoot() {
        let fileURL = URL(filePath: "/tmp/project/Sources/App.swift")
        XCTAssertEqual(
            LinkifiedText.folderRelativePath(for: fileURL, workingDirectory: URL(filePath: "/tmp/project")),
            "Sources"
        )
        XCTAssertEqual(
            LinkifiedText.folderRelativePath(for: URL(filePath: "/tmp/project/App.swift"), workingDirectory: URL(filePath: "/tmp/project")),
            "."
        )
    }

    func testResolvedFileURLFallsBackToExistingBasenameWhenStoredPathIsStale() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expected = root.appending(path: "test.md")
        try "hello".write(to: expected, atomically: true, encoding: .utf8)

        let resolved = LinkifiedText.resolvedFileURL(
            label: "test.md",
            relativePath: "missing/test.md",
            workingDirectory: root
        )

        XCTAssertEqual(resolved.standardizedFileURL.path, expected.standardizedFileURL.path)
    }

    func testDetectsExistingFileReferencesInMessageText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "hello".write(to: root.appending(path: "test.md"), atomically: true, encoding: .utf8)

        let links = LinkifiedText.existingFileReferences(
            in: "已修改 test.md，主要变更如下。",
            workingDirectory: root
        )

        XCTAssertEqual(links, ["test.md"])
    }

    func testExistingFileReferencesWithSnapshotOnlyMatchesIndexedFiles() {
        let snapshot = WorkspaceFileSnapshot(
            relativePaths: ["Sources/App.swift", "README.md"],
            basenameToRelative: ["App.swift": ["Sources/App.swift"], "README.md": ["README.md"]],
            truncated: false
        )
        let links = LinkifiedText.existingFileReferences(
            in: "见 App.swift 与 README.md，但 nope.swift 不存在（e.g. 略）。",
            snapshot: snapshot
        )
        XCTAssertEqual(links, ["README.md", "Sources/App.swift"])
    }

    func testResolvedFileURLUsesSnapshotBasenameFallback() {
        let snapshot = WorkspaceFileSnapshot(
            relativePaths: ["Sources/App.swift"],
            basenameToRelative: ["App.swift": ["Sources/App.swift"]],
            truncated: false
        )
        let resolved = LinkifiedText.resolvedFileURL(
            label: "App.swift",
            relativePath: "stale/App.swift",
            workingDirectory: URL(filePath: "/tmp/project"),
            snapshot: snapshot
        )
        XCTAssertEqual(resolved.standardizedFileURL.path, "/tmp/project/Sources/App.swift")
    }
}
