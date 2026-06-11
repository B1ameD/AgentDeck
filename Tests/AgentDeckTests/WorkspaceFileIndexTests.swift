import XCTest
@testable import AgentDeckApp

final class WorkspaceFileIndexTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testBuildCollectsRelativePathsAndBasenames() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("a", to: root.appending(path: "a.txt"))
        try write("b", to: root.appending(path: "sub/b.swift"))

        let snapshot = WorkspaceFileSnapshot.build(directory: root)
        XCTAssertTrue(snapshot.relativePaths.contains("a.txt"))
        XCTAssertTrue(snapshot.relativePaths.contains("sub/b.swift"))
        XCTAssertEqual(snapshot.basenameToRelative["b.swift"], ["sub/b.swift"])
        XCTAssertFalse(snapshot.truncated)
    }

    func testBuildExcludesHeavyDirectories() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("keep", to: root.appending(path: "keep.swift"))
        try write("dep", to: root.appending(path: "node_modules/pkg/index.js"))
        try write("obj", to: root.appending(path: ".build/debug/x.o"))

        let snapshot = WorkspaceFileSnapshot.build(directory: root)
        XCTAssertTrue(snapshot.relativePaths.contains("keep.swift"))
        XCTAssertFalse(snapshot.relativePaths.contains { $0.hasPrefix("node_modules/") })
        XCTAssertFalse(snapshot.relativePaths.contains { $0.hasPrefix(".build/") })
    }

    func testRelativePathForTokenResolvesDirectAndBasename() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("x", to: root.appending(path: "Sources/App.swift"))

        let snapshot = WorkspaceFileSnapshot.build(directory: root)
        // 直接相对路径命中
        XCTAssertEqual(snapshot.relativePath(forToken: "Sources/App.swift"), "Sources/App.swift")
        // "./" 前缀归一化
        XCTAssertEqual(snapshot.relativePath(forToken: "./Sources/App.swift"), "Sources/App.swift")
        // 仅文件名按 basename 兜底
        XCTAssertEqual(snapshot.relativePath(forToken: "App.swift"), "Sources/App.swift")
        // 不存在的 token 返回 nil（不触发任何走盘）
        XCTAssertNil(snapshot.relativePath(forToken: "Nope.swift"))
        XCTAssertNil(snapshot.relativePath(forToken: "e.g."))
    }

    func testBasenameFallbackPrefersShortestPath() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("1", to: root.appending(path: "dup.txt"))
        try write("2", to: root.appending(path: "deep/dir/dup.txt"))

        let snapshot = WorkspaceFileSnapshot.build(directory: root)
        XCTAssertEqual(snapshot.firstRelativePath(forBasename: "dup.txt"), "dup.txt")
    }

    func testBuildHonorsMaxEntriesCap() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<10 {
            try write("\(index)", to: root.appending(path: "f\(index).txt"))
        }

        let snapshot = WorkspaceFileSnapshot.build(directory: root, maxEntries: 3)
        XCTAssertTrue(snapshot.truncated)
        XCTAssertLessThanOrEqual(snapshot.relativePaths.count, 3)
    }

    @MainActor
    func testIndexVersionStableWhenInvalidateFindsNoChanges() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root.appending(path: "a.txt"))

        let index = WorkspaceFileIndex()
        let v1 = index.version(for: root)
        XCTAssertEqual(index.version(for: root), v1) // 缓存命中，版本稳定

        // 每轮对话结束都会 invalidate;内容没变就不许 bump——版本进了消息 renderKey,
        // 无谓 bump 会让全部可见气泡重设文本(清掉选区/链接闪烁,#6 不稳定根因)。
        index.invalidate(root)
        XCTAssertEqual(index.version(for: root), v1, "重建后内容一致 → 版本不动")

        try write("b", to: root.appending(path: "b.txt"))
        index.invalidate(root)
        XCTAssertNotEqual(index.version(for: root), v1, "内容真变了 → 版本提升")
    }

    @MainActor
    func testIndexDoesNotRebuildOnRenderPathWithoutInvalidate() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a", to: root.appending(path: "a.txt"))

        let index = WorkspaceFileIndex(ttl: 0)
        let v1 = index.version(for: root)
        XCTAssertTrue(index.snapshot(for: root).relativePaths.contains("a.txt"))

        try write("b", to: root.appending(path: "b.txt"))

        XCTAssertEqual(index.version(for: root), v1)
        XCTAssertFalse(index.snapshot(for: root).relativePaths.contains("b.txt"))

        index.invalidate(root)
        XCTAssertNotEqual(index.version(for: root), v1)
        XCTAssertTrue(index.snapshot(for: root).relativePaths.contains("b.txt"))
    }
}
