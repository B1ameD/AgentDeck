import SwiftUI

/// 聊天里内联 diff 卡片的「有界预览」选择逻辑（纯函数，便于测试）。
/// 关键：内联卡片只展示**有界预览**，不把大文件/大量改动灌进聊天（避免又一条刷屏路径）；
/// 超出部分由「在审核栏查看全部」跳到右侧栏看完整 diff。
enum InlineDiffPreview {
    struct Model: Equatable {
        var files: [TurnFileDiff]   // 已按上限裁剪 hunk/行
        var truncated: Bool         // 是否有未展示的文件/hunk/行
        var hiddenFileCount: Int    // 完全未展示的文件数
    }

    static func make(
        from summary: TurnDiffSummary,
        maxFiles: Int = 3,
        maxHunksPerFile: Int = 2,
        maxLines: Int = 80
    ) -> Model {
        var out: [TurnFileDiff] = []
        var usedLines = 0
        var truncated = false

        for file in summary.files.prefix(maxFiles) {
            guard file.hasInlineDiff else {
                out.append(file) // 二进制/过大：仅作头部条目，无行
                continue
            }
            if usedLines >= maxLines { truncated = true; break }

            var keptHunks: [DiffHunk] = []
            for hunk in file.diff.hunks.prefix(maxHunksPerFile) {
                let remaining = maxLines - usedLines
                if remaining <= 0 { truncated = true; break }
                if hunk.lines.count <= remaining {
                    keptHunks.append(hunk)
                    usedLines += hunk.lines.count
                } else {
                    keptHunks.append(DiffHunk(header: hunk.header, lines: Array(hunk.lines.prefix(remaining))))
                    usedLines = maxLines
                    truncated = true
                    break
                }
            }
            if file.diff.hunks.count > min(maxHunksPerFile, keptHunks.count) { truncated = true }
            out.append(TurnFileDiff(
                path: file.path, status: file.status,
                diff: FileDiff(hunks: keptHunks, isBinary: file.diff.isBinary),
                note: file.note
            ))
        }

        let hiddenFiles = max(0, summary.files.count - out.count)
        if hiddenFiles > 0 { truncated = true }
        return Model(files: out, truncated: truncated, hiddenFileCount: hiddenFiles)
    }
}

/// Claude 风格的内联 diff 卡片：路径头 + 状态 + 行号 + 绿增红删。展示有界预览，完整 diff 去右侧栏。
struct InlineDiffCardView: View {
    let summary: TurnDiffSummary
    var onViewAll: () -> Void = {}

    private var preview: InlineDiffPreview.Model { InlineDiffPreview.make(from: summary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            summaryHeader
            ForEach(preview.files) { file in
                InlineDiffFileCardView(file: file)
            }
            if preview.truncated {
                Button(action: onViewAll) {
                    Label(viewAllLabel, systemImage: "arrow.up.forward.app")
                        .appFont(relative: -2, weight: .medium)
                        .foregroundStyle(Theme.accentStrong)
                }
                .buttonStyle(.plain)
                .help("在右侧栏「审核」标签查看完整逐行 diff")
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text.magnifyingglass")
                .appFont(relative: -2, weight: .medium)
                .foregroundStyle(Theme.accent)
            Text("Diff 预览")
                .appFont(relative: -2, weight: .semibold)
            Text("\(summary.files.count) 个文件")
                .appFont(relative: -3)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if summary.totalAdded > 0 {
                Text("+\(summary.totalAdded)")
                    .appFont(relative: -3, weight: .medium)
                    .foregroundStyle(.green)
            }
            if summary.totalRemoved > 0 {
                Text("−\(summary.totalRemoved)")
                    .appFont(relative: -3, weight: .medium)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private var viewAllLabel: String {
        preview.hiddenFileCount > 0
            ? "在审核栏查看全部（另有 \(preview.hiddenFileCount) 个文件）"
            : "在审核栏查看全部"
    }
}

/// 单个文件的可展开 diff 卡片（路径头 + 状态 + 行号 + 绿增红删）。
/// 既用于内联 diff 预览，也用于聊天里「编辑 X」工具行就地展开该文件 diff。
struct InlineDiffFileCardView: View {
    let file: TurnFileDiff
    @State private var expanded: Bool

    init(file: TurnFileDiff, initiallyExpanded: Bool = false) {
        self.file = file
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起 \(file.path)" : "展开 \(file.path)")

            if expanded {
                if file.hasInlineDiff {
                    DiffView(diff: file.diff)
                } else {
                    Text(file.note ?? file.statusLabel)
                        .appFont(relative: -2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .appFont(relative: -2, weight: .semibold)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            statusBadge(file.status)
            Text(file.path)
                .appFont(relative: -2, weight: .medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if file.addedCount > 0 {
                Text("+\(file.addedCount)")
                    .appFont(relative: -3, weight: .medium)
                    .foregroundStyle(.green)
            }
            if file.removedCount > 0 {
                Text("−\(file.removedCount)")
                    .appFont(relative: -3, weight: .medium)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Theme.panelRaised)
        .contentShape(Rectangle())
    }

    private func statusBadge(_ status: TurnFileDiff.Status) -> some View {
        let label: String
        let color: Color
        switch status {
        case .added: (label, color) = ("新增", .green)
        case .modified: (label, color) = ("修改", Theme.accent)
        case .deleted: (label, color) = ("删除", .red)
        case .binary: (label, color) = ("二进制", Color.secondary)
        case .tooLarge: (label, color) = ("过大", .orange)
        }
        return Text(label)
            .appFont(relative: -3, weight: .medium)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.14)))
            .fixedSize()
    }
}
