import SwiftUI

/// 右侧栏「审核」标签：展示本轮 agent 改动的**结构化逐行 diff**（绿增红删）。
/// 数据来自会话运行后算好的 `TurnDiffSummary`（before→after，不可变）——不再从当前磁盘 / git HEAD 现算，
/// 故未跟踪文件、运行前已 dirty 的文件，也只显示本轮真正改动的几行，而非整文件标绿。
struct ChangeReviewView: View {
    let workingDirectory: URL
    let summary: TurnDiffSummary?
    var onOpenFile: (URL) -> Void = { _ in }

    @State private var expanded: Set<String> = []

    private var files: [TurnFileDiff] { summary?.files ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
            if files.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(files) { fileRow($0) }
                    }
                    .padding(10)
                }
            }
        }
        .background(Theme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "checklist").foregroundStyle(Theme.accent)
            Text("改动审核").appFont(relative: -1, weight: .semibold)
            if !files.isEmpty {
                Text("\(files.count) 个文件").appFont(relative: -2).foregroundStyle(.secondary)
                diffTotals
            }
            Spacer()
            if !files.isEmpty {
                Button(allExpanded ? "全部收起" : "全部展开") { toggleAll() }
                    .buttonStyle(.plain)
                    .appFont(relative: -2)
                    .foregroundStyle(Theme.accentStrong)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panelRaised)
    }

    @ViewBuilder
    private var diffTotals: some View {
        let added = summary?.totalAdded ?? 0
        let removed = summary?.totalRemoved ?? 0
        HStack(spacing: 6) {
            if added > 0 {
                Text("+\(added)").appFont(relative: -2, weight: .medium).foregroundStyle(.green)
            }
            if removed > 0 {
                Text("−\(removed)").appFont(relative: -2, weight: .medium).foregroundStyle(.red)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .appFont(relative: 10, weight: .semibold)
                .foregroundStyle(Theme.accent)
            Text("本轮没有文件改动").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allExpanded: Bool { !files.isEmpty && expanded.count == files.count }

    private func toggleAll() {
        withAnimation(.easeInOut(duration: 0.18)) {
            expanded = allExpanded ? [] : Set(files.map(\.path))
        }
    }

    @ViewBuilder
    private func fileRow(_ file: TurnFileDiff) -> some View {
        let isOpen = expanded.contains(file.path)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Button { toggle(file.path) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .appFont(relative: -2, weight: .semibold)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        statusBadge(file.status)
                        Text(file.path)
                            .appFont(relative: -1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        countsView(file)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button { onOpenFile(fileURL(file.path)) } label: {
                    Image(systemName: "arrow.up.forward.square").appFont(relative: -1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("在「文件」标签打开")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))

            if isOpen {
                Group {
                    if file.hasInlineDiff {
                        DiffView(diff: file.diff)
                    } else {
                        Text(file.note ?? "无逐行 diff")
                            .appFont(relative: -2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 6)
            }
        }
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

    @ViewBuilder
    private func countsView(_ file: TurnFileDiff) -> some View {
        HStack(spacing: 6) {
            if file.addedCount > 0 {
                Text("+\(file.addedCount)").appFont(relative: -2, weight: .medium).foregroundStyle(.green)
            }
            if file.removedCount > 0 {
                Text("−\(file.removedCount)").appFont(relative: -2, weight: .medium).foregroundStyle(.red)
            }
        }
        .fixedSize()
    }

    private func toggle(_ path: String) {
        withAnimation(.easeInOut(duration: 0.16)) {
            if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        }
    }

    private func fileURL(_ path: String) -> URL {
        LinkifiedText.fileURL(relativePath: path, workingDirectory: workingDirectory)
    }
}
