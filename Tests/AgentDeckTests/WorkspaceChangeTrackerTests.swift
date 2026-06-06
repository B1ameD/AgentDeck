import XCTest
@testable import AgentDeckApp

final class WorkspaceChangeTrackerTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testFilesystemFallbackDetectsNewAndModifiedFilesOutsideGit() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "v1".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let tracker = GitWorkspaceChangeTracker()
        let baseline = await tracker.snapshot(in: dir)

        // 改 a.txt（内容变长→size 变）+ 新增 b.txt。
        try "v2-modified".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new file".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let changed = await tracker.changedFiles(in: dir, since: baseline)
        XCTAssertTrue(changed.contains("a.txt"))
        XCTAssertTrue(changed.contains("b.txt"))
    }

    func testFilesystemFallbackIgnoresUnchangedFiles() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "stable".write(to: dir.appendingPathComponent("keep.txt"), atomically: true, encoding: .utf8)

        let tracker = GitWorkspaceChangeTracker()
        let baseline = await tracker.snapshot(in: dir)
        let changed = await tracker.changedFiles(in: dir, since: baseline)

        XCTAssertTrue(changed.isEmpty)
    }

    func testFingerprintsExcludeHeavyDirectories() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nodeModules = dir.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try "junk".write(to: nodeModules.appendingPathComponent("x.js"), atomically: true, encoding: .utf8)
        try "real".write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let prints = GitWorkspaceChangeTracker.fingerprintsSync(in: dir)

        XCTAssertNotNil(prints["main.swift"])
        XCTAssertNil(prints["node_modules/x.js"]) // 重目录被排除，不进指纹
    }
}

final class ShellEnvironmentTests: XCTestCase {
    func testEnrichedPATHPutsCommandDirectoryFirst() {
        let path = ShellEnvironment.enrichedPATH(forCommandAt: "/opt/custom/bin/claude")
        let components = path.split(separator: ":").map(String.init)
        XCTAssertEqual(components.first, "/opt/custom/bin") // 命令所在目录排最前（node 常与之同目录）
        XCTAssertTrue(components.contains("/usr/bin"))       // 始终含系统兜底目录
    }

    func testEnrichedPATHHasNoDuplicates() {
        let path = ShellEnvironment.enrichedPATH(forCommandAt: "/usr/bin/git")
        let components = path.split(separator: ":").map(String.init)
        XCTAssertEqual(components.count, Set(components).count) // 去重
    }
}
