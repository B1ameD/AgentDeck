# AgentDeck Right Sidebar File Preview Design

## Goal

Restructure the right sidebar so file navigation and file content are separate
tabs. Add a dedicated preview surface that renders Markdown, highlights source
code, and still allows editing and saving text files.

## Codex-to-AgentDeck Mapping

| Codex concept | AgentDeck component | Responsibility |
| --- | --- | --- |
| App shell | `ContentView.mainPage` | Own panel visibility, width, active tab, and selected file |
| Right panel slot | `RightSidebar` | Host independent sidebar tabs |
| Side panel tab registry | `RightSidebarMode` | Select Files, Preview, Browser, or Review |
| Files tab | `FileExplorerView` | Browse the workspace tree and request a file open |
| File tab | `FilePreviewView` | Preview, edit, and save the selected file |
| Review tab | `ChangeReviewView` | Display turn diffs and open a changed file in Preview |
| Browser tab | `WebBrowserView` | Display web content |
| Thread scroll controller | `ChatPaneView` | Preserve the current chat position when sidebar width changes |

## Sidebar Navigation

`RightSidebarMode` contains four tabs in this order:

1. Files
2. Preview
3. Browser
4. Review

The Files tab contains only the directory tree. Selecting a file updates the
selected file URL and switches to Preview.

File-open requests from chat messages, tool rows, and Review follow the same
path: update the selected file and switch to Preview. Browser and Review keep
their existing navigation behavior.

The sidebar continues to occupy layout width and resize the main chat area. It
does not become an overlay. Existing sidebar width constraints and drag resizing
remain unchanged.

## File Preview Model

Introduce a pure `FilePreviewModel` layer for behavior that can be unit tested:

- Validate that a selected URL is inside the active workspace.
- Determine preview kind from the file extension.
- Infer a syntax-highlighting language identifier for source files.
- Enforce a 1 MB text-file limit.
- Load UTF-8 content.
- Report unsupported binary, non-UTF-8, missing, and oversized files.

Preview kinds:

- Markdown: `.md`, `.markdown`
- Source code: known programming, markup, configuration, and shell extensions
- Plain text: UTF-8 files not mapped to Markdown or source code
- Unsupported: known binary/media/archive/document formats or failed UTF-8 decoding

## Preview And Edit Modes

`FilePreviewView` has a segmented `Preview / Edit` control.

Preview mode:

- Markdown uses the existing `MarkdownText` renderer.
- Source code uses the existing code font, code-block theme, and
  `CodeSyntaxHighlighter`.
- Plain text uses a selectable monospaced text view.

Edit mode:

- Uses a monospaced `TextEditor`.
- Displays an unsaved-change indicator when the current text differs from the
  loaded baseline.
- Offers an explicit Save command.
- Is unavailable for unsupported files or load failures.

Saving writes UTF-8 text atomically to the selected URL. A successful save
updates the baseline and clears the dirty state. A failed save leaves the dirty
state intact and displays the error.

## Unsaved Change Guard

Navigation away from a dirty preview is guarded when:

- Selecting another file
- Switching to another sidebar tab
- Closing the sidebar
- Changing the focused session or workspace

The confirmation offers:

- Save and Continue
- Discard Changes
- Cancel

Save and Continue only performs the pending navigation after a successful
write. Discard restores the loaded baseline before performing navigation.
Cancel leaves the selected file and active Preview tab unchanged.

Navigation is represented as a pending action rather than mutating selection
before confirmation. This avoids a brief display of the next file followed by
rollback.

## State Ownership

`ContentView` remains the owner of:

- Sidebar visibility
- Sidebar width
- Active sidebar mode
- Selected file URL
- Browser URL
- Review summary

`FilePreviewController` is a long-lived observable state object owned by
`ContentView` and passed into `RightSidebar`. It owns:

- Selected file URL
- Loaded text
- Loaded baseline
- Preview/Edit mode
- Load or save error
- Dirty state
- Pending guarded navigation

Keeping document state above the tab content is required because switching away
from Preview removes `FilePreviewView` from the view tree. The dirty buffer must
survive long enough to complete or cancel the confirmation.

`FilePreviewView` renders bindings from the controller and sends edit/save
commands back to it. `RightSidebar` and `ContentView` route file selection, tab
changes, close requests, session changes, and workspace changes through the
controller before committing navigation.

Directory expansion state remains in `ContentView` so closing and reopening the
sidebar preserves the tree. The obsolete tree/editor split fraction is removed.

## Performance

- File loading happens only when the selected URL changes.
- Syntax highlighting is computed for the selected file only.
- Preview content remains bounded by the 1 MB limit.
- Markdown reuses the existing render cache and renderer.
- The file tree remains lazy and caches expanded children as before.

## Testing

Add focused unit tests for:

- Extension-to-preview-kind mapping
- Extension-to-language inference
- Markdown classification
- Plain-text fallback
- Missing, oversized, binary, and non-UTF-8 load errors
- Dirty-state transitions after load, edit, save, and discard
- Pending navigation behavior for save, discard, and cancel
- File selection routes to Preview
- Review and chat file-open routes select the same Preview tab

Run the complete Swift test suite after focused tests pass. Package the app and
manually verify:

- File tree selection opens Preview
- Markdown renders and can switch to source editing
- Swift/Python/JavaScript files are highlighted
- Save updates the file and clears the dirty indicator
- Dirty navigation prompts on file change, tab change, sidebar close, and
  session change
- Sidebar resizing does not lose the current chat position
