# Right Sidebar File Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate the workspace file tree from file content, add a first-class Preview tab, and support rendered Markdown, syntax-highlighted code, editing, saving, and guarded navigation for unsaved changes.

**Architecture:** `ContentView` owns one long-lived `FilePreviewController` per app shell so edit buffers survive sidebar tab switches. `RightSidebar` becomes a four-tab container, `FileExplorerView` becomes tree-only, and `FilePreviewView` renders controller state. Pure file classification/loading and navigation decisions are kept outside SwiftUI for focused unit tests.

**Tech Stack:** Swift 6, SwiftUI, Observation, AppKit, XCTest, existing `MarkdownText`, `CodeSyntaxHighlighter`, `CodeBlockTheme`, and bundled code fonts.

---

### Task 1: File Preview Classification And Loading

**Files:**
- Create: `Sources/AgentDeckApp/UI/FilePreviewModel.swift`
- Create: `Tests/AgentDeckTests/FilePreviewModelTests.swift`

- [ ] **Step 1: Write failing classification tests**

Add tests that define the preview-kind and language contract:

```swift
final class FilePreviewModelTests: XCTestCase {
    func testClassifiesMarkdownAndSourceLanguages() {
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/README.md")), .markdown)
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/App.swift")), .code(language: "swift"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/tool.py")), .code(language: "python"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/app.tsx")), .code(language: "tsx"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/config.yml")), .code(language: "yaml"))
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/notes.txt")), .plainText)
    }

    func testKnownBinaryExtensionIsUnsupported() {
        XCTAssertEqual(FilePreviewModel.kind(for: URL(filePath: "/tmp/image.png")), .unsupported)
    }
}
```

- [ ] **Step 2: Run the classification tests and verify RED**

Run:

```bash
swift test --filter FilePreviewModelTests
```

Expected: compilation fails because `FilePreviewModel` does not exist.

- [ ] **Step 3: Implement preview kinds and extension mapping**

Create:

```swift
enum FilePreviewKind: Equatable, Sendable {
    case markdown
    case code(language: String)
    case plainText
    case unsupported
}

enum FilePreviewModel {
    static let maximumByteCount = 1_000_000

    static func kind(for url: URL) -> FilePreviewKind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) { return .markdown }
        if let language = sourceLanguages[ext] { return .code(language: language) }
        if unsupportedExtensions.contains(ext) { return .unsupported }
        return .plainText
    }
}
```

Populate `sourceLanguages` with the extensions already recognized by
`CodeSyntaxHighlighter`, including Swift, C-family languages, Java, Kotlin,
Python, Ruby, Go, Rust, JavaScript/JSX, TypeScript/TSX, shell, JSON, YAML,
TOML, XML, HTML, CSS, SQL, and Dockerfile-style names where the filename,
not extension, identifies the language.

- [ ] **Step 4: Add failing file-load tests**

Test success and each bounded error:

```swift
func testLoadsUTF8TextInsideWorkspace() throws {
    let fixture = try PreviewFixture(text: "let value = 1", name: "App.swift")
    let result = FilePreviewModel.load(url: fixture.file, workspace: fixture.root)
    XCTAssertEqual(try result.get().text, "let value = 1")
}

func testRejectsFileOutsideWorkspace() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside.txt")
    XCTAssertEqual(FilePreviewModel.load(url: outside, workspace: root), .failure(.outsideWorkspace))
}

func testRejectsOversizedAndBinaryFiles() throws {
    // Write maximumByteCount + 1 bytes and invalid UTF-8 bytes in separate fixtures.
    XCTAssertEqual(FilePreviewModel.load(url: oversized, workspace: root), .failure(.tooLarge))
    XCTAssertEqual(FilePreviewModel.load(url: binary, workspace: root), .failure(.unsupported))
}
```

- [ ] **Step 5: Run load tests and verify RED**

Run:

```bash
swift test --filter FilePreviewModelTests
```

Expected: compilation fails because `load`, `FilePreviewContent`, and
`FilePreviewLoadError` do not exist.

- [ ] **Step 6: Implement bounded UTF-8 loading**

Add:

```swift
struct FilePreviewContent: Equatable, Sendable {
    let url: URL
    let text: String
    let kind: FilePreviewKind
}

enum FilePreviewLoadError: Error, Equatable, Sendable {
    case outsideWorkspace
    case missing
    case tooLarge
    case unsupported
    case unreadable
}
```

`load(url:workspace:fileManager:)` must:

1. Compare standardized file paths and reject paths outside the workspace.
2. Verify the file exists and is not a directory.
3. Reject known unsupported extensions before reading.
4. Read file size and reject values above `maximumByteCount`.
5. Read `Data`, decode strictly as UTF-8, and return `.unsupported` when decoding fails.
6. Return `FilePreviewContent` with the inferred kind.

