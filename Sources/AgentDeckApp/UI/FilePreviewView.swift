import SwiftUI

enum FilePreviewPresentation: Equatable {
    case markdown
    case code(language: String)
    case plainText
    case unsupported

    static func presentation(for kind: FilePreviewKind) -> FilePreviewPresentation {
        switch kind {
        case .markdown:
            return .markdown
        case .code(let language):
            return .code(language: language)
        case .plainText:
            return .plainText
        case .unsupported:
            return .unsupported
        }
    }
}

extension FilePreviewLoadError {
    var message: String {
        switch self {
        case .outsideWorkspace:
            return "文件不在当前工作目录中"
        case .missing:
            return "文件不存在"
        case .tooLarge:
            return "文件过大（>1 MB），无法预览或编辑"
        case .unsupported:
            return "暂不支持预览此文件"
        case .unreadable:
            return "无法读取文件"
        }
    }
}

struct FilePreviewView: View {
    @Bindable var controller: FilePreviewController

    @AppStorage(BundledCodeFont.storageKey) private var codeFontID = BundledCodeFont.defaultID
    @AppStorage(AppFontSize.storageKey) private var appFontSize = AppFontSize.defaultValue

    private var codeFont: Font {
        BundledCodeFont.resolve(codeFontID).swiftUIFont(size: AppFontSize.points(appFontSize))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
            content
        }
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .appFont(relative: -1)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Text(controller.selectedFile?.lastPathComponent ?? "未选择文件")
                    .appFont(relative: -1, weight: .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if controller.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 7, height: 7)
                        .help("有未保存改动")
                }
                Spacer(minLength: 4)
                Button(action: { controller.save() }) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.isDirty ? Theme.accentStrong : Color.secondary)
                .disabled(!controller.isDirty || controller.error != nil)
                .help("保存")
            }

            Picker("", selection: $controller.displayMode) {
                ForEach(FilePreviewDisplayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.selectedFile == nil || controller.error != nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.panelRaised)
    }

    @ViewBuilder
    private var content: some View {
        if controller.selectedFile == nil {
            emptyState
        } else if let error = controller.error {
            errorState(error.message)
        } else if controller.displayMode == .edit {
            editor
        } else if let kind = controller.kind {
            preview(kind)
        } else {
            errorState("无法识别文件类型")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: "doc.text.magnifyingglass")
                .appFont(relative: 11, weight: .semibold)
                .foregroundStyle(Theme.accent)
            Text("从「文件」中选择一个文件")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .appFont(relative: 9, weight: .semibold)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func preview(_ kind: FilePreviewKind) -> some View {
        switch FilePreviewPresentation.presentation(for: kind) {
        case .markdown:
            ScrollView {
                MarkdownText(content: controller.text)
                    .padding(16)
            }
        case .code(let language):
            ScrollView {
                HighlightedCodeView(
                    language: language,
                    code: controller.text,
                    showsHeader: true,
                    widthFraction: nil
                )
                .padding(12)
            }
        case .plainText:
            ScrollView([.horizontal, .vertical]) {
                Text(controller.text)
                    .font(codeFont)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(14)
            }
        case .unsupported:
            errorState("暂不支持预览此文件")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            if let saveErrorMessage = controller.saveErrorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("保存失败：\(saveErrorMessage)")
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .appFont(relative: -2)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.08))
            }
            TextEditor(text: $controller.text)
                .font(codeFont)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.canvas)
        }
    }

    private var fileIcon: String {
        guard let kind = controller.kind else { return "doc" }
        switch kind {
        case .markdown, .plainText:
            return "doc.text"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .unsupported:
            return "doc"
        }
    }
}
