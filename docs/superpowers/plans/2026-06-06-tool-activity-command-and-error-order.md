# Tool Activity Command And Error Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep `运行` tool rows readable without path links and place per-tool failures at their actual chronological position in the assistant timeline.

**Architecture:** Extend the pure `ToolActivity` presentation logic to classify run commands and compact only directly executed workspace programs/scripts. Normalize Claude tool-result failures to `.tool` events so the existing `AgentSession` inline marker stream preserves event order without view-layer sorting.

**Tech Stack:** Swift 6, SwiftUI, Foundation, XCTest, Swift Package Manager.

---

### Task 1: Define Run Command Presentation With Failing Tests

**Files:**
- Modify: `Tests/AgentDeckTests/MessagePresentationTests.swift`
- Test: `Tests/AgentDeckTests/MessagePresentationTests.swift`

- [ ] **Step 1: Replace the existing run-link expectation with script compaction expectations**

Add focused assertions that require `运行` rows to return a single text part:

```swift
func testToolActivityRunCommandCompactsExecutedWorkspaceScriptWithoutLink() {
    let workingDirectory = URL(filePath: "/Users/jean/Desktop/Codex/AgentDeck")

    let python = "运行 python3 /Users/jean/Desktop/Codex/AgentDeck/test_script.py --check"
    XCTAssertEqual(
        ToolActivity.displayText(in: python, workingDirectory: workingDirectory),
        "运行 python3 test_script.py --check"
    )
    XCTAssertEqual(
        ToolActivity.displayParts(in: python, workingDirectory: workingDirectory),
        [.text("运行 python3 test_script.py --check")]
    )

    let shell = "运行 zsh /Users/jean/Desktop/Codex/AgentDeck/Scripts/package_app.sh 2>&1"
    XCTAssertEqual(
        ToolActivity.displayText(in: shell, workingDirectory: workingDirectory),
        "运行 zsh package_app.sh 2>&1"
    )
    XCTAssertEqual(
        ToolActivity.displayParts(in: shell, workingDirectory: workingDirectory),
        [.text("运行 zsh package_app.sh 2>&1")]
    )
}
```

- [ ] **Step 2: Add direct executable and inspection-command coverage**

```swift
func testToolActivityRunCommandCompactsDirectWorkspaceExecutableWithoutLink() {
    let workingDirectory = URL(filePath: "/work")
    let summary = "运行 /work/bin/tool --flag"

    XCTAssertEqual(
        ToolActivity.displayText(in: summary, workingDirectory: workingDirectory),
        "运行 tool --flag"
    )
    XCTAssertEqual(
        ToolActivity.displayParts(in: summary, workingDirectory: workingDirectory),
        [.text("运行 tool --flag")]
    )
}

func testToolActivityRunCommandPreservesInspectionPaths() {
    let workingDirectory = URL(filePath: "/work")
    let summaries = [
        "运行 ls -la /work/dist",
        "运行 find /work -name '*.swift'",
        "运行 grep -n TODO /work/Sources",
        "运行 pwd"
    ]

    for summary in summaries {
        XCTAssertEqual(
            ToolActivity.displayText(in: summary, workingDirectory: workingDirectory),
            summary
        )
        XCTAssertEqual(
            ToolActivity.displayParts(in: summary, workingDirectory: workingDirectory),
            [.text(summary)]
        )
    }
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
swift test --filter MessagePresentationTests/testToolActivityRunCommand
```

Expected: failures because run paths are still emitted as `.file` parts or compacted indiscriminately.

### Task 2: Implement Semantic Run Command Compaction

**Files:**
- Modify: `Sources/AgentDeckApp/Sessions/SessionModels.swift`
- Test: `Tests/AgentDeckTests/MessagePresentationTests.swift`

- [ ] **Step 1: Route `运行` summaries through a text-only formatter**

At the start of `ToolActivity.displayParts(in:workingDirectory:)`, return one text part for run commands:

```swift
if summary.hasPrefix("运行 ") {
    return [.text(displayRunCommand(in: summary, workingDirectory: workingDirectory))]
}
```

- [ ] **Step 2: Add the minimal command classifier**

