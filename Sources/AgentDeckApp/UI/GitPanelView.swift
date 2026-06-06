import SwiftUI

/// 针对某工作目录的 git 面板：分支、改动列表、暂存/取消暂存、提交、切分支。
struct GitPanelView: View {
    let workingDirectory: URL

    private let git = GitService()
    @Environment(\.dismiss) private var dismiss
    @State private var status: GitStatus?
    @State private var branches: [String] = []
    @State private var commitMessage = ""
    @State private var loading = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)

            if let status {
                branchRow(status)
                changeList(status)
                commitRow(status)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("不是 git 仓库，或 git 不可用。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let notice {
                Text(notice).appFont(relative: -2).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 480, height: 540)
        .background(Theme.panel)
        .task(id: workingDirectory) { await reload() }
    }

    private var header: some View {
        HStack {
            Label("Git", systemImage: "arrow.triangle.branch").appFont(relative: 5, weight: .semibold)
            Text(workingDirectory.lastPathComponent).appFont(relative: -2).foregroundStyle(.secondary)
            Spacer()
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .frame(width: 28, height: 26)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .help("刷新")
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func branchRow(_ status: GitStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.accent)
            Menu(status.branch ?? "(detached)") {
                ForEach(branches, id: \.self) { branch in
                    Button(branch) { Task { await switchBranch(branch) } }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer()
            Text("\(status.changes.count) changed").appFont(relative: -2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private func changeList(_ status: GitStatus) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if status.isClean {
                    Text("工作区干净").foregroundStyle(.secondary).padding(.vertical, 10)
                }
                ForEach(status.changes) { change in
                    HStack(spacing: 8) {
                        Text(glyph(change))
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(color(change))
                            .frame(width: 18)
                        Text(change.path)
                            .appFont(relative: -1)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button(change.isStaged ? "取消暂存" : "暂存") {
                            Task { await toggleStage(change) }
                        }
                        .appFont(relative: -2)
                        .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                }
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    private func commitRow(_ status: GitStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("提交信息", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack {
                Spacer()
                Button("提交已暂存") { Task { await commit() } }
                    .disabled(
                        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !status.changes.contains(where: \.isStaged)
                    )
            }
        }
        .padding(10)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }

    // MARK: - 动作

    private func reload() async {
        loading = true
        defer { loading = false }
        status = await git.status(in: workingDirectory)
        branches = await git.branches(in: workingDirectory)
    }

    private func toggleStage(_ change: GitFileChange) async {
        if change.isStaged {
            _ = await git.unstage(change.path, in: workingDirectory)
        } else {
            _ = await git.stage(change.path, in: workingDirectory)
        }
        await reload()
    }

    private func commit() async {
        let ok = await git.commit(message: commitMessage, in: workingDirectory)
        notice = ok ? "已提交。" : "提交失败。"
        if ok { commitMessage = "" }
        await reload()
    }

    private func switchBranch(_ branch: String) async {
        let ok = await git.checkout(branch: branch, in: workingDirectory)
        notice = ok ? "已切到 \(branch)" : "切换失败（可能有未提交改动）。"
        await reload()
    }

    private func glyph(_ change: GitFileChange) -> String {
        if change.isUntracked { return "?" }
        return String(change.isStaged ? change.index : change.worktree)
    }

    private func color(_ change: GitFileChange) -> Color {
        if change.isUntracked { return .gray }
        return change.isStaged ? .green : .orange
    }
}