- [ ] **Step 7: Verify model tests pass**

Run:

```bash
swift test --filter FilePreviewModelTests
```

Expected: all `FilePreviewModelTests` pass.

### Task 2: Long-Lived Preview Controller And Unsaved Navigation

**Files:**
- Create: `Sources/AgentDeckApp/UI/FilePreviewController.swift`
- Create: `Tests/AgentDeckTests/FilePreviewControllerTests.swift`

- [ ] **Step 1: Write failing controller state tests**

Define load/edit/save/discard behavior:

```swift
@MainActor
final class FilePreviewControllerTests: XCTestCase {
    func testEditMakesDocumentDirtyAndSaveClearsDirty() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        let controller = FilePreviewController(workspace: fixture.root)

        controller.open(fixture.file)
        controller.text = "after"
        XCTAssertTrue(controller.isDirty)

        XCTAssertTrue(controller.save())
        XCTAssertFalse(controller.isDirty)
        XCTAssertEqual(try String(contentsOf: fixture.file, encoding: .utf8), "after")
    }

    func testDiscardRestoresLoadedText() throws {
        let fixture = try PreviewFixture(text: "before", name: "notes.txt")
        let controller = FilePreviewController(workspace: fixture.root)
        controller.open(fixture.file)
        controller.text = "after"
        controller.discardChanges()
        XCTAssertEqual(controller.text, "before")
        XCTAssertFalse(controller.isDirty)
    }
}
```

- [ ] **Step 2: Run controller tests and verify RED**

Run:

```bash
swift test --filter FilePreviewControllerTests
```

Expected: compilation fails because `FilePreviewController` does not exist.

- [ ] **Step 3: Implement observable document state**

Create an `@MainActor @Observable final class FilePreviewController` with:

```swift
enum FilePreviewDisplayMode: String, CaseIterable, Identifiable {
    case preview = "预览"
    case edit = "编辑"
    var id: String { rawValue }
}

private(set) var selectedFile: URL?
private(set) var kind: FilePreviewKind?
var text = ""
private(set) var baseline = ""
var displayMode: FilePreviewDisplayMode = .preview
private(set) var error: FilePreviewLoadError?
private(set) var saveErrorMessage: String?

var isDirty: Bool {
    selectedFile != nil && error == nil && text != baseline
}
```

Implement `open(_:)`, `setWorkspace(_:)`, `save() -> Bool`,
`discardChanges()`, and `clear()`. `open(_:)` only mutates document state after
the model has returned a complete result.

- [ ] **Step 4: Add failing guarded-navigation tests**

Model pending navigation explicitly:

```swift
enum FilePreviewNavigation: Equatable {
    case openFile(URL)
    case switchMode(RightSidebarMode)
    case closeSidebar
    case changeWorkspace(URL)
}

func testDirtyDocumentDefersNavigationUntilResolution() throws {
    let controller = makeDirtyController()
    var committed: FilePreviewNavigation?

    controller.request(.switchMode(.browser)) { committed = $0 }

    XCTAssertEqual(controller.pendingNavigation, .switchMode(.browser))
    XCTAssertNil(committed)

    controller.resolvePendingNavigation(.discard)
    XCTAssertEqual(committed, .switchMode(.browser))
    XCTAssertFalse(controller.isDirty)
}

func testCancelLeavesDirtyDocumentAndDoesNotCommit() throws {
    let controller = makeDirtyController()
    var committed = false
    controller.request(.closeSidebar) { _ in committed = true }
    controller.resolvePendingNavigation(.cancel)
    XCTAssertFalse(committed)
    XCTAssertTrue(controller.isDirty)
}
```

- [ ] **Step 5: Run guarded-navigation tests and verify RED**

Run:

```bash
swift test --filter FilePreviewControllerTests
```

Expected: compilation fails because pending-navigation APIs are missing.

- [ ] **Step 6: Implement pending navigation**

Add:

```swift
enum FilePreviewNavigationResolution {
    case save
    case discard
    case cancel
}

private(set) var pendingNavigation: FilePreviewNavigation?
var isShowingUnsavedChangesConfirmation: Bool { pendingNavigation != nil }
```

`request(_:commit:)` commits immediately when clean. When dirty, it stores both
the action and callback. `resolvePendingNavigation(_:)`:

- `.save`: call `save()` and commit only after success.
- `.discard`: call `discardChanges()` and commit.
- `.cancel`: clear pending state without committing.

Use one private `commitPendingNavigation()` helper so the callback runs once.

- [ ] **Step 7: Verify controller tests pass**

Run:

```bash
swift test --filter FilePreviewControllerTests
```

Expected: all controller tests pass.

