# Claude Code Context Continuity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude Code tabs in AgentDeck preserve conversation context across consecutive sends, Recent reopen, and app restart.

**Architecture:** Treat Claude continuity as an explicit per-invocation strategy instead of an accidental side effect of `backendSessionID`. Prefer Claude's native `--resume <session-id>` when a valid captured Claude session exists; fall back once to AgentDeck's local transcript replay when native resume fails or no Claude session is available. Never allow the current broken state where `backendSessionID` disables local replay but is not passed to Claude.

**Tech Stack:** Swift, SwiftUI `@Observable`, async `ProcessRunner`, Claude Code `-p --output-format stream-json`, XCTest.

---

## Root Cause

Current user-visible failure: in one Claude Code tab, repeated prompts like "告诉我你上下文中有哪些对话" are answered as if each turn is a new conversation. The UI stores multiple messages, but Claude receives only the latest prompt.

The broken path in current code:

1. `AgentSession.performSend` computes `externalSessionID = externalSessionIDForInvocation()`.
2. After the first successful Claude run, `captureBackendSessionID` stores the Claude `session_id` into `backendSessionID`.
3. On the next send, `externalSessionIDForInvocation()` returns that non-nil ID.
4. `promptForInvocation(_:externalSessionID:)` only injects `<agentdeck_history>` when `externalSessionID == nil`.
5. `CLIInvocationBuilder.claude(.new)` intentionally ignores `externalSessionID` and does not pass `--resume`.
6. Result: Claude receives just `"second prompt"` with no `--resume` and no local transcript.

This is also reflected by a misleading test:

- `Tests/AgentDeckTests/AgentSessionTests.swift::testClaudeSecondSendResumesCapturedClaudeSessionID`
- The test name says "resumes", but it asserts the second call is `["-p", "--output-format", "stream-json", "--verbose", "second"]`.
- That assertion locks in the bug.

Reference from `mygu/claude-code-haha`:

- Its `src/cli/print.ts` treats `--resume` in print mode as a first-class path.
- In print mode, `--resume` requires a valid session id, then calls `loadConversationForResume(...)`.
- Its `QueryEngine.ts` comments also show why transcript persistence matters: the user message is written before the API loop so a later resume has something to load.
- Do not copy code from that repository. It is useful only as a behavioral reference for Claude Code's observable CLI contract.

## Files

- Modify: `Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift`
  - Add automatic Claude `--resume <backendSessionID>` support for normal `.new` sends when a valid backend session id is supplied.
- Modify: `Sources/AgentDeckApp/Sessions/AgentSession.swift`
  - Add an explicit Claude continuity strategy.
  - Make prompt construction depend on that strategy.
  - Add a single retry path from native resume failure to local transcript replay.
- Modify: `Sources/AgentDeckApp/Sessions/ClaudeSessionDiscovery.swift`
  - Add a small helper to check whether a Claude session file exists for a workdir/session id.
- Modify: `Sources/AgentDeckApp/Storage/SessionStore.swift`
  - Keep existing persisted `backendSessionID` and `backendSessionModel`; no schema break expected.
- Modify: `Sources/AgentDeckApp/Storage/ConversationStore.swift`
  - Keep existing persisted `backendSessionID` and `backendSessionModel`; no schema break expected.
- Test: `Tests/AgentDeckTests/CLIInvocationBuilderTests.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`
- Test: `Tests/AgentDeckTests/ClaudeSessionDiscoveryTests.swift`
- Optional doc update: `CHANGELOG-SESSION.md`

## Non-Goals

- Do not change OpenCode/Codex continuity in this plan.
- Do not rewrite the history search UI.
- Do not copy implementation code from `claude-code-haha`.
- Do not solve Claude slowness here; this plan only fixes missing conversation context.

---

### Task 1: Lock In The Current Bug With Failing Tests

**Files:**
- Modify: `Tests/AgentDeckTests/CLIInvocationBuilderTests.swift`
- Modify: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Replace the misleading builder test**

In `Tests/AgentDeckTests/CLIInvocationBuilderTests.swift`, replace `testClaudeNewDoesNotResumeToAvoidStaleSessionError` with this test:

```swift
func testClaudeNewWithExternalSessionIDUsesNativeResume() {
    let invocation = CLIInvocationBuilder.build(
        agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
        prompt: "second",
        model: "default",
        reasoningEffort: .medium,
        interactionMode: .chat,
        command: .new,
        attachments: [],
        sessionID: "11111111-2222-3333-4444-555555555555",
        externalSessionID: "550e8400-e29b-41d4-a716-446655440000"
    )

    XCTAssertEqual(invocation, CLIInvocation(
        arguments: ["-p", "--resume", "550e8400-e29b-41d4-a716-446655440000", "second"],
        stdin: nil
    ))
}
```

- [ ] **Step 2: Add an AgentSession regression test for second-turn continuity**

In `Tests/AgentDeckTests/AgentSessionTests.swift`, replace the current body of `testClaudeSecondSendResumesCapturedClaudeSessionID` with:

```swift
func testClaudeSecondSendResumesCapturedClaudeSessionID() async {
    let config = AgentConfig(
        id: "claude-code",
        name: "Claude Code",
        command: "/usr/bin/claude",
        args: ["-p", "--output-format", "stream-json", "--verbose"],
        env: [:],
        workingDirectoryPolicy: .workspace,
        inputMode: .oneShotArgument,
        outputMode: .jsonLines,
        supportsStop: true,
        stopSignal: .interrupt
    )
    let runner = ClaudeSessionIDRunner(sessionID: "550e8400-e29b-41d4-a716-446655440000")
    let session = AgentSession(
        agent: config,
        workingDirectory: FileManager.default.temporaryDirectory,
        runner: runner
    )

    await session.send("first")
    await session.send("second")

    let calls = await runner.calls()
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls[0].args, ["-p", "--output-format", "stream-json", "--verbose", "first"])
    XCTAssertEqual(calls[1].args, [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--resume",
        "550e8400-e29b-41d4-a716-446655440000",
        "second"
    ])
    XCTAssertEqual(session.backendSessionID, "550e8400-e29b-41d4-a716-446655440000")
}
```

- [ ] **Step 3: Run the targeted tests and verify they fail**

Run:

```bash
swift test --filter CLIInvocationBuilderTests/testClaudeNewWithExternalSessionIDUsesNativeResume
swift test --filter AgentSessionTests/testClaudeSecondSendResumesCapturedClaudeSessionID
```

Expected:

- The builder test fails because `.new` currently ignores `externalSessionID`.
- The session test fails because the second call currently sends only the raw prompt.

- [ ] **Step 4: Commit the failing tests**

```bash
git add Tests/AgentDeckTests/CLIInvocationBuilderTests.swift Tests/AgentDeckTests/AgentSessionTests.swift
git commit -m "test: expose claude context continuity regression"
```

---

### Task 2: Add Native Claude Resume For Captured Backend Sessions

**Files:**
- Modify: `Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift`
- Test: `Tests/AgentDeckTests/CLIInvocationBuilderTests.swift`

- [ ] **Step 1: Update Claude `.new` argument construction**

In `Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift`, change the `.new` branch inside `private static func claude(...)` to:

```swift
case .new:
    if let id = externalSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
        args += ["--resume", id]
    }
```

Keep the `.resume` branch for user-selected history sessions; it still uses `resumeSessionID`.

- [ ] **Step 2: Run the builder tests**

Run:

```bash
swift test --filter CLIInvocationBuilderTests
```

Expected:

- `testClaudeNewWithExternalSessionIDUsesNativeResume` passes.
- Existing tests that expected `.new` to ignore `externalSessionID` must be updated or removed.
- OpenCode/Codex builder tests remain unchanged.

- [ ] **Step 3: Commit**

```bash
git add Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift Tests/AgentDeckTests/CLIInvocationBuilderTests.swift
git commit -m "fix: resume captured claude sessions on new sends"
```

---

### Task 3: Make Continuity Strategy Explicit In AgentSession

**Files:**
- Modify: `Sources/AgentDeckApp/Sessions/AgentSession.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Add a small internal strategy enum**

Add this near the private state in `AgentSession.swift`:

```swift
private enum ClaudeContinuityStrategy: Equatable {
    case none
    case nativeResume(String)
    case localTranscriptReplay

