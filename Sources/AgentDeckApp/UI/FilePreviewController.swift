import Foundation
import Observation

enum FilePreviewDisplayMode: String, CaseIterable, Identifiable {
    case preview = "预览"
    case edit = "编辑"

    var id: String { rawValue }
}

enum FilePreviewNavigation: Equatable {
    case openFile(URL)
    case switchMode(RightSidebarMode)
    case closeSidebar
    case changeWorkspace(URL)
}

enum FilePreviewNavigationResolution {
    case save
    case discard
    case cancel
}

@MainActor
@Observable
final class FilePreviewController {
    private(set) var workspace: URL
    private(set) var selectedFile: URL?
    private(set) var kind: FilePreviewKind?
    var text = "" {
        didSet {
            if text != oldValue {
                saveErrorMessage = nil
            }
        }
    }
    private(set) var baseline = ""
    var displayMode: FilePreviewDisplayMode = .preview
    private(set) var error: FilePreviewLoadError?
    private(set) var saveErrorMessage: String?
    private(set) var pendingNavigation: FilePreviewNavigation?

    @ObservationIgnored
    private var pendingCommit: ((FilePreviewNavigation) -> Void)?

    init(workspace: URL) {
        self.workspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
    }

    var isDirty: Bool {
        selectedFile != nil && error == nil && text != baseline
    }

    var isShowingUnsavedChangesConfirmation: Bool {
        pendingNavigation != nil
    }

    func open(_ url: URL) {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        selectedFile = resolved
        kind = FilePreviewModel.kind(for: resolved)
        displayMode = .preview
        saveErrorMessage = nil

        switch FilePreviewModel.load(url: resolved, workspace: workspace) {
        case .success(let content):
            selectedFile = content.url
            kind = content.kind
            setLoadedText(content.text)
            error = nil
        case .failure(let loadError):
            setLoadedText("")
            error = loadError
        }
    }

    @discardableResult
    func save() -> Bool {
        guard let selectedFile, error == nil else { return false }
        do {
            try text.write(to: selectedFile, atomically: true, encoding: .utf8)
            baseline = text
            saveErrorMessage = nil
            return true
        } catch {
            saveErrorMessage = error.localizedDescription
            return false
        }
    }

    func discardChanges() {
        text = baseline
        saveErrorMessage = nil
    }

    func clear() {
        selectedFile = nil
        kind = nil
        setLoadedText("")
        error = nil
        saveErrorMessage = nil
        displayMode = .preview
        pendingNavigation = nil
        pendingCommit = nil
    }

    func setWorkspace(_ url: URL) {
        workspace = url.standardizedFileURL.resolvingSymlinksInPath()
        clear()
    }

    func request(
        _ navigation: FilePreviewNavigation,
        commit: @escaping (FilePreviewNavigation) -> Void
    ) {
        guard isDirty else {
            commit(navigation)
            return
        }
        pendingNavigation = navigation
        pendingCommit = commit
    }

    func resolvePendingNavigation(_ resolution: FilePreviewNavigationResolution) {
        guard pendingNavigation != nil else { return }
        switch resolution {
        case .save:
            guard save() else { return }
            commitPendingNavigation()
        case .discard:
            discardChanges()
            commitPendingNavigation()
        case .cancel:
            pendingNavigation = nil
            pendingCommit = nil
        }
    }

    private func setLoadedText(_ value: String) {
        text = value
        baseline = value
    }

    private func commitPendingNavigation() {
        guard let navigation = pendingNavigation else { return }
        let commit = pendingCommit
        pendingNavigation = nil
        pendingCommit = nil
        commit?(navigation)
    }
}
