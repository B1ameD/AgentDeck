import SwiftUI
import AppKit

/// Markdown 分段：围栏代码块 ``` 与其余文本。解析是纯函数，便于测试。
public enum MarkdownSegment: Equatable, Sendable {
    case text(String)
    case code(language: String?, content: String)
}

public enum MarkdownParser {
    /// 按 ``` 围栏把文本切成代码块/普通文本段。未闭合的尾部围栏也按代码处理。
    public static func segments(_ markdown: String) -> [MarkdownSegment] {
        var segments: [MarkdownSegment] = []
        var inCode = false
        var language: String?
        var buffer: [String] = []

        func flush(asCode: Bool) {
            let joined = buffer.joined(separator: "\n")
            if asCode {
                segments.append(.code(language: language, content: joined))
            } else if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.text(joined))
            }
            buffer.removeAll()
        }

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("```") {
                if inCode {
                    flush(asCode: true)
                    inCode = false
                    language = nil
                } else {
                    flush(asCode: false)
                    inCode = true
                    let fence = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = fence.isEmpty ? nil : fence
                }
            } else {
                buffer.append(line)
            }
        }
        flush(asCode: inCode)
        return segments
    }
}

/// 围栏代码块卡片的展示参数（纯数据，便于测试）。
enum MarkdownCodeBlockPresentation {
    /// 代码卡片相对内容宽度的占比（窄于散文、居中）。
    static let widthFraction: CGFloat = 0.8

    /// 围栏语言串 → 展示名（常见别名规范化、首字母大写；空→Code）。
    static func displayLanguage(_ language: String?) -> String {
        let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch raw {
        case "": return "Code"
        case "py", "python", "python3": return "Python"
        case "js", "javascript", "jsx", "mjs", "cjs", "node": return "JavaScript"
        case "ts", "typescript", "tsx": return "TypeScript"
        case "sh", "bash", "zsh", "shell", "shellscript", "console": return "Shell"
        case "objc", "objective-c": return "Objective-C"
        case "cpp", "c++": return "C++"
        case "json", "jsonc": return "JSON"
        case "html": return "HTML"
        case "css": return "CSS"
        case "sql": return "SQL"
        case "yaml", "yml": return "YAML"
        default:
            return raw.split(separator: "-").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        }
    }

    /// 头部语言标签字号：比代码字号大 1pt。
    static func headerFontSize(baseCodeSize: CGFloat) -> CGFloat {
        baseCodeSize + 1
    }
}

// MARK: - 块级解析

/// 一个文本段内的块级元素。解析是纯函数，便于测试。
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    /// 列表项：是否有序、显示用的标记（"•" 或 "1."）、缩进层级、正文。
    case listItem(ordered: Bool, marker: String, depth: Int, text: String)
    case quote(String)
    case rule
    /// 表格：表头 + 数据行（GFM：| 分隔，次行为 --- 分隔行）。
    case table(header: [String], rows: [[String]])
}

