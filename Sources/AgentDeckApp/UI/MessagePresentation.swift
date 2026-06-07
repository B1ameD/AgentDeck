import Foundation

struct ChangeReviewRequest: Equatable, Sendable {
    let summary: TurnDiffSummary

    static func forMessage(_ message: ChatMessage) -> ChangeReviewRequest? {
        guard message.kind == .changeReview, let summary = message.turnDiffSummary else {
            return nil
        }
        return ChangeReviewRequest(summary: summary)
    }
}

enum ReviewSelectionPolicy {
    static func shouldClearForGlobalSidebarToggle(
        sidebarIsVisible: Bool,
        mode: RightSidebarMode
    ) -> Bool {
        !sidebarIsVisible && mode == .review
    }
}

enum AssistantContentBlock: Equatable {
    case text(String)
    case thinking(String)
    case inlineError(String)
    /// 内联工具活动（如「读取 foo.swift」「运行 ls」）。按时间顺序穿插在文本块之间。
    case toolCall(String)
    /// 委派任务行：携带子任务 id（链接到 message.subagentTasks）与展示标签。点击可在右侧栏看明细。
    case subagentRef(id: String, label: String)
}

enum MessagePresentation {
    static func isInlineError(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("api error")
            || lowercased.contains("please run /login")
            || lowercased.contains(#""type":"error""#)
            || lowercased.contains(#""type": "error""#)
    }

    static func assistantBlocks(in text: String) -> [AssistantContentBlock] {
        let pieces = splitThinkingTags(in: text).flatMap { piece -> [RawContentPiece] in
            switch piece {
            case .text(let text): splitLabeledThinking(in: text)
            case .thinking: [piece]
            }
        }

        var blocks: [AssistantContentBlock] = []
        for piece in pieces {
            switch piece {
            case .thinking(let text):
                appendThinking(clean(text), to: &blocks)
            case .text(let text):
                // 先按内联工具标记切段，保持「文本 / 工具活动」的原始时间顺序，再对文本段做行内错误拆分。
                for segment in ToolActivity.segments(in: text) {
                    switch segment {
                    case .tool(let summary):
                        let cleaned = clean(summary)
                        if cleaned.isEmpty {
                            break
                        } else if let sub = SubagentMarker.decode(cleaned) {
                            blocks.append(.subagentRef(id: sub.id, label: sub.label))
                        } else {
                            blocks.append(.toolCall(cleaned))
                        }
                    case .text(let prose):
                        blocks.append(contentsOf: splitInlineErrors(in: prose))
                    }
                }
            }
        }

        return blocks.isEmpty ? [.text(text)] : blocks
    }

    /// 视图层实际渲染的有序块流：思考、正文、工具活动都按输出出现顺序排列；
    /// 只合并相邻且完全相同的工具活动，避免连续编辑同一文件时刷屏。
    static func assistantTimelineBlocks(in text: String) -> [CollapsedBlock] {
        collapsingToolRuns(assistantBlocks(in: text))
    }

    /// 一个渲染块及其「连续重复次数」。仅相邻且完全相同的工具活动会被合并计数（如对同一文件连续 8 次编辑→1 行 ×8）。
    struct CollapsedBlock: Equatable {
        let block: AssistantContentBlock
        let count: Int
    }

    /// 合并相邻且文案相同的工具活动块，避免「编辑同一文件」刷出一长串重复行。文本/思考/错误块原样保留（count=1）。
    static func collapsingToolRuns(_ blocks: [AssistantContentBlock]) -> [CollapsedBlock] {
        var result: [CollapsedBlock] = []
        for block in blocks {
            if case .toolCall(let text) = block,
               let last = result.last, case .toolCall(let previous) = last.block, previous == text {
                result[result.count - 1] = CollapsedBlock(block: last.block, count: last.count + 1)
            } else {
                result.append(CollapsedBlock(block: block, count: 1))
            }
        }
        return result
    }

    static func assistantPlainTextForCopy(_ text: String) -> String {
        assistantBlocks(in: text)
            .map { block in
                switch block {
                case .text(let text), .inlineError(let text):
                    text
                case .toolCall(let text):
                    "› \(text)"
                case .subagentRef(_, let label):
                    "› 委派任务：\(label)"
                case .thinking(let text):
                    "思考过程：\n\(text)"
                }
            }
            .joined(separator: "\n\n")
    }

    private enum RawContentPiece {
        case text(String)
        case thinking(String)
    }

    private static func splitThinkingTags(in text: String) -> [RawContentPiece] {
        let pattern = #"<(?:think|thinking|reasoning)>\s*(.*?)\s*</(?:think|thinking|reasoning)>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return [.text(text)]
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return [.text(text)] }

        var pieces: [RawContentPiece] = []
        var cursor = text.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let contentRange = Range(match.range(at: 1), in: text) else { continue }

            if cursor < matchRange.lowerBound {
                appendText(String(text[cursor..<matchRange.lowerBound]), to: &pieces)
            }
            appendThinking(String(text[contentRange]), to: &pieces)
            cursor = matchRange.upperBound
        }

        if cursor < text.endIndex {
            appendText(String(text[cursor...]), to: &pieces)
        }

        return pieces
    }

