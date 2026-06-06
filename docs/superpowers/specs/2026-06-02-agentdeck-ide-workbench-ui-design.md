# AgentDeck IDE Workbench UI Design

## Goal

Refine AgentDeck into a calmer, denser IDE-style workbench while preserving the current product shape: a left agent rail, central chat, optional right files/browser sidebar, and optional bottom terminal. The redesign should make long sessions easier to scan and reduce the current mix of glass surfaces, rounded controls, and ad hoc button treatments.

## Scope

This design changes visual hierarchy and component styling only. It does not change agent execution, session persistence, permission prompts, terminal behavior, file loading/saving behavior, Git commands, or prompt optimization logic.

## Direction

Use the selected "IDE workbench refinement" direction:

- Prefer structured light surfaces over decorative glass.
- Use crisp separators, restrained shadows, and consistent 8px-style radii for tool surfaces.
- Keep information density high enough for repeated work.
- Make command surfaces look like toolbars instead of marketing cards.
- Keep the existing blue accent but use it mostly for selection, focus, and primary action states.

## Theme Tokens

Update `Theme` so UI components can share a single workbench vocabulary:

- Background: a quiet cool gray/blue surface with minimal gradient.
- Panels: opaque or near-opaque light surfaces for sidebar, header, composer, right sidebar, and message canvas.
- Border: a subtle cool gray separator for panel edges and controls.
- Selection: blue accent fill at low opacity plus a clearer left indicator where useful.
- Shadows: very light and rare, used only for raised interactive surfaces such as the composer dock or popover menus.
- Radius: prefer `8` for rows and controls, `10-12` for larger panels, avoiding oversized rounded cards.

## Layout And Components

### Left Rail

The left rail remains fixed width, but becomes a clearer navigation/tool panel:

- Brand block at the top with app name and a compact workspace subtitle.
- Agent list rows use a consistent icon, label, status dot, selected fill, and hover state.
- Recent conversations use smaller rows with title and agent metadata, visually quieter than active agents.
- Bottom controls are grouped: broadcast toggle, workspace chooser, add agent, history, settings.
- Avoid nested card styling; rows are individual list controls on a panel surface.

### Page Header

The focused session header becomes a toolbar:

- Left side: agent name, command, model badge, and Claude history menu when available.
- Right side: icon-first buttons for Git, right sidebar, and terminal with tooltips.
- User name is de-emphasized or integrated as a small metadata pill.
- Use one bottom border and a stable height so the chat area feels anchored.

### Chat Pane

The chat pane gets a cleaner reading surface:

- Message canvas uses a solid or near-solid workbench surface.
- Assistant messages can span wide but remain visually grouped.
- User messages stay narrower and right-aligned.
- System and error messages remain distinct with subdued color treatments.
- Existing Markdown improvements and message insertion animation are preserved.

### Composer Dock

The composer becomes a stable bottom dock:

- Prompt field and send/stop button align on a single primary row.
- Controls row stays compact: attachments, mode, model, reasoning, prompt optimization, and context usage.
- Controls should not jump or reflow awkwardly when optimization/error/context state appears.
- Primary actions use icons with tooltips; text labels remain only where they improve clarity.

### Right Sidebar

The right sidebar should match the workbench panel language:

- Header uses a segmented switch plus close icon with consistent spacing.
- File tree rows use the same selected/hover treatment as agent rows where practical.
- Editor header clearly shows filename, dirty state, and save action.
- Browser address bar uses toolbar-style icon buttons and a compact "go" control.

### Empty And Modal States

Empty states should be functional and quiet:

- Empty registry / no session states use the same panel background as the main canvas.
- Settings and Git sheets keep their current functionality but receive consistent section spacing, borders, and button treatments if touched during implementation.

## Error Handling

No new runtime error paths are introduced. Existing file load errors, permission dialogs, Git failures, and prompt optimization failures remain unchanged. Visual updates should keep those messages readable and not hide disabled states.

## Testing And Verification

Run the existing test suite with `swift test`. If possible, launch the app with `swift run AgentDeck` and visually verify:

- Main window renders without layout overlap at desktop size.
- Left rail rows, header toolbar, chat messages, composer dock, right sidebar, and terminal toggles remain usable.
- Existing dirty file indicator and save behavior still work.
- Markdown rendering and code-copy UI remain intact.
- Buttons have visible enabled/disabled/selected states.

## Non-Goals

- No new app architecture.
- No new navigation model.
- No new animation system.
- No changes to agent CLI invocation or model selection behavior.
- No redesign of history search beyond styling consistency if needed.
