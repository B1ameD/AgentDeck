import SwiftUI

/// 广播对比视图（#27）：同一 prompt 广播后，各 agent 的回答按列并排对比（最近一轮）。
/// sheet 形态（同 Git 面板/历史检索），列内可滚动，可一键跳到对应会话继续追问。
struct BroadcastCompareView: View {
    var workspace: WorkspaceController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 880, idealWidth: 1080, minHeight: 540, idealHeight: 680)
    }

    private var broadcastID: String? {
        BroadcastCompare.latestBroadcastID(in: workspace.sessions.map(\.messages))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.split.2x1")
                .foregroundStyle(Theme.accent)
            Text("广播对比")
                .appFont(relative: 3, weight: .semibold)
            if let id = broadcastID,
               let prompt = BroadcastCompare.prompt(in: workspace.sessions.map(\.messages), broadcastID: id) {
                Text(SessionTitle.summarize(prompt) ?? "")
                    .appFont(relative: -1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let id = broadcastID {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(workspace.sessions) { session in
                        if let reply = BroadcastCompare.reply(in: session.messages, broadcastID: id) {
                            CompareColumn(
                                session: session,
                                reply: reply,
                                onJump: {
                                    workspace.focusSession(id: session.id)
                                    dismiss()
                                }
                            )
                        }
                    }
                }
                .padding(16)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .appFont(relative: 12)
                    .foregroundStyle(.secondary)
                Text("还没有广播轮次。切到「广播」给所有 agent 发同一条消息后，到这里并排对比各家回答。")
                    .appFont(relative: -1)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CompareColumn: View {
    let session: AgentSession
    let reply: BroadcastCompare.RoundReply
    let onJump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    if let image = AgentVisuals.iconImage(for: session.agent.kind) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: AgentVisuals.icon(for: session.agent.kind))
                            .foregroundStyle(AgentVisuals.tint(for: session.agent.kind))
                    }
                }
                .frame(width: 16, height: 16)
                Text(session.displayTitle)
                    .appFont(relative: -1, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if session.status == .running {
                    ProgressView().controlSize(.small)
                } else if !session.usage.isEmpty {
                    Text(session.usage.costUSD > 0 ? session.usage.costLabel : session.usage.tokensLabel)
                        .appFont(relative: -3)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                if reply.text.isEmpty {
                    Text(session.status == .running ? "生成中…" : "（无输出）")
                        .appFont(relative: -1)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // 复用单聊气泡的完整渲染器:计时头、思考折叠、内联工具行与正文显示完全一致。
                    AssistantMessageContent(
                        text: reply.text,
                        toolCalls: [],
                        isStreaming: session.status == .running,
                        runStartedAt: reply.runStartedAt,
                        runEndedAt: reply.runEndedAt,
                        linkContext: MessageLinkContext(
                            workingDirectory: session.workingDirectory,
                            fileLinks: [],
                            openFile: { _ in },
                            openWebURL: { url in NSWorkspace.shared.open(url) },
                            detectFileReferences: false
                        )
                    )
                    .padding(12)
                }
            }
            .frame(maxHeight: .infinity)

            Divider()

            Button(action: onJump) {
                Label("前往会话", systemImage: "arrow.right.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accentStrong)
            .padding(.vertical, 8)
        }
        .frame(width: 360)
        .frame(maxHeight: .infinity)
        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        }
    }
}
