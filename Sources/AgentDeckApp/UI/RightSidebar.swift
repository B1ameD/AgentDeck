import SwiftUI
import WebKit

enum RightSidebarMode: String, CaseIterable, Identifiable {
    case files = "文件"
    case browser = "浏览器"
    case review = "审核"
    var id: String { rawValue }
}

/// 右侧栏：在「文件」「浏览器」「审核」之间切换。头部含分段切换 + 关闭。
struct RightSidebar: View {
    let workingDirectory: URL
    @Binding var mode: RightSidebarMode
    @Binding var selectedFile: URL?
    @Binding var browserURL: URL?
    @Binding var topFraction: CGFloat // 文件树/编辑器上下占比，由父级常驻持有
    @Binding var expandedFolders: Set<URL> // 已展开文件夹，由父级常驻持有
    var reviewSummary: TurnDiffSummary? = nil // 本轮 agent 改动的结构化逐行 diff（「审核」标签据此渲染）
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    ForEach(RightSidebarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark").font(.caption) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("关闭侧栏")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.panelRaised)
            Rectangle().fill(Theme.border.opacity(0.72)).frame(height: 1)

            switch mode {
            case .files:
                FileExplorerView(
                    root: workingDirectory,
                    selection: $selectedFile,
                    topFraction: $topFraction,
                    expandedFolders: $expandedFolders
                )
            case .browser:
                WebBrowserView(targetURL: $browserURL)
            case .review:
                ChangeReviewView(workingDirectory: workingDirectory, summary: reviewSummary) { url in
                    // 从审核里点开文件：切到「文件」标签并选中（与聊天里点文件链接一致）。
                    selectedFile = url
                    mode = .files
                }
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border.opacity(0.72)).frame(width: 1)
        }
    }
}

/// 持有 WKWebView，供 SwiftUI 控件调用导航。
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
