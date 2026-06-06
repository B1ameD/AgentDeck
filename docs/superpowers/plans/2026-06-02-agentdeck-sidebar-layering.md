# AgentDeck Sidebar Layering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make AgentDeck's left agent rail read as a raised floating panel while preserving existing app behavior.

**Architecture:** Keep the existing SwiftUI layout and component tree. Add focused theme tokens and adjust only the shell spacing, left rail surface, and main page inset.

**Tech Stack:** Swift 6, SwiftUI, Swift Package Manager, macOS app bundle packaging.

---

### Task 1: Add Raised Rail Theme Tokens

**Files:**
- Modify: `Sources/AgentDeckApp/UI/Theme.swift`

- [ ] Add a `railSurface` color that is brighter than the base panel.
- [ ] Add a `railShadowColor` token for a stronger but still restrained panel shadow.
- [ ] Keep existing workbench tokens intact for existing components.

### Task 2: Float The Left Rail

**Files:**
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`

- [ ] Change the root shell from a flush split to an inset `HStack` with spacing between rail and page.
- [ ] Restyle `leftRail` with `Theme.railSurface`, rounded corners, border, and shadow.
- [ ] Remove the old trailing hard divider from the rail.
- [ ] Keep the rail width and all button/session interactions unchanged.

### Task 3: Recess The Main Page

**Files:**
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`

- [ ] Wrap focused and empty main content in an inset workbench surface so it sits behind the rail.
- [ ] Preserve existing `HSplitView`, `VSplitView`, terminal, and right sidebar behavior.
- [ ] Keep the right sidebar resizable inside the existing split view.

### Task 4: Verify And Package

**Files:**
- Verify modified Swift files and packaged app.

- [ ] Run `swift test`.
- [ ] Run `./Scripts/package_app.sh`.
- [ ] Confirm `dist/AgentDeck.app/Contents/MacOS/AgentDeck` exists.