public enum MarkdownBlockParser {
    /// 把一个文本段拆成块级元素：标题 / 段落 / 列表项 / 引用 / 分隔线。
    /// 行内格式（粗体/斜体/行内代码/链接）留给渲染层用 AttributedString 处理。
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: "\n")
            paragraph.removeAll()
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(joined))
            }
        }
        func flushQuote() {
            let joined = quote.joined(separator: "\n")
            quote.removeAll()
            if !joined.isEmpty { blocks.append(.quote(joined)) }
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 表格：当前行含 | 且下一行是 ---|--- 分隔行（连续含 | 的行作为数据行）。
            if i + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[i + 1]) {
                flushParagraph(); flushQuote()
                let header = splitRow(trimmed)
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count {
                    let rowTrimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    guard !rowTrimmed.isEmpty, rowTrimmed.contains("|") else { break }
                    rows.append(splitRow(rowTrimmed))
                    j += 1
                }
                blocks.append(.table(header: header, rows: rows))
                i = j
                continue
            }

            if trimmed.isEmpty {                       // 空行：结束当前段落/引用
                flushParagraph(); flushQuote(); i += 1; continue
            }
            if isRule(trimmed) {                       // --- *** ___ 分隔线
                flushParagraph(); flushQuote()
                blocks.append(.rule); i += 1; continue
            }
            if let heading = parseHeading(trimmed) {   // # 标题
                flushParagraph(); flushQuote()
                blocks.append(heading); i += 1; continue
            }
            if trimmed.hasPrefix(">") {                // > 引用（连续行合并）
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                i += 1; continue
            }
            flushQuote()                               // 非引用行：先结束引用块
            if let item = parseListItem(line) {        // - / * / + / 1. 列表
                flushParagraph()
                blocks.append(item); i += 1; continue
            }
            paragraph.append(line)                     // 其余并入段落
            i += 1
        }
        flushParagraph(); flushQuote()
        return blocks
    }

    /// `#` 到 `######` + 空格（或行尾）。
    private static func parseHeading(_ s: String) -> MarkdownBlock? {
        var level = 0
        var idx = s.startIndex
        while idx < s.endIndex, s[idx] == "#", level < 6 {
            level += 1
            idx = s.index(after: idx)
        }
        guard level > 0, idx == s.endIndex || s[idx] == " " else { return nil }
        let text = String(s[idx...]).trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    /// 三个及以上相同的 `-`/`*`/`_`（已 trim）即分隔线。
    private static func isRule(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        let set = Set(s)
        return set == ["-"] || set == ["*"] || set == ["_"]
    }

    /// 列表项：前导空格按每 2 格一级算缩进；支持 `-`/`*`/`+` 与 `1.`/`1)`。
    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " }.count
        let depth = leading / 2
        let s = String(line.dropFirst(leading))

        for marker in ["- ", "* ", "+ "] where s.hasPrefix(marker) {
            return .listItem(ordered: false, marker: "•", depth: depth, text: String(s.dropFirst(2)))
        }
        let digits = s.prefix { $0.isNumber }
        if !digits.isEmpty {
            let rest = s.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return .listItem(ordered: true, marker: "\(digits).", depth: depth, text: String(rest.dropFirst(2)))
            }
        }
        return nil
    }

    /// 表格分隔行：含 `|`，每个单元格仅由 `-`/`:`/空格组成且至少一个 `-`。
    private static func isTableSeparator(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.contains("|") else { return false }
        let cells = splitRow(t)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            guard cell.contains("-"), Set(cell).isSubset(of: ["-", ":"]) else { return false }
        }
        return true
    }

    /// 拆分一行表格单元格：去掉首尾可选的 `|`，再按 `|` 切分并 trim。
    private static func splitRow(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - 渲染

/// 把内容按 Markdown 渲染：围栏代码块用等宽 + 复制按钮；其余按块级排版
/// （标题/列表/引用/分隔线），块内再用 AttributedString 渲染行内格式（粗体/斜体/行内代码/链接）。
struct MessageLinkContext {
    let workingDirectory: URL
    let fileLinks: [String]
    let openFile: (URL) -> Void
    let openWebURL: (URL) -> Void
    /// 是否在散文里检测「已存在文件名」并生成链接。流式输出的那条气泡置 false：
    /// 避免每个分片都重扫散文（provided fileLinks 本就在跑完后才赋值），跑完再以 true 重渲染一次。
    var detectFileReferences: Bool = true
}

struct MarkdownText: View {
    let content: String
    var linkContext: MessageLinkContext?

    var body: some View {
        // 按围栏切段：散文走可选中的 NSTextView 渲染器，围栏代码块走独立 SwiftUI 卡片。
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.segments(content).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    SelectableMarkdownText(content: text, linkContext: linkContext)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    HighlightedCodeView(language: language, code: code)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum FileLinkContextMenuPresentation {
    static let copyAbsoluteFolderTitle = "复制文件夹绝对路径"
    static let copyRelativeFolderTitle = "复制文件夹相对路径"
    static let openInFinderTitle = "在Finder中打开"

    static var titles: [String] {
        [copyAbsoluteFolderTitle, copyRelativeFolderTitle, openInFinderTitle]
    }

    static func absoluteFolderPath(for url: URL) -> String {
        url.deletingLastPathComponent().path
    }

    static func relativeFolderPath(for url: URL, workingDirectory: URL) -> String {
        LinkifiedText.folderRelativePath(for: url, workingDirectory: workingDirectory)
    }
}

/// 可复用的高亮代码卡片。聊天围栏代码默认使用 0.8 宽，文件预览传 nil 使用完整宽度。
struct HighlightedCodeView: View {
    let language: String?
    let code: String
    var showsHeader = true
    var widthFraction: CGFloat? = MarkdownCodeBlockPresentation.widthFraction

    @AppStorage(BundledCodeFont.storageKey) private var codeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue
    @AppStorage(CodeBlockTheme.storageKey) private var codeThemeID = CodeBlockTheme.defaultID
    @State private var copied = false

    private var theme: CodeBlockTheme { CodeBlockTheme.resolve(codeThemeID) }
    private var codeSize: CGFloat { AppFontSize.points(appFontSize) }
    private var codeFont: Font { BundledCodeFont.resolve(codeFontID).swiftUIFont(size: codeSize) }

    @ViewBuilder
    var body: some View {
        if let widthFraction {
            ProportionalWidthLayout(fraction: widthFraction) {
                card
            }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(attributedCode)
                    .font(codeFont)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.top, showsHeader ? 11 : 12)
                    .padding(.bottom, 12)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(Color(nsColor: theme.nsBorder), lineWidth: 1)
        )
        .shadow(color: Theme.shadowColor, radius: 5, y: 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(MarkdownCodeBlockPresentation.displayLanguage(language))
                .font(.system(
                    size: MarkdownCodeBlockPresentation.headerFontSize(baseCodeSize: codeSize),
                    weight: .semibold,
                    design: .monospaced
                ))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    if copied {
                        Text("已复制").font(.system(size: max(codeSize - 2, 9), weight: .medium))
                    }
                }
                .foregroundStyle(copied ? Color.green : Color.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("复制代码")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.16, green: 0.17, blue: 0.20)) // 固定深色头条
    }

    /// 语法高亮后的代码（SwiftUI scope 的 AttributedString：前景色用 Color，字体由外层 .font 提供）。
    private var attributedCode: AttributedString {
        var attributed = AttributedString(code)
        attributed.foregroundColor = Color(nsColor: theme.nsForeground)
        for span in CodeSyntaxHighlighter.highlights(code: code, language: language, palette: theme.syntaxPalette) {
            guard let stringRange = Range(span.range, in: code),
                  let low = AttributedString.Index(stringRange.lowerBound, within: attributed),
                  let high = AttributedString.Index(stringRange.upperBound, within: attributed) else { continue }
            attributed[low..<high].foregroundColor = Color(nsColor: span.color)
        }
        return attributed
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string) // 只复制原始代码，不含语言名/头部
        withAnimation(.easeOut(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { copied = false } }
        }
    }
}