    private static func splitLabeledThinking(in text: String) -> [RawContentPiece] {
        var pieces: [RawContentPiece] = []
        var normalLines: [String] = []
        var thinkingLines: [String] = []
        var inThinking = false

        func flushNormal() {
            let joined = clean(normalLines.joined(separator: "\n"))
            normalLines.removeAll()
            appendText(joined, to: &pieces)
        }

        func flushThinking() {
            let joined = clean(thinkingLines.joined(separator: "\n"))
            thinkingLines.removeAll()
            appendThinking(joined, to: &pieces)
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let payload = markerPayload(
                in: line,
                markers: ["思考过程", "推理过程", "思考", "reasoning", "thinking", "thought process"]
            ) {
                flushNormal()
                inThinking = true
                if !payload.isEmpty { thinkingLines.append(payload) }
                continue
            }

            if let payload = markerPayload(
                in: line,
                markers: ["最终回答", "最终答案", "final answer", "final response"]
            ) {
                flushThinking()
                inThinking = false
                if !payload.isEmpty { normalLines.append(payload) }
                continue
            }

            if inThinking {
                thinkingLines.append(line)
            } else {
                normalLines.append(line)
            }
        }

        if inThinking {
            flushThinking()
        } else {
            flushNormal()
        }

        return pieces.isEmpty ? [.text(text)] : pieces
    }

    private static func splitInlineErrors(in text: String) -> [AssistantContentBlock] {
        var blocks: [AssistantContentBlock] = []
        var normalLines: [String] = []

        func flushNormal() {
            let joined = clean(normalLines.joined(separator: "\n"))
            normalLines.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(.text(joined))
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if isInlineError(line) {
                flushNormal()
                blocks.append(.inlineError(line))
            } else {
                normalLines.append(line)
            }
        }
        flushNormal()

        return blocks
    }

    private static func markerPayload(in line: String, markers: [String]) -> String? {
        var normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("#") {
            normalized.removeFirst()
            normalized = normalized.trimmingCharacters(in: .whitespaces)
        }
        normalized = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "*_ "))

        let lower = normalized.lowercased()
        for marker in markers {
            guard lower.hasPrefix(marker.lowercased()) else { continue }
            let suffix = normalized.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if suffix.isEmpty { return "" }
            if suffix.hasPrefix(":") || suffix.hasPrefix("：") {
                return suffix.dropFirst().trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func appendText(_ text: String, to pieces: inout [RawContentPiece]) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        pieces.append(.text(cleaned))
    }

    private static func appendThinking(_ text: String, to pieces: inout [RawContentPiece]) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        pieces.append(.thinking(cleaned))
    }

    private static func appendThinking(_ text: String, to blocks: inout [AssistantContentBlock]) {
        let cleaned = clean(text)
        guard !cleaned.isEmpty else { return }
        if case .thinking(let previous) = blocks.last {
            blocks[blocks.count - 1] = .thinking(joinThinking(previous, cleaned))
            return
        }
        blocks.append(.thinking(cleaned))
    }

    private static func joinThinking(_ lhs: String, _ rhs: String) -> String {
        guard let left = lhs.last, let right = rhs.first else { return lhs + rhs }
        if left.isWhitespace || right.isWhitespace || isCJKBoundary(left, right) {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }

    private static func isCJKBoundary(_ lhs: Character, _ rhs: Character) -> Bool {
        isCJK(lhs) || isCJK(rhs)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0x3040...0x30FF,   // Hiragana / Katakana
                 0xAC00...0xD7AF,   // Hangul
                 0xFF00...0xFFEF:   // Fullwidth forms and punctuation
                return true
            default:
                return false
            }
        }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum RunDurationPresentation {
    static func label(startedAt: Date, endedAt: Date?, now: Date) -> String {
        let end = endedAt ?? now
        let seconds = max(0, Int(end.timeIntervalSince(startedAt).rounded(.down)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "运行 %d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "运行 %02d:%02d", minutes, remainder)
    }

    static func timerInsertionIndex(in blocks: [MessagePresentation.CollapsedBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        return 0
    }
}

enum RunProcessDetailPresentation {
    static let animatesLayoutOnToggle = false
    static let usesMovingTransition = false

    /// 折叠只针对**思考过程**：折叠时隐藏思考块，但工具活动行（读取/编辑/运行…）始终保留——
    /// 这样既能在输出结束后自动收起冗长思考（issue 3），又不会把「编辑 X +N −M」这类带 diff 的工具行一并藏掉（issue 4）。
    static func shouldRender(_ block: AssistantContentBlock, detailsHidden: Bool) -> Bool {
        guard detailsHidden else { return true }
        switch block {
        case .thinking:
            return false
        case .text, .inlineError, .toolCall, .subagentRef:
            return true
        }
    }

    /// 是否含可折叠的思考块（决定运行时间行是否显示折叠箭头、是否在结束时自动折叠）。
    static func containsCollapsibleThinking(_ blocks: [MessagePresentation.CollapsedBlock]) -> Bool {
        blocks.contains { collapsed in
            if case .thinking = collapsed.block { return true }
            return false
        }
    }
}

enum ThinkingBlockPresentation {
    static let allowsIndividualCollapse = false
    static let alwaysShowsContent = true
}

enum RunCompletionTimePresentation {
    static let reservesHoverSlot = true
    static let movesBodyOnHover = false

    static func label(endedAt: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute, .second], from: endedAt)
        return String(
            format: "完成于 %02d:%02d:%02d",
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }
}
