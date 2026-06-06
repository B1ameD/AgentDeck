# Workflow Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore history conversations correctly, bind review buttons to their own diffs, support Claude OAuth login, replace Chat/Auto with Plan/Build, and refresh Claude models after cc-switch without reopening the Agent tab.

**Architecture:** Keep persistence and process behavior in existing session/controller types, while extracting small pure values for migration, review requests, terminal launches, and model refresh transitions. SwiftUI views bind those values to existing panels and callbacks. Every behavior change begins with a focused failing test, then receives the smallest production change needed to pass.

**Tech Stack:** Swift 6, SwiftUI, Observation, SwiftTerm, XCTest, Swift Package Manager.

---

## File Map

- `Sources/AgentDeckApp/Sessions/SessionModels.swift`: define Plan/Build modes and legacy stored-value migration.
- `Sources/AgentDeckApp/Sessions/AgentSession.swift`: default new sessions to Build.
- `Sources/AgentDeckApp/Sessions/WorkspaceController.swift`: use centralized mode migration and return history reopen results.
- `Sources/AgentDeckApp/UI/HistorySearchView.swift`: restore selected history records and report unavailable agents.
- `Sources/AgentDeckApp/Presentation/MessagePresentation.swift`: derive an exact review request from a message's persisted diff.
- `Sources/AgentDeckApp/UI/ChatPaneView.swift`: pass the selected message's review summary and disable legacy review actions.
- `Sources/AgentDeckApp/AppShell/ContentView.swift`: retain selected historical review state, clear it on session changes, and coordinate terminal launches.
- `Sources/AgentDeckApp/UI/PTYTerminalView.swift`: support normal shells and direct `claude auth login` launches.
- `Sources/AgentDeckApp/UI/SlashCommand.swift`: add Claude `/login`, add `/build`, remove `/chat` and `/auto`.
- `Sources/AgentDeckApp/UI/ComposerView.swift`: invoke login and refresh Claude model snapshots when entering `/model`.
- `Sources/AgentDeckApp/Agents/AgentRegistry.swift`: remove Claude `--bare`.
- `Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift`: map Plan/Build to Claude permission modes.
- `Sources/AgentDeckApp/Agents/ClaudeSettings.swift`: parse one internally consistent Claude model snapshot.
- `Sources/AgentDeckApp/Agents/ModelCatalog.swift`: preserve OpenCode caching while exposing uncached Claude snapshots.
- `Tests/AgentDeckTests/*`: focused regression coverage for each behavior.

### Task 1: Replace Chat/Auto With Plan/Build And Migrate Stored State

**Files:**
- Modify: `Tests/AgentDeckTests/CLIInvocationBuilderTests.swift`
- Modify: `Tests/AgentDeckTests/SlashCommandTests.swift`
- Modify: `Tests/AgentDeckTests/WorkspaceControllerTests.swift`
- Modify: `Tests/AgentDeckTests/AgentSessionTests.swift`
- Modify: `Sources/AgentDeckApp/Sessions/SessionModels.swift`
- Modify: `Sources/AgentDeckApp/Sessions/AgentSession.swift`
- Modify: `Sources/AgentDeckApp/Sessions/WorkspaceController.swift`
- Modify: `Sources/AgentDeckApp/Agents/CLIInvocationBuilder.swift`
- Modify: `Sources/AgentDeckApp/UI/SlashCommand.swift`
- Modify: `Sources/AgentDeckApp/UI/ComposerView.swift`

- [ ] **Step 1: Write failing mode and migration tests**

Add assertions equivalent to:

```swift
func testInteractionModesExposeOnlyPlanAndBuild() {
    XCTAssertEqual(InteractionMode.allCases, [.plan, .build])
    XCTAssertEqual(InteractionMode.restore("plan"), .plan)
    for legacy in ["build", "chat", "auto", "unknown"] {
        XCTAssertEqual(InteractionMode.restore(legacy), .build)
    }
    XCTAssertEqual(InteractionMode.restore(nil), .build)
}

func testClaudeBuildModeBypassesNativePermissionPrompt() {
    let invocation = CLIInvocationBuilder.build(
        agent: config(id: "claude-code", args: ["-p"], inputMode: .oneShotArgument),
        prompt: "edit test.md",
        model: "default",
        reasoningEffort: .medium,
        interactionMode: .build,
        command: .new,
        attachments: []
    )
    XCTAssertEqual(
        invocation.arguments,
        ["-p", "--permission-mode", "bypassPermissions", "edit test.md"]
    )
}
```

