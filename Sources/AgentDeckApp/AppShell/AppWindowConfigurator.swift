import SwiftUI
import AppKit

struct AppWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false // 仅顶部标题栏可拖窗口，避免拖背景误移整个窗口
        window.hasShadow = true
        // 最小窗口尺寸：左栏(238)+主聊天+右侧栏(最小≈300)与底部聊天框需要的最小可用空间。
        // 防止窗口被压缩到内容（聊天列表 / 输入框 / 侧栏）塌陷不可用。
        window.minSize = NSSize(width: 900, height: 600)
        if window.frame.width < 900 || window.frame.height < 600 {
            var frame = window.frame
            frame.size.width = max(frame.size.width, 900)
            frame.size.height = max(frame.size.height, 600)
            window.setFrame(frame, display: true)
        }
    }
}