private struct SelectableMarkdownText: NSViewRepresentable {
    let content: String
    let linkContext: MessageLinkContext?

    @AppStorage(InterfaceFont.storageKey) private var interfaceFontID = InterfaceFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue
    @AppStorage(BundledCodeFont.storageKey) private var selectedCodeFontID = BundledCodeFont.defaultID
    @AppStorage(CodeBlockTheme.storageKey) private var codeBlockThemeID = CodeBlockTheme.defaultID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> LinkedTextView {
        // 散文渲染器（围栏代码块已在上层拆出为 SwiftUI 卡片，这里只排版散文）。
        let textView = LinkedTextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        return textView
    }

    func updateNSView(_ textView: LinkedTextView, context: Context) {
        let font = InterfaceFont.resolve(interfaceFontID).nsFont(size: AppFontSize.points(appFontSize))
        let codeFont = BundledCodeFont.resolve(selectedCodeFontID).nsFont(size: AppFontSize.points(appFontSize))
        let codeTheme = CodeBlockTheme.resolve(codeBlockThemeID)

        // 仅在「需要检测散文文件名」时取工作目录快照与版本号（流式气泡置 detect=false → 不建索引、不付出枚举）。
        let snapshot: WorkspaceFileSnapshot
        let indexVersion: Int
        if let linkContext, linkContext.detectFileReferences {
            snapshot = WorkspaceFileIndex.shared.snapshot(for: linkContext.workingDirectory)
            indexVersion = WorkspaceFileIndex.shared.version(for: linkContext.workingDirectory)
        } else {
            snapshot = .empty
            indexVersion = 0
        }

        let renderKey = [
            content,
            linkContext?.workingDirectory.standardizedFileURL.path ?? "",
            (linkContext?.fileLinks ?? []).joined(separator: "\u{1f}"),
            linkContext?.detectFileReferences == false ? "0" : "1",
            String(indexVersion),
            interfaceFontID,
            String(appFontSize),
            selectedCodeFontID,
            codeBlockThemeID
        ].joined(separator: "\u{1e}")

        if textView.renderKey != renderKey {
            let rendered = MarkdownRenderCache.shared.rendered(for: renderKey) {
                LinkedTextRenderer.render(
                    markdown: content,
                    messageContext: linkContext,
                    font: font,
                    codeFont: codeFont,
                    codeTheme: codeTheme,
                    snapshot: snapshot
                )
            }
            textView.textStorage?.setAttributedString(rendered.text)
            textView.payloads = rendered.payloads
            textView.renderKey = renderKey
            textView.resetHeightCache() // 内容变了，旧的「按宽度记忆高度」失效
            textView.invalidateIntrinsicContentSize()
        }

        textView.workingDirectory = linkContext?.workingDirectory
        textView.openFile = linkContext?.openFile
        textView.openWebURL = linkContext?.openWebURL
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let textView = textView as? LinkedTextView else { return false }
            return textView.activate(link)
        }
    }
}

