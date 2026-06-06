import SwiftUI
import AppKit

/// 文件树的一个节点。
public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let isDirectory: Bool
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
}

/// 列目录（纯逻辑，便于测试）：目录在前，再按名称不分大小写排序，跳过隐藏项。
public enum FileTree {
    public static func children(of url: URL, fileManager: FileManager = .default) -> [FileNode] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .map { item in
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return FileNode(url: item, isDirectory: isDir)
            }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

/// 工作目录的文件浏览器：上树下编辑器，可查看/编辑/保存 UTF-8 文本文件。
/// 头部与关闭由外层 RightSidebar 提供。
struct FileExplorerView: View {
    let root: URL

    @State private var rootChildren: [FileNode] = []
    @Binding var selection: URL?
    @State private var fileText = ""
    @State private var loadedText = "" // 加载时的基线，用于判断未保存改动（避免程序化赋值误标脏）
    @State private var loadError: String?
    @Binding var topFraction: CGFloat // 上方文件树占比（由父级常驻持有，关闭侧栏不丢失）
    @Binding var expandedFolders: Set<URL> // 已展开文件夹（由父级常驻持有，关闭侧栏不丢失）
    @State private var dragBaseline: CGFloat? // 拖动起始时的上栏高度基准
    @AppStorage(BundledCodeFont.storageKey) private var selectedCodeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue

    /// 是否有未保存改动：当前文本与加载基线不同（无选中 / 加载失败时恒为否）。
    private var dirty: Bool {
        selection != nil && loadError == nil && fileText != loadedText
    }

    var body: some View {
        GeometryReader { geo in
            let minPane: CGFloat = 90
            let handleHeight: CGFloat = 10
            let available = max(0, geo.size.height - handleHeight)
            let topHeight = available <= minPane * 2
                ? available / 2
                : min(max(topFraction * available, minPane), available - minPane)

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(rootChildren) { node in
                            FileRow(node: node, depth: 0, selection: $selection, expandedFolders: $expandedFolders)
                        }
                    }
                    .padding(8)
                }
                .frame(height: topHeight)
                .background(Theme.panel)

                resizeHandle(height: handleHeight, available: available)

