import SwiftUI

/// 历史检索：在落盘的会话转录里全文搜索，点结果只读查看转录。
struct HistorySearchView: View {
    let workspace: WorkspaceController

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ConversationHit] = []
    @State private var selected: StoredConversation?
    @State private var restoreError: String?
    @State private var filterCurrentWorkspace = false

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索历史会话（留空显示全部）", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, _ in refresh() }
                Spacer()
                Toggle("仅当前工作区", isOn: $filterCurrentWorkspace)
                    .toggleStyle(.checkbox)
                    .appFont(relative: -2)
                    .onChange(of: filterCurrentWorkspace) { _, _ in refresh() }
                Text("\(hits.count) 条").appFont(relative: -2).foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider().opacity(0.4)

            HSplitView {
                results.frame(minWidth: 280)
                transcript.frame(minWidth: 380)
            }
        }
        .frame(width: 840, height: 560)
        // 打开即默认列出全部历史会话；输入关键词再收窄。
        .onAppear(perform: refresh)
    }

    /// 无查询时展示全部历史会话；有查询时全文搜索；可选只看当前工作区。
    private func refresh() {
        var results = trimmedQuery.isEmpty
            ? workspace.allConversationHits()
            : workspace.searchConversations(query)
        if filterCurrentWorkspace {
            let currentPath = workspace.workspaceDirectory.path
            let idsInWorkspace = Set(
                workspace.conversationSummaries(inDirectory: currentPath).map(\.id)
            )
            results = results.filter { idsInWorkspace.contains($0.id) }
        }
        hits = results
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if hits.isEmpty {
                    Text(trimmedQuery.isEmpty ? "暂无历史会话" : "无匹配")
                        .foregroundStyle(.secondary).padding(12)
                }
                ForEach(hits) { hit in
                    Button {
                        selected = workspace.conversation(id: hit.id)
                        restoreError = nil
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(hit.title).appFont(relative: -1, weight: .medium).lineLimit(1)
                                Spacer()
                                Text(hit.agentName).appFont(relative: -3).foregroundStyle(.secondary)
                            }
                            Text(hit.snippet).appFont(relative: -2).foregroundStyle(.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(selected?.id == hit.id ? Theme.accent.opacity(0.15) : Theme.control.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.title)
                            .appFont(relative: 1, weight: .semibold)
                            .lineLimit(1)
                        Text(selected.agentName)
                            .appFont(relative: -2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !workspace.canReopenConversation(id: selected.id) {
                        Label("原 Agent 不可用", systemImage: "exclamationmark.triangle")
                            .appFont(relative: -2)
                            .foregroundStyle(.orange)
                    }
                    Button("恢复会话") {
                        restore(selected)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!workspace.canReopenConversation(id: selected.id))
                    .help(workspace.canReopenConversation(id: selected.id)
                        ? "恢复到聊天栏并聚焦该会话"
                        : "当前未找到该历史记录对应的 Agent")
                }
                .padding(12)
                Divider().opacity(0.4)

                if let restoreError {
                    Text(restoreError)
                        .appFont(relative: -2)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(selected.messages) { message in
                            if message.role == .assistant {
                                MarkdownText(content: message.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(message.text)
                                    .appFont()
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            Text("选择左侧结果查看转录")
                .appFont()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func restore(_ conversation: StoredConversation) {
        switch workspace.reopenConversation(id: conversation.id) {
        case .focusedExisting, .restored:
            dismiss()
        case .unavailable:
            restoreError = "无法恢复：当前未找到 \(conversation.agentName)。"
        }
    }
}
