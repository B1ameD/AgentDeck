import XCTest
@testable import AgentDeckApp

final class TurnDiffBuilderTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 用一组「路径 -> 运行前内容」造基线快照（含指纹，便于 existedBefore 判断）。
    private func baseline(_ contents: [String: String]) -> WorkspaceChangeSnapshot {
        var fingerprints: [String: String] = [:]
        var snapshots: [String: FileSnapshot] = [:]
        for (path, content) in contents {
            fingerprints[path] = "\(content.utf8.count):0"
            snapshots[path] = FileSnapshot(relativePath: path, text: content, isBinary: false, byteCount: content.utf8.count)
        }
        return WorkspaceChangeSnapshot(paths: [], fingerprints: fingerprints, fileSnapshots: snapshots)
    }

    // 核心修复：未跟踪 / 运行前已存在的文件被本轮修改 → 只显示改的那行，而不是整文件标绿。
    func testModifiedFileWithBaselineShowsOnlyChangedLines() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let v8 = "line1\nline2\nline3\nline4\n"
        let v9 = "line1\nline2\nCHANGED\nline4\n"
        try v9.write(to: dir.appending(path: "test.md"), atomically: true, encoding: .utf8)

        let summary = await TurnDiffBuilder.build(
            changedPaths: ["test.md"], in: dir, since: baseline(["test.md": v8])
        )

        XCTAssertEqual(summary.files.count, 1)
        let file = summary.files[0]
        XCTAssertEqual(file.status, .modified)
        XCTAssertEqual(file.addedCount, 1, "只应有 1 行新增（CHANGED），而非整文件")
        XCTAssertEqual(file.removedCount, 1, "只应有 1 行删除（line3）")
    }

    func testNewFileIsFullAddition() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "alpha\nbeta\ngamma\n".write(to: dir.appending(path: "new.txt"), atomically: true, encoding: .utf8)

        let summary = await TurnDiffBuilder.build(changedPaths: ["new.txt"], in: dir, since: baseline([:]))

        XCTAssertEqual(summary.files.count, 1)
        XCTAssertEqual(summary.files[0].status, .added)
        XCTAssertEqual(summary.files[0].addedCount, 3)
        XCTAssertEqual(summary.files[0].removedCount, 0)
    }

    func testDeletedFileIsFullDeletion() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 不创建 gone.md（运行后它不存在），基线里有它的内容。
        let summary = await TurnDiffBuilder.build(
            changedPaths: ["gone.md"], in: dir, since: baseline(["gone.md": "a\nb\n"])
        )

        XCTAssertEqual(summary.files.count, 1)
        XCTAssertEqual(summary.files[0].status, .deleted)
        XCTAssertEqual(summary.files[0].removedCount, 2)
        XCTAssertEqual(summary.files[0].addedCount, 0)
    }

    func testUnchangedContentIsNotListed() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let same = "unchanged\nbody\n"
        try same.write(to: dir.appending(path: "same.md"), atomically: true, encoding: .utf8)

        // 指纹「变了」（模拟 mtime 触碰）但内容相同 → 不应进入审核清单。
        let summary = await TurnDiffBuilder.build(
            changedPaths: ["same.md"], in: dir, since: baseline(["same.md": same])
        )
        XCTAssertTrue(summary.files.isEmpty)
    }

    func testNonexistentNeverSeenPathIsSkipped() async throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 路径既不存在于磁盘、也不在基线 → 跳过（多半是路径形态不一致），不误报删除。
        let summary = await TurnDiffBuilder.build(changedPaths: ["ghost.md"], in: dir, since: baseline([:]))
        XCTAssertTrue(summary.files.isEmpty)
    }
}

final class WorkspaceSnapshotContentTests: XCTestCase {
    func testSnapshotCapturesTextBaselineContent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "baseline content\nsecond line\n".write(to: dir.appending(path: "a.txt"), atomically: true, encoding: .utf8)

        let tracker = GitWorkspaceChangeTracker()
        let snapshot = await tracker.snapshot(in: dir)

        XCTAssertEqual(snapshot.fileSnapshots["a.txt"]?.text, "baseline content\nsecond line\n")
        XCTAssertNotNil(snapshot.fingerprints["a.txt"])
    }
}

final class InlineDiffPreviewTests: XCTestCase {
    private func diff(added: Int) -> FileDiff {
        let lines = (0..<added).map { DiffLine(kind: .addition, oldNumber: nil, newNumber: $0 + 1, text: "line\($0)") }
        return FileDiff(hunks: [DiffHunk(header: "@@ -0,0 +1,\(added) @@", lines: lines)], isBinary: false)
    }

    func testPreviewLimitsFileCountAndMarksTruncated() {
        let files = (0..<5).map { TurnFileDiff(path: "f\($0).txt", status: .added, diff: diff(added: 2)) }
        let summary = TurnDiffSummary(workingDirectory: "/tmp", files: files)

        let model = InlineDiffPreview.make(from: summary, maxFiles: 3, maxHunksPerFile: 2, maxLines: 80)

        XCTAssertEqual(model.files.count, 3)
        XCTAssertTrue(model.truncated)
        XCTAssertEqual(model.hiddenFileCount, 2)
    }

    func testPreviewLimitsTotalLines() {
        let summary = TurnDiffSummary(workingDirectory: "/tmp", files: [
            TurnFileDiff(path: "big.txt", status: .added, diff: diff(added: 200))
        ])

        let model = InlineDiffPreview.make(from: summary, maxFiles: 3, maxHunksPerFile: 2, maxLines: 80)

        XCTAssertEqual(model.files.count, 1)
        XCTAssertTrue(model.truncated)
        XCTAssertLessThanOrEqual(model.files[0].diff.hunks.reduce(0) { $0 + $1.lines.count }, 80)
    }

    func testSmallDiffIsNotTruncated() {
        let summary = TurnDiffSummary(workingDirectory: "/tmp", files: [
            TurnFileDiff(path: "a.txt", status: .added, diff: diff(added: 3))
        ])
        let model = InlineDiffPreview.make(from: summary)
        XCTAssertFalse(model.truncated)
        XCTAssertEqual(model.files.count, 1)
    }
}