Update slash-command expectations to include `/plan` and `/build` only for Claude. Add workspace restoration cases for stored `chat`, `auto`, missing, and unknown values.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --filter 'CLIInvocationBuilderTests|SlashCommandTests|WorkspaceControllerTests'
```

Expected: compile failures for missing `.build`/`restore`, plus expectation failures for old commands/defaults.

- [ ] **Step 3: Implement Plan/Build and migration**

Use:

```swift
public enum InteractionMode: String, CaseIterable, Equatable, Sendable {
    case plan
    case build

    public static func restore(_ storedValue: String?) -> InteractionMode {
        storedValue == plan.rawValue ? .plan : .build
    }
}
```

Default `AgentSession` to `.build`; restore through `InteractionMode.restore`; map `.plan` to Claude `plan` and `.build` to `bypassPermissions`; expose `Plan`/`Build` in the composer and `/plan`/`/build` in slash commands.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the same filtered command. Expected: all selected tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: replace Claude chat mode with build mode"
```

### Task 2: Restore Conversations From History Search

**Files:**
- Modify: `Tests/AgentDeckTests/WorkspaceControllerTests.swift`
- Modify: `Sources/AgentDeckApp/Sessions/WorkspaceController.swift`
- Modify: `Sources/AgentDeckApp/UI/HistorySearchView.swift`

- [ ] **Step 1: Write failing history reopen result tests**

Cover:

```swift
XCTAssertEqual(controller.reopenConversation(id: openID), .focusedExisting)
XCTAssertEqual(controller.reopenConversation(id: storedID), .restored)
XCTAssertEqual(controller.reopenConversation(id: missingAgentID), .unavailable)
XCTAssertTrue(controller.canReopenConversation(id: openID))
XCTAssertFalse(controller.canReopenConversation(id: missingAgentID))
```

Verify restored messages and focused session identity.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter WorkspaceControllerTests
```

Expected: compile failures because `ConversationReopenResult` and `canReopenConversation` do not exist.

- [ ] **Step 3: Implement controller results and history UI**

Add:

```swift
public enum ConversationReopenResult: Equatable, Sendable {
    case focusedExisting
    case restored
    case unavailable
}
```

Return the correct result from `reopenConversation(id:)`. In `HistorySearchView`, keep click-to-preview, add a primary "恢复会话" button, disable it when `canReopenConversation` is false, explain that the original Agent is unavailable, and dismiss only after `.focusedExisting` or `.restored`.

- [ ] **Step 4: Run focused tests and verify GREEN**

```bash
swift test --filter WorkspaceControllerTests
```

Expected: all workspace controller tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDeckApp/Sessions/WorkspaceController.swift Sources/AgentDeckApp/UI/HistorySearchView.swift Tests/AgentDeckTests/WorkspaceControllerTests.swift
git commit -m "fix: restore conversations from history search"
```

### Task 3: Bind Every Review Action To Its Own Persisted Diff

**Files:**
- Modify: `Tests/AgentDeckTests/MessagePresentationTests.swift`
- Modify: `Sources/AgentDeckApp/Presentation/MessagePresentation.swift`
- Modify: `Sources/AgentDeckApp/UI/ChatPaneView.swift`
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`

- [ ] **Step 1: Write failing exact-review tests**

Add a pure request:

```swift
func testChangeReviewRequestUsesOnlyTheMessagesPersistedSummary() {
    let old = ChatMessage(role: .system, text: "old", kind: .changeReview, turnDiffSummary: oldSummary)
    let latest = ChatMessage(role: .system, text: "new", kind: .changeReview, turnDiffSummary: latestSummary)

    XCTAssertEqual(ChangeReviewRequest.forMessage(old)?.summary, oldSummary)
    XCTAssertEqual(ChangeReviewRequest.forMessage(latest)?.summary, latestSummary)
}