                editor
                    .frame(maxHeight: .infinity)
                    .background(Theme.panelRaised)
            }
        }
        .task(id: root) {
            if let selection, !Self.contains(selection, in: root) {
                self.selection = nil
            }
            rootChildren = FileTree.children(of: root)
            load(selection)
        }
        .onChange(of: selection) { _, url in load(url) }
    }

    /// 可拖拽的分隔条：用 NSView 接管鼠标（mouseDownCanMoveWindow=false，避免拖到窗口本身），
    /// 以 mouseDown 时位置为基准按累计位移调整上下占比，hover 显示上下调整光标。
    private func resizeHandle(height: CGFloat, available: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Theme.panel)
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.border)
                .frame(width: 32, height: 3)
            ResizeDivider(
                axis: .vertical,
                onBegan: { dragBaseline = topFraction * available },
                onChanged: { deltaDown in
                    guard available > 0 else { return }
                    let lo = min(90, available / 2)
                    let base = dragBaseline ?? (topFraction * available)
                    let newTop = min(max(base + deltaDown, lo), available - lo)
                    topFraction = newTop / available
                },
                onEnded: { dragBaseline = nil }
            )
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let selection {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .appFont(relative: -2)
                        .foregroundStyle(.secondary)
                    Text(selection.lastPathComponent)
                        .appFont(relative: -1, weight: .medium)
                        .lineLimit(1)
                    if dirty {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                            .help("有未保存改动")
                    }
                    Spacer()
                    Button(action: save) {
                        Label("保存", systemImage: "square.and.arrow.down")
                            .appFont(relative: -2)
                    }
                    .buttonStyle(.borderless)
                        .disabled(loadError != nil || !dirty)
                }
                .padding(.bottom, 2)
                if let loadError {
                    Text(loadError).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $fileText)
                        .font(BundledCodeFont.resolve(selectedCodeFontID).swiftUIFont(size: AppFontSize.points(appFontSize)))
                        .scrollContentBackground(.hidden)
                        .background(Theme.canvas)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .stroke(Theme.hairline, lineWidth: 1)
                        }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .appFont(relative: 10, weight: .semibold)
                        .foregroundStyle(Theme.accent)
                    Text("选择一个文件查看 / 编辑")
                        .foregroundStyle(.secondary)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
    }

    private func load(_ url: URL?) {
        loadError = nil
        guard let url else { setText(""); return }

        guard FileManager.default.fileExists(atPath: url.path) else {
            setText("")
            loadError = "文件不存在：\(url.lastPathComponent)"
            return
        }

        // 已知非文本类型（ppt/docx/png/pdf…）直接提示不支持预览。
        if Self.nonPreviewable.contains(url.pathExtension.lowercased()) {
            setText("")
            loadError = unsupportedMessage(for: url)
            return
        }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 {
            setText("")
            loadError = "文件过大（>1MB），不便在此编辑。"
            return
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            setText(text)
        } else {
            // 未列入名单、但也不是 UTF-8 文本（其它二进制）。
            setText("")
            loadError = unsupportedMessage(for: url)
        }
    }

    /// 同步设置编辑内容与基线（加载后视为「干净」）。
    private func setText(_ text: String) {
        fileText = text
        loadedText = text
    }

    private func unsupportedMessage(for url: URL) -> String {
        let ext = url.pathExtension
        let label = ext.isEmpty ? url.lastPathComponent : ".\(ext.lowercased())"
        return "暂不支持预览「\(label)」文件"
    }

    /// 已知不便以文本预览的扩展名。
    private static let nonPreviewable: Set<String> = [
        "ppt", "pptx", "doc", "docx", "xls", "xlsx", "pdf", "key", "numbers", "pages",
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif", "icns", "ico",
        "zip", "gz", "tar", "rar", "7z", "dmg", "pkg", "app",
        "mp3", "mp4", "mov", "avi", "mkv", "wav", "aac", "m4a", "flac",
        "ttf", "otf", "woff", "woff2", "o", "a", "dylib", "so", "class", "jar", "wasm", "bin"
    ]

    private static func contains(_ file: URL, in root: URL) -> Bool {
        let filePath = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private func save() {
        guard let url = selection else { return }
        guard (try? fileText.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        loadedText = fileText // 保存成功 → 基线对齐，回到「干净」。
    }
}

/// 递归的文件行：用 depth 做层级缩进，自绘展开箭头（旋转动画）。
/// 目录点击展开/折叠（首次展开时懒加载子项并缓存），文件点击选中。
private struct FileRow: View {
    let node: FileNode
    let depth: Int
    @Binding var selection: URL?
    @Binding var expandedFolders: Set<URL>

    @State private var children: [FileNode] = []
    @State private var loaded = false
    @State private var hovering = false

    private var isSelected: Bool { selection == node.url }
    /// 展开态读自父级常驻集合，故关闭侧栏后重开仍保持。
    private var isExpanded: Bool { expandedFolders.contains(node.url) }

    /// 每一级缩进的像素宽度。
    private static let indentStep: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if isExpanded {
                ForEach(children) { child in
                    FileRow(node: child, depth: depth + 1, selection: $selection, expandedFolders: $expandedFolders)
                }
            }
        }
        .onAppear {
            // 挂载时若该文件夹被记忆为展开，懒加载其子项（侧栏重开后逐级恢复展开树）。
            if node.isDirectory, isExpanded, !loaded {
                children = FileTree.children(of: node.url)
                loaded = true
            }
        }
    }

    private var row: some View {
        Button(action: activate) {
            HStack(spacing: 5) {
                Color.clear.frame(width: CGFloat(depth) * Self.indentStep, height: 1)

                // 目录显示可旋转箭头；文件留同宽空位以对齐。
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .opacity(node.isDirectory ? 1 : 0)

                Image(systemName: iconName)
                    .appFont(relative: -1)
                    .foregroundStyle(node.isDirectory ? Theme.accent : Color.secondary)
                    .frame(width: 16)

                Text(node.name)
                    .appFont(relative: -1)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Theme.accent : .primary)

                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let fill: Color = isSelected
            ? Theme.selected
            : (hovering ? Theme.controlHover : .clear)
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(fill)
    }

    private var iconName: String {
        if node.isDirectory { return isExpanded ? "folder.fill" : "folder" }
        switch node.url.pathExtension.lowercased() {
        case "swift", "js", "ts", "py", "rb", "go", "rs", "java", "c", "cpp", "h", "sh", "json", "yml", "yaml", "toml":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rtf":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "icns":
            return "photo"
        default:
            return "doc"
        }
    }

    private func activate() {
        if node.isDirectory {
            if !loaded {
                children = FileTree.children(of: node.url)
                loaded = true
            }
            withAnimation(.easeInOut(duration: 0.18)) {
                if isExpanded { expandedFolders.remove(node.url) }
                else { expandedFolders.insert(node.url) }
            }
        } else {
            selection = node.url
        }
    }
}
