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

/// 工作目录文件树。文件内容由独立的 Preview 标签负责。
struct FileExplorerView: View {
    let root: URL

    @State private var rootChildren: [FileNode] = []
    let selectedFile: URL?
    @Binding var expandedFolders: Set<URL> // 已展开文件夹（由父级常驻持有，关闭侧栏不丢失）
    let onOpenFile: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(rootChildren) { node in
                    FileRow(
                        node: node,
                        depth: 0,
                        selectedFile: selectedFile,
                        expandedFolders: $expandedFolders,
                        onOpenFile: onOpenFile
                    )
                }
                if rootChildren.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .appFont(relative: 8, weight: .semibold)
                            .foregroundStyle(Theme.accent)
                        Text("此目录为空")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                }
            }
            .padding(8)
        }
        .background(Theme.panel)
        .task(id: root) {
            rootChildren = FileTree.children(of: root)
        }
    }
}

/// 递归的文件行：用 depth 做层级缩进，自绘展开箭头（旋转动画）。
/// 目录点击展开/折叠（首次展开时懒加载子项并缓存），文件点击选中。
private struct FileRow: View {
    let node: FileNode
    let depth: Int
    let selectedFile: URL?
    @Binding var expandedFolders: Set<URL>
    let onOpenFile: (URL) -> Void

    @State private var children: [FileNode] = []
    @State private var loaded = false
    @State private var hovering = false

    private var isSelected: Bool { selectedFile == node.url }
    /// 展开态读自父级常驻集合，故关闭侧栏后重开仍保持。
    private var isExpanded: Bool { expandedFolders.contains(node.url) }

    /// 每一级缩进的像素宽度。
    private static let indentStep: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            row
            if isExpanded {
                ForEach(children) { child in
                    FileRow(
                        node: child,
                        depth: depth + 1,
                        selectedFile: selectedFile,
                        expandedFolders: $expandedFolders,
                        onOpenFile: onOpenFile
                    )
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
            onOpenFile(node.url)
        }
    }
}
