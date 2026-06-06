import SwiftUI
import AppKit

/// 附件相关的轻量元信息助手（类型判断 / 大小格式化 / 图标）。
/// 附件模型本身用 `[URL]`，由普通聊天与广播两个 composer 共享，避免两边 UI 漂移。
enum AttachmentInfo {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "bmp", "tiff", "tif", "webp"
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 人类可读文件大小（如 “12 KB”）；取不到则返回 nil。
    static func sizeString(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 按扩展名挑一个能代表类型的 SF Symbol。
    static func icon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if isImage(url) { return "photo" }
        switch ext {
        case "pdf": return "doc.richtext"
        case "md", "markdown", "txt", "rtf": return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist": return "curlybraces"
        case "swift", "py", "js", "ts", "rb", "go", "rs", "java", "c", "cpp", "h", "sh", "html", "css":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "tar", "gz", "7z", "rar": return "doc.zipper"
        case "mp4", "mov", "m4v", "avi", "mkv": return "film"
        case "mp3", "wav", "aac", "m4a", "flac": return "waveform"
        case "csv", "xlsx", "xls", "numbers": return "tablecells"
        case "doc", "docx", "pages": return "doc"
        case "ppt", "pptx", "key": return "rectangle.on.rectangle"
        default: return "doc"
        }
    }
}

/// 附件队列展示：每个附件一张卡片（类型图标 / 图片缩略图、文件名、大小、单独移除按钮）。
/// 普通聊天与广播 composer 共用同一组件，保证两边附件预览/移除行为一致。
struct AttachmentChipsView: View {
    let attachments: [URL]
    let onRemove: (URL) -> Void
    var onOpen: ((URL) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { url in
                    AttachmentChip(url: url, onRemove: { onRemove(url) }, onOpen: onOpen)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 50)
    }
}

private struct AttachmentChip: View {
    let url: URL
    let onRemove: () -> Void
    var onOpen: ((URL) -> Void)?

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            preview
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .appFont(relative: -2, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let size = AttachmentInfo.sizeString(url) {
                    Text(size)
                        .appFont(relative: -3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 120, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .appFont(relative: -1)
                    .foregroundStyle(hovering ? Color.red.opacity(0.9) : Color.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("移除该附件")
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let onOpen { onOpen(url) } else { NSWorkspace.shared.open(url) }
        }
        .help(url.path)
        .task(id: url) { await loadThumbnailIfImage() }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: AttachmentInfo.icon(for: url))
                .appFont(relative: 0)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    /// 图片附件：后台读盘并按比例下采样成缩略图，避免主线程卡顿与大图占内存。
    private func loadThumbnailIfImage() async {
        guard AttachmentInfo.isImage(url) else { return }
        let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
            guard let image = NSImage(contentsOf: url) else { return nil }
            let target: CGFloat = 56 // @2x of 28pt
            let size = image.size
            guard size.width > 0, size.height > 0 else { return image }
            let scale = min(target / size.width, target / size.height, 1)
            let newSize = NSSize(width: size.width * scale, height: size.height * scale)
            let thumb = NSImage(size: newSize)
            thumb.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize))
            thumb.unlockFocus()
            return thumb
        }.value
        if let loaded { thumbnail = loaded }
    }
}

/// 附件采集：弹「附加照片/文件」面板，或用系统 `screencapture -i` 做交互式区域截图。
/// 两个 composer 共用同一套采集逻辑。
@MainActor
enum AttachmentPicker {
    /// 选择本地文件（可多选）。返回所选 URL（取消则空）。
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// 交互式屏幕截图（拖选区域）。完成后回调 PNG 临时文件 URL；用户取消则不回调。
    static func captureScreenshot(completion: @escaping (URL) -> Void) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDeck-Shot-\(UUID().uuidString.prefix(8)).png")
        Task {
            let ok = await Task.detached(priority: .userInitiated) { () -> Bool in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-i", tmp.path] // -i：交互式选区；用户取消则不生成文件
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    return false
                }
                return FileManager.default.fileExists(atPath: tmp.path)
            }.value
            if ok {
                await MainActor.run { completion(tmp) }
            }
        }
    }
}