Add private helpers within `ToolActivity`:

```swift
private struct ShellToken {
    let value: String
    let range: Range<String.Index>
    let quote: Character?
}

private static let scriptInterpreters: Set<String> = [
    "bash", "node", "python", "python3", "ruby", "sh", "zsh"
]

private static func displayRunCommand(in summary: String, workingDirectory: URL) -> String {
    let prefix = "运行 "
    guard summary.hasPrefix(prefix) else { return summary }

    let command = String(summary.dropFirst(prefix.count))
    let tokens = shellPrefixTokens(in: command, limit: 2)
    guard !tokens.isEmpty else { return summary }

    let targetIndex: Int
    let executable = URL(filePath: tokens[0].value).lastPathComponent
    if scriptInterpreters.contains(executable) {
        guard tokens.count > 1 else { return summary }
        targetIndex = 1
    } else {
        targetIndex = 0
    }

    let target = tokens[targetIndex]
    guard isAbsoluteWorkspacePath(target.value, workingDirectory: workingDirectory) else {
        return summary
    }

    let basename = URL(filePath: target.value).lastPathComponent
    guard !basename.isEmpty else { return summary }

    let replacement: String
    if let quote = target.quote, basename.contains(where: { $0.isWhitespace }) {
        replacement = "\(quote)\(basename)\(quote)"
    } else {
        replacement = basename
    }

    var compact = command
    compact.replaceSubrange(target.range, with: replacement)
    return prefix + compact
}

private static func shellPrefixTokens(in command: String, limit: Int) -> [ShellToken] {
    var tokens: [ShellToken] = []
    var cursor = command.startIndex

    while cursor < command.endIndex, tokens.count < limit {
        while cursor < command.endIndex, command[cursor].isWhitespace {
            cursor = command.index(after: cursor)
        }
        guard cursor < command.endIndex else { break }

        if isAmbiguousShellOperator(at: cursor, in: command) {
            return []
        }

        let start = cursor
        var value = ""
        var quote: Character?

        while cursor < command.endIndex {
            let character = command[cursor]

            if let activeQuote = quote {
                if character == activeQuote {
                    cursor = command.index(after: cursor)
                    quote = nil
                    continue
                }
                value.append(character)
                cursor = command.index(after: cursor)
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                cursor = command.index(after: cursor)
                continue
            }
            if character.isWhitespace {
                break
            }
            if isAmbiguousShellOperator(at: cursor, in: command) {
                return []
            }

            value.append(character)
            cursor = command.index(after: cursor)
        }

        guard quote == nil, !value.isEmpty else { return [] }
        tokens.append(ShellToken(value: value, range: start..<cursor, quote: command[start] == "'" || command[start] == "\"" ? command[start] : nil))
    }

    return tokens
}

private static func isAmbiguousShellOperator(at index: String.Index, in command: String) -> Bool {
    let character = command[index]
    if "|;<>`".contains(character) { return true }
    return character == "$"
        && command.index(after: index) < command.endIndex
        && command[command.index(after: index)] == "("
}

private static func isAbsoluteWorkspacePath(_ path: String, workingDirectory: URL) -> Bool {
    guard path.hasPrefix("/") else { return false }
    let file = URL(filePath: path).standardizedFileURL.path
    let root = workingDirectory.standardizedFileURL.path
    return file == root || file.hasPrefix(root + "/")
}
```

The scanner deliberately stops after two tokens, so later flags, paths, pipes, and redirections remain untouched. If an operator or unterminated quote appears before the executable/script target, it returns no tokens and preserves the original summary.

- [ ] **Step 3: Run focused presentation tests and verify GREEN**

Run:

```bash
swift test --filter MessagePresentationTests/testToolActivity
```

Expected: all `ToolActivity` tests pass, including existing file-link tests.

### Task 3: Define Inline Claude Tool Failure Ordering With Failing Tests

**Files:**
- Modify: `Tests/AgentDeckTests/OutputParserTests.swift`
- Modify: `Tests/AgentDeckTests/AgentSessionTests.swift`
- Test: `Tests/AgentDeckTests/OutputParserTests.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Change the parser expectation for Claude tool-result errors**