func testLegacyChangeReviewWithoutSummaryHasNoReviewRequest() {
    let legacy = ChatMessage(role: .system, text: "files", kind: .changeReview)
    XCTAssertNil(ChangeReviewRequest.forMessage(legacy))
}
```

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter MessagePresentationTests
```

Expected: compile failure because `ChangeReviewRequest` is missing.

- [ ] **Step 3: Implement exact review selection**

Define `ChangeReviewRequest` from `message.turnDiffSummary` only. Change callbacks to `(TurnDiffSummary) -> Void`. Remove the `session.lastTurnDiffSummary` fallback from individual messages. Disable the legacy button with help text. Store `selectedReviewSummary` in `ContentView`, pass it into `RightSidebar`, and clear it when the focused session changes. Global review display resolves to `selectedReviewSummary ?? session.lastTurnDiffSummary`.

- [ ] **Step 4: Run focused tests and build**

```bash
swift test --filter MessagePresentationTests
swift build
```

Expected: tests and build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDeckApp/Presentation/MessagePresentation.swift Sources/AgentDeckApp/UI/ChatPaneView.swift Sources/AgentDeckApp/AppShell/ContentView.swift Tests/AgentDeckTests/MessagePresentationTests.swift
git commit -m "fix: open the diff attached to each review message"
```

### Task 4: Open Claude OAuth Login In The Built-In PTY

**Files:**
- Create: `Tests/AgentDeckTests/TerminalLaunchTests.swift`
- Modify: `Tests/AgentDeckTests/SlashCommandTests.swift`
- Modify: `Tests/AgentDeckTests/AgentRegistryTests.swift`
- Modify: `Sources/AgentDeckApp/UI/PTYTerminalView.swift`
- Modify: `Sources/AgentDeckApp/UI/SlashCommand.swift`
- Modify: `Sources/AgentDeckApp/UI/ComposerView.swift`
- Modify: `Sources/AgentDeckApp/UI/ChatPaneView.swift`
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`
- Modify: `Sources/AgentDeckApp/Agents/AgentRegistry.swift`

- [ ] **Step 1: Write failing launch and command tests**

Cover:

```swift
func testClaudeAuthenticationLaunchRunsAuthLoginDirectly() {
    let launch = TerminalLaunch.claudeAuthentication(executable: "/usr/local/bin/claude")
    XCTAssertEqual(launch.executable, "/usr/local/bin/claude")
    XCTAssertEqual(launch.arguments, ["auth", "login"])
    XCTAssertEqual(launch.title, "Claude 登录")
}
```

Assert Claude commands contain `/login`, non-Claude commands do not receive the application action, and built-in Claude args no longer contain `--bare`.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter 'TerminalLaunchTests|SlashCommandTests|AgentRegistryTests'
```

Expected: missing launch/action compile failures and old `--bare` expectation failure.

- [ ] **Step 3: Implement terminal launch routing**

Create an equatable `TerminalLaunch` value with normal-shell and Claude-auth factories. Make `PTYTerminalView` start the launch's executable/arguments. Replace `showTerminal` with optional launch state in `ContentView`; the toolbar opens a shell, while Claude `/login` opens `claude auth login`. Add `.claudeLogin` to `SlashCommand.Action`, consume it in `ComposerView`, and never call `AgentSession.send` for it. Remove `--bare`.

- [ ] **Step 4: Run focused tests and build**

```bash
swift test --filter 'TerminalLaunchTests|SlashCommandTests|AgentRegistryTests'
swift build
```

Expected: selected tests and build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: support Claude OAuth login in the terminal"
```

### Task 5: Refresh Claude Models On Every New Model Menu Session

**Files:**
- Modify: `Tests/AgentDeckTests/ClaudeSettingsTests.swift`
- Modify: `Tests/AgentDeckTests/ModelCatalogTests.swift`
- Modify: `Tests/AgentDeckTests/ComposerPresentationTests.swift`
- Modify: `Sources/AgentDeckApp/Agents/ClaudeSettings.swift`
- Modify: `Sources/AgentDeckApp/Agents/ModelCatalog.swift`
- Modify: `Sources/AgentDeckApp/UI/ComposerView.swift`

