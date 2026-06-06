import XCTest
@testable import AgentDeckApp

final class GitStatusParserTests: XCTestCase {
    func testParsesBranchAndChanges() {
        let output = """
        ## main...origin/main [ahead 1]
        M  Sources/App.swift
         M README.md
        ?? new.txt
        A  added.swift
        """
        let status = GitStatusParser.parse(output)

        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changes.map(\.path), ["Sources/App.swift", "README.md", "new.txt", "added.swift"])

        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })
        XCTAssertTrue(byPath["Sources/App.swift"]!.isStaged)      // "M " 已暂存
        XCTAssertFalse(byPath["README.md"]!.isStaged)             // " M" 未暂存
        XCTAssertTrue(byPath["new.txt"]!.isUntracked)             // "??"
        XCTAssertFalse(byPath["new.txt"]!.isStaged)
        XCTAssertTrue(byPath["added.swift"]!.isStaged)            // "A "
    }

    func testBranchVariants() {
        XCTAssertEqual(GitStatusParser.parseBranch("main...origin/main [ahead 1]"), "main")
        XCTAssertEqual(GitStatusParser.parseBranch("feature/x"), "feature/x")          // 无上游
        XCTAssertEqual(GitStatusParser.parseBranch("No commits yet on master"), "master")
        XCTAssertNil(GitStatusParser.parseBranch("HEAD (no branch)"))                   // 分离头指针
        XCTAssertEqual(GitStatusParser.parseBranch("release/1.0...origin/release/1.0"), "release/1.0")
    }

    func testRenameShowsNewPath() {
        let status = GitStatusParser.parse("## main\nR  old.swift -> new.swift")
        XCTAssertEqual(status.changes.map(\.path), ["new.swift"])
        XCTAssertTrue(status.changes[0].isStaged)
    }

    func testQuotedPathIsUnquoted() {
        let status = GitStatusParser.parse(#"## main\n?? "with space.txt""#.replacingOccurrences(of: "\\n", with: "\n"))
        XCTAssertEqual(status.changes.map(\.path), ["with space.txt"])
    }

    func testCleanRepo() {
        let status = GitStatusParser.parse("## main...origin/main")
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.isClean)
    }

    func testParsesBranchList() {
        XCTAssertEqual(
            GitStatusParser.parseBranchList("main\nfeature/x\n  release/1.0  \n"),
            ["main", "feature/x", "release/1.0"]
        )
    }
}
