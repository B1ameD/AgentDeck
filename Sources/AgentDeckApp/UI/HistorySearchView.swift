import SwiftUI

/// 历史检索：在落盘的会话转录里全文搜索，点结果只读查看转录。
struct HistorySearchView: View {
    let workspace: WorkspaceController

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ConversationHit] = []
    @State private var selected: StoredConversation?

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

    /// 无查询时展示全部历史会话；有查询时全文搜索。
    private func refresh() {
        hits = trimmedQuery.isEmpty
            ? workspace.allConversationHits()
            : workspace.searchConversations(query)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if hits.isEmpty {
                    Text(trimmedQuery.isEmpty ? "暂无历史会话" : "无匹配")
                        .foregroundStyle(.secondary).padding(12)
                }
                ForEach(hits) { hit in
                    Button { selected = workspace.conversation(id: hit.id) } label: {
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
        } else {
            Text("选择左侧结果查看转录")
                .appFont()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