- [ ] **Step 1: Write failing snapshot and refresh transition tests**

Cover:

```swift
func testClaudeModelSnapshotKeepsCandidatesRolesAndDefaultConsistent() throws {
    let snapshot = ClaudeSettings.modelSnapshot(settingsURL: settingsURL)
    XCTAssertEqual(snapshot.candidates, ["provider/model-a", "provider/model-b"])
    XCTAssertEqual(snapshot.roles.defaultModel, "provider/model-a")
    XCTAssertEqual(snapshot.roles.labels["provider/model-b"], "Sonnet")
}

func testClaudeModelRefreshOnlyTriggersWhenEnteringModelState() {
    XCTAssertTrue(ModelMenuRefreshTrigger.shouldRefresh(agentKind: .claudeCode, wasOpen: false, isOpen: true))
    XCTAssertFalse(ModelMenuRefreshTrigger.shouldRefresh(agentKind: .claudeCode, wasOpen: true, isOpen: true))
    XCTAssertTrue(ModelMenuRefreshTrigger.shouldRefresh(agentKind: .claudeCode, wasOpen: false, isOpen: true))
    XCTAssertFalse(ModelMenuRefreshTrigger.shouldRefresh(agentKind: .openCode, wasOpen: false, isOpen: true))
}
```

Also overwrite the settings fixture between two reads and assert the second snapshot contains only the new provider.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
swift test --filter 'ClaudeSettingsModelRolesTests|ModelCatalogTests|ComposerPresentationTests'
```

Expected: compile failures for `modelSnapshot` and `ModelMenuRefreshTrigger`.

- [ ] **Step 3: Implement coherent snapshots and entry refresh**

Parse settings once into:

```swift
public struct ModelSnapshot: Equatable, Sendable {
    public var candidates: [String]
    public var roles: ModelRoles
}
```

Keep Claude uncached. In `ComposerView`, detect only the transition into `.models`, clear stale Claude catalog/roles, show loading, then replace both from one snapshot. Query edits while already in model state do not refetch. OpenCode retains its existing startup fetch and cache.

- [ ] **Step 4: Run focused tests and build**

```bash
swift test --filter 'ClaudeSettingsModelRolesTests|ModelCatalogTests|ComposerPresentationTests'
swift build
```

Expected: selected tests and build pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentDeckApp/Agents/ClaudeSettings.swift Sources/AgentDeckApp/Agents/ModelCatalog.swift Sources/AgentDeckApp/UI/ComposerView.swift Tests/AgentDeckTests/ClaudeSettingsTests.swift Tests/AgentDeckTests/ModelCatalogTests.swift Tests/AgentDeckTests/ComposerPresentationTests.swift
git commit -m "fix: refresh Claude models after provider changes"
```

### Task 6: Full Regression, Packaging, And Integration

**Files:**
- Modify only if verification reveals a regression.

- [ ] **Step 1: Run the complete test suite**

```bash
swift test
```

Expected: 0 failures. If the known global-temporary-directory test flakes again, isolate its fixture in a UUID directory and rerun the full suite.

- [ ] **Step 2: Build the release app**

```bash
zsh Scripts/package_app.sh
```

Expected: `dist/AgentDeck.app` is created with exit code 0.

- [ ] **Step 3: Inspect the final diff**

```bash
git diff main...HEAD --check
git diff main...HEAD --stat
git status --short
```

Expected: no whitespace errors, only planned source/test/docs changes, and a clean worktree after commit.

- [ ] **Step 4: Perform manual packaged-app checks**

Verify:

1. A history result previews on click and restores with "恢复会话".
2. Two different historical review messages open two different diffs.
3. Claude `/login` opens the terminal and runs `claude auth login`.
4. Claude mode control cycles only Plan and Build.
5. Switching cc-switch provider and reopening `/model` in the same Agent tab replaces the visible provider models.

- [ ] **Step 5: Commit any final verification-only fixes**

```bash
git add Sources Tests
git commit -m "test: stabilize workflow regression coverage"
```

Skip this commit when verification requires no additional changes.