private enum LinkedTextPayload {
    case file(URL)
    case web(URL)
}

/// 渲染结果（已链接化的 NSAttributedString + 链接负载）。
private typealias RenderedMarkdown = (text: NSAttributedString, payloads: [String: LinkedTextPayload])

/// 跨 NSViewRepresentable 实例的渲染缓存（按 renderKey）：SwiftUI 频繁重建文本视图时直接命中，
/// 不必重跑 markdown 解析 + 链接化。仅主线程访问，简单 FIFO 上限淘汰。
@MainActor
private final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()
    private var store: [String: RenderedMarkdown] = [:]
    private var order: [String] = []
    private let limit = 200

    func rendered(for key: String, build: () -> RenderedMarkdown) -> RenderedMarkdown {
        if let cached = store[key] { return cached }
        let value = build()
        store[key] = value
        order.append(key)
        if order.count > limit {
            let evicted = order.removeFirst()
            store[evicted] = nil
        }
        return value
    }
}

private enum LinkedTextRenderer {
    private static let scheme = "agentdeck-link"

    static func render(
        markdown: String,
        messageContext: MessageLinkContext?,
        font: NSFont,
        codeFont: NSFont,
        codeTheme: CodeBlockTheme,
        snapshot: WorkspaceFileSnapshot
    ) -> RenderedMarkdown {
        let result = markdownAttributedString(markdown, baseFont: font, codeFont: codeFont, codeTheme: codeTheme)
        applyBaseStyle(to: result, font: font)

        guard let messageContext else {
            return (result, [:])
        }

        // 散文文件名检测仅在 detect 开启时进行（流式气泡关闭，避免逐分片重扫）。
        let detected = messageContext.detectFileReferences
            ? LinkifiedText.existingFileReferences(in: result.string, snapshot: snapshot)
            : []
        let fileLinks = Array(Set(messageContext.fileLinks + detected)).sorted()
        var payloads: [String: LinkedTextPayload] = [:]
        applyGeneratedLinks(
            to: result,
            fileLinks: fileLinks,
            workingDirectory: messageContext.workingDirectory,
            snapshot: snapshot,
            payloads: &payloads
        )
        return (result, payloads)
    }

    private static func markdownAttributedString(
        _ markdown: String,
        baseFont: NSFont,
        codeFont: NSFont,
        codeTheme: CodeBlockTheme
    ) -> NSMutableAttributedString {
        // 围栏代码块已由上层 MarkdownText 拆成 SwiftUI 卡片渲染；散文渲染器只排版块级散文。
        let result = NSMutableAttributedString(string: "")
        appendBlocks(MarkdownBlockParser.blocks(markdown), to: result, baseFont: baseFont)
        trimTrailingNewlines(result)
        if result.length == 0 {
            result.append(NSAttributedString(string: markdown, attributes: [.font: baseFont]))
        }
        return result
    }

