import SwiftUI

// 提问卡片(AskUserQuestion)相关视图。从 ChatPaneView.swift 拆出(#26):
// 卡片本体 + 时间线块 + 已答复行,private→internal 供 MessageBubble 使用。

/// AskUserQuestion 卡片：渲染问题与可点选项。
/// opencode（question.requestID 非空）：agent **原地等待**，提交直接经 reply API 回传、它据此继续。
/// Claude（requestID 为空）：`-p` 非交互无法回灌进程，提交作为**下一条消息**发出（会话续接）。
struct AskUserQuestionCard: View {
    let question: AskUserQuestion
    let onAnswer: ([[String]]) -> Void
    var onReject: () -> Void = {}
    @State private var selections: [String: Set<String>] = [:] // 问题 id → 已选 label 集合
    @State private var submitting = false

    /// 会阻塞等待回答：opencode（requestID）或 Claude 经 MCP ask_user（mcpRequestID）。其余（Claude 追加消息）为 false。
    private var waitsForReply: Bool { question.requestID != nil || question.mcpRequestID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(waitsForReply
                ? "Agent 正在等待你的选择；选好点「提交」即据此继续。"
                : "Claude 不会停下来等待；选好点「提交」会作为新消息发给它继续。")
                .appFont(relative: -3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(question.questions) { item in
                questionBlock(item)
            }
            submitRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "questionmark.bubble")
                .foregroundStyle(Theme.accent)
            Text("需要你的选择")
                .appFont(relative: -1, weight: .semibold)
            Spacer(minLength: 8)
        }
    }

    private func questionBlock(_ item: AskUserQuestion.Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(item.title)
                    .appFont(relative: -1, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                if item.multiSelect {
                    Text("可多选")
                        .appFont(relative: -3, weight: .medium)
                        .foregroundStyle(Theme.accentStrong)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }
            ForEach(item.options) { option in
                optionRow(item: item, option: option)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func optionRow(item: AskUserQuestion.Item, option: AskUserQuestion.Option) -> some View {
        let isSelected = selections[item.id]?.contains(option.label) == true
        return Button {
            toggle(item: item, option: option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selectionSymbol(multiSelect: item.multiSelect, selected: isSelected))
                    .appFont(relative: -1)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .appFont(relative: -1, weight: .medium)
                        .foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .appFont(relative: -3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(isSelected ? Theme.selected : Theme.panelRaised.opacity(0.6))
            )
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(isSelected ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    private var submitRow: some View {
        HStack(spacing: 10) {
            Button(action: skip) {
                Text("跳过")
                    .appFont(relative: -2, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.controlHover.opacity(0.5), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(submitting)
            .help(waitsForReply ? "拒绝该提问（agent 继续）" : "跳过，不回复")
            Spacer(minLength: 0)
            Button(action: submit) {
                Text(submitting ? "提交中" : "提交")
                    .appFont(relative: -1, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(canSubmit ? Theme.accent : Color.secondary.opacity(0.32), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help(waitsForReply ? "把选择回传给运行中的 agent" : "把选择作为新消息发给 Claude")
        }
    }

    private func selectionSymbol(multiSelect: Bool, selected: Bool) -> String {
        if multiSelect { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    private var canSubmit: Bool {
        !submitting && question.questions.allSatisfy { !(selections[$0.id]?.isEmpty ?? true) }
    }

    private func toggle(item: AskUserQuestion.Item, option: AskUserQuestion.Option) {
        var set = selections[item.id] ?? []
        if item.multiSelect {
            if set.contains(option.label) { set.remove(option.label) } else { set.insert(option.label) }
        } else {
            set = [option.label] // 单选：替换
        }
        selections[item.id] = set
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        onAnswer(orderedSelections())
    }

    private func skip() {
        guard !submitting else { return }
        submitting = true
        onReject()
    }

    /// 每题按选项原始顺序导出选中的 label 数组（opencode reply / Claude 文案共用）。
    private func orderedSelections() -> [[String]] {
        question.questions.map { item in
            item.options.map(\.label).filter { selections[item.id]?.contains($0) == true }
        }
    }
}

/// 提问工具在 assistant 时间线中的两种形态：待回答显示卡片，完成后原位折叠成「询问」工具记录。
struct QuestionToolTimelineBlock: View {
    let record: QuestionToolRecord
    let onAnswer: ([[String]]) -> Void
    let onReject: () -> Void

    @ViewBuilder
    var body: some View {
        if record.isPending {
            AskUserQuestionCard(
                question: record.question,
                onAnswer: onAnswer,
                onReject: onReject
            )
        } else {
            ResolvedQuestionToolRow(record: record)
        }
    }
}

struct ResolvedQuestionToolRow: View {
    let record: QuestionToolRecord
    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.bubble")
                        .appFont(relative: -2, weight: .semibold)
                        .foregroundStyle(Theme.accent.opacity(0.82))
                    Text(QuestionToolPresentation.title)
                        .appFont(relative: -1, weight: .semibold)
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .appFont(relative: -2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .appFont(relative: -3, weight: .semibold)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "收起询问详情" : "展开询问详情")

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(record.detailLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .appFont(relative: -2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.leading, 21)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if hovering && InlineRecordRowPresentation.highlightsOnHover {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(Theme.controlHover.opacity(InlineRecordRowPresentation.hoverBackgroundOpacity))
            }
        }
        .onHover { hovering = $0 }
    }

    private var summary: String {
        switch record.resolution {
        case .pending:
            return ""
        case .answered:
            return QuestionToolPresentation.answeredSummary
        case .skipped:
            return QuestionToolPresentation.skippedSummary
        }
    }
}
