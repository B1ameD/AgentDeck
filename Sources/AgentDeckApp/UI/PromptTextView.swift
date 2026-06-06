import SwiftUI
import AppKit

struct PromptTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    /// 处理 Tab：返回 true 表示已消费（斜杠补全 / 切换模式）；false 则走默认 Tab 行为。
    var onTab: () -> Bool = { false }
    /// Ctrl+T：循环推理强度（参考 opencode 的 variants 切换）。
    var onCtrlT: () -> Void = {}
    /// 改变此值会把焦点重新交回输入框（点击菜单补全后用）。
    var focusToken: Int = 0
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Esc：返回 true 表示已消费（如关闭斜杠/模型菜单）；false 走默认行为。
    var onEscape: () -> Bool = { false }
    /// 拖入文件 / 图片时作为附件加入队列，而不是把文件路径插入输入框。
    var onAttachFiles: ([URL]) -> Void = { _ in }
    /// 内容高度变化时回报（让输入框随内容自适应增高）。
    var onHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onSubmit: onSubmit,
            onTab: onTab,
            onCtrlT: onCtrlT,
            onEscape: onEscape,
            onAttachFiles: onAttachFiles,
            onHeightChange: onHeightChange
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // 内容未溢出（高度未达 168）时整条滚动条（滑轨+滑块）隐藏；溢出时一起出现。
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let textView = PlaceholderPromptTextView(frame: .zero)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        scrollView.documentView = textView
        _ = textView.layoutManager // 强制回退 TextKit 1，确保 layoutManager 可用于测量内容高度
        textView.delegate = context.coordinator
        textView.font = font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.onAttachFiles = { [weak coordinator = context.coordinator] urls in
            coordinator?.onAttachFiles(urls)
        }
        context.coordinator.textView = textView
        context.coordinator.lastFocusToken = focusToken
        // 监听 textView 尺寸变化（内容增减 / 宽度变化都会改变行高），用于回报内容高度。
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        // 始终刷新闭包，确保拿到的是当前 render 的处理逻辑。
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onTab = onTab
        context.coordinator.onCtrlT = onCtrlT
        context.coordinator.onEscape = onEscape
        context.coordinator.onAttachFiles = onAttachFiles
        context.coordinator.onHeightChange = onHeightChange
        textView.font = font
        if let textView = textView as? PlaceholderPromptTextView {
            textView.placeholder = placeholder
        }

        // 仅当文本被外部改动（发送后清空、或编程式回填如选中 /model）时进入：把光标移到末尾，
        // 这样回填后用户接着输入是追加而非插在中间。用户自己打字时 string 已等于 text，
        // 不会进入此分支，光标不受影响。
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            context.coordinator.reportHeight()
        }

        // 点击菜单补全会把焦点抢到按钮上；focusToken 变化时把第一响应者交回输入框。
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        var onTab: () -> Bool
        var onCtrlT: () -> Void
        var onEscape: () -> Bool
        var onAttachFiles: ([URL]) -> Void
        var onHeightChange: (CGFloat) -> Void
        weak var textView: NSTextView?
        var lastFocusToken = 0
        private var lastReportedHeight: CGFloat = -1

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onTab: @escaping () -> Bool,
            onCtrlT: @escaping () -> Void,
            onEscape: @escaping () -> Bool,
            onAttachFiles: @escaping ([URL]) -> Void,
            onHeightChange: @escaping (CGFloat) -> Void
        ) {
            _text = text
            self.onSubmit = onSubmit
            self.onTab = onTab
            self.onCtrlT = onCtrlT
            self.onEscape = onEscape
            self.onAttachFiles = onAttachFiles
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            text = textView?.string ?? ""
            reportHeight()
        }

        @MainActor @objc func frameDidChange() {
            reportHeight()
        }

        /// 测量文本内容高度（含上下内边距）并回报；去重以避免重复触发状态更新。
        @MainActor func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let height = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            onHeightChange(height)
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    textView.insertNewline(nil)
                } else {
                    onSubmit()
                }
                return true
            case #selector(NSResponder.insertTab(_:)):
                // 斜杠态：Tab 补全；否则切换交互模式。返回是否已消费。
                return onTab()
            case #selector(NSResponder.transpose(_:)):
                // Ctrl+T：切换推理强度（拦掉默认的字符转置）。
                onCtrlT()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                // Esc：关闭斜杠/模型菜单（已消费则不再走默认行为）。
                return onEscape()
            default:
                return false
            }
        }
    }
}

enum PromptAttachmentDrop {
    @MainActor
    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return normalizedFileURLs(objects.compactMap { object in
            if let url = object as? URL { return url }
            if let url = object as? NSURL { return url as URL }
            return nil
        })
    }

    static func normalizedFileURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        var normalized: [URL] = []
        for url in urls where url.isFileURL {
            let fileURL = url.standardizedFileURL
            guard seen.insert(fileURL.path).inserted else { continue }
            normalized.append(fileURL)
        }
        return normalized
    }
}

private final class PlaceholderPromptTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onAttachFiles: ([URL]) -> Void = { _ in }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let font = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let padding = textContainer?.lineFragmentPadding ?? 0
        let rect = NSRect(
            x: textContainerInset.width + padding,
            y: textContainerInset.height,
            width: max(0, bounds.width - textContainerInset.width * 2 - padding * 2),
            height: max(0, bounds.height - textContainerInset.height * 2)
        )
        placeholder.draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        PromptAttachmentDrop.fileURLs(from: sender.draggingPasteboard).isEmpty
            ? super.draggingEntered(sender)
            : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        attachFiles(from: sender.draggingPasteboard) || super.performDragOperation(sender)
    }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        attachFiles(from: pasteboard) || super.readSelection(from: pasteboard, type: type)
    }

    private func attachFiles(from pasteboard: NSPasteboard) -> Bool {
        let urls = PromptAttachmentDrop.fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        onAttachFiles(urls)
        return true
    }
}