Update the existing test:

```swift
func testToolResultErrorIsSurfacedAsInlineToolActivity() {
    let parser = OutputParser(mode: .jsonLines)
    let events = parser.parse(
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"File not found: x.swift"}]}}"# + "\n"
    )

    XCTAssertEqual(events, [OutputEvent(kind: .tool, text: "工具出错：File not found: x.swift")])
}
```

- [ ] **Step 2: Add a session ordering regression test**

```swift
func testJSONLinesToolErrorStaysBetweenEarlierAndLaterAssistantText() async {
    let config = streamingConfig(id: "jsonl-tool-error-agent", outputMode: .jsonLines)
    let runner = ChunkedRunner(events: [
        .stdout(#"{"type":"message","text":"先尝试。"}"# + "\n"),
        .stdout(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"Exit code 1"}]}}"# + "\n"),
        .stdout(#"{"type":"message","text":"改用另一种方式。"}"# + "\n"),
        .exit(0)
    ])
    let session = AgentSession(
        agent: config,
        workingDirectory: FileManager.default.temporaryDirectory,
        runner: runner
    )

    await session.send("run")

    XCTAssertEqual(session.messages.map(\.role), [.user, .assistant])
    XCTAssertEqual(MessagePresentation.assistantBlocks(in: session.messages[1].text), [
        .text("先尝试。"),
        .toolCall("工具出错：Exit code 1"),
        .text("改用另一种方式。")
    ])
}
```

- [ ] **Step 3: Run focused tests and verify RED**

Run:

```bash
swift test --filter OutputParserTests/testToolResultErrorIsSurfacedAsInlineToolActivity
swift test --filter AgentSessionTests/testJSONLinesToolErrorStaysBetweenEarlierAndLaterAssistantText
```

Expected: parser test fails with `.status`; session test shows a separate system message or missing inline block.

### Task 4: Normalize Tool-Result Errors To Inline Tool Events

**Files:**
- Modify: `Sources/AgentDeckApp/Parsing/OutputParser.swift`
- Test: `Tests/AgentDeckTests/OutputParserTests.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Emit `.tool` for Claude tool-result errors**

In `OutputParser.classify(_:)`, change only the `type == "user"` tool-result error branch:

```swift
case "user":
    return Self.toolResultError(in: object).map { OutputEvent(kind: .tool, text: $0) }
```

Do not change structured API errors, result errors, process exit handling, or OpenCode tool-state errors.

- [ ] **Step 2: Run focused parser and session tests and verify GREEN**

Run:

```bash
swift test --filter OutputParserTests/testToolResultErrorIsSurfacedAsInlineToolActivity
swift test --filter AgentSessionTests/testJSONLinesToolErrorStaysBetweenEarlierAndLaterAssistantText
swift test --filter OutputParserTests/testOpenCodeToolUseErrorEmitsCompactStatus
```

Expected: all pass.

### Task 5: Regression Verification

**Files:**
- Verify: `Sources/AgentDeckApp/Sessions/SessionModels.swift`
- Verify: `Sources/AgentDeckApp/Parsing/OutputParser.swift`
- Verify: `Tests/AgentDeckTests/MessagePresentationTests.swift`
- Verify: `Tests/AgentDeckTests/OutputParserTests.swift`
- Verify: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Run the complete test suite**

Run:

```bash
swift test
```

Expected: all tests pass with no new warnings or failures.

- [ ] **Step 2: Build the release app**

Run:

```bash
zsh Scripts/package_app.sh
```

Expected: release build succeeds and `dist/AgentDeck.app` exists.

- [ ] **Step 3: Verify the resulting diff is scoped**

Run:

```bash
git diff --check
git diff -- Sources/AgentDeckApp/Sessions/SessionModels.swift \
  Sources/AgentDeckApp/Parsing/OutputParser.swift \
  Tests/AgentDeckTests/MessagePresentationTests.swift \
  Tests/AgentDeckTests/OutputParserTests.swift \
  Tests/AgentDeckTests/AgentSessionTests.swift
```

Expected: only run-command presentation, inline tool-error ordering, and their tests are added on top of the existing worktree changes.
