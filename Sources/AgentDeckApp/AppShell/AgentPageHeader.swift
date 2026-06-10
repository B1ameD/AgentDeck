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

/// Claude 历史会话菜单：发现当前工作目录下的会话，选中即设为 --resume 目标并回填转录。
/// ⚠️ 当前无任何调用方（页眉重构后遗留），保留待决策：恢复入口或删除。
struct SessionHistoryMenu: View {
    let session: AgentSession
    @State private var sessions: [DiscoveredSession] = []
    @State private var loaded = false

    var body: some View {
        Menu {
            if sessions.isEmpty {
                Text(loaded ? "无历史会话" : "加载中…")
            } else {
                ForEach(sessions) { discovered in
                    Button { resume(discovered) } label: {
                        Text(discovered.title)
                    }
                }
            }
        } label: {
            Label(resumeLabel, systemImage: "clock.arrow.circlepath")
                .appFont(relative: -2)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .task(id: session.workingDirectory) {
            loaded = false
            sessions = await Self.discover(session.workingDirectory)
            loaded = true
        }
    }

    private var resumeLabel: String {
        if let id = session.resumeSessionID, !id.isEmpty {
            return "续 " + String(id.prefix(8))
        }
        return "历史会话"
    }

    private func resume(_ discovered: DiscoveredSession) {
        session.resumeSessionID = discovered.id
        session.command = .resume
        let url = discovered.url
        Task {
            let history = await Task.detached { ClaudeSessionDiscovery.transcript(in: url) }.value
            session.loadHistory(history)
        }
    }

    private static func discover(_ workingDirectory: URL) async -> [DiscoveredSession] {
        await Task.detached {
            ClaudeSessionDiscovery.sessions(
                claudeHome: ClaudeSessionDiscovery.defaultClaudeHome(),
                workingDirectory: workingDirectory
            )
        }.value
    }
}
