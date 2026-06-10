import SwiftUI

// 左栏(rail)通用组件:节标题、动作按钮、最近会话行。从 ContentView.swift 拆出(#24)。

struct RailSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .appFont(relative: -3, weight: .semibold)
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .padding(.horizontal, 2)
    }
}

struct RailActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(hovering ? Theme.controlHover : Color.clear)
        )
        .onHover { hovering = $0 }
    }
}

struct RecentConversationRow: View {
    let conversation: ConversationSummary
    let onOpen: () -> Void
    let onRemoveFromRecent: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .appFont(relative: -2)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .appFont(relative: -2, weight: .medium)
                        .lineLimit(1)
                    Text(conversation.agentName)
                        .appFont(relative: -3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button(action: onRemoveFromRecent) {
                        Image(systemName: "xmark").appFont(relative: -3, weight: .bold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("从最近移除（保留历史记录）")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(hovering ? Theme.controlHover : Color.clear)
        )
        .help("重新打开继续")
        .onHover { hovering = $0 }
        .contextMenu {
            Button("打开", action: onOpen)
            Button("从最近移除", action: onRemoveFromRecent)
            Divider()
            Button("删除会话记录", role: .destructive, action: onDelete)
        }
    }
}