    var externalSessionID: String? {
        if case .nativeResume(let id) = self { return id }
        return nil
    }
}
```

- [ ] **Step 2: Add a strategy selector**

Add this method below `externalSessionIDForInvocation()`:

```swift
private func claudeContinuityStrategy(for prompt: String) -> ClaudeContinuityStrategy {
    guard agent.kind == .claudeCode, command == .new else { return .none }

    if let id = externalSessionIDForInvocation()?.trimmingCharacters(in: .whitespacesAndNewlines),
       !id.isEmpty {
        return .nativeResume(id)
    }

    if let transcript = localHistoryTranscript(excludingUserPrompt: prompt),
       !transcript.isEmpty {
        return .localTranscriptReplay
    }

    return .none
}
```

- [ ] **Step 3: Change prompt construction to use strategy**

Replace `promptForInvocation(_:externalSessionID:)` with:

```swift
private func promptForInvocation(_ prompt: String, continuity: ClaudeContinuityStrategy) -> String {
    guard agent.kind == .claudeCode,
          command == .new,
          continuity == .localTranscriptReplay,
          let transcript = localHistoryTranscript(excludingUserPrompt: prompt),
          !transcript.isEmpty else {
        return prompt
    }

    return """
    <agentdeck_history>
    The following is the local AgentDeck transcript for this chat. Treat it as prior conversation context.

    \(transcript)
    </agentdeck_history>

    Current user request:
    \(prompt)
    """
}
```

- [ ] **Step 4: Update `performSend` call flow**

At the top of `performSend(prompt:attachments:)`, replace:

```swift
let externalSessionID = externalSessionIDForInvocation()
let title = conversationTitleForInvocation(externalSessionID: externalSessionID)
let invocationPrompt = promptForInvocation(prompt, externalSessionID: externalSessionID)
```

with:

```swift
let continuity = claudeContinuityStrategy(for: prompt)
let externalSessionID = continuity.externalSessionID
let title = conversationTitleForInvocation(externalSessionID: externalSessionID)
let invocationPrompt = promptForInvocation(prompt, continuity: continuity)
```

- [ ] **Step 5: Run the session tests**

Run:

```bash
swift test --filter AgentSessionTests/testClaudeSecondSendResumesCapturedClaudeSessionID
swift test --filter AgentSessionTests/testClaudeWithoutBackendSessionReplaysLocalHistoryOnNextSend
swift test --filter AgentSessionTests/testClaudeLocalHistoryReplayStripsThinkingAndSkipsDuplicateCurrentPrompt
```

Expected:

- Captured backend session uses native `--resume`.
- No backend session still uses `<agentdeck_history>`.
- Thinking blocks are still stripped from local replay.

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentDeckApp/Sessions/AgentSession.swift Tests/AgentDeckTests/AgentSessionTests.swift
git commit -m "fix: make claude continuity strategy explicit"
```

---

### Task 4: Add Resume Failure Fallback To Local Transcript Replay

**Files:**
- Modify: `Sources/AgentDeckApp/Sessions/AgentSession.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Add a run outcome type**

In `AgentSession.swift`, add:

```swift
private struct AgentRunOutcome: Equatable {
    var exitCode: Int32
    var stderr: String
    var producedMessage: Bool

    var isClaudeResumeFailure: Bool {
        let detail = stderr.lowercased()
        return detail.contains("no conversation found")
            || detail.contains("already in use")
            || detail.contains("invalid session")
            || detail.contains("--resume requires")
    }
}
```

- [ ] **Step 2: Make `consume` return the outcome**

Change:

```swift
private func consume(invocation: CLIInvocation) async
```

to:

```swift
private func consume(invocation: CLIInvocation, suppressResumeFailureError: Bool = false) async -> AgentRunOutcome
```

At each successful return, return:

```swift
return AgentRunOutcome(exitCode: exitCode, stderr: stderrBuffer, producedMessage: producedMessage)
```

When exit code is non-zero, only append the error message if it is not a suppressed resume failure:

```swift
let outcome = AgentRunOutcome(exitCode: exitCode, stderr: stderrBuffer, producedMessage: producedMessage)
if !(suppressResumeFailureError && outcome.isClaudeResumeFailure) {
    messages.append(ChatMessage(
        role: .error,
        text: stderrDetail.isEmpty
            ? "运行失败（退出码 \(exitCode)）"
            : "运行失败（退出码 \(exitCode)）：\n\(stderrDetail)"
    ))
}
status = .failed("Exited with code \(exitCode): \(detail)")
return outcome
```

For thrown errors, return:

```swift
return AgentRunOutcome(exitCode: -1, stderr: error.localizedDescription, producedMessage: false)
```

- [ ] **Step 3: Add a helper to clear stale Claude continuity**

Add:

```swift
private func clearBackendSessionForLocalReplay() {
    backendSessionID = nil
    backendSessionModel = currentBackendModelKey
    backendSessionJSONBuffer = ""
}
```

- [ ] **Step 4: Retry once in `performSend`**

Replace the single task call:

```swift
let task = Task { await self.consume(invocation: invocation) }
runTask = task
```

with a small run helper:

```swift
func run(_ invocation: CLIInvocation, suppressResumeFailureError: Bool) async -> AgentRunOutcome {
    let task = Task {
        await self.consume(
            invocation: invocation,
            suppressResumeFailureError: suppressResumeFailureError
        )
    }
    runTask = task
    let outcome = await task.value
    runTask = nil
    return outcome
}
```

Then after the first run finishes, retry only for Claude native-resume failures:

```swift
let firstOutcome = await run(invocation, suppressResumeFailureError: continuity.externalSessionID != nil)