### Task 3: Split The File Tree And Route Files To Preview

**Files:**
- Modify: `Sources/AgentDeckApp/UI/FileExplorerView.swift`
- Modify: `Sources/AgentDeckApp/UI/RightSidebar.swift`
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`
- Modify: `Sources/AgentDeckApp/UI/ChangeReviewView.swift`
- Modify: `Tests/AgentDeckTests/FileTreeTests.swift`
- Create: `Tests/AgentDeckTests/RightSidebarNavigationTests.swift`

- [ ] **Step 1: Write failing navigation policy tests**

Extract the route decision from SwiftUI:

```swift
final class RightSidebarNavigationTests: XCTestCase {
    func testOpeningFileSelectsPreviewTab() {
        XCTAssertEqual(
            RightSidebarNavigation.destinationForOpenedFile,
            .preview
        )
    }

    func testTabOrderPlacesPreviewBesideFiles() {
        XCTAssertEqual(
            RightSidebarMode.allCases,
            [.files, .preview, .browser, .review]
        )
    }
}
```

- [ ] **Step 2: Run navigation tests and verify RED**

Run:

```bash
swift test --filter RightSidebarNavigationTests
```

Expected: compilation fails because `.preview` and the navigation policy do not
exist.

- [ ] **Step 3: Make `FileExplorerView` tree-only**

Remove:

- `fileText`, `loadedText`, and `loadError`
- `topFraction` and `dragBaseline`
- The resize divider
- The editor, load, save, and unsupported-extension code

Keep:

- Root children
- Selected-row styling
- Expanded-folder persistence
- Lazy recursive directory loading

Change the interface to:

```swift
struct FileExplorerView: View {
    let root: URL
    let selectedFile: URL?
    @Binding var expandedFolders: Set<URL>
    let onOpenFile: (URL) -> Void
}
```

Pass `selectedFile` and `onOpenFile` through `FileRow`. A file row invokes
`onOpenFile(node.url)`; directory behavior remains unchanged.

- [ ] **Step 4: Add Preview to the sidebar and route all file opens**

Update:

```swift
enum RightSidebarMode: String, CaseIterable, Identifiable {
    case files = "文件"
    case preview = "预览"
    case browser = "浏览器"
    case review = "审核"
}

enum RightSidebarNavigation {
    static let destinationForOpenedFile: RightSidebarMode = .preview
}
```

Pass `FilePreviewController` into `RightSidebar`. File-tree and Review callbacks
request `.openFile(url)` and, after commit, call `controller.open(url)` and set
the tab to `.preview`.

In `ContentView`, replace direct file selection mutations in `onOpenFile` with
the same guarded open-file request. Remove `sidebarTopFraction`. Keep expanded
folders in `ContentView`.

- [ ] **Step 5: Add guarded tab and close actions**

Do not bind the Picker directly to mutable mode. Use:

```swift
Picker("", selection: Binding(
    get: { mode },
    set: { requestedMode in
        requestNavigation(.switchMode(requestedMode))
    }
))
```

Route close through `.closeSidebar`. Add one
`confirmationDialog("保存对文件的修改？", ...)` driven by the controller with:

- `保存并继续`
- `放弃改动`
- `取消`

- [ ] **Step 6: Run focused sidebar tests**

Run:

```bash
swift test --filter FileTreeTests
swift test --filter RightSidebarNavigationTests
swift test --filter FilePreviewControllerTests
```

Expected: all pass.

### Task 4: Rendered Preview And Editor UI

**Files:**
- Create: `Sources/AgentDeckApp/UI/FilePreviewView.swift`
- Modify: `Sources/AgentDeckApp/UI/MarkdownText.swift`
- Create: `Tests/AgentDeckTests/FilePreviewPresentationTests.swift`

- [ ] **Step 1: Write failing presentation tests**

Keep view decisions in a pure presentation helper:

```swift
final class FilePreviewPresentationTests: XCTestCase {
    func testMarkdownUsesRenderedMarkdownPresentation() {
        XCTAssertEqual(FilePreviewPresentation.presentation(for: .markdown), .markdown)
    }

    func testCodeCarriesDetectedLanguage() {
        XCTAssertEqual(
            FilePreviewPresentation.presentation(for: .code(language: "swift")),
            .code(language: "swift")
        )
    }

    func testPlainTextUsesTextPresentation() {
        XCTAssertEqual(FilePreviewPresentation.presentation(for: .plainText), .plainText)
    }
}
```

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
swift test --filter FilePreviewPresentationTests
```

Expected: compilation fails because `FilePreviewPresentation` does not exist.

- [ ] **Step 3: Expose a reusable highlighted code view**

Rename the private `MarkdownCodeBlockView` implementation to a reusable
internal `HighlightedCodeView`:

```swift
struct HighlightedCodeView: View {
    let language: String?
    let code: String
    var showsHeader = true
    var widthFraction: CGFloat? = MarkdownCodeBlockPresentation.widthFraction
}
```

Markdown fenced code keeps `showsHeader = true` and the existing proportional
width. File Preview uses full width with a compact language header. Both paths
reuse `CodeSyntaxHighlighter`, `CodeBlockTheme`, selected code font, horizontal
scrolling, text selection, and copy behavior.

- [ ] **Step 4: Implement `FilePreviewView`**

Build:

```swift
struct FilePreviewView: View {
    @Bindable var controller: FilePreviewController
}
```

Header:

- File icon and truncated filename
- Dirty dot
- Preview/Edit segmented picker
- Save icon button, disabled when clean or unavailable

Body:

- No file: centered selection prompt
- Error: centered icon and localized error message
- Preview + Markdown: vertical `ScrollView` containing `MarkdownText`
- Preview + code: vertical `ScrollView` containing full-width
  `HighlightedCodeView`
- Preview + plain text: selectable monospaced text
- Edit: `TextEditor` bound to `controller.text`

Use the existing appearance storage keys for font size, code font, and theme.
Do not duplicate syntax colors.

- [ ] **Step 5: Add localized load-error messages**

Implement a presentation helper mapping:

```swift
extension FilePreviewLoadError {
    var message: String {
        switch self {
        case .outsideWorkspace: "文件不在当前工作目录中"
        case .missing: "文件不存在"
        case .tooLarge: "文件过大（>1 MB），无法预览或编辑"
        case .unsupported: "暂不支持预览此文件"
        case .unreadable: "无法读取文件"
        }
    }
}
```

Save failures use the controller's concrete error text and remain visible until
the next edit, successful save, or file load.

- [ ] **Step 6: Run presentation and Markdown/highlighter tests**

Run:

```bash
swift test --filter FilePreviewPresentationTests
swift test --filter MarkdownParserTests
swift test --filter MarkdownBlockParserTests
swift test --filter CodeSyntaxHighlighterTests
```

Expected: all pass.

### Task 5: Session Changes, Full Regression, Package, And Visual Verification

**Files:**
- Modify: `Sources/AgentDeckApp/AppShell/ContentView.swift`
- Modify: `Tests/AgentDeckTests/MessagePresentationTests.swift` if the new enum
  case requires exhaustive expectations
- Modify: `Tests/AgentDeckTests/SidebarSizingTests.swift` only if integration
  exposes a sizing regression

- [ ] **Step 1: Guard focused-session and workspace changes**

Before committing a focused-session or workspace change that would replace the
preview workspace, route `.changeWorkspace(newURL)` through the controller.
On save/discard success:

1. Update controller workspace.
2. Clear the selected file, text buffer, baseline, display error, and pending
   navigation so content from the old workspace cannot leak into the new one.
3. Commit the session/workspace transition.

If the existing `WorkspaceController` changes focused sessions before
`ContentView` receives `onChange`, use the confirmation to guard only preview
cleanup and retain the dirty document until resolved; do not attempt to roll
back workspace controller state without an explicit controller API.

- [ ] **Step 2: Run all tests**

Run:

```bash
swift test
```

Expected: all tests pass with no failures.

- [ ] **Step 3: Build the release app**

Run:

```bash
zsh Scripts/package_app.sh
```

Expected: `dist/AgentDeck.app` is produced successfully.

- [ ] **Step 4: Launch and verify with Computer Use**

Open the packaged app and verify:

1. Right sidebar tabs read `文件 / 预览 / 浏览器 / 审核`.
2. Files shows only the workspace tree.
3. Selecting Markdown opens Preview and renders headings, lists, links, tables,
   and fenced code.
4. Selecting Swift, Python, and JavaScript files shows syntax colors.
5. Edit mode displays source, Save writes the file, and the dirty dot clears.
6. Dirty file change, tab switch, and sidebar close each show the three-option
   confirmation.
7. Cancel keeps Preview and its buffer.
8. The sidebar can still resize and chat remains at the current bottom position
   when it was already pinned.

- [ ] **Step 5: Inspect the final diff**

Run:

```bash
git diff --check
git status --short
git diff -- Sources/AgentDeckApp/UI/FilePreviewModel.swift \
  Sources/AgentDeckApp/UI/FilePreviewController.swift \
  Sources/AgentDeckApp/UI/FilePreviewView.swift \
  Sources/AgentDeckApp/UI/FileExplorerView.swift \
  Sources/AgentDeckApp/UI/RightSidebar.swift \
  Sources/AgentDeckApp/AppShell/ContentView.swift
```

Expected: no whitespace errors and no unrelated files modified by this feature.
