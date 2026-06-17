import SwiftUI
import AppKit

// 左栏 Agent 标签行:图标/状态/改名/置顶/右键菜单。从 ContentView.swift 拆出(#24)。

struct AgentTabRow: View {
    let session: AgentSession
    let isSelected: Bool
    var showWorkspace: Bool = false
    let onFocus: () -> Void
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onSetWorkingDirectory: () -> Void
    let onUnpinWorkingDirectory: () -> Void
    let onRevealWorkspace: () -> Void
    let onCopyWorkspacePath: () -> Void

    @State private var hovering = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: Theme.Spacing.sm) {
                // 按 agent 家族显示专属图标：有官方品牌图标用图标（保留原色），否则回落 SF Symbol + 主色。
                Group {
                    if let image = AgentVisuals.iconImage(for: session.agent.kind) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                    } else {
                        Image(systemName: AgentVisuals.icon(for: session.agent.kind))
                            .foregroundStyle(AgentVisuals.tint(for: session.agent.kind))
                    }
                }
                .frame(width: 18, height: 18)
                .help(session.agent.name)
                VStack(alignment: .leading, spacing: 2) {
                    if renaming {
                        TextField("标签名", text: $draftTitle)
                            .textFieldStyle(.plain)
                            .appFont(relative: -1, weight: .medium)
                            .focused($renameFocused)
                            .onSubmit(commitRename)
                            .onExitCommand { renaming = false }
                            .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
                    } else {
                        Text(session.displayTitle)
                            .appFont(relative: -1, weight: .medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(showWorkspace ? session.workingDirectory.lastPathComponent : session.status.shortLabel)
                            .appFont(relative: -3)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if session.pinned {
                    Image(systemName: "pin.fill")
                        .appFont(relative: -3)
                        .foregroundStyle(Theme.accentStrong)
                        .help("已置顶")
                }
                if session.isRunning {
                    // 运行中不可关闭：误关后重开会丢失正在进行的运行（#防误关）。显示旋转指示替代关闭按钮。
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        .help("运行中，无法关闭——请先等待完成或停止运行")
                } else if hovering || isSelected {
                    Button(action: onClose) {
                        Image(systemName: "xmark").appFont(relative: -3, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭标签（保留到最近）")
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm + 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(isSelected ? Theme.accent.opacity(0.28) : Theme.hairline.opacity(hovering ? 0.8 : 0), lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule().fill(Theme.accent).frame(width: 3).padding(.vertical, 9)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        // 双击标签即改名（参考请求）。
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() })
        .contextMenu {
            Button("改名", action: beginRename)
            Button(session.pinned ? "取消置顶" : "置顶", action: onTogglePin)
            Divider()
            if session.workingDirectoryLocked {
                // 已有对话:目录锁死(换目录会让 claude resume 失败丢上下文,#4)。
                Button("工作目录已随对话锁定") {}
                    .disabled(true)
            } else {
                Button("设置工作目录…", action: onSetWorkingDirectory)
                if session.directoryPinned {
                    Button("跟随全局工作区", action: onUnpinWorkingDirectory)
                }
            }
            Button("在 Finder 中打开工作区", action: onRevealWorkspace)
            Button("复制工作区路径", action: onCopyWorkspacePath)
            Divider()
            Button(session.isRunning ? "运行中，无法关闭" : "关闭标签", action: onClose)
                .disabled(session.isRunning)
            Button("删除会话记录", role: .destructive, action: onDelete)
                .disabled(session.isRunning)
        }
    }

    private func beginRename() {
        draftTitle = session.customTitle ?? session.displayTitle
        renaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard renaming else { return }
        renaming = false
        onRename(draftTitle)
    }

    private var fillColor: Color {
        if isSelected { return Theme.selected }
        return hovering ? Theme.controlHover : Color.clear
    }

    private var statusColor: Color {
        switch session.status {
        case .idle: .green
        case .running: Theme.accent
        case .failed: .red
        }
    }
}

private extension SessionStatus {
    var shortLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .running:
            "Running"
        case .failed:
            "Error"
        }
    }
}
