import Foundation

enum FilePreviewKind: Equatable, Sendable {
    case markdown
    case code(language: String)
    case plainText
    case unsupported
}

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

enum FilePreviewModel {
    static let maximumByteCount = 1_000_000

    static func kind(for url: URL) -> FilePreviewKind {
        let filename = url.lastPathComponent.lowercased()
        if let language = filenameLanguages[filename] {
            return .code(language: language)
        }

        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) {
            return .markdown
        }
        if let language = sourceLanguages[ext] {
            return .code(language: language)
        }
        if unsupportedExtensions.contains(ext) {
            return .unsupported
        }
        return .plainText
    }

    static func load(
        url: URL,
        workspace: URL,
        fileManager: FileManager = .default
    ) -> Result<FilePreviewContent, FilePreviewLoadError> {
        let resolvedWorkspace = workspace.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFile = url.standardizedFileURL.resolvingSymlinksInPath()
        guard contains(resolvedFile, in: resolvedWorkspace) else {
            return .failure(.outsideWorkspace)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedFile.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(.missing)
        }

        let previewKind = kind(for: resolvedFile)
        guard previewKind != .unsupported else {
            return .failure(.unsupported)
        }

        do {
            let values = try resolvedFile.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize, size > maximumByteCount {
                return .failure(.tooLarge)
            }
            let data = try Data(contentsOf: resolvedFile, options: [.mappedIfSafe])
            guard data.count <= maximumByteCount else {
                return .failure(.tooLarge)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.unsupported)
            }
            return .success(FilePreviewContent(url: resolvedFile, text: text, kind: previewKind))
        } catch {
            return .failure(.unreadable)
        }
    }

    private static func contains(_ file: URL, in workspace: URL) -> Bool {
        let filePath = file.path
        let workspacePath = workspace.path
        return filePath == workspacePath || filePath.hasPrefix(workspacePath + "/")
    }

    private static let markdownExtensions: Set<String> = ["md", "markdown"]

    private static let filenameLanguages: [String: String] = [
        "dockerfile": "dockerfile",
        "makefile": "makefile",
        "gemfile": "ruby",
        "rakefile": "ruby"
    ]

    private static let sourceLanguages: [String: String] = [
        "swift": "swift",
        "c": "c",
        "h": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "m": "objective-c",
        "mm": "objective-c",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "py": "python",
        "pyw": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "js": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "jsx": "jsx",
        "ts": "typescript",
        "tsx": "tsx",
        "sh": "bash",
        "bash": "bash",
        "zsh": "zsh",
        "fish": "shell",
        "json": "json",
        "jsonc": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "xml": "xml",
        "html": "html",
        "htm": "html",
        "css": "css",
        "scss": "css",
        "sass": "css",
        "sql": "sql"
    ]

    private static let unsupportedExtensions: Set<String> = [
        "ppt", "pptx", "doc", "docx", "xls", "xlsx", "pdf", "key", "numbers", "pages",
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico",
        "zip", "gz", "tar", "rar", "7z", "dmg", "pkg", "app",
        "mp3", "mp4", "mov", "avi", "mkv", "wav", "aac", "m4a", "flac",
        "ttf", "otf", "woff", "woff2", "o", "a", "dylib", "so", "class", "jar", "wasm", "bin"
    ]
}
