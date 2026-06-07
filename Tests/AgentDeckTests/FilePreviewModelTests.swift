import Foundation
import XCTest
@testable import AgentDeckApp

final class FilePreviewModelTests: XCTestCase {
    func testClassifiesMarkdownAndSourceLanguages() {
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/README.md")), .markdown)
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/App.swift")), .code(language: "swift"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/tool.py")), .code(language: "python"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/app.tsx")), .code(language: "tsx"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/config.yml")), .code(language: "yaml"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/Dockerfile")), .code(language: "dockerfile"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/notes.txt")), .plainText)
    }

    func testKnownBinaryExtensionIsUnsupported() {
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/image.png")), .unsupported)
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/archive.zip")), .unsupported)
    }

    func testLoadsUTF8TextInsideWorkspace() throws {
        let fixture = try PreviewFixture(text: "let value = 1", name: "App.swift")
        defer { fixture.remove() }

        let content = try FilePreviewModel.load(url: fixture.file, workspace: fixture.root).get()

        XCTAssertEqual(content.text, "let value = 1")
        XCTAssertEqual(content.kind, .code(language: "swift"))
        XCTAssertEqual(content.url, fixture.file)
    }

    func testRejectsFileOutsideWorkspace() throws {
        let fixture = try PreviewFixture(text: "inside", name: "inside.txt")
        defer { fixture.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        assertFailure(
            FilePreviewModel.load(url: outside, workspace: fixture.root),
            equals: .outsideWorkspace
        )
    }

    func testRejectsMissingFile() throws {
        let fixture = try PreviewFixture(text: "inside", name: "inside.txt")
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing.txt")

        assertFailure(
            FilePreviewModel.load(url: missing, workspace: fixture.root),
            equals: .missing
        )
    }

    func testRejectsOversizedFile() throws {
        let fixture = try PreviewFixture(data: Data(repeating: 65, count: FilePreviewModel.maximumByteCount + 1), name: "large.txt")
        defer { fixture.remove() }

        assertFailure(
            FilePreviewModel.load(url: fixture.file, workspace: fixture.root),
            equals: .tooLarge
        )
    }

    func testRejectsKnownBinaryAndInvalidUTF8() throws {
        let image = try PreviewFixture(data: Data([0x89, 0x50, 0x4E, 0x47]), name: "image.png")
        defer { image.remove() }
        assertFailure(
            FilePreviewModel.load(url: image.file, workspace: image.root),
            equals: .unsupported
        )

        let invalidText = try PreviewFixture(data: Data([0xC3, 0x28]), name: "broken.txt")
        defer { invalidText.remove() }
        assertFailure(
            FilePreviewModel.load(url: invalidText.file, workspace: invalidText.root),
            equals: .unsupported
        )
    }

    private func assertFailure(
        _ result: Result<FilePreviewContent, FilePreviewLoadError>,
        equals expected: FilePreviewLoadError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success(let content):
            XCTFail("Expected \(expected), got \(content)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, file: file, line: line)
        }
    }
}

struct PreviewFixture {
    let root: URL
    let file: URL

    init(text: String, name: String) throws {
        try self.init(data: Data(text.utf8), name: name)
    }

    init(data: Data, name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
