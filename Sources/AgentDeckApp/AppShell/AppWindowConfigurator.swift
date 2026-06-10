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
        // 高度 600 时页眉按钮(侧栏/终端)与 composer 控件(/model 等)会被挤出可视区(用户反馈)→ 680。
        window.minSize = NSSize(width: 900, height: 680)
        if window.frame.width < 900 || window.frame.height < 680 {
            var frame = window.frame
            frame.size.width = max(frame.size.width, 900)
            frame.size.height = max(frame.size.height, 680)
            window.setFrame(frame, display: true)
        }
    }
}