    private static func appendBlocks(_ blocks: [MarkdownBlock], to result: NSMutableAttributedString, baseFont: NSFont) {
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                let delta: CGFloat = switch level {
                case 1: 8
                case 2: 5
                case 3: 2
                default: 0
                }
                appendInline(text, to: result, font: sizedFont(baseFont, delta: delta, weight: .semibold))
                appendString("\n\n", to: result, font: baseFont)

            case .paragraph(let text):
                appendInline(text, to: result, font: baseFont)
                appendString("\n\n", to: result, font: baseFont)

            case .listItem(let ordered, let marker, let depth, let text):
                let prefix = String(repeating: "  ", count: max(depth, 0)) + (ordered ? marker : "•") + " "
                appendString(prefix, to: result, font: baseFont)
                appendInline(text, to: result, font: baseFont)
                appendString("\n", to: result, font: baseFont)

            case .quote(let text):
                appendString("▌ ", to: result, font: baseFont, color: NSColor.secondaryLabelColor)
                appendInline(text, to: result, font: baseFont, color: NSColor.secondaryLabelColor)
                appendString("\n\n", to: result, font: baseFont)

            case .rule:
                appendString("────────\n\n", to: result, font: baseFont, color: NSColor.separatorColor)

            case .table(let header, let rows):
                let lines = ([header] + rows).map { row in
                    row.joined(separator: " | ")
                }
                result.append(NSAttributedString(
                    string: lines.joined(separator: "\n") + "\n\n",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)]
                ))
            }
        }
    }

    private static func appendInline(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor = .labelColor
    ) {
        let attributed: NSMutableAttributedString
        if let parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            attributed = NSMutableAttributedString(attributedString: NSAttributedString(parsed))
        } else {
            attributed = NSMutableAttributedString(string: text)
        }
        let range = NSRange(location: 0, length: attributed.length)
        if range.length > 0 {
            attributed.enumerateAttribute(.font, in: range) { value, subrange, _ in
                if value == nil {
                    attributed.addAttribute(.font, value: font, range: subrange)
                }
            }
            attributed.addAttribute(.foregroundColor, value: color, range: range)
        }
        result.append(attributed)
    }

    private static func appendString(
        _ string: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor = .labelColor
    ) {
        result.append(NSAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: color]
        ))
    }

    private static func sizedFont(_ baseFont: NSFont, delta: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: max(8, baseFont.pointSize + delta), weight: weight)
    }

    private static func trimTrailingNewlines(_ text: NSMutableAttributedString) {
        while text.length > 0, text.string.hasSuffix("\n") {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
    }

    private static func applyBaseStyle(to attributed: NSMutableAttributedString, font: NSFont) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineSpacing = 1.5
        attributed.enumerateAttribute(.foregroundColor, in: fullRange) { value, range, _ in
            if value == nil {
                attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        attributed.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            if value == nil {
                attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
            }
        }

        attributed.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                attributed.addAttribute(.font, value: font, range: range)
            }
        }
    }

    private static func applyGeneratedLinks(
        to attributed: NSMutableAttributedString,
        fileLinks: [String],
        workingDirectory: URL,
        snapshot: WorkspaceFileSnapshot,
        payloads: inout [String: LinkedTextPayload]
    ) {
        let text = attributed.string
        let parts = LinkifiedText.parts(in: text, fileLinks: fileLinks, workingDirectory: workingDirectory)
        var location = 0
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]

        for part in parts {
            let display: String
            switch part {
            case .text(let value): display = value
            case .file(let label, _): display = label
            case .webURL(let value): display = value
            }

            let length = (display as NSString).length
            defer { location += length }
            guard length > 0 else { continue }
            let range = NSRange(location: location, length: length)

            switch part {
            case .text:
                continue
            case .file(let label, let relativePath):
                let id = UUID().uuidString
                let url = LinkifiedText.resolvedFileURL(
                    label: label,
                    relativePath: relativePath,
                    workingDirectory: workingDirectory,
                    snapshot: snapshot
                )
                payloads[id] = .file(url)
                if let linkURL = URL(string: "\(scheme)://\(id)") {
                    var attributes = linkAttributes
                    attributes[.link] = linkURL
                    attributed.addAttributes(attributes, range: range)
                }
            case .webURL(let value):
                guard let url = URL(string: value) else { continue }
                let id = UUID().uuidString
                payloads[id] = .web(url)
                if let linkURL = URL(string: "\(scheme)://\(id)") {
                    var attributes = linkAttributes
                    attributes[.link] = linkURL
                    attributed.addAttributes(attributes, range: range)
                }
            }
        }
    }

    static func payloadID(from link: Any) -> String? {
        if let url = link as? URL, url.scheme == scheme {
            return url.host
        }
        if let string = link as? String,
           let url = URL(string: string),
           url.scheme == scheme {
            return url.host
        }
        return nil
    }
}


