import SwiftUI
import WebKit

enum RightSidebarMode: String, CaseIterable, Identifiable {
    case files = "文件"
    case preview = "预览"
    case browser = "浏览器"
    case review = "审核"
    /// 委派任务明细：上下文标签（不进分段选择器，由点击「委派任务」行进入，带返回）。
    case subagent = "子任务"
    var id: String { rawValue }

    /// 分段选择器里展示的常驻标签（子任务是上下文进入的，不在其中）。
    static var primaryCases: [RightSidebarMode] { [.files, .preview, .browser, .review] }
}

enum RightSidebarNavigation {
    static let destinationForOpenedFile: RightSidebarMode = .preview
}

/// 右侧栏：文件树、文件预览、浏览器和审核是彼此独立的标签。
struct RightSidebar: View {
    let workingDirectory: URL
    @Binding var mode: RightSidebarMode
    @Bindable var previewController: FilePreviewController
    @Binding var browserURL: URL?
    @Binding var expandedFolders: Set<URL> // 已展开文件夹，由父级常驻持有
    var reviewSummary: TurnDiffSummary? // 本轮 agent 改动的结构化逐行 diff（「审核」标签据此渲染）
    var selectedSubagent: SubagentTask? // 「子任务」标签展示的委派明细
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if mode == .subagent {
                    Button { requestNavigation(.switchMode(.files)) } label: {
                        Label("委派任务明细", systemImage: "chevron.left")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accentStrong)
                    .help("返回")
                    Spacer()
                } else {
                    Picker("", selection: Binding(
                        get: { mode },
                        set: { requestNavigation(.switchMode($0)) }
                    )) {
                        ForEach(RightSidebarMode.primaryCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
                Button { requestNavigation(.closeSidebar) } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭侧栏")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.panelRaised)
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)

            switch mode {
            case .subagent:
                SubagentDetailView(task: selectedSubagent)
            case .files:
                FileExplorerView(
                    root: workingDirectory,
                    selectedFile: previewController.selectedFile,
                    expandedFolders: $expandedFolders,
                    onOpenFile: { requestNavigation(.openFile($0)) }
                )
            case .preview:
                FilePreviewView(controller: previewController)
            case .browser:
                WebBrowserView(targetURL: $browserURL)
            case .review:
                ChangeReviewView(workingDirectory: workingDirectory, summary: reviewSummary) { url in
                    requestNavigation(.openFile(url))
                }
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border.opacity(0.72)).frame(width: 1)
        }
        .confirmationDialog(
            "保存对文件的修改？",
            isPresented: Binding(
                get: { previewController.isShowingUnsavedChangesConfirmation },
                set: { presented in
                    if !presented {
                        previewController.resolvePendingNavigation(.cancel)
                    }
                }
            )
        ) {
            Button("保存并继续") {
                previewController.resolvePendingNavigation(.save)
            }
            Button("放弃改动", role: .destructive) {
                previewController.resolvePendingNavigation(.discard)
            }
            Button("取消", role: .cancel) {
                previewController.resolvePendingNavigation(.cancel)
            }
        } message: {
            Text("当前文件包含未保存改动。")
        }
    }

    private func requestNavigation(_ navigation: FilePreviewNavigation) {
        if case .switchMode(let target) = navigation, target == mode {
            return
        }
        previewController.request(navigation) { committed in
            switch committed {
            case .openFile(let url):
                previewController.open(url)
                mode = RightSidebarNavigation.destinationForOpenedFile
            case .switchMode(let target):
                mode = target
            case .closeSidebar:
                onClose()
            case .changeWorkspace(let url):
                previewController.setWorkspace(url)
            }
        }
    }
}

/// 持有 WKWebView，供 SwiftUI 控件调用导航。
/// 委派任务明细：派发的子代理类型/描述/完整 prompt + 子代理返回的最终结果。
/// 注：Claude 的 headless 输出不暴露子代理逐步内部对话，故展示的是「派发内容 + 最终结果」。
struct SubagentDetailView: View {
    let task: SubagentTask?

    var body: some View {
        if let task {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(task)
                    if !task.taskDescription.isEmpty {
                        section("描述", text: task.taskDescription, mono: false)
                    }
                    section("派发的指令", text: task.prompt.isEmpty ? "（无）" : task.prompt, mono: true)
                    resultSection(task)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "person.2")
                    .appFont(relative: 10)
                    .foregroundStyle(.secondary)
                Text("没有选中的委派任务")
                    .appFont(relative: -1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ task: SubagentTask) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.fill").foregroundStyle(Theme.accent)
            Text(task.agentType.isEmpty ? "子任务" : task.agentType)
                .appFont(relative: 0, weight: .semibold)
            Spacer(minLength: 8)
            statusBadge(task)
        }
    }

    @ViewBuilder
    private func statusBadge(_ task: SubagentTask) -> some View {
        if task.isError {
            Text("出错").appFont(relative: -2, weight: .medium)
                .foregroundStyle(.red)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.14)))
        } else if task.result != nil {
            Label("已完成", systemImage: "checkmark.circle.fill")
                .appFont(relative: -2, weight: .medium).foregroundStyle(.green)
        } else {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("进行中").appFont(relative: -2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ task: SubagentTask) -> some View {
        if let result = task.result, !result.isEmpty {
            section(task.isError ? "结果（出错）" : "子代理结果", text: result, mono: false)
        } else if task.result == nil {
            section("子代理结果", text: "进行中…", mono: false)
        } else {
            section("子代理结果", text: "（空）", mono: false)
        }
    }

    private func section(_ title: String, text: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .appFont(relative: -2, weight: .semibold)
                .foregroundStyle(Theme.accentStrong)
            Group {
                if mono {
                    Text(text).font(.system(.caption, design: .monospaced))
                } else {
                    Text(text).appFont(relative: -1)
                }
            }
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
        }
    }
}

@MainActor
final class WebController: ObservableObject {
    let webView = WKWebView()

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
}

/// 简易内嵌浏览器：地址栏 + 前进/后退/刷新 + WKWebView。
struct WebBrowserView: View {
    @Binding var targetURL: URL?
    @StateObject private var controller = WebController()
    @State private var address = "https://www.google.com"
    @State private var started = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { controller.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                Button { controller.goForward() } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                Button { controller.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                TextField("输入网址", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
                Button(action: go) {
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accentStrong)
                .frame(width: 26, height: 24)
                .background(Theme.selected, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                .help("前往")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.panelRaised)
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)
            WebViewContainer(webView: controller.webView)
        }
        .onAppear {
            guard !started else { return }
            started = true
            if let targetURL {
                load(targetURL)
            } else {
                go()
            }
        }
        .onChange(of: targetURL) { _, url in
            guard let url else { return }
            load(url)
        }
    }

    private func go() {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        load(url)
    }

    private func load(_ url: URL) {
        address = url.absoluteString
        controller.load(url)
    }
}

struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
