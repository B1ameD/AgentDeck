import SwiftUI
import AppKit

/// 通用拖拽缩放分隔条：用 NSView 接管鼠标（mouseDownCanMoveWindow=false，避免拖到窗口本身），
/// 以 mouseDown 时的位置为基准回报「沿指定轴的累计位移」。
/// 横向：向右为正；纵向：向下为正。配套显示左右 / 上下调整光标。
struct ResizeDivider: NSViewRepresentable {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    var onBegan: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void
    /// 双击：恢复默认宽度（参考 Codex 分隔条双击复位）。可选。
    var onDoubleClick: (() -> Void)? = nil

    func makeNSView(context: Context) -> ResizeDividerNSView {
        let view = ResizeDividerNSView()
        view.configure(axis: axis, onBegan: onBegan, onChanged: onChanged, onEnded: onEnded, onDoubleClick: onDoubleClick)
        return view
    }

    func updateNSView(_ nsView: ResizeDividerNSView, context: Context) {
        nsView.configure(axis: axis, onBegan: onBegan, onChanged: onChanged, onEnded: onEnded, onDoubleClick: onDoubleClick)
    }
}

final class ResizeDividerNSView: NSView {
    private var axis: ResizeDivider.Axis = .vertical
    private var onBegan: (() -> Void)?
    private var onChanged: ((CGFloat) -> Void)?
    private var onEnded: (() -> Void)?
    private var onDoubleClick: (() -> Void)?

    private var start: CGFloat = 0

    func configure(
        axis: ResizeDivider.Axis,
        onBegan: @escaping () -> Void,
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void,
        onDoubleClick: (() -> Void)? = nil
    ) {
        self.axis = axis
        self.onBegan = onBegan
        self.onChanged = onChanged
        self.onEnded = onEnded
        self.onDoubleClick = onDoubleClick
        window?.invalidateCursorRects(for: self)
    }

    /// 关键：禁止在本视图按下时移动整个窗口。
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        // 双击复位：不进入拖拽流程。
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
            return
        }
        let p = event.locationInWindow
        start = axis == .horizontal ? p.x : p.y
        onBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = event.locationInWindow
        // 横向：向右为正；纵向：窗口 y 向上为正 → 取 start - y 使向下为正。
        onChanged?(axis == .horizontal ? p.x - start : start - p.y)
    }

    override func mouseUp(with event: NSEvent) {
        onEnded?()
    }
}