if agent.kind == .claudeCode,
   continuity.externalSessionID != nil,
   firstOutcome.exitCode != 0,
   firstOutcome.isClaudeResumeFailure {
    clearBackendSessionForLocalReplay()
    status = .running
    let fallbackPrompt = promptForInvocation(prompt, continuity: .localTranscriptReplay)
    let fallbackInvocation = CLIInvocationBuilder.build(
        agent: agent,
        prompt: fallbackPrompt,
        model: model,
        reasoningEffort: reasoningEffort,
        interactionMode: interactionMode,
        command: command,
        attachments: attachments,
        sessionID: id.uuidString,
        externalSessionID: nil,
        conversationTitle: title,
        resumeSessionID: resumeSessionID
    )
    _ = await run(fallbackInvocation, suppressResumeFailureError: false)
}
```

Keep the existing watchdog around the whole `performSend` call. The timeout should cover the native-resume attempt plus the single fallback attempt, so a stuck fallback still cancels through the existing `runTask` reference.

- [ ] **Step 5: Add a fallback regression test**

Add this runner to `AgentSessionTests.swift`:

```swift
private actor ClaudeResumeFailureThenReplayRunner: AgentRunning {
    private var storedCalls: [AgentRunCall] = []

    func calls() -> [AgentRunCall] { storedCalls }

    func runOneShot(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?
    ) async throws -> String {
        ""
    }

    func stream(
        command: String,
        args: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdin: String?,
        stopSignal: AgentConfig.StopSignal
    ) -> AsyncThrowingStream<ProcessStreamEvent, Error> {
        storedCalls.append(AgentRunCall(command: command, args: args, environment: environment, workingDirectory: workingDirectory, stdin: stdin))
        let callNumber = storedCalls.count
        return AsyncThrowingStream { continuation in
            if callNumber == 1 {
                continuation.yield(.stdout(#"{"type":"system","subtype":"init","session_id":"550e8400-e29b-41d4-a716-446655440000"}"# + "\n"))
                continuation.yield(.stdout(#"{"type":"assistant","message":{"content":[{"type":"text","text":"first answer"}]}}"# + "\n"))
                continuation.yield(.exit(0))
            } else if args.contains("--resume") {
                continuation.yield(.stderr("No conversation found with session ID: 550e8400-e29b-41d4-a716-446655440000"))
                continuation.yield(.exit(1))
            } else {
                continuation.yield(.stdout(#"{"type":"system","subtype":"init","session_id":"660e8400-e29b-41d4-a716-446655440001"}"# + "\n"))
                continuation.yield(.stdout(#"{"type":"assistant","message":{"content":[{"type":"text","text":"second answer"}]}}"# + "\n"))
                continuation.yield(.exit(0))
            }
            continuation.finish()
        }
    }
}
```

Then add:

```swift
func testClaudeResumeFailureFallsBackToLocalHistoryReplay() async {
    let config = AgentConfig(
        id: "claude-code",
        name: "Claude Code",
        command: "/usr/bin/claude",
        args: ["-p", "--output-format", "stream-json", "--verbose"],
        env: [:],
        workingDirectoryPolicy: .workspace,
        inputMode: .oneShotArgument,
        outputMode: .jsonLines,
        supportsStop: true,
        stopSignal: .interrupt
    )
    let runner = ClaudeResumeFailureThenReplayRunner()
    let session = AgentSession(
        agent: config,
        workingDirectory: FileManager.default.temporaryDirectory,
        runner: runner
    )

    await session.send("first question")
    await session.send("second question")

    let calls = await runner.calls()
    XCTAssertEqual(calls.count, 3)
    XCTAssertTrue(calls[1].args.contains("--resume"))
    XCTAssertFalse(calls[2].args.contains("--resume"))
    let fallbackPrompt = calls[2].args.last ?? ""
    XCTAssertTrue(fallbackPrompt.contains("<agentdeck_history>"))
    XCTAssertTrue(fallbackPrompt.contains("user:\nfirst question"))
    XCTAssertTrue(fallbackPrompt.contains("assistant:\nfirst answer"))
    XCTAssertTrue(fallbackPrompt.contains("Current user request:\nsecond question"))
    XCTAssertFalse(session.messages.contains { $0.text.contains("No conversation found") })
    XCTAssertEqual(session.status, .idle)
}
```

- [ ] **Step 6: Run targeted tests**

Run:

```bash
swift test --filter AgentSessionTests/testClaudeResumeFailureFallsBackToLocalHistoryReplay
swift test --filter AgentSessionTests/testClaudeSecondSendResumesCapturedClaudeSessionID
swift test --filter AgentSessionTests/testClaudeWithoutBackendSessionReplaysLocalHistoryOnNextSend
```

Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/AgentDeckApp/Sessions/AgentSession.swift Tests/AgentDeckTests/AgentSessionTests.swift
git commit -m "fix: fallback from stale claude resume to local transcript"
```

---

### Task 5: Validate Restored Claude Session IDs Before Native Resume

**Files:**
- Modify: `Sources/AgentDeckApp/Sessions/ClaudeSessionDiscovery.swift`
- Modify: `Sources/AgentDeckApp/Sessions/AgentSession.swift`
- Test: `Tests/AgentDeckTests/ClaudeSessionDiscoveryTests.swift`
- Test: `Tests/AgentDeckTests/AgentSessionTests.swift`

- [ ] **Step 1: Add a session-file helper**

In `ClaudeSessionDiscovery.swift`, add:

```swift
public static func sessionFile(
    claudeHome: URL = defaultClaudeHome(),
    workingDirectory: URL,
    sessionID: String
) -> URL {
    claudeHome
        .appending(path: "projects", directoryHint: .isDirectory)
        .appending(path: encodedProjectDirName(forPath: workingDirectory.path), directoryHint: .isDirectory)
        .appending(path: "\(sessionID).jsonl")
}

public static func hasSessionFile(
    claudeHome: URL = defaultClaudeHome(),
    workingDirectory: URL,
    sessionID: String,
    fileManager: FileManager = .default
) -> Bool {
    fileManager.fileExists(atPath: sessionFile(
        claudeHome: claudeHome,
        workingDirectory: workingDirectory,
        sessionID: sessionID
    ).path)
}
```

- [ ] **Step 2: Use the helper for restored IDs only**

Add a private flag in `AgentSession`:

```swift
private var backendSessionWasRestored: Bool
```

Initialize it:

```swift
self.backendSessionWasRestored = restoredBackendSessionID != nil
```

When `captureBackendSessionID` captures a fresh id, set:

```swift
backendSessionWasRestored = false
```

In `claudeContinuityStrategy(for:)`, before returning `.nativeResume(id)`, add:

```swift
if backendSessionWasRestored,
   !ClaudeSessionDiscovery.hasSessionFile(workingDirectory: workingDirectory, sessionID: id) {
    clearBackendSessionForLocalReplay()
    return localHistoryTranscript(excludingUserPrompt: prompt).isEmptyOrNil ? .none : .localTranscriptReplay
}
```

Add this helper in `AgentSession.swift` so the strategy code stays readable:

```swift
private extension Optional where Wrapped == String {
    var isEmptyOrNil: Bool {
        self?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }
}
```

- [ ] **Step 3: Add discovery tests**

Create or update `Tests/AgentDeckTests/ClaudeSessionDiscoveryTests.swift`:

```swift
func testClaudeSessionFileUsesEncodedProjectDirectory() throws {
    let root = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let workingDirectory = root.appending(path: "Claude Code", directoryHint: .isDirectory)
    let file = ClaudeSessionDiscovery.sessionFile(
        claudeHome: root.appending(path: ".claude", directoryHint: .isDirectory),
        workingDirectory: workingDirectory,
        sessionID: "550e8400-e29b-41d4-a716-446655440000"
    )

    XCTAssertTrue(file.path.contains("projects/-"))
    XCTAssertTrue(file.path.hasSuffix("/550e8400-e29b-41d4-a716-446655440000.jsonl"))
}
```

- [ ] **Step 4: Run tests**

Run:

```bash
swift test --filter ClaudeSessionDiscoveryTests
swift test --filter AgentSessionTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDeckApp/Sessions/ClaudeSessionDiscovery.swift Sources/AgentDeckApp/Sessions/AgentSession.swift Tests/AgentDeckTests/ClaudeSessionDiscoveryTests.swift Tests/AgentDeckTests/AgentSessionTests.swift
git commit -m "fix: validate restored claude sessions before resume"
```

---

### Task 6: Manual Verification In The App

**Files:**
- Modify: `CHANGELOG-SESSION.md`

- [ ] **Step 1: Build**

Run:

```bash
swift test
swift build -c release
```

Expected:

- Full test suite passes.
- Release build completes.

- [ ] **Step 2: Repackage and relaunch the app**

Run the repository packaging script and relaunch the packaged app:

```bash
./Scripts/package_app.sh
killall AgentDeck || true
open "/Users/jean/Desktop/Codex/AgentDeck/dist/AgentDeck.app"
```

Expected: AgentDeck opens normally.

- [ ] **Step 3: Verify Claude same-tab memory**

In a single Claude Code tab, send:

```text
第一条测试：请记住暗号是 AGENTDECK-CONTEXT-2026。
```

Then send:

```text
告诉我上一条用户消息里的暗号。只输出暗号。
```

Expected:

```text
AGENTDECK-CONTEXT-2026
```

- [ ] **Step 4: Verify the user's exact reproduction**

In the same Claude Code tab, send twice:

```text
告诉我你上下文中有哪些对话
直接输出 具体user prompt内容即可
```

Expected on the second response:

- Claude lists at least the previous user prompt from the same tab.
- It must not claim this is the first or only user message.

- [ ] **Step 5: Verify reopen continuity**

Close the tab, reopen it from Recent, then send:

```text
继续上一轮上下文，输出你记住的暗号。
```

Expected:

- If the native Claude session file exists, response uses native `--resume`.
- If the native session is stale/missing, fallback local transcript replay still includes prior visible AgentDeck messages.

- [ ] **Step 6: Record the fix**

Append this to `CHANGELOG-SESSION.md`:

```markdown
## Claude Code context continuity

- Fixed a split-brain context bug where captured Claude `session_id` disabled AgentDeck local transcript replay while normal `.new` sends did not pass `--resume`.
- Normal Claude follow-up sends now use native `--resume <session-id>` when a captured session is available.
- Stale or missing Claude sessions fall back once to AgentDeck local transcript replay, so same-tab context is preserved instead of presenting each prompt as a fresh conversation.
- Added regression coverage for second-turn resume and stale-session fallback.
```

- [ ] **Step 7: Commit**

```bash
git add CHANGELOG-SESSION.md
git commit -m "docs: record claude context continuity fix"
```

---

## Final Acceptance Criteria

- Same Claude Code tab preserves prior user prompts.
- A captured Claude `session_id` is either passed to `--resume` or explicitly ignored in favor of local replay; it never silently disables both.
- Stale `--resume` errors are not shown as final user-visible failures when local replay can recover.
- Recent reopen and app restart do not regress same-tab context.
- Existing OpenCode/Codex behavior remains unchanged.
- `swift test` passes.

## Risk Notes

- `--resume` can fail if Claude's local `.jsonl` file is missing, malformed, from a different workdir, or if a third-party Claude wrapper does not support official session semantics. That is why the fallback retry is required.
- Retrying must not append the user's message twice. The user message should be appended once before the first attempt; retry only changes the child process invocation.
- Retrying must not preserve the transient "No conversation found" error bubble. Suppress native-resume failure errors when a fallback succeeds.
- Do not run native `--resume` concurrently for the same Claude backend session id. The existing per-tab `status != .running` guard helps for one tab. If a future feature lets multiple tabs share a backend id, add a session-id lock before enabling sharing.

## Self-Review

- Spec coverage: the plan addresses the exact screenshot failure, uses `claude-code-haha` only for observable CLI/session behavior, and covers same-tab + reopened-session continuity.
- Placeholder scan: no task relies on missing future details; each task names files, commands, and expected outcomes.
- Type consistency: `ClaudeContinuityStrategy`, `AgentRunOutcome`, and `ClaudeSessionDiscovery.sessionFile/hasSessionFile` are defined before later tasks use them.
