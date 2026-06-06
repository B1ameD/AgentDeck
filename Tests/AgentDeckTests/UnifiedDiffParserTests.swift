import XCTest
@testable import AgentDeckApp

final class UnifiedDiffParserTests: XCTestCase {
    func testEmptyInputYieldsEmptyDiff() {
        XCTAssertEqual(UnifiedDiffParser.parse(""), .empty)
    }

    func testSingleHunkTracksLineNumbersAndCounts() {
        let diff = """
        diff --git a/file.txt b/file.txt
        index e69de29..b6fc4c6 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,4 @@
         line1
        -line2
        +line2 modified
        +line3 added
         line4
        """

        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertFalse(parsed.isBinary)
        XCTAssertEqual(parsed.hunks.count, 1)
        XCTAssertEqual(parsed.addedCount, 2)
        XCTAssertEqual(parsed.removedCount, 1)

        let lines = parsed.hunks[0].lines
        XCTAssertEqual(lines.map(\.kind), [.context, .deletion, .addition, .addition, .context])
        // 上下文 line1：旧1/新1
        XCTAssertEqual(lines[0].oldNumber, 1)
        XCTAssertEqual(lines[0].newNumber, 1)
        // 删除 line2：旧2、新 nil
        XCTAssertEqual(lines[1].oldNumber, 2)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[1].text, "line2")
        // 新增 line2 modified：旧 nil、新2
        XCTAssertNil(lines[2].oldNumber)
        XCTAssertEqual(lines[2].newNumber, 2)
        // 末尾上下文 line4：旧3/新4
        XCTAssertEqual(lines[4].oldNumber, 3)
        XCTAssertEqual(lines[4].newNumber, 4)
    }

    func testUntrackedNewFileIsAllAdditions() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..3b18e51
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """

        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.addedCount, 2)
        XCTAssertEqual(parsed.removedCount, 0)
        XCTAssertEqual(parsed.hunks[0].lines.map(\.kind), [.addition, .addition])
        XCTAssertEqual(parsed.hunks[0].lines[0].newNumber, 1)
        XCTAssertEqual(parsed.hunks[0].lines[1].newNumber, 2)
        XCTAssertNil(parsed.hunks[0].lines[0].oldNumber)
    }

    func testBinaryFileIsDetected() {
        let diff = """
        diff --git a/img.png b/img.png
        index 1234567..89abcde 100644
        Binary files a/img.png and b/img.png differ
        """

        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertTrue(parsed.isBinary)
        XCTAssertTrue(parsed.hunks.isEmpty)
        XCTAssertFalse(parsed.isEmpty) // 二进制不算「空」（isEmpty 仅指无可视文本差异）
    }

    func testNoNewlineMarkersAreSkipped() {
        let diff = """
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """

        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.addedCount, 1)
        XCTAssertEqual(parsed.removedCount, 1)
        XCTAssertEqual(parsed.hunks[0].lines.map(\.kind), [.deletion, .addition])
    }

    func testMultipleHunksEachTrackOwnLineNumbers() {
        let diff = """
        @@ -1,2 +1,2 @@
         a
        -b
        +B
        @@ -10,2 +10,3 @@
         x
        +Y
         z
        """

        let parsed = UnifiedDiffParser.parse(diff)
        XCTAssertEqual(parsed.hunks.count, 2)
        XCTAssertEqual(parsed.addedCount, 2)
        XCTAssertEqual(parsed.removedCount, 1)
        // 第二个 hunk 从旧10/新10 起算。
        XCTAssertEqual(parsed.hunks[1].lines[0].oldNumber, 10)
        XCTAssertEqual(parsed.hunks[1].lines[0].newNumber, 10)
        // "+Y" 新增：新11；其后上下文 z：旧11/新12。
        XCTAssertEqual(parsed.hunks[1].lines[1].newNumber, 11)
        XCTAssertEqual(parsed.hunks[1].lines[2].oldNumber, 11)
        XCTAssertEqual(parsed.hunks[1].lines[2].newNumber, 12)
    }

    func testParseHunkHeaderWithoutCounts() {
        XCTAssertEqual(UnifiedDiffParser.parseHunkHeader("@@ -1 +1 @@").oldStart, 1)
        XCTAssertEqual(UnifiedDiffParser.parseHunkHeader("@@ -10,0 +11,5 @@").newStart, 11)
        XCTAssertEqual(UnifiedDiffParser.parseHunkHeader("@@ -10,0 +11,5 @@").oldStart, 10)
    }
}