private final class LinkedTextView: NSTextView {
    var payloads: [String: LinkedTextPayload] = [:]
    var renderKey: String?
    var workingDirectory: URL?
    var openFile: ((URL) -> Void)?
    var openWebURL: ((URL) -> Void)?

    // 按宽度记忆已测高度：内在高度只随「宽度 + 内容」变化，与当前 frame 高度无关。
    // 缓存后，侧栏拖拽 / 窗口缩放产生的「等宽逐帧 setFrameSize」直接命中缓存，
    // 不再每帧跑 ensureLayout + usedRect（这正是右侧栏拖拽 101% CPU 的根因）。
    private var cachedHeight: CGFloat?
    private var cachedWidth: CGFloat = -1

    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        let width = max(bounds.width, 1)
        if let cachedHeight, abs(width - cachedWidth) < 0.5 {
            return NSSize(width: NSView.noIntrinsicMetric, height: cachedHeight)
        }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = ceil(used.height)
        cachedHeight = height
        cachedWidth = width
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        // 仅在「宽度」变化时才作废内在尺寸：高度变化不影响内在高度，
        // 若每次 setFrameSize 都 invalidate 会与 SwiftUI 布局形成重测回环（resize 卡顿）。
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            cachedHeight = nil
            invalidateIntrinsicContentSize()
        }
    }

    /// 内容（attributedString / 字体）变化后清掉高度缓存，强制按当前宽度重测一次。
    func resetHeightCache() {
        cachedHeight = nil
        cachedWidth = -1
    }

    func activate(_ link: Any) -> Bool {
        guard let payload = payload(for: link) else {
            if let url = externalURL(from: link) {
                if let openWebURL {
                    openWebURL(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
                return true
            }
            return false
        }
        switch payload {
        case .file(let url):
            openFile?(url)
        case .web(let url):
            openWebURL?(url)
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let payload = payload(at: event),
              case .file(let url) = payload else {
            return super.menu(for: event)
        }

        let menu = NSMenu()
        let absolute = NSMenuItem(
            title: FileLinkContextMenuPresentation.copyAbsoluteFolderTitle,
            action: #selector(copyAbsoluteFolder(_:)),
            keyEquivalent: ""
        )
        absolute.target = self
        absolute.representedObject = url
        menu.addItem(absolute)

        let relative = NSMenuItem(
            title: FileLinkContextMenuPresentation.copyRelativeFolderTitle,
            action: #selector(copyRelativeFolder(_:)),
            keyEquivalent: ""
        )
        relative.target = self
        relative.representedObject = url
        menu.addItem(relative)

        let finder = NSMenuItem(
            title: FileLinkContextMenuPresentation.openInFinderTitle,
            action: #selector(openInFinder(_:)),
            keyEquivalent: ""
        )
        finder.target = self
        finder.representedObject = url
        menu.addItem(finder)

        return menu
    }

    @objc private func copyAbsoluteFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        copy(FileLinkContextMenuPresentation.absoluteFolderPath(for: url))
    }

    @objc private func copyRelativeFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        copy(FileLinkContextMenuPresentation.relativeFolderPath(
            for: url,
            workingDirectory: workingDirectory ?? url.deletingLastPathComponent()
        ))
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func payload(at event: NSEvent) -> LinkedTextPayload? {
        guard let layoutManager, let textContainer, string.utf16.count > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard point.x >= 0, point.y >= 0 else { return nil }
        let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
        guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
        let charIndex = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard charIndex < string.utf16.count,
              let link = textStorage?.attribute(.link, at: charIndex, effectiveRange: nil) else {
            return nil
        }
        return payload(for: link)
    }

    private func payload(for link: Any) -> LinkedTextPayload? {
        guard let id = LinkedTextRenderer.payloadID(from: link) else { return nil }
        return payloads[id]
    }

    private func externalURL(from link: Any) -> URL? {
        if let url = link as? URL, url.scheme != "agentdeck-link" {
            return url
        }
        if let string = link as? String,
           let url = URL(string: string),
           url.scheme != "agentdeck-link" {
            return url
        }
        return nil
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

}

// （原 SwiftUI 原生渲染路径的 FileReferenceButton / WebReferenceButton / InlineFlowLayout /
//  CodeBlockView 已随死代码移除；实时渲染走 SelectableMarkdownText → LinkedTextRenderer。）
