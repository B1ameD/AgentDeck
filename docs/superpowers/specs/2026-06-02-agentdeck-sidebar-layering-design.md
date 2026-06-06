# AgentDeck Sidebar Layering Design

## Goal

Further refine AgentDeck's visual hierarchy by making the left agent rail read as a raised, independent layer above the main workbench surface.

## Selected Direction

Use option B from the visual mockup: an independent floating left rail.

- Keep the left rail fixed-width and functionally unchanged.
- Add outer shell padding so the rail no longer touches the window edge or main content.
- Give the rail a slightly brighter surface, rounded panel shape, subtle border, and restrained shadow.
- Let the main page sit visually behind the rail with its own inset and quiet canvas background.
- Preserve the existing header, chat, terminal, right sidebar, files, browser, settings, and Git behavior.

## Scope

This is a styling and layout adjustment only. It does not change agent execution, session management, file editing, terminal behavior, browser navigation, Git commands, or prompt composition.

## Implementation Notes

- Update shared theme tokens for a raised rail surface and shadow.
- Change `ContentView` shell spacing from a flush split layout to an inset workbench layout.
- Restyle `leftRail` as a floating panel and remove the old hard trailing divider.
- Keep row hover, selected, broadcast, workspace, history, settings, and add-agent interactions unchanged.

## Verification

- Run `swift test`.
- Run `./Scripts/package_app.sh` to rebuild `dist/AgentDeck.app`.
- Confirm the app bundle exists at `/Users/jean/Desktop/Codex/AgentDeck/dist/AgentDeck.app`.
