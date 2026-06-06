# AgentDeck IDE Workbench UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refine AgentDeck into a calmer IDE-style workbench while preserving existing behavior.

**Architecture:** Keep the current SwiftUI view structure and update visual tokens plus focused component styling. No session, agent, storage, Git, terminal, or permission logic changes are planned.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Package Manager tests.

---

### Task 1: Theme And Shell

**Files:**
- Modify: `Sources/AgentDeckApp/UI/Theme.swift`
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`

- [ ] Add workbench theme tokens for app background, panel, canvas, border, hover, selected, and control surfaces.
- [ ] Replace the decorative glass background with a quiet workbench background.
- [ ] Restyle the left rail with structured sections and row-style controls.
- [ ] Restyle the focused page shell so the main area reads as a workbench surface.

### Task 2: Header, Chat, And Composer

**Files:**
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`
- Modify: `Sources/AgentDeckApp/UI/ChatPaneView.swift`
- Modify: `Sources/AgentDeckApp/UI/ComposerView.swift`

- [ ] Convert the focused session header to a stable toolbar with icon-first actions.
- [ ] Tune message bubble surfaces and spacing for the new workbench background.
- [ ] Convert the composer into a bottom dock with a primary input row and compact controls row.
- [ ] Keep prompt optimization, context usage, slash menu, attachment, send, and stop behavior unchanged.

### Task 3: Right Sidebar And Sheets

**Files:**
- Modify: `Sources/AgentDeckApp/UI/RightSidebar.swift`
- Modify: `Sources/AgentDeckApp/UI/FileExplorerView.swift`
- Modify: `Sources/AgentDeckApp/UI/GitPanelView.swift`
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`

- [ ] Align right sidebar header, file tree rows, editor header, browser toolbar, and Git sheet with workbench tokens.
- [ ] Preserve existing file loading, dirty state, saving, and browser navigation behavior.
- [ ] Keep Settings and empty states quiet and consistent with the shell.

### Task 4: Verification And Local Commit

**Files:**
- Verify all modified files.

- [ ] Run `swift test`.
- [ ] Run `swift run AgentDeck` if practical and inspect the main window.
- [ ] Commit locally only. Do not push to GitHub.
