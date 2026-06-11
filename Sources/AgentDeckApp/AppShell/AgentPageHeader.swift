import SwiftUI

// 页眉:标题 + Git/右侧栏/终端按钮。从 ContentView.swift 拆出(#24)。

struct AgentPageHeader: View {
    let session: AgentSession
    @Binding var terminalLaunch: TerminalLaunch?
    let showFiles: Bool
    let onToggleFiles: () -> Void
    @State private var showingGit = false

    var body: some View {
        HStack(spacing: 12) {
            Text(session.displayTitle)
                .appFont(relative: 3, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
            if session.displayTitle != session.agent.name {
                Text(session.agent.name)
                    .appFont(relative: -1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            HeaderIconButton(systemImage: "arrow.triangle.branch", help: "Git 面板") {
                showingGit = true
            }
            HeaderIconButton(
                systemImage: "sidebar.right",
                isActive: showFiles,
                help: "右侧栏：文件 / 预览 / 浏览器 / 审核"
            ) {
                onToggleFiles()
            }
            HeaderIconButton(systemImage: "terminal", isActive: terminalLaunch != nil, help: "终端（下方）") {
                withAnimation(.easeInOut(duration: 0.28)) {
                    terminalLaunch = terminalLaunch == nil ? .shell() : nil
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
        }
        .sheet(isPresented: $showingGit) {
            GitPanelView(workingDirectory: session.workingDirectory)
        }
    }
}

struct HeaderIconButton: View {
    let systemImage: String
    var isActive = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Theme.accentStrong : Color.secondary)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(isActive ? Theme.selected : (hovering ? Theme.controlHover : Color.clear))
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .stroke(isActive ? Theme.accent.opacity(0.28) : Theme.hairline.opacity(hovering ? 0.8 : 0), lineWidth: 1)
        }
        .help(help)
        .onHover { hovering = $0 }
    }
}
