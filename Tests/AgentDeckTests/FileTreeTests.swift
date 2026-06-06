import XCTest
@testable import AgentDeckApp

final class FileTreeTests: XCTestCase {
    func testListsDirectoriesFirstThenFilesAlphabeticallySkippingHidden() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: root.appendingPathComponent("Zsub", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("asub", isDirectory: true), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("banana.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Apple.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let nodes = FileTree.children(of: root)

        // 目录在前(按名不分大小写)，再文件；隐藏项跳过。
        XCTAssertEqual(nodes.map(\.name), ["asub", "Zsub", "Apple.swift", "banana.txt"])
        XCTAssertEqual(nodes.map(\.isDirectory), [true, true, false, false])
    }

    func testNonexistentDirectoryYieldsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertTrue(FileTree.children(of: missing).isEmpty)
    }
}
