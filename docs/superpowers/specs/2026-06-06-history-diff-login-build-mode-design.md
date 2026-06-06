# History Restore, Diff Selection, Claude Login, And Build Mode Design

## Goal

Fix four related user-facing workflow problems:

1. A conversation selected in history search can be restored into the main chat workspace.
2. Every historical "审核改动" action opens the diff stored on that specific message instead of the newest session diff.
3. Claude Code users can complete official Anthropic OAuth login from AgentDeck.
4. Claude interaction modes are reduced to `Plan` and `Build`, with old `chat` and `auto` state migrated to `build`.

## Current Root Causes

### History search is preview-only

`HistorySearchView` only assigns a `StoredConversation` to local `selected` state. It never calls the existing `WorkspaceController.reopenConversation(id:)` method, so the selected record cannot return to the active chat tabs.

### Review actions discard message identity

Each change-review message already persists its own optional `turnDiffSummary`. However, `MessageBubble` invokes a parameterless `onReviewChanges` closure, and `ContentView` always passes `session.lastTurnDiffSummary` into the right sidebar. This replaces the selected historical diff with the newest diff.

### Claude login is interactive but chat execution is not

AgentDeck runs Claude with `-p`, so a `/login` prompt cannot complete inside the chat process. AgentDeck already has a real PTY terminal suitable for interactive authentication.

The built-in Claude arguments also include `--bare`. Claude Code documents that bare mode does not read OAuth or keychain credentials, so an OAuth login would remain ineffective until `--bare` is removed.

### Chat mode cannot safely edit in non-interactive execution

Claude `-p` cannot relay Claude's native permission prompt into AgentDeck. The current `chat` mode therefore reaches an edit request without a usable approval path. The existing `auto` mode already maps to `bypassPermissions`, but its name incorrectly implies that AgentDeck's own authorization is skipped.

## User Experience

### Restoring history

- Clicking a history result continues to show its read-only transcript preview.
- The preview header contains a primary "恢复会话" action.
- Activating it calls `WorkspaceController.reopenConversation(id:)`.
- The history sheet closes.
- The restored or already-open session becomes the focused chat tab.
- Missing agents remain non-restorable and produce a disabled action with a concise explanation rather than silently failing.

### Reviewing historical diffs

- A change-review message renders its own inline diff when `turnDiffSummary` exists.
- Clicking either its "审核改动" button or inline "查看全部" action passes that exact summary to `ContentView`.
- `ContentView` stores the selected review summary separately from `session.lastTurnDiffSummary`.
- The right sidebar review tab renders the selected summary.
- Opening the review tab from the global sidebar control, without selecting a message, uses the current session's latest summary.
- A historical message without a persisted `turnDiffSummary` must not fall back to the latest summary. It continues to show its stored file list, while its review action is disabled with a "此历史记录没有可用的逐行 Diff" help message.
- Switching focused sessions clears the selected historical review summary so one session cannot display another session's diff.

### Claude official login

- Claude's slash-command menu contains an application-handled `/login` command.
- Selecting or submitting `/login` does not send it through Claude's non-interactive `-p` chat process.
- AgentDeck opens the bottom PTY panel in a dedicated Claude login mode and starts:

```text
claude auth login
```

- The user completes browser authentication and can observe the terminal result.
- Closing the panel returns to the existing chat.
- The regular terminal toolbar action still opens a normal login shell.
- The built-in Claude configuration removes `--bare`, allowing subsequent `-p` requests to use OAuth/keychain credentials.
- Other agents continue treating `/login` as an ordinary native or passthrough command.

## Interaction Modes

`InteractionMode` exposes only:

```swift
case plan
case build
```

### Plan

- Display label: `Plan`
- Slash command: `/plan`
- Claude mapping: `--permission-mode plan`
- Intended for analysis and planning without file modification.

### Build

- Display label: `Build`
- Slash command: `/build`
- Default for new and restored sessions when no valid mode is stored.
- AgentDeck's existing permission broker remains the user-facing authorization boundary.
- After AgentDeck approval, Claude mapping is:

```text
--permission-mode bypassPermissions
```

This bypasses the unusable native Claude prompt inside `-p`; it does not bypass AgentDeck's own confirmation.

### Stored-state migration

The raw values `chat` and `auto` may exist in workspace snapshots and stored conversations. Decoding or restoration maps:

| Stored value | Restored mode |
|---|---|
| `plan` | `plan` |
| `build` | `build` |
| `chat` | `build` |
| `auto` | `build` |
| missing or unknown | `build` |

New persistence writes only `plan` or `build`.

The `/chat` and `/auto` application commands are removed. `/build` is added. Unknown commands from other agents retain the existing passthrough behavior.

## Component Changes

### `HistorySearchView`

Add restore availability and action handling around the selected conversation. The view remains responsible for preview UI; `WorkspaceController` remains responsible for reconstructing sessions.

### `WorkspaceController`

Change `reopenConversation(id:)` to return a result indicating whether restoration/focus succeeded. This lets history search dismiss only after a successful restore and display an unavailable state when the stored agent no longer exists.

Centralize stored-mode migration in one helper used by both workspace snapshot restoration and conversation restoration.

### Review selection

Change review callbacks from:

```swift
() -> Void
```

to:

```swift
(TurnDiffSummary?) -> Void
```

`MessageBubble` supplies the message's own summary. `ContentView` stores the selected summary and passes it to `RightSidebar`.

### Terminal launch configuration

Introduce a small terminal launch value that distinguishes:

- normal shell
- Claude authentication command

`PTYTerminalView` starts the configured executable and arguments directly inside the pseudo-terminal. It must not implement login using a non-interactive `ProcessRunner`.

### Slash commands and composer

Add a dedicated Claude-login action to `SlashCommand.Action`. `ComposerView` invokes a callback supplied by `ChatPaneView` and `ContentView`, clears the command text, and does not append `/login` as a user chat message.

## Error Handling

- History restoration failure leaves the sheet open and explains that the original agent is unavailable.
- A missing historical structured diff never substitutes unrelated newer data.
- If the Claude executable is unavailable, the login action is not offered because no Claude session can exist without the detected executable.
- PTY process errors remain visible in the terminal panel.
- Login completion does not automatically retry a previously failed prompt; the user deliberately resends it after authentication.

## Testing

### History

- Restoring a stored conversation focuses it and restores messages.
- Restoring an already-open conversation only focuses it.
- Restoration reports failure when the original agent is unavailable.
- History presentation exposes restore only for a selected record and dismisses only after success.

### Diff review

- Two review messages with distinct summaries retain distinct selections.
- Selecting an old review passes the old summary.
- Selecting the latest review passes the latest summary.
- A legacy review message without a summary does not resolve to `lastTurnDiffSummary`.
- Changing sessions clears a prior selected historical summary.

### Claude login

- Claude's available commands include `/login`.
- Other agents do not receive the application-handled login action.
- Submitting `/login` requests a Claude-auth terminal launch and does not call `AgentSession.send`.
- The terminal launch configuration resolves to the detected Claude executable with `["auth", "login"]`.
- Built-in Claude arguments no longer contain `--bare`.

### Modes and migration

- `InteractionMode.allCases` is `[.plan, .build]`.
- New sessions default to `.build`.
- `plan`, `build`, `chat`, `auto`, missing, and unknown stored values restore according to the migration table.
- `/plan` and `/build` are shown for Claude; `/chat` and `/auto` are absent.
- Plan maps to Claude `plan`; Build maps to `bypassPermissions`.
- Existing Codex, OpenCode, Pi, and custom command behavior remains unchanged.

### Regression verification

- Run the complete Swift test suite.
- Build the release application with `zsh Scripts/package_app.sh`.
- Manually verify history restore, two historical diff selections, `/login`, and Plan/Build switching in the packaged app.
